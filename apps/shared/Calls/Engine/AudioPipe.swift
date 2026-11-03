/// Voice, for everyone in the call. The microphone, through the system's voice processing (echo
/// cancellation and gain), becomes Opus 20 ms at a time, encoded once and handed to every link.
/// Each remote has its own jitter buffer and decoder; every 20 ms one frame from each (decoded,
/// or concealed, or nothing) is mixed into a small queue the speaker drains. Muted sends silence,
/// so timing and loss stay honest. The system stops an audio engine, without a word, whenever
/// the devices under it change (voice processing coming on, the speaker button, AirPods, another
/// call): a watchdog sees it within a quarter second, by the engine or by the sound no longer
/// moving, and builds it again at once. Every second of that is a second of a call nobody hears.
/// `test` swaps the microphone for a synthetic voice and the speaker for a meter: a call can be
/// proven with neither, and without asking for either. With `BAUD_CALL_SPEAKER=silent` the real
/// speaker stays, at zero volume: playout proven on real hardware, still with no microphone.
import AVFoundation
import BaudCore
#if os(macOS)
import CoreAudio
#endif
import Foundation
import os

final class AudioPipe: @unchecked Sendable {
	static let samples = 960   // 20 ms at 48 kHz
	static let silentSpeaker = ProcessInfo.processInfo.environment["BAUD_CALL_SPEAKER"] == "silent"

	/// How the engine listens: through the system's voice processing (echo cancellation), plain,
	/// or not at all (the others are still heard).
	enum Mode: String { case voice = "voice processing", plain = "plain capture", playout = "playout alone" }

	let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
	let opus: AVAudioFormat
	private let encoder: AVAudioConverter
	private let test: Bool
	private let send: @Sendable (AudioPacket) -> Void
	/// Encoding, mixing, and keeping the speaker's queue full.
	private let queue = DispatchQueue(label: "baud.audio", qos: .userInteractive)
	/// The engine's life, one step at a time: starting, healing, stopping.
	private let control = DispatchQueue(label: "baud.audio.control", qos: .userInitiated)
	private var engine: AVAudioEngine?
	private var mode = Mode.voice
	private var startedAt = Date.distantPast
	/// From `start` to `stop`: there should be an engine.
	private var wanted = false
	/// The iPhone's audio is someone else's for now (a phone call): no healing until it's back.
	private var interrupted = false
	private var heals: [Date] = []
	private var seen = (renders: 0, captures: 0)
	/// Quarter seconds in a row the speaker (or the microphone) didn't come by.
	private var stalls = (renders: 0, captures: 0)
	private var changes: NSObjectProtocol?
	private var observers: [NSObjectProtocol] = []
	private var pending: [Float] = []
	private var seq: UInt32 = 0
	private var previous: Data?
	private var timers: [DispatchSourceTimer] = []
	private var phase = 0.0, t = 0.0
	/// The synthetic voice's pitch, so two test callers don't sound (or measure) the same.
	private let pitch = Double.random(in: 150...260)

	/// One voice coming in: its own jitter buffer, decoder, and what it last said (for concealment).
	final class Remote {
		var jitter = JitterBuffer()
		let decoder: AVAudioConverter
		var last = [Float](repeating: 0, count: AudioPipe.samples)
		var concealRun = 0
		var level: Float = 0
		/// When it joined, and whether a word of theirs has played yet (for the record: how soon a
		/// call is heard).
		let added = Date()
		var heard = false
		let id: String
		init(id: String, decoder: AVAudioConverter) { self.id = id; self.decoder = decoder }
	}
	/// Guards the remotes, the playout queue (the render thread reads it) and the counts below.
	private let lock = OSAllocatedUnfairLock()
	private var remotes: [String: Remote] = [:]
	private var fifo: [Float] = []
	/// For the watchdog: the speaker's callbacks and the microphone's buffers, ever. For the stats:
	/// how loud each was since the last `health`, and how the engine stood when last looked at.
	private var renders = 0, captures = 0
	private var outSq = 0.0, outN = 0, micSq = 0.0, micN = 0
	private var shown = (mode: Mode.voice, running: true)
	private var lastHealth = (renders: 0, captures: 0, at: Date())

	var muted = false
	/// Opus's bitrate, from any thread: 96 kbps on a good one-to-one link, down to 24 on a poor one
	/// (CallMedia). Full band from 64 up.
	var bitrate: Int {
		get { lock.withLockUnchecked { _bitrate } }
		set { lock.withLockUnchecked { _bitrate = newValue }; queue.async { [self] in encoder.bitRate = newValue } }
	}
	private var _bitrate = 32_000
	/// Opus bytes encoded, ever (the bitrate it actually makes).
	private(set) var opusBytes = 0
	/// The microphone isn't baud's to use (never allowed, or turned off in Settings): the call
	/// still plays what the others say, and says so. Allowed during the call, it's taken up.
	private(set) var micOff = false
	/// 0…1, smoothed, mine as I speak.
	private(set) var localLevel: Float = 0
	private(set) var sent = 0
	/// Testing: frames mixed and played, and how loud (proof the decoded audio is voice, not silence).
	private(set) var playedFrames = 0
	private(set) var playedRMS: Float = 0

	init(test: Bool, send: @escaping @Sendable (AudioPacket) -> Void) throws {
		self.test = test; self.send = send
		var desc = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.samples), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
		guard let opus = AVAudioFormat(streamDescription: &desc), let enc = AVAudioConverter(from: pcm, to: opus) else { throw CallError.audio("Opus isn't available here.") }
		enc.bitRate = 32_000
		self.opus = opus; encoder = enc
	}

	// MARK: who's in

	func add(_ id: String) {
		guard let dec = AVAudioConverter(from: opus, to: pcm) else { return }
		lock.withLockUnchecked { if remotes[id] == nil { remotes[id] = Remote(id: id, decoder: dec) } }
	}
	func remove(_ id: String) { lock.withLockUnchecked { _ = remotes.removeValue(forKey: id) } }

	// MARK: start and stop

	/// Starts capture and playout. On the iPhone the audio session must already be active (CallKit
	/// activates it); on the Mac nothing else is needed. The system's voice processing first (echo
	/// cancellation); if it won't start (it refuses some device pairs, with -10875), plain capture;
	/// without the microphone, playout alone, so the others can still be heard.
	func start() throws {
		try control.sync {
			wanted = true
			if test {
				startTest()
				guard Self.silentSpeaker else { return }
				try open([.playout])
			} else {
				micOff = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
				try open(micOff ? [.playout] : [.voice, .plain])
				#if os(iOS)
				observeSession()
				#endif
			}
			every(.milliseconds(10), on: queue) { [weak self] in self?.refill() }
			every(.milliseconds(250), on: control) { [weak self] in self?.watch() }
		}
	}

	func stop() {
		control.sync {
			wanted = false
			timers.forEach { $0.cancel() }; timers = []
			observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
			close()
		}
	}

	/// The first of `modes` that starts, in place of whatever was there. Voice processing gets a few
	/// tries a quarter second apart: just after the system moves the route, the microphone can read
	/// as no channels at all for a moment, and plain capture would cost the call its echo cancelling.
	private func open(_ modes: [Mode]) throws {
		close()
		var last: Error?
		for m in modes {
			do {
				var tries = m == .voice ? 4 : 1
				var made: AVAudioEngine?
				while made == nil {
					do { made = try makeEngine(m) } catch {
						tries -= 1
						if tries == 0 { throw error }
						usleep(250_000)
					}
				}
				let e = made!
				engine = e; mode = m; startedAt = Date()
				lock.withLockUnchecked { shown = (m, true) }
				let id = ObjectIdentifier(e)
				changes = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
					guard let self else { return }
					self.control.async { [self] in if let e = self.engine, ObjectIdentifier(e) == id { self.changed(e) } }
				}
				callLog("audio: \(m.rawValue)\(last.map { " (after: \($0))" } ?? "") · \(describe(e, m))")
				return
			} catch {
				last = error
				callLog("audio: \(m.rawValue) wouldn't start: \(error)")
			}
		}
		throw CallError.audio("The call's audio wouldn't start\(last.map { " (\(($0 as NSError).code))" } ?? "").")
	}

	private func close() {
		if let c = changes { NotificationCenter.default.removeObserver(c); changes = nil }
		if let e = engine {
			if mode != .playout { e.inputNode.removeTap(onBus: 0) }
			e.stop()
		}
		engine = nil
	}

	/// One engine: the microphone with or without voice processing, or none, and the mixed voices
	/// out. Each tap converts with its own converter, so a rebuilt engine never shares one.
	private func makeEngine(_ m: Mode) throws -> AVAudioEngine {
		let e = AVAudioEngine()
		if m != .playout {
			let input = e.inputNode
			if m == .voice {
				try input.setVoiceProcessingEnabled(true)
				// Music or a video playing alongside the call is lowered as little as possible.
				input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
			}
			let hw = input.outputFormat(forBus: 0)
			guard hw.channelCount > 0, hw.sampleRate > 0, let resample = AVAudioConverter(from: hw, to: pcm) else { throw CallError.audio("No microphone to listen to.") }
			input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buf, _ in self?.captured(buf, resample) }
		}
		let src = AVAudioSourceNode(format: pcm) { [weak self] _, _, frames, list -> OSStatus in
			self?.render(Int(frames), UnsafeMutableAudioBufferListPointer(list)) ?? noErr
		}
		e.attach(src)
		e.connect(src, to: e.mainMixerNode, format: pcm)
		if test { e.mainMixerNode.outputVolume = 0 }
		e.prepare()
		do { try e.start() } catch {
			if m != .playout { e.inputNode.removeTap(onBus: 0) }
			e.stop()
			throw error
		}
		return e
	}

	private func every(_ interval: DispatchTimeInterval, on q: DispatchQueue, _ f: @escaping () -> Void) {
		let t = DispatchSource.makeTimerSource(queue: q)
		t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
		t.setEventHandler(handler: f)
		t.resume()
		timers.append(t)
	}

	// MARK: healing

	/// Every quarter second: an engine that stopped, or whose speaker or microphone hasn't come by
	/// for half a second, is built again. A microphone allowed during the call is taken up.
	private func watch() {
		guard wanted, !interrupted else { return }
		guard let e = engine else { heal("there was no engine"); return }
		let now = lock.withLockUnchecked { (renders: renders, captures: captures) }
		defer { seen = now }
		let running = e.isRunning
		lock.withLockUnchecked { shown = (mode, running) }
		if !test, micOff, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
			micOff = false
			heal("the microphone was allowed", modes: [.voice, .plain])
			return
		}
		stalls.renders = now.renders == seen.renders ? stalls.renders + 1 : 0
		stalls.captures = now.captures == seen.captures ? stalls.captures + 1 : 0
		if !running { heal("the engine stopped"); return }
		// A new engine takes a moment to get going.
		guard Date().timeIntervalSince(startedAt) > 0.8 else { return }
		if stalls.renders >= 2 { heal("the speaker stopped asking for sound") }
		else if mode != .playout, stalls.captures >= 2 { heal("the microphone stopped") }
	}

	/// The devices under the engine changed. The system stops it when their formats did; when it
	/// runs on, the watchdog keeps an eye on it.
	private func changed(_ e: AVAudioEngine) {
		if e.isRunning { callLog("audio: the devices changed, still running · \(describe(e, mode))") }
		else { heal("the devices changed") }
	}

	/// A new engine, the same way as before (voice processing may still give way to plain capture);
	/// no more often than twice a second, and a way that broke five times in a minute gives way
	/// to the next.
	private func heal(_ why: String, modes: [Mode]? = nil, now force: Bool = false) {
		guard wanted else { return }
		let now = Date()
		if !force, let last = heals.last, now.timeIntervalSince(last) < 0.5 { return }
		stalls = (0, 0)
		heals = heals.filter { now.timeIntervalSince($0) < 60 } + [now]
		var ways = modes ?? (mode == .voice ? [.voice, .plain] : [mode])
		if modes == nil, heals.count >= 5, mode == .voice { ways = [.plain]; heals = [] }
		callLog("audio: \(why); starting again")
		do { try open(ways) } catch { callLog("audio: couldn't start again: \(error)") }
	}

	#if os(iOS)
	/// Another call takes the audio and gives it back; the media services restart; the route moves.
	private func observeSession() {
		let c = NotificationCenter.default
		observers = [
			c.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
				let began = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began
				guard let self else { return }
				self.control.async { [self] in
					guard self.wanted else { return }
					self.interrupted = began
					if began { callLog("audio: interrupted") } else { self.heal("the interruption ended", now: true) }
				}
			},
			c.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
				guard let self else { return }
				self.control.async { [self] in self.heal("the media services restarted", now: true) }
			},
			c.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] n in
				let why = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
				callLog("audio: the route changed (\(why.map(Self.words) ?? "?"))\(Self.route())")
				// The engine often stops a moment after the route moves, with or without a word.
				self?.control.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
					guard let self, self.wanted, !self.interrupted, let e = self.engine, !e.isRunning else { return }
					self.heal("the route moved", now: true)
				}
			},
		]
	}

	private static func words(_ r: AVAudioSession.RouteChangeReason) -> String {
		switch r {
		case .newDeviceAvailable: "a device came"
		case .oldDeviceUnavailable: "a device went"
		case .categoryChange: "the category changed"
		case .override: "the speaker button"
		case .wakeFromSleep: "woke"
		case .noSuitableRouteForCategory: "no route"
		case .routeConfigurationChange: "reconfigured"
		default: "\(r.rawValue)"
		}
	}
	#endif

	/// "in 48 kHz 1 ch, out 48 kHz 2 ch · MicrophoneBuiltIn → Receiver"
	private func describe(_ e: AVAudioEngine, _ m: Mode) -> String {
		func f(_ x: AVAudioFormat) -> String { "\(Int(x.sampleRate / 1000)) kHz \(x.channelCount) ch" }
		return (m == .playout ? "" : "in \(f(e.inputNode.outputFormat(forBus: 0))), ") + "out \(f(e.outputNode.outputFormat(forBus: 0)))" + Self.route()
	}

	/// The devices in use, by kind on the iPhone and by name on the Mac.
	private static func route() -> String {
		#if os(iOS)
		let r = AVAudioSession.sharedInstance().currentRoute
		return " · " + r.inputs.map(\.portType.rawValue).joined(separator: "+") + " → " + r.outputs.map(\.portType.rawValue).joined(separator: "+")
		#else
		return " · " + device(kAudioHardwarePropertyDefaultInputDevice) + " → " + device(kAudioHardwarePropertyDefaultOutputDevice)
		#endif
	}

	#if os(macOS)
	private static func device(_ which: AudioObjectPropertySelector) -> String {
		var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
		var at = AudioObjectPropertyAddress(mSelector: which, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &at, 0, nil, &size, &id) == noErr else { return "?" }
		var name: Unmanaged<CFString>?
		size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
		at.mSelector = kAudioObjectPropertyName
		guard AudioObjectGetPropertyData(id, &at, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return "?" }
		return n as String
	}
	#endif

	/// The last second (since the last ask), in a few words: how it listens, how often the
	/// microphone and the speaker came by, and how loud each was.
	func health() -> String {
		if test && !Self.silentSpeaker { return "synthetic audio" }
		let (r, c, out, mic, s) = lock.withLockUnchecked { () -> (Int, Int, Double, Double, (mode: Mode, running: Bool)) in
			defer { outSq = 0; outN = 0; micSq = 0; micN = 0 }
			return (renders, captures, outN == 0 ? 0 : outSq / Double(outN), micN == 0 ? 0 : micSq / Double(micN), shown)
		}
		let dt = max(0.001, Date().timeIntervalSince(lastHealth.at))
		defer { lastHealth = (r, c, Date()) }
		func db(_ meanSquare: Double) -> String { meanSquare < 1e-10 ? "silent" : "\(Int((10 * log10(meanSquare)).rounded())) dB" }
		let listening = s.mode == .playout ? "no microphone" : String(format: "mic %.0f/s %@", Double(c - lastHealth.captures) / dt, db(mic))
		return String(format: "%@ · %@ · speaker %.0f/s %@%@", s.mode.rawValue, listening, Double(r - lastHealth.renders) / dt, db(out), s.running ? "" : " · stopped")
	}

	// MARK: out

	private func captured(_ buf: AVAudioPCMBuffer, _ resample: AVAudioConverter) {
		let ratio = 48_000 / buf.format.sampleRate
		guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16) else { return }
		var given = false
		var err: NSError?
		resample.convert(to: out, error: &err) { _, s in if given { s.pointee = .noDataNow; return nil }; given = true; s.pointee = .haveData; return buf }
		let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
		let sq = samples.reduce(0.0) { $0 + Double($1 * $1) }
		lock.withLockUnchecked { captures += 1; micSq += sq; micN += samples.count }
		queue.async { [weak self] in self?.push(samples) }
	}

	/// Whole 20 ms frames out of whatever sizes the microphone gives.
	private func push(_ samples: [Float]) {
		pending += samples
		while pending.count >= Self.samples {
			let frame = Array(pending.prefix(Self.samples))
			pending.removeFirst(Self.samples)
			encode(muted ? [Float](repeating: 0, count: Self.samples) : frame)
		}
	}

	private func encode(_ frame: [Float]) {
		guard let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Self.samples)) else { return }
		buf.frameLength = AVAudioFrameCount(Self.samples)
		frame.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: Self.samples) }
		let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(1, encoder.maximumOutputPacketSize))
		var fed = false
		var err: NSError?
		encoder.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
		guard out.packetCount > 0, out.byteLength > 0 else { return }
		let level = Self.level(frame)
		localLevel = localLevel * 0.6 + level * 0.4
		let opus = Data(bytes: out.data, count: Int(out.byteLength))
		opusBytes += opus.count
		send(AudioPacket(seq: seq, level: UInt8(level * 255), payload: opus, previous: previous))
		previous = opus
		seq &+= 1; sent += 1
	}

	/// Loudness 0…1 from −50…0 dBFS.
	static func level(_ s: [Float]) -> Float {
		let rms = sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(max(1, s.count)))
		let db = 20 * log10(max(rms, 1e-6))
		return min(1, max(0, (db + 50) / 50))
	}

	// MARK: in

	func receive(_ p: AudioPacket, from id: String) {
		let at = seconds()
		lock.withLockUnchecked { remotes[id]?.jitter.put(p, at: at) }
	}

	/// Keep 30 ms mixed ahead of the speaker.
	private func refill() {
		while lock.withLockUnchecked({ fifo.count }) < Self.samples * 3 / 2 {
			guard let frame = mix() else { break }
			if test { meter(frame) }
			lock.withLockUnchecked { fifo += frame }
		}
	}

	/// The next 20 ms from everyone, summed; nil when nobody has anything yet.
	private func mix() -> [Float]? {
		let all = lock.withLockUnchecked { Array(remotes.values) }
		var out: [Float]?
		for r in all {
			guard let f = next(r) else { continue }
			if out == nil { out = f } else { for i in 0..<Self.samples { out![i] += f[i] } }
		}
		// Several voices at once: a soft knee above 0.8, never a hard clip.
		if all.count > 1, var o = out {
			for i in 0..<o.count where abs(o[i]) > 0.8 {
				let over = abs(o[i]) - 0.8
				o[i] = (o[i] > 0 ? 1 : -1) * (0.8 + over / (1 + over * 5))
			}
			out = o
		}
		return out
	}

	/// One remote's next 20 ms: decoded, concealed (the last frame, fading), or nothing yet.
	private func next(_ r: Remote) -> [Float]? {
		let pull = lock.withLockUnchecked { r.jitter.pull() }
		switch pull {
		case .idle:
			r.level *= 0.8
			return nil
		case .frame(let opus, let level):
			if !r.heard { r.heard = true; callLog("audio: first sound from \(r.id.prefix(8)) \(Int(Date().timeIntervalSince(r.added) * 1000)) ms after they joined") }
			r.concealRun = 0
			r.level = r.level * 0.5 + Float(level) / 255 * 0.5
			r.last = decode(opus, r.decoder) ?? r.last
			return r.last
		case .missing:
			r.concealRun += 1
			let fade = r.concealRun > 3 ? 0 : Float(pow(0.5, Double(r.concealRun)))
			return r.last.map { $0 * fade }
		}
	}

	private func decode(_ bytes: Data, _ decoder: AVAudioConverter) -> [Float]? {
		let inBuf = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: bytes.count)
		bytes.withUnsafeBytes { inBuf.data.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
		inBuf.byteLength = UInt32(bytes.count)
		inBuf.packetCount = 1
		inBuf.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
		guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Self.samples)) else { return nil }
		var given = false
		var err: NSError?
		decoder.convert(to: out, error: &err) { _, s in if given { s.pointee = .noDataNow; return nil }; given = true; s.pointee = .haveData; return inBuf }
		guard out.frameLength > 0 else { return nil }
		var frame = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
		if frame.count < Self.samples { frame += [Float](repeating: 0, count: Self.samples - frame.count) }
		return frame
	}

	/// The render thread: copy what's queued, silence for the rest.
	private func render(_ frames: Int, _ list: UnsafeMutableAudioBufferListPointer) -> OSStatus {
		guard let out = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
		lock.withLockUnchecked {
			renders += 1
			let n = min(frames, fifo.count)
			if n > 0 {
				fifo.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: n) }
				fifo.removeFirst(n)
				for i in 0..<n { outSq += Double(out[i] * out[i]) }
			}
			if n < frames { (out + n).update(repeating: 0, count: frames - n) }
			outN += frames
		}
		return noErr
	}

	// MARK: testing

	/// A voice that isn't anyone's: a hum in syllables, four a second with pauses, 20 ms every
	/// 20 ms; and, unless the real speaker plays it, a meter mixing 20 ms every 20 ms in its place.
	private func startTest() {
		every(.milliseconds(20), on: queue) { [weak self] in
			guard let self else { return }
			var frame = [Float](repeating: 0, count: Self.samples)
			for i in 0..<Self.samples {
				let syllable = max(0, sin(2 * .pi * 4 * t)) * (sin(2 * .pi * 0.3 * t) > -0.4 ? 1 : 0)
				frame[i] = Float(0.25 * syllable * sin(phase))
				phase += 2 * .pi * (pitch + 30 * sin(2 * .pi * 1.3 * t)) / 48_000
				t += 1 / 48_000
			}
			push(frame)
			guard !Self.silentSpeaker, let played = mix() else { return }
			meter(played)
		}
	}

	private func meter(_ played: [Float]) {
		playedFrames += 1
		let rms = sqrt(played.reduce(0) { $0 + $1 * $1 } / Float(played.count))
		playedRMS = playedRMS * 0.95 + rms * 0.05
	}

	/// Testing: the engine stops the way the system stops it when the devices change, to prove the
	/// call heals; `quietly`, with no word of it, for the watchdog to find.
	func breakEngine(quietly: Bool = false) {
		control.async { [self] in
			guard let e = engine else { return }
			e.stop()
			if !quietly { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: e) }
		}
	}

	struct Stats { var received = 0, expected = 0, played = 0, concealed = 0, late = 0, rescued = 0, target = 0 }
	func stats(_ id: String) -> Stats {
		lock.withLockUnchecked {
			guard let j = remotes[id]?.jitter else { return Stats() }
			return Stats(received: j.received, expected: j.expected, played: j.played, concealed: j.concealed, late: j.late, rescued: j.rescued, target: j.target)
		}
	}
	func level(_ id: String) -> Float { lock.withLockUnchecked { remotes[id]?.level ?? 0 } }
	/// The loudest voice now, for a one-to-one call's ring.
	var remoteLevel: Float { lock.withLockUnchecked { remotes.values.map(\.level).max() ?? 0 } }
}

enum CallError: Error { case audio(String), video(String) }
