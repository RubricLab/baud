/// One call's media, for a mesh of any size: one capture and one encoder for my voice and my
/// picture, handed to every peer's link through the pacer; for each peer, its own reassembler,
/// decoder and parity. Each end says what its media can do (`caps`, the first signal on a link).
/// A peer on media 2 gets sequenced datagrams and says back what arrived every 50 ms: from that
/// its own rate control (RateControl), the clock offset for latency, and which frames it has, so
/// the encoder can refer back to them after a loss rather than send a keyframe. A peer that never
/// said (baud 0.2.15) gets H.264 in the first frame form, and adapts the way 0.2.15 did: from its
/// once-a-second stats and the round trip. The encoder runs at the lowest rate any peer taking
/// video can take, capped by how many are listening (one: as high as the path goes, to 12 Mbps of
/// HEVC; two: 1.8 Mbps each; three: 1.2; four: 0.8; more: 0.5), so a mesh still fits a home uplink; its size and frame rate follow
/// from that (Ladder). HEVC when every peer encodes and decodes it in hardware, and so do I. A peer
/// that can't take video at the floor gets voice only until its link calms; the others keep their
/// picture.
import BaudCore
import CoreMedia
import Foundation

/// Where call milestones go: the app's log, or the test harness's stdout.
nonisolated(unsafe) var callLog: @Sendable (String) -> Void = { print($0) }

/// How a call is going, for the call screen.
struct CallQuality: Sendable {
	/// What I send: codec, size ("1920×1080"), frame rate, bitrate (kbps).
	var codec = "", size = "", fps = 0, kbps = 0
	/// What comes in from them: size and frames shown a second.
	var inSize = "", inFps = 0
	/// From their camera to my screen (ms, median of the last few seconds), when it can be told.
	var latency: Double?
	var rtt: Int?
	/// Of what I send them, the share lost on the way.
	var loss = 0.0
	/// They speak media 2 (feedback, refreshes, HEVC if both can).
	var media2 = false
}

final class CallMedia: @unchecked Sendable {
	/// What this device's media can do, said first on every link.
	static let mine = MediaCaps(media: 2, hevc: VideoPipe.hevcEncode && VideoDecoder.hevc)

	let audio: AudioPipe
	let video: VideoPipe?
	let pacer = Pacer()
	private let lock = NSLock()
	private var peers: [String: Peer] = [:]
	private var timer: DispatchSourceTimer?
	private var ticker: DispatchSourceTimer?
	private var audioOn = false
	private var ladder = Ladder()
	private var tokens: [UInt32: (session: Int, token: Int)] = [:]
	private var lastRefresh = 0.0, lastKey = 0.0, keySent = 0.0
	private var opusSeen = 0
	var onChange: (@Sendable () -> Void)?

	/// One device in the call, as my media sees it.
	final class Peer: @unchecked Sendable {
		let link: CallRoute
		var caps: MediaCaps?
		var media2: Bool { (caps?.media ?? 1) >= 2 }
		let decoder: VideoDecoder?
		var reassembler = VideoReassembler()
		let lane: Pacer.Lane
		var arrivals = Arrivals()
		var askedKey = Date.distantPast
		var lostSeen = 0
		var last = (delivered: 0, lost: 0, received: 0, expected: 0, encodedTo: 0, shown: 0)
		/// What it reported last (audio: datagrams lost; video: frames lost after parity).
		var theirs = (audioLoss: 0.0, videoFps: 0.0, videoLoss: 0.0)
		/// What arrived here from it in the last second.
		var mine = (audioLoss: 0.0, videoFps: 0.0, videoLoss: 0.0)
		var fec: Int = 10
		/// Media 1: the rate it can take, as 0.2.15 worked it out.
		var rate: Int
		var calm = 0, weak = 0
		var baseRtt = Int.max
		/// Media 2: where its decoding of my video stands.
		var theirDecoded: UInt32?, theirChain: UInt32 = 0
		/// Too weak for video: voice only, until `pausedAt + backoff`.
		var paused = false
		var pausedAt: Date?
		var backoff: TimeInterval = 10
		var sentFrames = 0, sentFps = 0.0, shownFps = 0
		/// Pacer stamp to here (ms, by the clocks' offset), the last few hundred datagrams.
		var transit: [Double] = []
		init(link: CallRoute, decoder: VideoDecoder?, lane: Pacer.Lane, rate: Int) { self.link = link; self.decoder = decoder; self.lane = lane; self.rate = rate }
	}
	/// This device, as relay packets name it.
	private let me: Data

	init(video: Bool, test: Bool, me: String) throws {
		self.me = RelayPacket.short(me)
		let ref = Weak<CallMedia>()
		audio = try AudioPipe(test: test) { p in
			guard let media = ref.value else { return }
			let d = p.data
			for peer in media.all() { media.pacer.now(d, to: peer.lane) }
		}
		self.video = video ? VideoPipe(test: test) { e in ref.value?.send(e) } : nil
		ref.value = self
	}

	private func all() -> [Peer] { lock.withLock { Array(peers.values) } }
	var count: Int { lock.withLock { peers.count } }

	// MARK: who's in

	/// A device joins the call: its voice into the mix, its picture to `onFrame`.
	func add(_ link: CallRoute, onFrame: (@Sendable (CMSampleBuffer) -> Void)?) {
		let decoder = video.map { _ in VideoDecoder() }
		decoder?.onFrame = onFrame
		let direct = link.relay == nil && link.via == nil
		let start = direct ? 1_500_000 : 600_000
		let lane = Pacer.Lane(link: link, control: nil, rate: Double(start))
		let peer = Peer(link: link, decoder: decoder, lane: lane, rate: start)
		decoder?.onNeedKey = { [weak self, weak peer] in if let peer, !peer.media2 { self?.askForKey(peer) } }
		decoder?.onWant = { [weak self, weak peer] in if let peer { self?.sendFeedback(peer) } }
		audio.add(link.device)
		lock.withLock { peers[link.device] = peer }
		pacer.add(lane)
		if let caps = link.caps { said(caps, by: peer) }
		link.onDatagram = { [weak self, weak peer] d in if let peer { self?.datagram(d, from: peer) } }
		// A link through someone in the call hasn't heard mine yet; a direct one has, but twice is harmless.
		Task { await link.send(.caps(Self.mine)) }
		video?.keyframe()
		fit()
	}

	func remove(_ device: String) {
		guard let peer = lock.withLock({ peers.removeValue(forKey: device) }) else { return }
		pacer.remove(peer.lane)
		peer.decoder?.stop()
		audio.remove(device)
		fit()
	}

	/// What a peer's media can do: media 2 gets its own rate control from here on.
	private func said(_ caps: MediaCaps, by peer: Peer) {
		let first = lock.withLock { () -> Bool in let f = peer.caps == nil; peer.caps = caps; if caps.media >= 2 { peer.reassembler = VideoReassembler(patience: 2) }; return f }
		guard caps.media >= 2 else { return }
		pacer.withLock {
			guard peer.lane.control == nil else { return }
			let direct = peer.link.relay == nil && peer.link.via == nil
			peer.lane.control = RateControl(start: Double(peer.rate), ceiling: direct ? 25_000_000 : peer.link.via == nil ? 4_000_000 : 2_000_000)
		}
		if first { callLog("call \(peer.link.device.prefix(8)): media \(caps.media)\(caps.hevc ? ", HEVC" : "")") }
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
		let k = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInteractive))
		k.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25), leeway: .milliseconds(2))
		k.setEventHandler { [weak self] in self?.tick() }
		k.resume()
		ticker = k
	}

	func startAudio() throws {
		guard !lock.withLock({ audioOn }) else { return }
		try audio.start()
		lock.withLock { audioOn = true }
	}

	func stop() {
		timer?.cancel(); timer = nil
		ticker?.cancel(); ticker = nil
		audio.stop(); video?.stop()
		pacer.stop()
		for p in all() { p.decoder?.stop() }
	}

	// MARK: out

	/// A frame from the encoder: in the form each peer reads, cut, and paced out to each.
	private func send(_ e: VideoPipe.Encoded) {
		if e.key { lock.withLock { keySent = seconds() } }
		if let t = e.token { lock.withLock { tokens[e.id] = (e.session, t); if tokens.count > 900 { tokens = tokens.filter { e.id &- $0.key < 600 } } } }
		var first: Data?, timed: Data?
		for peer in all() where !peer.paused {
			let v2 = peer.media2
			let blob: Data
			if v2 {
				if timed == nil { timed = VideoFrame(key: e.key, hevc: e.hevc, refresh: e.refresh, capture: e.capture, sets: e.sets, nals: e.nals).data }
				blob = timed!
			} else {
				// Never happens: HEVC only goes out when everyone reads it. But never send it to 0.2.15.
				guard !e.hevc else { continue }
				if first == nil { first = VideoFrame(key: e.key, sets: e.sets, nals: e.nals).data }
				blob = first!
			}
			let pieces: [Data]
			if v2 {
				// Reed-Solomon parity for the loss its feedback shows, with a fifth to spare.
				let loss = pacer.withLock { peer.lane.control?.loss ?? 0 }
				pieces = VideoFragment.code(frame: e.id, key: e.key || e.refresh, bytes: blob, mtu: peer.link.mtu - Sequenced.header, loss: loss * 1.2)
			} else {
				pieces = VideoFragment.cut(frame: e.id, key: e.key, bytes: blob, mtu: peer.link.mtu, group: peer.fec)
			}
			pacer.frame(pieces, id: e.id, key: e.key, to: peer.lane)
			peer.sentFrames += 1
		}
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
		case .sequenced:
			guard let s = Sequenced(d), s.inner.first != MediaKind.sequenced.rawValue else { return }
			let at = micros()
			let o = peer.decoder?.offset
			lock.withLock {
				peer.arrivals.add(s, at: at)
				if let o { peer.transit.append(Double(since(at, s.sent &- UInt32(truncatingIfNeeded: o))) / 1000); if peer.transit.count > 400 { peer.transit.removeFirst(200) } }
			}
			datagram(s.inner, from: peer)
		case .feedback:
			if let f = Feedback(d) { feedback(f, from: peer) }
		case .padding: break
		case .audio: if let p = AudioPacket(d) { audio.receive(p, from: peer.link.device) }
		case .video, .coded:
			guard let f = VideoFragment(d) else { return }
			let (frames, needKey, lostMore) = lock.withLock { () -> ([VideoReassembler.Frame], Bool, Bool) in
				let fr = peer.reassembler.add(f)
				let more = peer.reassembler.lost > peer.lostSeen
				peer.lostSeen = peer.reassembler.lost
				return (fr, peer.reassembler.needsKeyframe, more)
			}
			// A frame lost for good: media 2 asks for a refresh (in the feedback), media 1 for a key.
			if needKey, lostMore { peer.decoder?.lost() }
			for fr in frames { peer.decoder?.receive(fr) }
			if needKey, !peer.media2 { askForKey(peer) }
		}
	}

	private func askForKey(_ peer: Peer) {
		let now = Date()
		guard lock.withLock({ () -> Bool in guard now.timeIntervalSince(peer.askedKey) > 0.5 else { return false }; peer.askedKey = now; return true }) else { return }
		Task { await peer.link.send(.keyframe) }
	}

	/// A media 2 peer's word on what arrived: its rate, the clocks, and its decoding of mine.
	private func feedback(_ f: Feedback, from peer: Peer) {
		let (offset, rtt) = pacer.withLock { () -> (Int64?, Double?) in
			guard let c = peer.lane.control else { return (nil, nil) }
			c.feedback(f)
			return (c.offset, c.rtt)
		}
		if let offset { peer.decoder?.offset = offset }
		lock.withLock { if let d = f.decoded { peer.theirDecoded = d; peer.theirChain = f.chain } }
		acknowledge()
		// One answer a round trip, and none while a keyframe that went out lately may still be landing.
		let now = seconds(), wait = (rtt ?? 100) / 1000 + 0.05, landing = max(0.35, wait + 0.1)
		switch f.want {
		case .nothing: break
		case .refresh:
			guard lock.withLock({ () -> Bool in guard now - lastRefresh > wait, now - lastKey > wait, now - keySent > landing else { return false }; lastRefresh = now; return true }) else { return }
			video?.refresh()
		case .keyframe:
			guard lock.withLock({ () -> Bool in guard now - lastKey > wait, now - keySent > landing else { return false }; lastKey = now; return true }) else { return }
			video?.keyframe()
		}
	}

	/// The encoder's acknowledged references: frames every media 2 peer taking video has decoded
	/// (each says its unbroken run, start to newest), the newest three of them.
	private func acknowledge() {
		guard let v = video else { return }
		let tokens: [Int] = lock.withLock {
			let ps = peers.values.filter { $0.media2 && !$0.paused }
			guard !ps.isEmpty, ps.allSatisfy({ $0.theirDecoded != nil }) else { return [] }
			// Frame ids only grow; a run is [chain, decoded].
			let lo = ps.map(\.theirChain).max()!, hi = ps.compactMap(\.theirDecoded).min()!
			guard Int32(bitPattern: hi &- lo) >= 0 else { return [] }
			let session = self.tokens[hi]?.session
			var out: [Int] = []
			var id = hi
			while out.count < 3, Int32(bitPattern: id &- lo) >= 0, hi &- id < 120 {
				if let t = self.tokens[id], t.session == session { out.insert(t.token, at: 0) }
				id &-= 1
			}
			return out
		}
		v.acked = tokens
	}

	/// Media 2: what arrived from this peer, now.
	private func sendFeedback(_ peer: Peer) {
		guard peer.media2 else { return }
		let state = peer.decoder?.state ?? (nil, 0, .nothing)
		let fs = lock.withLock { peer.arrivals.feedback(room: peer.link.mtu, decoded: state.decoded, chain: state.chain, want: state.want) }
		for f in fs { pacer.now(f.data, to: peer.lane, numbered: false) }
	}

	/// A signal for the media; false when it's the session's.
	func handle(_ s: CallSignal, from device: String) -> Bool {
		guard let peer = lock.withLock({ peers[device] }) else { if case .caps = s { return true }; return false }
		switch s {
		case .caps(let c): said(c, by: peer); return true
		case .keyframe:
			// 0.2.15 asks every half second until one lands: one is enough while it's on its way.
			let now = seconds(), rtt = Double(peer.link.rtt ?? 100) / 1000
			if lock.withLock({ () -> Bool in guard now - keySent > max(0.35, rtt + 0.15), now - lastKey > 0.2 else { return false }; lastKey = now; return true }) { video?.keyframe() }
			return true
		case .stats(let a, let fps, let loss):
			lock.withLock { peer.theirs = (a, fps, loss) }
			adapt(peer)
			return true
		default: return false
		}
	}

	// MARK: every 25 ms, every second

	/// Feedback due to each media 2 peer (every 50 ms with anything to say, every 250 ms regardless,
	/// sooner with a lot), and the encoder fitted to the rates.
	private func tick() {
		let now = seconds()
		for peer in all() where peer.media2 {
			let due = lock.withLock { () -> Bool in
				let since = now - peer.arrivals.lastSent
				return peer.arrivals.waiting > 0 && since >= 0.05 || peer.arrivals.waiting >= 200 || since >= 0.25
			}
			if due { sendFeedback(peer) }
		}
		fit()
	}

	private func second() {
		var lines: [String] = []
		for peer in all() {
			let d = peer.link.device
			let r = lock.withLock { (peer.reassembler.delivered, peer.reassembler.lost, peer.reassembler.recovered) }
			let a = audio.stats(d)
			let dv = r.0 - peer.last.delivered, dl = r.1 - peer.last.lost
			let got = a.received - peer.last.received, sent = a.expected - peer.last.expected
			let out = peer.sentFrames - peer.last.encodedTo
			let shown = peer.decoder?.shownCount ?? 0
			peer.mine = (sent <= 0 ? 0 : max(0, 1 - Double(got) / Double(sent)), Double(dv), dv + dl == 0 ? 0 : Double(dl) / Double(dv + dl))
			peer.shownFps = shown - peer.last.shown
			peer.last = (r.0, r.1, a.received, a.expected, peer.sentFrames, shown)
			peer.sentFps = Double(out)
			let m = peer.mine
			Task { await peer.link.send(.stats(audioLoss: m.audioLoss, videoFps: m.videoFps, videoLoss: m.videoLoss)) }
			var v2 = ""
			if let c = pacer.withLock({ peer.lane.control.map { ($0.rate, $0.queue, $0.loss, $0.delivered) } }) {
				let b = peer.decoder?.breakdown
				let enc = video?.encodeLatency.sorted() ?? []
				v2 = String(format: " · rate %d kbps (delivered %d) queue %.0f ms lost %.1f%%%@", Int(c.0 / 1000), Int(c.3 / 1000), c.1, c.2 * 100,
					transitLine(peer) +
					(b.map { String(format: " · from their capture: whole %.0f/%.0f, decoded %.0f/%.0f, shown %.0f/%.0f ms · my encode %.0f, paced %.0f ms", $0.whole.0, $0.whole.1, $0.decoded.0, $0.decoded.1, $0.shown.0, $0.shown.1, enc.isEmpty ? .nan : enc[enc.count / 2], pacer.stats.first { $0.device == d }?.wait ?? .nan) } ?? ""))
			}
			lines.append(String(format: "%@%@ rtt %@ · audio in %d/%d lost %.1f%% rescued %d concealed %d · video out %d fps fec 1/%d%@ · in %.0f fps lost %.1f%% rebuilt %d decoded %d%@",
				String(d.prefix(8)), peer.link.via.map { " via \($0.prefix(8))" } ?? "", peer.link.rtt.map(String.init) ?? "-", a.received, a.expected, m.audioLoss * 100, a.rescued, a.concealed,
				out, peer.fec, peer.paused ? " (voice only)" : "", m.videoFps, m.videoLoss * 100, r.2, peer.decoder?.decoded ?? 0, v2))
		}
		if !lines.isEmpty {
			let v = video.map { "\($0.codec) \($0.size) \($0.fps) fps \($0.bitrate / 1000) kbps" } ?? "off"
			let opus = audio.opusBytes
			let made = (opus - opusSeen) * 8 / 1000
			opusSeen = opus
			callLog("call stats · \(count) connected · audio out \(audio.sent) at \(audio.bitrate / 1000) kbps (made \(made)) · \(audio.health()) · video \(v)\n    " + lines.joined(separator: "\n    "))
		}
		onChange?()
	}

	private func transitLine(_ peer: Peer) -> String {
		let t = lock.withLock { peer.transit.sorted() }
		return t.isEmpty ? "" : String(format: " · transit %.1f/%.1f", t[t.count / 2], t[t.count * 95 / 100])
	}

	/// A peer's report of my media, once a second. Media 2: parity from the loss its feedback shows,
	/// and voice only while even the floor gets no frames through. Media 1, as 0.2.15: missing
	/// datagrams with no queue behind them are noise on its path (more parity, not less video); a
	/// queue building (its round trip rising) or frames lost even after parity is congestion: its
	/// rate steps down fast and back up slowly. When even the floor can't get a third of the frames
	/// to it for five seconds, it gets voice only and is offered video again after ten (twenty,
	/// forty…) seconds.
	private func adapt(_ p: Peer) {
		guard video != nil else { return }
		let control = pacer.withLock { p.lane.control.map { ($0.rate, $0.loss) } }
		lock.withLock {
			if let (rate, loss) = control {
				p.fec = loss < 0.002 ? 20 : loss < 0.01 ? 10 : loss < 0.03 ? 6 : loss < 0.06 ? 4 : loss < 0.1 ? 3 : 2
				p.rate = Int(rate)
				p.calm = p.theirs.videoLoss < 0.05 ? p.calm + 1 : 0
			} else {
				let raw = p.theirs.audioLoss
				p.fec = raw < 0.01 ? 10 : raw < 0.03 ? 6 : raw < 0.06 ? 4 : raw < 0.1 ? 3 : 2
				let rtt = p.link.rtt ?? 0
				p.baseRtt = min(p.baseRtt, rtt)
				let queue = rtt - p.baseRtt
				if queue > 150 || p.theirs.videoLoss > 0.15 { p.rate = Int(Double(p.rate) * 0.7); p.calm = 0 }
				else if queue > 60 || p.theirs.videoLoss > 0.05 || raw > 0.12 { p.rate = Int(Double(p.rate) * 0.9); p.calm = 0 }
				else { p.calm += 1; if p.calm >= 3 { p.rate = Int(Double(p.rate) * 1.08) } }
				p.rate = min(p.link.relay == nil && p.link.via == nil ? 2_500_000 : 1_200_000, max(120_000, p.rate))
			}

			if let at = p.pausedAt {
				if Date().timeIntervalSince(at) >= p.backoff { p.pausedAt = nil; p.weak = 0; p.paused = false; callLog("call video to \(p.link.device.prefix(8)): trying again") }
			} else {
				let through = p.sentFps > 0 ? min(1, p.theirs.videoFps / p.sentFps) : 1
				p.weak = p.rate <= 160_000 && through < 0.33 ? p.weak + 1 : 0
				if p.weak >= 5 {
					p.pausedAt = Date(); p.backoff = min(60, p.backoff * (p.paused ? 2 : 1)); p.paused = true
					callLog("call video to \(p.link.device.prefix(8)) paused: its link is too weak")
				} else if p.calm >= 10 { p.backoff = 10 }
			}
		}
		fit()
	}

	/// The encoder fitted to the peers: the lowest rate any taking video can take, less the voice
	/// and the parity, capped by how many listen; the codec everyone reads; and the size and frame
	/// rate that rate affords. The voice's own bitrate from the same rate.
	private func fit() {
		let ps = all()
		let n = ps.count
		let rates = ps.filter { !$0.paused }.map { p in pacer.withLock { p.lane.control?.rate } ?? Double(p.rate) }
		for p in ps where !p.media2 { pacer.withLock { p.lane.rate = Double(p.rate) } }
		let path = rates.min() ?? 1_500_000
		let voice = n == 1 && path > 2_000_000 ? 96_000 : path > 800_000 ? 64_000 : path > 300_000 ? 32_000 : 24_000
		if voice != audio.bitrate { audio.bitrate = voice }
		guard let v = video else { return }
		let legacy = ps.contains { !$0.media2 }
		let hevc = Self.mine.hevc && !ps.isEmpty && ps.allSatisfy { $0.caps?.hevc == true }
		if hevc != v.hevc { v.hevc = hevc; callLog("call video: \(hevc ? "HEVC" : "H.264")") }
		if legacy != v.periodicKeys { v.periodicKeys = legacy }
		// Voice twice over (each packet carries the one before) with its headers, then parity:
		// media 2's for a typical block of 16 at the loss it shows, media 1's one in `fec`.
		let parity = ps.map { p -> Double in
			if let loss = pacer.withLock({ p.lane.control?.loss }) { return 1 + Double(Erasure.parity(for: 16, loss: loss * 1.2)) / 16 }
			return p.fec > 0 ? 1 + 1 / Double(p.fec) : 1
		}.max() ?? 1
		// One to one: 1080p60 looks as good as it gets by 12 Mbps of HEVC (16 of H.264); more only
		// makes each frame longer to get through the path.
		// A mesh sends to each: n × cap (and the voice, and parity) is the uplink it needs, about 4
		// Mbps whatever the size, so a call still fits a home connection.
		let cap: Double = n <= 1 ? (hevc ? 12_000_000 : 16_000_000) : n == 2 ? 1_800_000 : n == 3 ? 1_200_000 : n == 4 ? 800_000 : 500_000
		let rate = max(100_000, min(cap, (path - Double(voice * 2 + 20_000)) / parity * 0.88))
		// Told when it moves by more than 3%: the encoder needn't hear every 25 ms.
		if abs(rate - Double(v.bitrate)) > Double(v.bitrate) * 0.03 { v.bitrate = Int(rate) }
		let tier = lock.withLock { ladder.fit(rate, hevc: hevc, source: v.source) }
		if tier.height != v.height || tier.fps != v.fps {
			v.height = tier.height; v.fps = tier.fps
			callLog("call video: \(tier.height)p\(tier.fps) at \(Int(rate) / 1000) kbps")
		}
	}

	/// Latency from their camera to my screen (ms), the last few hundred frames.
	func latencies(_ device: String) -> [Double] { lock.withLock { peers[device] }?.decoder?.latency ?? [] }
	/// Frames of this peer's video decoded so far.
	func decoded(_ device: String) -> Int { lock.withLock { peers[device]?.decoder?.decoded ?? 0 } }
	/// Voice and video quality of one peer, for the screen.
	func paused(_ device: String) -> Bool { lock.withLock { peers[device]?.paused ?? false } }
	/// Whether every peer is getting voice only from me (my picture is paused for all).
	var videoPaused: Bool { lock.withLock { !peers.isEmpty && peers.values.allSatisfy(\.paused) } }
	var remoteLevel: Float { audio.remoteLevel }
	func level(_ device: String) -> Float { audio.level(device) }
	var localLevel: Float { audio.localLevel }

	/// How it's going with one peer: what I send it, what it sends me, and the path between.
	func quality(_ device: String) -> CallQuality? {
		guard let p = lock.withLock({ peers[device] }) else { return nil }
		var q = CallQuality()
		if let v = video { q.codec = v.codec; q.size = v.size; q.fps = v.fps; q.kbps = v.bitrate / 1000 }
		q.inSize = p.decoder?.size ?? ""; q.inFps = p.shownFps
		let lat = p.decoder?.latency.suffix(150).sorted() ?? []
		q.latency = lat.isEmpty ? nil : lat[lat.count / 2]
		q.rtt = pacer.withLock { p.lane.control?.rtt.map { Int($0) } } ?? p.link.rtt
		q.loss = pacer.withLock { p.lane.control?.loss } ?? p.theirs.videoLoss
		q.media2 = p.media2
		return q
	}
}

/// Size and frame rate for a bitrate: the best of 1080p60, 720p60, 1080p30, 720p30, 540p30,
/// 360p30, 360p15 (none above the camera) whose pixels a second the rate covers at the bits per
/// pixel that codec needs to look good. Each new size starts on a keyframe, and a keyframe on a
/// tight path is itself a queue, so the size holds four seconds after it changes (unless the rate
/// falls below 60% of what it needs); a step up waits until the rate has covered the next with 40%
/// to spare for three seconds; a step down comes once the rate falls a sixth short.
struct Ladder {
	static let rungs: [(height: Int, fps: Int)] = [(1080, 60), (720, 60), (1080, 30), (720, 30), (540, 30), (360, 30), (360, 15)]
	private(set) var current = 3
	private var above: Double?
	private var changed = 0.0

	static func needs(_ r: (height: Int, fps: Int), hevc: Bool) -> Double {
		Double(r.height * r.height * 16 / 9 * r.fps) * (hevc ? 0.042 : 0.06)
	}

	mutating func fit(_ rate: Double, hevc: Bool, source: (width: Int, height: Int, fps: Int)) -> (height: Int, fps: Int) {
		let short = min(source.width, source.height)
		let allowed = Self.rungs.indices.filter { Self.rungs[$0].height <= short && Self.rungs[$0].fps <= source.fps }
		guard let last = allowed.last else { return (min(short, 720), min(30, source.fps)) }
		if !allowed.contains(current) { current = allowed.first { Self.rungs[$0].height <= Self.rungs[current].height && Self.rungs[$0].fps <= Self.rungs[current].fps } ?? last }
		let now = seconds()
		let need = Self.needs(Self.rungs[current], hevc: hevc)
		let held = now - changed < 4 && rate >= need * 0.6
		// The best this rate affords outright.
		let best = allowed.first { Self.needs(Self.rungs[$0], hevc: hevc) <= rate } ?? last
		if best > current, rate < need * 0.85, !held {
			current = best; changed = now; above = nil
		} else if best < current, !held {
			// Up only with room to spare, held for three seconds.
			let up = allowed.first { Self.needs(Self.rungs[$0], hevc: hevc) * 1.4 <= rate } ?? current
			if up < current { if let a = above { if now - a >= 3 { current = up; changed = now; above = nil } } else { above = now } } else { above = nil }
		} else if best >= current { above = nil }
		return Self.rungs[current]
	}
}

private final class Weak<T: AnyObject>: @unchecked Sendable { weak var value: T? }
