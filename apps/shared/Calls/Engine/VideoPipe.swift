/// Video out: frames from the camera (or, testing, the drawn pattern) become HEVC or H.264 in the
/// hardware encoder, in real time: low-latency rate control, no reordering, encoded once for
/// everyone in the call. The camera runs at the best it has of 1080p60, 1080p30, 720p60, 720p30.
/// What goes out is chosen by the rate (CallMedia): a size (`height`, the short side, never above
/// the camera's) and a frame rate (every frame, or every other), and the bitrate. Long-term
/// references are on: every frame comes back with a token, the receivers' feedback says which
/// frames they have, and those tokens go back to the encoder (`acked`); after a loss, `refresh()`
/// makes the next frame one that refers only to a picture everyone has, in place of a keyframe.
/// A keyframe on request; every four seconds as well while a 0.2.15 device is in the call (it has
/// no other way back after a loss).
import AVFoundation
import BaudCore
import CoreMedia
import Foundation
import VideoToolbox

final class VideoPipe: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
	/// One encoded frame, before it's put in either form for the wire.
	struct Encoded {
		var id: UInt32
		var key: Bool, refresh: Bool, hevc: Bool
		/// When it was captured (µs, this device's clock).
		var capture: UInt32
		var sets: [Data]
		var nals: Data
		/// Its long-term reference token, to hand back once everyone has it, and which encoder
		/// session gave it (a token means nothing to the next one).
		var token: Int?
		var session: Int
	}

	/// The hardware here encodes HEVC: from the list of encoders, so asking costs no session (it's
	/// asked as a call connects). Should its low-latency mode still refuse, the encoder falls back to
	/// H.264 and says so in each frame.
	static let hevcEncode: Bool = {
		var list: CFArray?
		guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
		return encoders.contains { e in
			(e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_HEVC
				&& (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false)
		}
	}()

	private let test: Bool
	private let send: @Sendable (Encoded) -> Void
	/// What I send, as it leaves the camera (for my own picture).
	var onLocal: (@Sendable (CMSampleBuffer) -> Void)?

	private let queue = DispatchQueue(label: "baud.video", qos: .userInteractive)
	/// Where old encoders go to be put away. Putting one away waits on the system's encoder, which
	/// has been seen to stall for good; waiting here, it stalls nobody else.
	private let retired = DispatchQueue(label: "baud.video.retired", qos: .utility)
	private var capture: AVCaptureSession?
	private var encoder: VTCompressionSession?
	private var encoderShape: (w: Int32, h: Int32, hevc: Bool)?
	private var generation = 0
	private var forceKey = true
	private var forceRefresh = false
	private var timer: DispatchSourceTimer?
	private var pool: CVPixelBufferPool?
	private var pattern: TestPattern?
	private var tick = 0
	private var lastEncoded: Double?
	private let out = NSLock()
	private var nextId: UInt32 = 0

	/// Settable from any thread; applied on the video queue.
	var bitrate = 1_500_000 { didSet { queue.async { self.applyRate() } } }
	/// The short side to encode at, at most the camera's.
	var height = 720 { didSet { if oldValue != height { queue.async { self.resetEncoder() } } } }
	var fps = 30 { didSet { if oldValue != fps { queue.async { self.applyRate() } } } }
	var hevc = false { didSet { if oldValue != hevc { queue.async { self.resetEncoder() } } } }
	/// Tokens of frames every receiver has, newest last.
	var acked: [Int] { get { out.withLock { _acked } } set { out.withLock { _acked = newValue } } }
	private var _acked: [Int] = []
	/// A 0.2.15 device is in the call: a keyframe every four seconds for it.
	var periodicKeys = true { didSet { if oldValue != periodicKeys { queue.async { self.applyKeys() } } } }
	/// The link is too weak for video (CallMedia): nothing is encoded until it calms.
	var paused = false
	/// Nobody to send to yet (my camera is up while the call rings): the camera feeds my own
	/// picture and nothing is encoded, so the encoder is made once, for the first one in.
	var idle = false
	/// The person's switch. Off stops the capture itself, so the camera's light goes out.
	private(set) var cameraOn = true
	private(set) var front = true
	/// What the camera (or the pattern) gives: size and frame rate.
	private(set) var source = (width: 1920, height: 1080, fps: 60)

	private(set) var encoded = 0, keyframes = 0, refreshes = 0, bytesSent = 0
	private var encodeTimes: [Double] = []
	/// Submit to output, the last hundred frames (ms).
	var encodeLatency: [Double] { out.withLock { encodeTimes } }

	init(test: Bool, send: @escaping @Sendable (Encoded) -> Void) { self.test = test; self.send = send }

	func start() throws {
		if test { startPattern(); return }
		if cameraOn { try startCamera() }
	}

	func stop() {
		timer?.cancel(); timer = nil
		let c = capture; capture = nil
		queue.async { [self] in
			c?.stopRunning()
			retire()
		}
	}

	func keyframe() { queue.async { self.forceKey = true } }
	/// The next frame refers only to what everyone has (or is a keyframe, if they have nothing).
	func refresh() { queue.async { self.forceRefresh = true } }

	// MARK: the camera

	private func startCamera() throws {
		let s = AVCaptureSession()
		#if os(iOS)
		// The call's audio session is CallKit's and the voice's: the camera leaves it alone.
		s.automaticallyConfiguresApplicationAudioSession = false
		// In picture-in-picture, over another app, my camera keeps going where the system allows it.
		if s.isMultitaskingCameraAccessSupported { s.isMultitaskingCameraAccessEnabled = true }
		#endif
		s.beginConfiguration()
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
		chosen = choose(device).map { (device, $0.0, $0.1) }
		s.commitConfiguration()
		capture = s
		queue.async { s.startRunning(); self.reassert() }
	}

	/// The Mac's session may pick its own format as it starts: the chosen one again if so.
	private var chosen: (AVCaptureDevice, AVCaptureDevice.Format, CMTime)?
	private func reassert() {
		guard let (device, f, d) = chosen, device.activeFormat != f || device.activeVideoMinFrameDuration != d, (try? device.lockForConfiguration()) != nil else { return }
		device.activeFormat = f; device.activeVideoMinFrameDuration = d; device.activeVideoMaxFrameDuration = d
		device.unlockForConfiguration()
	}

	/// The best the camera has of 1080p60, 1080p30, 720p60, 720p30 (else what the session picks),
	/// at that frame rate. Stabilization stays off: it holds frames back.
	@discardableResult private func choose(_ device: AVCaptureDevice) -> (AVCaptureDevice.Format, CMTime)? {
		let wanted: [(Int32, Int32, Double)] = [(1920, 1080, 60), (1920, 1080, 30), (1280, 720, 60), (1280, 720, 30)]
		for (w, h, rate) in wanted {
			let fits = device.formats.filter { f in
				let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
				let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
				return d.width == w && d.height == h && (sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
					&& f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= rate - 0.5 }
			}
			guard let f = fits.first, (try? device.lockForConfiguration()) != nil else { continue }
			device.activeFormat = f
			let d = CMTime(value: 1, timescale: CMTimeScale(rate))
			device.activeVideoMinFrameDuration = d; device.activeVideoMaxFrameDuration = d
			device.unlockForConfiguration()
			#if os(iOS)
			source = (Int(h), Int(w), Int(rate))   // turned upright: portrait
			#else
			source = (Int(w), Int(h), Int(rate))
			#endif
			return (f, d)
		}
		source = (1280, 720, 30)
		return nil
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
		if let c = out.connection(with: .video) {
			if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
			if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
		}
		#endif
	}

	/// The other camera, on the iPhone; `done` hears which one is on now (true: the front).
	func flip(done: @escaping @Sendable (Bool) -> Void = { _ in }) {
		#if os(iOS)
		queue.async { [self] in
			guard let s = capture, let current = s.inputs.first as? AVCaptureDeviceInput, let next = camera(front: !front), let input = try? AVCaptureDeviceInput(device: next) else { done(front); return }
			s.beginConfiguration()
			s.removeInput(current)
			if s.canAddInput(input) { s.addInput(input); front.toggle(); choose(next) } else { s.addInput(current) }
			if let out = s.outputs.first as? AVCaptureVideoDataOutput { orient(out) }
			s.commitConfiguration()
			forceKey = true
			done(front)
		}
		#endif
	}

	func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
		guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
		if let local = VideoDecoder.displayable(pb) { onLocal?(local) }
		// How long ago it was captured, on the host clock, taken off now in the wire's microseconds.
		let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMSampleBufferGetPresentationTimeStamp(sample)))
		let at = micros() &- UInt32(clamping: Int(max(0, min(1, age)) * 1e6))
		encode(pb, at: CMSampleBufferGetPresentationTimeStamp(sample), capture: at)
	}

	// MARK: the test pattern

	/// 1080p60 of the test pattern (TestPattern), in place of a camera.
	private func startPattern() {
		source = (1920, 1080, 60)
		let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
		t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 60), leeway: .milliseconds(1))
		t.setEventHandler { [weak self] in self?.drawPattern() }
		t.resume()
		timer = t
	}

	private func drawPattern() {
		let (w, h) = (source.width, source.height)
		if pool == nil {
			let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
			CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
			pattern = TestPattern(width: w, height: h)
		}
		var buf: CVPixelBuffer?
		guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf) == kCVReturnSuccess, let pb = buf else { return }
		let at = micros()
		pattern?.draw(into: pb, time: Double(tick) / Double(source.fps), stamp: TestPattern.stamp())
		tick += 1
		guard cameraOn else { return }
		if let local = VideoDecoder.displayable(pb) { onLocal?(local) }
		encode(pb, at: CMTime(value: CMTimeValue(tick), timescale: CMTimeScale(source.fps)), capture: at)
	}

	// MARK: encode

	func setCamera(_ on: Bool) {
		guard on != cameraOn else { return }
		cameraOn = on
		if test { return }
		if on { if let c = capture { queue.async { c.startRunning(); self.forceKey = true } } else { queue.async { try? self.startCamera() } } }
		else { let c = capture; queue.async { c?.stopRunning() } }
	}

	private func encode(_ pb: CVPixelBuffer, at pts: CMTime, capture: UInt32) {
		guard cameraOn, !paused, !idle else { return }
		// Every frame, or every other: whichever the rate allows.
		let t = CMTimeGetSeconds(pts)
		if let last = lastEncoded, t - last < 1 / Double(fps) * 0.9 { return }
		lastEncoded = t
		let (w, h) = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
		let scale = min(1, Double(height) / Double(min(w, h)))
		let size = (Int32(Double(w) * scale) & ~1, Int32(Double(h) * scale) & ~1)
		if encoder == nil || encoderShape?.w != size.0 || encoderShape?.h != size.1 || encoderShape?.hevc != hevc { makeEncoder(size) }
		guard let e = encoder, let shape = encoderShape else { return }
		var props: [CFString: Any] = [:]
		let tokens = acked
		if !tokens.isEmpty { props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = tokens }
		let key = forceKey, refresh = forceRefresh && !forceKey
		if key { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
		if refresh { props[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true }
		forceKey = false; forceRefresh = false
		let submitted = seconds(), session = generation
		VTCompressionSessionEncodeFrame(e, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil) { [weak self] status, _, sample in
			guard status == noErr, let sample, let self else { return }
			self.output(sample, hevc: shape.hevc, refresh: refresh, capture: capture, submitted: submitted, session: session)
		}
	}

	private func makeEncoder(_ size: (Int32, Int32)) {
		retire()
		var s: VTCompressionSession?
		var codec = hevc && Self.hevcEncode ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
		let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
		if VTCompressionSessionCreate(allocator: nil, width: size.0, height: size.1, codecType: codec, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) != noErr {
			codec = kCMVideoCodecType_H264
			guard VTCompressionSessionCreate(allocator: nil, width: size.0, height: size.1, codecType: codec, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr else { return }
		}
		guard let s else { return }
		let isHevc = codec == kCMVideoCodecType_HEVC
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: isHevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
		VTSessionSetProperty(s, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue)
		VTCompressionSessionPrepareToEncodeFrames(s)
		encoder = s; encoderShape = (size.0, size.1, isHevc); forceKey = true
		generation += 1
		out.withLock { live = generation; shape = encoderShape }
		acked = []
		applyRate(); applyKeys()
	}

	private func resetEncoder() { retire() }

	/// The encoder put away, off this queue; whatever it still hands back is dropped (`live`).
	private func retire() {
		guard let e = encoder else { return }
		encoder = nil
		generation += 1
		out.withLock { live = generation }
		retired.async { VTCompressionSessionInvalidate(e) }
	}
	/// The encoder whose frames go out, and its shape, for any thread to read without waiting on
	/// the video queue.
	private var live = 0
	private var shape: (w: Int32, h: Int32, hevc: Bool)?

	private func applyRate() {
		guard let e = encoder else { return }
		VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
		VTSessionSetProperty(e, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
	}

	private func applyKeys() {
		guard let e = encoder else { return }
		VTSessionSetProperty(e, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: (periodicKeys ? 4 : 0) as CFNumber)
	}

	private func output(_ sample: CMSampleBuffer, hevc: Bool, refresh: Bool, capture: UInt32, submitted: Double, session: Int) {
		let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
		let key = !(attachments?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
		let token = attachments?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? Int
		var sets: [Data] = []
		if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
			var count = 0
			if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) }
			else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) }
			for i in 0..<count {
				var ptr: UnsafePointer<UInt8>?
				var size = 0
				if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
				else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
				if let ptr { sets.append(Data(bytes: ptr, count: size)) }
			}
		}
		guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
		let n = CMBlockBufferGetDataLength(block)
		var nals = Data(count: n)
		nals.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
		let id: UInt32? = out.withLock {
			guard session == live else { return nil }
			encoded += 1; if key { keyframes += 1 } else if refresh { refreshes += 1 }
			bytesSent += n
			encodeTimes.append((seconds() - submitted) * 1000); if encodeTimes.count > 100 { encodeTimes.removeFirst() }
			defer { nextId &+= 1 }
			return nextId
		}
		guard let id else { return }
		send(Encoded(id: id, key: key, refresh: refresh && !key, hevc: hevc, capture: capture, sets: sets, nals: nals, token: token, session: session))
	}

	/// The codec going out now.
	var codec: String { out.withLock { shape.map { $0.hevc ? "HEVC" : "H.264" } } ?? (hevc ? "HEVC" : "H.264") }
	/// The size going out now, "1920×1080".
	var size: String { out.withLock { shape.map { "\($0.w)×\($0.h)" } } ?? "-" }
}

