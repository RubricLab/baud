/// One call's media, for a mesh of any size: one capture and one encoder for my voice and my
/// picture, handed to every peer's link; for each peer, its own reassembler, decoder, parity and
/// report. Each peer says once a second what arrived; from that each gets its own parity (more as
/// more datagrams go missing) and its own sustainable rate, and the encoder runs at the lowest of
/// those, capped by how many are listening: up to 2.5 Mbps (720p) for one, 900 kbps for two, 450
/// kbps at 360p for three or more, so a mesh of four fits a home uplink. A peer that can't take
/// video at the floor gets voice only until its link calms; the others keep their picture.
import CoreMedia
import Foundation

/// Where call milestones go: the app's log, or the test harness's stdout.
nonisolated(unsafe) var callLog: @Sendable (String) -> Void = { print($0) }

final class CallMedia: @unchecked Sendable {
	let audio: AudioPipe
	let video: VideoPipe?
	private let lock = NSLock()
	private var peers: [String: Peer] = [:]
	private var timer: DispatchSourceTimer?
	private var audioOn = false
	var onChange: (@Sendable () -> Void)?

	/// One device in the call, as my media sees it.
	final class Peer: @unchecked Sendable {
		let link: CallRoute
		let decoder: VideoDecoder?
		var reassembler = VideoReassembler()
		var askedKey = Date.distantPast
		var last = (delivered: 0, lost: 0, received: 0, expected: 0, encodedTo: 0)
		/// What it reported last (audio: datagrams lost; video: frames lost after parity).
		var theirs = (audioLoss: 0.0, videoFps: 0.0, videoLoss: 0.0)
		/// What arrived here from it in the last second.
		var mine = (audioLoss: 0.0, videoFps: 0.0, videoLoss: 0.0)
		var fec: Int = 10
		var rate: Int
		var calm = 0, weak = 0
		var baseRtt = Int.max
		/// Too weak for video: voice only, until `pausedAt + backoff`.
		var paused = false
		var pausedAt: Date?
		var backoff: TimeInterval = 10
		var sentFrames = 0, sentFps = 0.0
		init(link: CallRoute, decoder: VideoDecoder?, rate: Int) { self.link = link; self.decoder = decoder; self.rate = rate }
	}
	/// This device, as relay packets name it.
	private let me: Data

	init(video: Bool, test: Bool, me: String) throws {
		self.me = RelayPacket.short(me)
		let peersRef = Weak<CallMedia>()
		audio = try AudioPipe(test: test) { p in
			let d = p.data
			for peer in peersRef.value?.all() ?? [] { peer.link.datagram(d) }
		}
		if video {
			let frames = Counter()
			let v = VideoPipe(test: test) { bytes, key in
				guard let media = peersRef.value else { return }
				let id = frames.next()
				for peer in media.all() where !peer.paused {
					for d in VideoFragment.cut(frame: id, key: key, bytes: bytes, mtu: peer.link.mtu, group: peer.fec) { peer.link.datagram(d) }
					peer.sentFrames += 1
				}
			}
			v.bitrate = 1_200_000
			v.tier = .hd
			self.video = v
		} else { self.video = nil }
		peersRef.value = self
	}

	private func all() -> [Peer] { lock.withLock { Array(peers.values) } }
	var count: Int { lock.withLock { peers.count } }

	// MARK: who's in

	/// A device joins the call: its voice into the mix, its picture to `onFrame`.
	func add(_ link: CallRoute, onFrame: (@Sendable (CMSampleBuffer) -> Void)?) {
		let decoder = video.map { _ in VideoDecoder() }
		decoder?.onFrame = onFrame
		let peer = Peer(link: link, decoder: decoder, rate: link.relay == nil && link.via == nil ? 1_200_000 : 600_000)
		decoder?.onNeedKey = { [weak self, weak peer] in if let peer { self?.askForKey(peer) } }
		audio.add(link.device)
		lock.withLock { peers[link.device] = peer }
		link.onDatagram = { [weak self, weak peer] d in if let peer { self?.datagram(d, from: peer) } }
		video?.keyframe()
		fit()
	}

	func remove(_ device: String) {
		guard let peer = lock.withLock({ peers.removeValue(forKey: device) }) else { return }
		peer.decoder?.stop()
		audio.remove(device)
		fit()
	}

	// MARK: start and stop

	/// Video and the stats now; the voice now too, or when `startAudio` is called (the iPhone
	/// waits for CallKit to hand over the audio session).
	func start(audio withAudio: Bool = true) throws {
		if withAudio { try startAudio() }
		try video?.start()
		let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
		t.schedule(deadline: .now() + 1, repeating: 1)
		t.setEventHandler { [weak self] in self?.second() }
		t.resume()
		timer = t
	}

	func startAudio() throws {
		guard !lock.withLock({ audioOn }) else { return }
		try audio.start()
		lock.withLock { audioOn = true }
	}

	func stop() {
		timer?.cancel(); timer = nil
		audio.stop(); video?.stop()
		for p in all() { p.decoder?.stop() }
	}

	// MARK: in

	private func datagram(_ d: Data, from peer: Peer) {
		guard let kind = d.first.flatMap(MediaKind.init) else { return }
		switch kind {
		case .relay:
			guard let r = RelayPacket(d) else { return }
			if r.to == me {
				// For me, from someone I reach through this peer.
				guard let origin = lock.withLock({ peers.values.first { RelayPacket.short($0.link.device) == r.from && $0.link.via == peer.link.device } }) else { return }
				datagram(r.inner, from: origin)
			} else if let target = lock.withLock({ peers.values.first { RelayPacket.short($0.link.device) == r.to && $0.link.via == nil } }) {
				// For someone this peer can't reach and I can: pass it on as it came.
				target.link.datagram(d)
			}
		case .audio: if let p = AudioPacket(d) { audio.receive(p, from: peer.link.device) }
		case .video:
			guard let f = VideoFragment(d) else { return }
			let (frames, needKey) = lock.withLock { (peer.reassembler.add(f), peer.reassembler.needsKeyframe) }
			for fr in frames { peer.decoder?.receive(fr.bytes) }
			if needKey { askForKey(peer) }
		}
	}

	private func askForKey(_ peer: Peer) {
		let now = Date()
		guard lock.withLock({ () -> Bool in guard now.timeIntervalSince(peer.askedKey) > 0.5 else { return false }; peer.askedKey = now; return true }) else { return }
		Task { await peer.link.send(.keyframe) }
	}

	/// A signal for the media; false when it's the session's.
	func handle(_ s: CallSignal, from device: String) -> Bool {
		guard let peer = lock.withLock({ peers[device] }) else { return false }
		switch s {
		case .keyframe: video?.keyframe(); return true
		case .stats(let a, let fps, let loss):
			lock.withLock { peer.theirs = (a, fps, loss) }
			adapt(peer)
			return true
		default: return false
		}
	}

	// MARK: each second

	private func second() {
		var lines: [String] = []
		for peer in all() {
			let d = peer.link.device
			let r = lock.withLock { (peer.reassembler.delivered, peer.reassembler.lost, peer.reassembler.recovered) }
			let a = audio.stats(d)
			let dv = r.0 - peer.last.delivered, dl = r.1 - peer.last.lost
			let got = a.received - peer.last.received, sent = a.expected - peer.last.expected
			let out = peer.sentFrames - peer.last.encodedTo
			peer.mine = (sent <= 0 ? 0 : max(0, 1 - Double(got) / Double(sent)), Double(dv), dv + dl == 0 ? 0 : Double(dl) / Double(dv + dl))
			peer.last = (r.0, r.1, a.received, a.expected, peer.sentFrames)
			peer.sentFps = Double(out)
			let m = peer.mine
			Task { await peer.link.send(.stats(audioLoss: m.audioLoss, videoFps: m.videoFps, videoLoss: m.videoLoss)) }
			lines.append(String(format: "%@%@ rtt %@ · audio in %d/%d lost %.1f%% rescued %d concealed %d · video out %d fps fec 1/%d%@ · in %.0f fps lost %.1f%% rebuilt %d decoded %d",
				String(d.prefix(8)), peer.link.via.map { " via \($0.prefix(8))" } ?? "", peer.link.rtt.map(String.init) ?? "-", a.received, a.expected, m.audioLoss * 100, a.rescued, a.concealed,
				out, peer.fec, peer.paused ? " (voice only)" : "", m.videoFps, m.videoLoss * 100, r.2, peer.decoder?.decoded ?? 0))
		}
		if !lines.isEmpty {
			callLog("call stats · \(count) connected · audio out \(audio.sent) · \(audio.health()) · video \(video.map { "\($0.bitrate / 1000) kbps \($0.tier == .hd ? "720p" : "360p")" } ?? "off")\n    " + lines.joined(separator: "\n    "))
		}
		onChange?()
	}

	/// A peer's report of my media. Missing datagrams with no queue behind them are noise on its
	/// path: more parity for it, not less video. A queue building (its round trip rising) or frames
	/// lost even after parity is congestion: its rate steps down fast and back up slowly. When even
	/// the floor can't get a third of the frames to it for five seconds, it gets voice only and is
	/// offered video again after ten (twenty, forty…) seconds.
	private func adapt(_ p: Peer) {
		guard video != nil else { return }
		lock.withLock {
			let raw = p.theirs.audioLoss
			p.fec = raw < 0.01 ? 10 : raw < 0.03 ? 6 : raw < 0.06 ? 4 : raw < 0.1 ? 3 : 2
			let rtt = p.link.rtt ?? 0
			p.baseRtt = min(p.baseRtt, rtt)
			let queue = rtt - p.baseRtt
			if queue > 150 || p.theirs.videoLoss > 0.15 { p.rate = Int(Double(p.rate) * 0.7); p.calm = 0 }
			else if queue > 60 || p.theirs.videoLoss > 0.05 || raw > 0.12 { p.rate = Int(Double(p.rate) * 0.9); p.calm = 0 }
			else { p.calm += 1; if p.calm >= 3 { p.rate = Int(Double(p.rate) * 1.08) } }
			p.rate = min(p.link.relay == nil && p.link.via == nil ? 2_500_000 : 1_200_000, max(120_000, p.rate))

			if let at = p.pausedAt {
				if Date().timeIntervalSince(at) >= p.backoff { p.pausedAt = nil; p.weak = 0; p.paused = false; callLog("call video to \(p.link.device.prefix(8)): trying again") }
			} else {
				let through = p.sentFps > 0 ? min(1, p.theirs.videoFps / p.sentFps) : 1
				p.weak = p.rate <= 150_000 && through < 0.33 ? p.weak + 1 : 0
				if p.weak >= 5 {
					p.pausedAt = Date(); p.backoff = min(60, p.backoff * (p.paused ? 2 : 1)); p.paused = true
					callLog("call video to \(p.link.device.prefix(8)) paused: its link is too weak")
				} else if p.calm >= 10 { p.backoff = 10 }
			}
		}
		fit()
	}

	/// The encoder's rate: the lowest any peer taking video can sustain, capped by how many listen.
	private func fit() {
		guard let v = video else { return }
		let (rates, n) = lock.withLock { (peers.values.filter { !$0.paused }.map(\.rate), peers.count) }
		let cap = n <= 1 ? 2_500_000 : n == 2 ? 900_000 : 450_000
		let rate = min(cap, rates.min() ?? cap)
		if rate != v.bitrate { v.bitrate = rate }
		let tier: VideoPipe.Tier = n >= 3 || rate < 600_000 ? .sd : rate > 800_000 ? .hd : v.tier
		if tier != v.tier { v.tier = tier }
	}

	/// Frames of this peer's video decoded so far.
	func decoded(_ device: String) -> Int { lock.withLock { peers[device]?.decoder?.decoded ?? 0 } }
	/// Voice and video quality of one peer, for the screen.
	func paused(_ device: String) -> Bool { lock.withLock { peers[device]?.paused ?? false } }
	/// Whether every peer is getting voice only from me (my picture is paused for all).
	var videoPaused: Bool { lock.withLock { !peers.isEmpty && peers.values.allSatisfy(\.paused) } }
	var remoteLevel: Float { audio.remoteLevel }
	func level(_ device: String) -> Float { audio.level(device) }
	var localLevel: Float { audio.localLevel }
}

private final class Weak<T: AnyObject>: @unchecked Sendable { weak var value: T? }

private final class Counter: @unchecked Sendable {
	private var n: UInt32 = 0
	private let lock = NSLock()
	func next() -> UInt32 { lock.withLock { defer { n &+= 1 }; return n } }
}
