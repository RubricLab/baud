/// One remote's video in: whole frames (H.264 or HEVC, in either frame form) to pictures in the
/// hardware, then shown at an even pace. A frame in the timed form carries when it was captured; the
/// delay from there to decoded wobbles with the path, so each picture waits until the capture time
/// plus the 80th percentile of the last two seconds' delays, but never more than 15 ms past when it
/// was ready: the camera's cadence back, for the small wobble; a big one shows late rather than
/// holding every frame for it. From the
/// same stamps, and the offset between the two clocks (the rate control's), the latency from
/// capture to shown. For media 2 it keeps where decoding stands for the feedback: the newest frame
/// decoded, where its unbroken run began, and whether it needs a refresh (a frame was lost) or a
/// keyframe (the decoder couldn't go on). For media 1 it asks for a keyframe, as 0.2.15 did.
import BaudCore
import CoreMedia
import Foundation
import VideoToolbox

final class VideoDecoder: @unchecked Sendable {
	static let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)

	var onFrame: (@Sendable (CMSampleBuffer) -> Void)?
	/// Media 1: the decoder lost its place; ask for a keyframe.
	var onNeedKey: (@Sendable () -> Void)?
	/// Media 2: what it wants changed (say so now, not at the next feedback).
	var onWant: (@Sendable () -> Void)?
	/// Their clock minus mine (µs), when known.
	var offset: Int64? { get { lock.withLock { _offset } } set { lock.withLock { _offset = newValue } } }

	private let queue = DispatchQueue(label: "baud.video.decode", qos: .userInteractive)
	private let show = DispatchQueue(label: "baud.video.show", qos: .userInteractive)
	private let lock = NSLock()
	private var decoder: VTDecompressionSession?
	private var format: CMVideoFormatDescription?
	private var _offset: Int64?
	private var _decoded: UInt32?, _chain: UInt32 = 0, _want = Feedback.Want.nothing
	private var gap = false
	/// Delay from capture to decoded (µs, against the first, so the clocks' offset cancels).
	private var delays: [(at: Double, d: Int64)] = []
	private var origin: Int64?
	private var lastShow: Double = 0
	private var latencies: [Double] = []
	/// Capture to whole (all its pieces here) and to decoded (ms), as `latencies` is to shown.
	private var stages: (whole: [Double], decoded: [Double]) = ([], [])
	private(set) var decoded = 0, decodeErrors = 0, shownCount = 0, freezes = 0
	private var lastShown = 0.0
	private(set) var size = ""
	private(set) var hevcIn = false

	/// For the feedback: newest decoded, start of its unbroken run, and what it needs.
	var state: (decoded: UInt32?, chain: UInt32, want: Feedback.Want) { lock.withLock { (_decoded, _chain, _want) } }

	/// Latency, capture to shown (ms), over the last few seconds.
	var latency: [Double] { lock.withLock { latencies } }

	/// A whole frame from the other side.
	func receive(_ frame: VideoReassembler.Frame) {
		let at = micros()
		queue.async { [weak self] in self?.decode(frame, whole: at) }
	}

	/// Where the latency goes: (median, 95th percentile) in ms from capture to whole, decoded, shown.
	var breakdown: (whole: (Double, Double), decoded: (Double, Double), shown: (Double, Double))? {
		lock.withLock {
			func p(_ xs: [Double]) -> (Double, Double) {
				let s = xs.suffix(120).sorted()
				return s.isEmpty ? (.nan, .nan) : (s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)])
			}
			return latencies.isEmpty ? nil : (p(stages.whole), p(stages.decoded), p(latencies))
		}
	}

	/// ms from a capture stamp (their clock) to `at` (mine), when the offset is known.
	private func age(_ capture: UInt32, at: UInt32) -> Double? {
		guard let o = _offset else { return nil }
		return Double(since(at, capture &- UInt32(truncatingIfNeeded: o))) / 1000
	}

	/// The reassembler gave up on a frame: nothing decodes until a refresh or a keyframe.
	func lost() {
		let changed = lock.withLock { () -> Bool in gap = true; guard _want == .nothing else { return false }; _want = .refresh; return true }
		if changed { onWant?() }
		onNeedKey?()
	}

	func stop() {
		queue.sync { if let d = decoder { VTDecompressionSessionInvalidate(d) }; decoder = nil }
	}

	private func want(_ w: Feedback.Want) {
		let changed = lock.withLock { () -> Bool in guard _want.rawValue < w.rawValue else { return false }; _want = w; return true }
		if changed { onWant?() }
		onNeedKey?()
	}

	private func decode(_ fr: VideoReassembler.Frame, whole: UInt32) {
		guard let f = VideoFrame(fr.bytes) else { return }
		if f.key, f.sets.count >= 2 { setFormat(f.sets, hevc: f.hevc) }
		guard let format, let decoder else { want(.keyframe); return }
		var block: CMBlockBuffer?
		let n = f.nals.count
		guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return }
		f.nals.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) }
		var sample: CMSampleBuffer?
		var size = n
		guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
		// Decoded in place (no asynchronous flag): the handler has run by the time this returns.
		let out = Picture()
		let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
			if status == noErr { out.image = img }
		}
		guard status == noErr, let image = out.image else { decodeErrors += 1; want(.keyframe); return }
		decoded += 1
		let done = micros()
		lock.withLock {
			if let c = f.capture, let w = age(c, at: whole), let d = age(c, at: done) {
				stages.whole.append(w); stages.decoded.append(d)
				if stages.whole.count > 600 { stages.whole.removeFirst(300); stages.decoded.removeFirst(300) }
			}
			_decoded = fr.id
			if f.key || (f.refresh && gap) { _chain = fr.id; gap = false; _want = .nothing }
		}
		present(image, capture: f.capture)
	}

	/// Shown when its turn comes: capture time plus the path's recent worst delay.
	private func present(_ image: CVImageBuffer, capture: UInt32?) {
		let now = seconds()
		guard let capture else { display(image, capture: nil); return }
		let raw = since(micros(), capture)
		let wait: Double = lock.withLock {
			if origin == nil { origin = raw }
			let d = raw - origin!
			delays.append((now, d))
			delays.removeAll { now - $0.at > 2 }
			let sorted = delays.map(\.d).sorted()
			let p80 = sorted[min(sorted.count - 1, sorted.count * 80 / 100)]
			// In order, and never more than 15 ms on top of when it was ready.
			let at = max(now + min(0.015, max(0, Double(p80 - d) / 1e6)), lastShow + 0.0001)
			lastShow = at
			return at - now
		}
		if wait < 0.001 { display(image, capture: capture) }
		else {
			let later = Picture(image)
			show.asyncAfter(deadline: .now() + wait) { [weak self] in if let i = later.image { self?.display(i, capture: capture) } }
		}
	}

	private func display(_ image: CVImageBuffer, capture: UInt32?) {
		let now = seconds()
		lock.withLock {
			if lastShown > 0, now - lastShown > 0.1 { freezes += 1 }
			lastShown = now; shownCount += 1
			if let capture, let o = _offset {
				// Their capture, on my clock: their stamp less (their clock − mine).
				let ms = Double(since(micros(), capture &- UInt32(truncatingIfNeeded: o))) / 1000
				if ms > -50, ms < 10_000 { latencies.append(ms); if latencies.count > 600 { latencies.removeFirst(latencies.count - 600) } }
			}
		}
		if let s = Self.displayable(image) { onFrame?(s) }
	}

	private func setFormat(_ sets: [Data], hevc: Bool) {
		var fmt: CMFormatDescription?
		let pointers = sets.map { s -> UnsafePointer<UInt8> in
			let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count); s.copyBytes(to: p, count: s.count); return UnsafePointer(p)
		}
		defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
		let sizes = sets.map(\.count)
		let status = hevc
			? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
			: CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
		guard status == noErr, let fmt else { return }
		if let format, CMFormatDescriptionEqual(format, otherFormatDescription: fmt), decoder != nil { return }
		if let d = decoder { VTDecompressionSessionInvalidate(d) }
		format = fmt
		let dims = CMVideoFormatDescriptionGetDimensions(fmt)
		size = "\(dims.width)×\(dims.height)"; hevcIn = hevc
		var d: VTDecompressionSession?
		let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
		#if os(macOS)
		let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
		#else
		let spec: CFDictionary? = nil
		#endif
		VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &d)
		if let d { VTSessionSetProperty(d, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
		decoder = d
	}

	/// A picture as a sample buffer a display layer shows the moment it gets it.
	static func displayable(_ image: CVImageBuffer) -> CMSampleBuffer? {
		var fmt: CMVideoFormatDescription?
		guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
		var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
		var s: CMSampleBuffer?
		guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &s) == noErr, let s else { return nil }
		if let a = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true), CFArrayGetCount(a) > 0 {
			let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
			CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
		}
		return s
	}
}

/// A decoded picture handed between threads (the decoder's handler, the queue that shows it).
private final class Picture: @unchecked Sendable {
	var image: CVImageBuffer?
	init(_ image: CVImageBuffer? = nil) { self.image = image }
}
