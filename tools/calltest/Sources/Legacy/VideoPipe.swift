/// Video out: frames from the camera (or, testing, a drawn pattern) become H.264 in real time,
/// low-latency rate control, no reordering, a keyframe on request or every four seconds, encoded
/// once for everyone in the call. Size and bitrate follow what the others report (CallMedia). Video
/// in: a `VideoDecoder` per remote turns whole frames back into pictures ready to show at once.
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

final class VideoPipe: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
	enum Tier: Equatable { case hd, sd
		var longSide: Int { self == .hd ? 1280 : 640 }
	}
	private let test: Bool
	private let send: @Sendable (Data, Bool) -> Void
	/// What I send, as it leaves the camera (for my own picture).
	var onLocal: (@Sendable (CMSampleBuffer) -> Void)?

	private let queue = DispatchQueue(label: "baud.video", qos: .userInteractive)
	private var capture: AVCaptureSession?
	private var encoder: VTCompressionSession?
	private var encoderSize: (Int32, Int32) = (0, 0)
	private var forceKey = true
	private var timer: DispatchSourceTimer?
	private var pool: CVPixelBufferPool?
	private var tick = 0
	private var pattern: TestPattern?

	/// Settable from any thread; applied on the video queue.
	var bitrate = 1_000_000 { didSet { queue.async { self.applyRate() } } }
	var tier: Tier = .hd { didSet { if oldValue != tier { queue.async { self.resetEncoder() } } } }
	/// The link is too weak for video (CallMedia): nothing is encoded until it calms.
	var paused = false
	/// The person's switch. Off stops the capture itself, so the camera's light goes out.
	private(set) var cameraOn = true
	private(set) var front = true

	private(set) var encoded = 0, keyframes = 0, bytesSent = 0

	init(test: Bool, send: @escaping @Sendable (Data, Bool) -> Void) { self.test = test; self.send = send }

	func start() throws {
		if test { startPattern(); return }
		if cameraOn { try startCamera() }
	}

	func stop() {
		timer?.cancel(); timer = nil
		let c = capture; capture = nil
		queue.async { c?.stopRunning() }
		queue.sync {
			if let e = encoder { VTCompressionSessionInvalidate(e) }; encoder = nil
		}
	}

	func keyframe() { queue.async { self.forceKey = true } }

	// MARK: the camera

	private func startCamera() throws {
		let s = AVCaptureSession()
		#if os(iOS)
		// The call's audio session is CallKit's and the voice's: the camera leaves it alone.
		s.automaticallyConfiguresApplicationAudioSession = false
		#endif
		s.beginConfiguration()
		if s.canSetSessionPreset(.hd1280x720) { s.sessionPreset = .hd1280x720 } else { s.sessionPreset = .high }
		guard let device = camera(front: front) else { throw CallError.video("No camera here.") }
		let input = try AVCaptureDeviceInput(device: device)
		guard s.canAddInput(input) else { throw CallError.video("The camera is busy.") }
		s.addInput(input)
		let out = AVCaptureVideoDataOutput()
		out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
		out.alwaysDiscardsLateVideoFrames = true
		out.setSampleBufferDelegate(self, queue: queue)
		guard s.canAddOutput(out) else { throw CallError.video("The camera is busy.") }
		s.addOutput(out)
		orient(out)
		s.commitConfiguration()
		try? device.lockForConfiguration()
		if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) { device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30); device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30) }
		device.unlockForConfiguration()
		capture = s
		queue.async { s.startRunning() }
	}

	private func camera(front: Bool) -> AVCaptureDevice? {
		#if os(iOS)
		return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
		#else
		return AVCaptureDevice.default(for: .video)
		#endif
	}

	/// Upright on the iPhone, which is held in portrait during a call.
	private func orient(_ out: AVCaptureVideoDataOutput) {
		#if os(iOS)
		if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
		#endif
	}

	/// The other camera, on the iPhone.
	func flip() {
		#if os(iOS)
		queue.async { [self] in
			guard let s = capture, let current = s.inputs.first as? AVCaptureDeviceInput, let next = camera(front: !front), let input = try? AVCaptureDeviceInput(device: next) else { return }
			s.beginConfiguration()
			s.removeInput(current)
			if s.canAddInput(input) { s.addInput(input); front.toggle() } else { s.addInput(current) }
			if let out = s.outputs.first as? AVCaptureVideoDataOutput { orient(out) }
			s.commitConfiguration()
			forceKey = true
		}
		#endif
	}

	func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
		guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
		if let local = Self.displayable(pb) { onLocal?(local) }
		encode(pb, at: CMSampleBufferGetPresentationTimeStamp(sample))
	}

	// MARK: the test pattern

	/// Thirty frames a second of something that moves: a slow wash of colour, a soft disc on a
	/// path, a bar that sweeps. Enough motion that the encoder works for its frames.
	private func startPattern() {
		let t = DispatchSource.makeTimerSource(queue: queue)
		t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
		t.setEventHandler { [weak self] in self?.drawPattern() }
		t.resume()
		timer = t
	}

	private func drawPattern() {
		let w = 1280, h = 720
		if pool == nil {
			let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
			CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
		}
		var buf: CVPixelBuffer?
		guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf) == kCVReturnSuccess, let pb = buf else { return }
		// calltest: the same detailed picture the new engine's test call draws (the 0.2.15 one was a
		// plain wash an encoder barely spends on), with the time in it, for latency read off the
		// decoded picture.
		if pattern == nil { pattern = TestPattern(width: w, height: h) }
		pattern?.draw(into: pb, time: Double(tick) / 30, stamp: TestPattern.stamp())
		tick += 1
		guard cameraOn else { return }
		if let local = Self.displayable(pb) { onLocal?(local) }
		encode(pb, at: CMTime(value: CMTimeValue(tick), timescale: 30))
	}

	private static func color(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
		// HSB to RGB, enough for a wash of colour.
		let i = Int(h * 6) % 6, f = h * 6 - CGFloat(Int(h * 6)), p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
		let (r, g, bl): (CGFloat, CGFloat, CGFloat) = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i]
		return CGColor(red: r, green: g, blue: bl, alpha: 1)
	}

	// MARK: encode

	func setCamera(_ on: Bool) {
		guard on != cameraOn else { return }
		cameraOn = on
		if test { return }
		if on { if let c = capture { queue.async { c.startRunning(); self.forceKey = true } } else { try? startCamera() } }
		else { let c = capture; queue.async { c?.stopRunning() } }
	}

	private func encode(_ pb: CVPixelBuffer, at pts: CMTime) {
		guard cameraOn, !paused else { return }
		let (w, h) = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
		let scale = min(1, Double(tier.longSide) / Double(max(w, h)))
		let size = (Int32(Double(w) * scale) & ~1, Int32(Double(h) * scale) & ~1)
		if encoder == nil || encoderSize != size { makeEncoder(size) }
		guard let e = encoder else { return }
		let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
		forceKey = false
		VTCompressionSessionEncodeFrame(e, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
			guard status == noErr, let sample, let self else { return }
			self.encoded(sample)
		}
	}

	private func makeEncoder(_ size: (Int32, Int32)) {
		if let e = encoder { VTCompressionSessionInvalidate(e) }
		encoder = nil
		var s: VTCompressionSession?
		let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
		guard VTCompressionSessionCreate(allocator: nil, width: size.0, height: size.1, codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return }
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4 as CFNumber)
		VTCompressionSessionPrepareToEncodeFrames(s)
		encoder = s; encoderSize = size; forceKey = true
		applyRate()
	}

	private func resetEncoder() {
		if let e = encoder { VTCompressionSessionInvalidate(e) }
		encoder = nil
	}

	private func applyRate() {
		guard let e = encoder else { return }
		VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
	}

	/// [flags: bit 0 key][if key: count, then each parameter set as u16 length + bytes][AVCC NAL units]
	private func encoded(_ sample: CMSampleBuffer) {
		let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
		let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
		var out = Data([key ? 1 : 0])
		if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
			var count = 0
			CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
			out.append(UInt8(count))
			for i in 0..<count {
				var ptr: UnsafePointer<UInt8>?
				var size = 0
				CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
				guard let ptr else { continue }
				out.append(contentsOf: [UInt8(size >> 8), UInt8(size & 0xff)])
				out.append(ptr, count: size)
			}
		}
		guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
		let n = CMBlockBufferGetDataLength(block)
		var bytes = Data(count: n)
		bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
		out += bytes
		encoded += 1; if key { keyframes += 1 }; bytesSent += out.count
		send(out, key)
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

/// One remote's video in: whole frames to pictures, ready to show at once. A frame it can't
/// decode (no keyframe yet, a hole behind it) asks for a keyframe.
final class VideoDecoder: @unchecked Sendable {
	var onFrame: (@Sendable (CMSampleBuffer) -> Void)?
	var onNeedKey: (@Sendable () -> Void)?
	private let queue = DispatchQueue(label: "baud.video.decode", qos: .userInteractive)
	private var decoder: VTDecompressionSession?
	private var format: CMVideoFormatDescription?
	private(set) var decoded = 0, decodeErrors = 0

	/// A whole frame from the other side.
	func receive(_ frame: Data) {
		queue.async { [weak self] in self?.decode(frame) }
	}

	func stop() {
		queue.sync { if let d = decoder { VTDecompressionSessionInvalidate(d) }; decoder = nil }
	}

	private func decode(_ frame: Data) {
		let b = [UInt8](frame)
		guard b.count > 1 else { return }
		var i = 1
		if b[0] & 1 == 1 {
			let count = Int(b[i]); i += 1
			var sets: [[UInt8]] = []
			for _ in 0..<count {
				guard i + 2 <= b.count else { return }
				let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
				guard i + n <= b.count else { return }
				sets.append(Array(b[i..<i + n])); i += n
			}
			if sets.count >= 2 { setFormat(sets) }
		}
		guard let format, let decoder, i < b.count else { onNeedKey?(); return }
		let payload = Data(b[i...])
		var block: CMBlockBuffer?
		guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return }
		payload.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
		var sample: CMSampleBuffer?
		var size = payload.count
		guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
		let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
			guard let self else { return }
			guard status == noErr, let image else { self.decodeErrors += 1; self.onNeedKey?(); return }
			self.decoded += 1
			if let s = VideoPipe.displayable(image) { self.onFrame?(s) }
		}
		if status != noErr { decodeErrors += 1; onNeedKey?() }
	}

	private func setFormat(_ sets: [[UInt8]]) {
		var fmt: CMFormatDescription?
		let pointers = sets.map { s -> UnsafePointer<UInt8> in
			let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count); p.update(from: s, count: s.count); return UnsafePointer(p)
		}
		defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
		let sizes = sets.map(\.count)
		guard CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt) == noErr, let fmt else { return }
		if let format, CMFormatDescriptionEqual(format, otherFormatDescription: fmt), decoder != nil { return }
		if let d = decoder { VTDecompressionSessionInvalidate(d) }
		format = fmt
		var d: VTDecompressionSession?
		let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
		VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &d)
		if let d { VTSessionSetProperty(d, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
		decoder = d
	}

}
