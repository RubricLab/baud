import XCTest
@testable import BaudCore

final class CallWireTests: XCTestCase {
	func testSignalsSurviveAnyChunking() {
		let sent: [CallSignal] = [.ring(id: "c1", conv: "conv", video: true, user: "u", name: "Ana"), .ringing, .accept(video: false), .state(muted: true, camera: false), .keyframe, .stats(audioLoss: 0.01, videoFps: 29.5, videoLoss: 0), .end]
		let bytes = sent.reduce(Data()) { $0 + $1.framed }
		for size in [1, 3, 7, 64, bytes.count] {
			var r = SignalReader(), got: [CallSignal] = []
			var i = 0
			while i < bytes.count { got += r.add(bytes[i..<min(bytes.count, i + size)]); i += size }
			XCTAssertEqual(got, sent, "chunks of \(size)")
		}
	}

	func testPacketsRoundTrip() {
		let a = AudioPacket(seq: 0xDEADBEEF, level: 200, payload: Data([1, 2, 3]))
		XCTAssertEqual(AudioPacket(a.data), a)
		XCTAssertNil(AudioPacket(Data([2, 0, 0, 0, 0, 0, 1])))
		let bytes = Data((0..<5000).map { UInt8($0 % 251) })
		let pieces = VideoFragment.cut(frame: 7, key: true, bytes: bytes, mtu: 1200)
		XCTAssertEqual(pieces.count, 5)
		XCTAssertTrue(pieces.allSatisfy { $0.count <= 1200 })
		var r = VideoReassembler()
		var out: [VideoReassembler.Frame] = []
		for p in pieces.reversed() { out += r.add(VideoFragment(p)!) }
		XCTAssertEqual(out, [.init(id: 7, key: true, bytes: bytes)])
	}

	/// A run of frames, a keyframe every `gop`; `drop` decides per piece whether it's lost.
	private func play(frames: Int, gop: Int, shuffle: Bool = false, drop: (Int, Int) -> Bool) -> (VideoReassembler, [UInt32]) {
		var r = VideoReassembler(), out: [UInt32] = []
		var pieces: [(Int, Data)] = []
		for f in 0..<frames {
			let size = f % gop == 0 ? 6000 : 1500
			for (i, p) in VideoFragment.cut(frame: UInt32(f), key: f % gop == 0, bytes: Data(repeating: UInt8(f % 255), count: size), mtu: 1200).enumerated() where !drop(f, i) { pieces.append((f, p)) }
		}
		if shuffle {
			// Neighbours swap: what a busy path does, never more than a frame or two out of order.
			for i in stride(from: 0, to: pieces.count - 1, by: 3) { pieces.swapAt(i, i + 1) }
		}
		for (_, p) in pieces { out += r.add(VideoFragment(p)!).map(\.id) }
		return (r, out)
	}

	func testCleanAndReorderedFramesAllArriveInOrder() {
		for shuffle in [false, true] {
			let (r, out) = play(frames: 90, gop: 30, shuffle: shuffle) { _, _ in false }
			XCTAssertEqual(out, (0..<90).map(UInt32.init), "shuffle \(shuffle)")
			XCTAssertEqual(r.lost, 0)
			XCTAssertFalse(r.needsKeyframe)
		}
	}

	func testALostFrameWaitsForTheNextKeyframe() {
		// Frame 10 loses a piece: 10 to 29 can't be decoded; 30 (a keyframe) and on play.
		let (r, out) = play(frames: 60, gop: 30) { f, i in f == 10 && i == 0 }
		XCTAssertEqual(out, (0..<10).map(UInt32.init) + (30..<60).map(UInt32.init))
		XCTAssertEqual(r.lost, 20)
		XCTAssertFalse(r.needsKeyframe)
	}

	func testAsksForAKeyframeWhileItWaits() {
		var r = VideoReassembler()
		// Frame 2 never comes: two later frames aren't enough to call it, the third is.
		for f in 0..<5 { for p in VideoFragment.cut(frame: UInt32(f), key: f == 0, bytes: Data(count: 100), mtu: 1200) where f != 2 { _ = r.add(VideoFragment(p)!) } }
		XCTAssertFalse(r.needsKeyframe)
		_ = r.add(VideoFragment(VideoFragment.cut(frame: 5, key: false, bytes: Data(count: 100), mtu: 1200)[0])!)
		XCTAssertTrue(r.needsKeyframe)
		_ = r.add(VideoFragment(VideoFragment.cut(frame: 6, key: true, bytes: Data(count: 100), mtu: 1200)[0])!)
		XCTAssertFalse(r.needsKeyframe)
		XCTAssertEqual(r.delivered, 3) // 0, 1, then the keyframe 6
	}

	func testJitterBufferSmoothsAndConceals() {
		var j = JitterBuffer(target: 3)
		XCTAssertEqual(j.pull(), .idle)
		// Packets 0…99 arrive in bursts of two every 40 ms, 17 lost; playout pulls every 20 ms.
		var pulled: [JitterBuffer.Pull] = []
		// As long as the stream lasts: playout runs two ticks behind the last arrival.
		for tick in 0..<102 {
			if tick % 2 == 0 { for s in [tick, tick + 1] where s < 100 && s != 17 { j.put(AudioPacket(seq: UInt32(s), level: 9, payload: Data([UInt8(s)]))) } }
			pulled.append(j.pull())
		}
		let frames = pulled.compactMap { if case .frame(let d, _) = $0 { return Int(d[0]) }; return nil }
		XCTAssertEqual(frames, (0..<100).filter { $0 != 17 })
		XCTAssertEqual(j.concealed, 1)
		XCTAssertEqual(j.late, 0)
		XCTAssertEqual(j.loss, 1.0 / 100, accuracy: 0.001)
	}

	func testLatePacketsRaiseTheTarget() {
		var j = JitterBuffer(target: 2)
		for s in 0..<4 { j.put(AudioPacket(seq: UInt32(s), level: 0, payload: Data([0]))) }
		for _ in 0..<3 { _ = j.pull() }
		j.put(AudioPacket(seq: 1, level: 0, payload: Data([0])))   // after its turn
		XCTAssertEqual(j.late, 1)
		XCTAssertEqual(j.target, 3)
	}

	func testParityRebuildsOneLostPiecePerGroup() {
		let bytes = Data((0..<7500).map { UInt8($0 * 7 % 256) })
		let pieces = VideoFragment.cut(frame: 0, key: true, bytes: bytes, mtu: 1200, group: 3).map { VideoFragment($0)! }
		XCTAssertEqual(pieces.filter(\.parity).count, 3)   // 7 data pieces: groups of 3, 3, 1
		// Lose one data piece in each group, including the short last one.
		let lost: Set<UInt16> = [1, 3, 6]
		var r = VideoReassembler(), out: [VideoReassembler.Frame] = []
		for p in pieces where p.parity || !lost.contains(p.index) { out += r.add(p) }
		XCTAssertEqual(out.map(\.bytes), [bytes])
		XCTAssertEqual(r.recovered, 3)
		// Two lost in one group: parity can't, the frame waits.
		var r2 = VideoReassembler()
		for p in pieces where p.parity || ![0, 1].contains(p.index) { XCTAssertTrue(r2.add(p).isEmpty) }
	}

	func testTheFrameBeforeFillsAHole() {
		var j = JitterBuffer(target: 2)
		func packet(_ s: UInt32) -> AudioPacket { AudioPacket(seq: s, level: 1, payload: Data([UInt8(s)]), previous: s > 0 ? Data([UInt8(s - 1)]) : nil) }
		for s: UInt32 in [0, 1, 3, 4] { j.put(packet(s)) }   // 2 never comes; 3 carries it
		let got = (0..<5).compactMap { _ -> Int? in if case .frame(let d, _) = j.pull() { return Int(d[0]) }; return nil }
		XCTAssertEqual(got, [0, 1, 2, 3, 4])
		XCTAssertEqual(j.rescued, 1)
		XCTAssertEqual(j.concealed, 0)
		XCTAssertEqual(j.expected, 5)
		XCTAssertEqual(AudioPacket(packet(3).data), packet(3))
	}

	func testCallLinesReadPlainly() {
		XCTAssertEqual(CallRecord(video: true, outcome: "talked", seconds: 245).line(mine: true, caller: "Ana"), "Video call · 4 min")
		XCTAssertEqual(CallRecord(video: false, outcome: "talked", seconds: 32).line(mine: false, caller: "Ana"), "Call · 32 s")
		XCTAssertEqual(CallRecord(video: false, outcome: "missed", seconds: 0).line(mine: false, caller: "Ana"), "Missed call from Ana")
		XCTAssertEqual(CallRecord(video: true, outcome: "missed", seconds: 0).line(mine: true, caller: "Ana"), "Video call · no answer")
		XCTAssertEqual(CallRecord(video: false, outcome: "declined", seconds: 0).line(mine: false, caller: "Ana"), "Declined call from Ana")
	}

	/// Caps go first on every link; a reader that can't decode a signal (0.2.15's, meeting `caps`)
	/// skips just that one and reads on.
	func testCapsAreSaidAndUnknownSignalsSkipped() {
		let caps = CallSignal.caps(MediaCaps(media: 2, hevc: true))
		XCTAssertTrue(String(data: caps.framed.dropFirst(4), encoding: .utf8)!.hasPrefix(#"{"caps":{"_0":{"#))
		var unknown = Data(#"{"somethingNew":{"_0":1}}"#.utf8)
		var n = UInt32(unknown.count).bigEndian
		unknown = Data(bytes: &n, count: 4) + unknown
		var r = SignalReader()
		XCTAssertEqual(r.add(caps.framed + unknown + CallSignal.ringing.framed), [caps, .ringing])
	}

	func testFramesInBothForms() {
		let sets = [Data([0x67, 1, 2, 3]), Data([0x68, 9])]
		let nals = Data([0, 0, 0, 3, 0x65, 7, 7])
		// The first form is byte for byte what 0.2.15 sends and decodes.
		let first = VideoFrame(key: true, sets: sets, nals: nals)
		XCTAssertEqual(first.data, Data([1, 2, 0, 4, 0x67, 1, 2, 3, 0, 2, 0x68, 9]) + nals)
		XCTAssertEqual(VideoFrame(first.data), first)
		XCTAssertEqual(VideoFrame(VideoFrame(key: false, nals: nals).data), VideoFrame(key: false, nals: nals))
		let timed = VideoFrame(key: false, hevc: true, refresh: true, capture: 0xF00DCAFE, nals: nals)
		XCTAssertEqual(VideoFrame(timed.data), timed)
		let timedKey = VideoFrame(key: true, hevc: true, capture: 7, sets: sets + [Data([0x40])], nals: nals)
		XCTAssertEqual(VideoFrame(timedKey.data), timedKey)
		XCTAssertNil(VideoFrame(Data([1, 3])))
	}

	func testSequencedAndFeedbackRoundTrip() {
		let inner = AudioPacket(seq: 9, level: 3, payload: Data([1, 2])).data
		let s = Sequenced(seq: 0xFFFE, sent: 0xFFFF_FFF0, inner: inner)
		XCTAssertEqual(Sequenced(s.data), s)
		XCTAssertEqual(MediaKind(rawValue: s.data[0]), .sequenced)
		// Arrivals straddling the clock's wrap, one missing; kept to a tenth of a millisecond.
		let f = Feedback(first: 0xFFFF, arrivals: [0xFFFF_FF00, nil, 0x0000_0100, 0x0000_2000], now: 5, echo: 6, held: 7, decoded: 42, chain: 30, want: .refresh)
		let back = Feedback(f.data)!
		XCTAssertEqual(back.first, 0xFFFF)
		XCTAssertEqual(back.arrivals.map { $0.map { Int32(bitPattern: $0 &- 0xFFFF_FF00) } }, [0, nil, 500, 8400])
		XCTAssertEqual([back.now, back.echo, back.held, back.chain], [5, 6, 7, 30])
		XCTAssertEqual(back.decoded, 42)
		XCTAssertEqual(back.want, .refresh)
		let none = Feedback(first: 0, arrivals: [], now: 1, echo: 0, held: 0, decoded: nil, chain: 0, want: .nothing)
		XCTAssertEqual(Feedback(none.data), none)
		XCTAssertEqual(none.data.count, Feedback.header)
	}

	/// Media 2's Reed-Solomon parity: any `block` of a block's pieces bring it back, whichever they are.
	func testCodedFramesComeBackFromAnyOfThem() {
		var rng = SystemRandomNumberGenerator()
		for size in [900, 7500, 100_000] {
			let bytes = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
			let pieces = VideoFragment.code(frame: 3, key: true, bytes: bytes, mtu: 1200, loss: 0.05).map { VideoFragment($0)! }
			XCTAssertTrue(pieces.allSatisfy { $0.data.count <= 1200 })
			let data = pieces.filter { !$0.parity }, parity = pieces.filter(\.parity)
			let block = data[0].group, rows = parity.first?.rows ?? 0
			XCTAssertEqual(rows, Erasure.parity(for: block, loss: 0.05))
			XCTAssertLessThanOrEqual(block, Erasure.block)
			for trial in 0..<20 {
				// Lose `rows` pieces of every block (data or parity, at random), then shuffle.
				var kept: [VideoFragment] = []
				let blocks = (data.count + block - 1) / block
				for b in 0..<blocks {
					let mine = pieces.filter { $0.parity ? Int($0.index) / rows == b : Int($0.index) / block == b }
					kept += mine.shuffled(using: &rng).dropFirst(rows)
				}
				var r = VideoReassembler()
				let out = kept.shuffled(using: &rng).flatMap { r.add($0) }
				XCTAssertEqual(out.map(\.bytes), [bytes], "size \(size), trial \(trial)")
			}
			// One more lost than parity in a block: it can't, and waits.
			var r = VideoReassembler()
			let short = pieces.filter { $0.parity ? Int($0.index) / max(1, rows) != 0 : Int($0.index) >= rows + 1 || Int($0.index) / block != 0 }
			XCTAssertTrue(short.flatMap { r.add($0) }.isEmpty, "size \(size)")
		}
		// No loss to speak of: one parity piece for a typical block; ten percent: a good few more.
		XCTAssertEqual(Erasure.parity(for: 16, loss: 0), 1)
		XCTAssertGreaterThan(Erasure.parity(for: 16, loss: 0.1), 4)
	}

	/// Given arrival times, the buffer sizes itself to the jitter: a calm path plays a frame or two
	/// behind, a path that starts wobbling by 50 ms gets room for it within a couple of seconds and
	/// stops concealing, and once it calms the buffer comes back down.
	func testJitterBufferSizesItselfToTheJitter() {
		var j = JitterBuffer()
		var rng = SystemRandomNumberGenerator()
		var seq: UInt32 = 0
		var t = 0.0
		var pending: [(at: Double, seq: UInt32)] = []
		func run(seconds: Double, jitter: Double) -> (concealed: Int, maxTarget: Int, lastTarget: Int) {
			let c0 = j.concealed
			var most = 0
			let end = t + seconds
			while t < end {
				// The sender: a frame every 20 ms, each delayed somewhere between 0 and `jitter`.
				if Int((t * 1000).rounded()) % 20 == 0 {
					pending.append((t + Double.random(in: 0...jitter, using: &rng), seq)); seq += 1
				}
				for p in pending where p.at <= t { j.put(AudioPacket(seq: p.seq, level: 0, payload: Data([1])), at: p.at) }
				pending.removeAll { $0.at <= t }
				// The speaker: 20 ms every 20 ms, half a frame out of step with the sender.
				if Int((t * 1000).rounded()) % 20 == 10 { _ = j.pull() }
				most = max(most, j.target)
				t += 0.001
			}
			return (j.concealed - c0, most, j.target)
		}
		let calm = run(seconds: 3, jitter: 0.002)
		XCTAssertLessThanOrEqual(calm.lastTarget, 2)
		_ = run(seconds: 2, jitter: 0.05)
		let settled = run(seconds: 4, jitter: 0.05)
		XCTAssertGreaterThanOrEqual(settled.lastTarget, 3)
		XCTAssertLessThanOrEqual(settled.concealed, 6, "settled at \(settled.lastTarget)")
		let after = run(seconds: 8, jitter: 0.002)
		XCTAssertLessThanOrEqual(after.lastTarget, 2)
		XCTAssertGreaterThan(j.skipped, 0)
	}

	func testPatienceCallsAHoleSooner() {
		var r = VideoReassembler(patience: 1)
		for f in 0..<4 { for p in VideoFragment.cut(frame: UInt32(f), key: f == 0, bytes: Data(count: 100), mtu: 1200) where f != 2 { _ = r.add(VideoFragment(p)!) } }
		XCTAssertTrue(r.needsKeyframe)
		XCTAssertEqual(r.delivered, 2)
	}

	func testRelayPacketsNameBothEnds() {
		let a = String(repeating: "ab", count: 32), b = String(repeating: "0f", count: 32)
		let inner = AudioPacket(seq: 7, level: 1, payload: Data([9, 9])).data
		let p = RelayPacket(from: a, to: b, inner: inner)
		let back = RelayPacket(p.data)!
		XCTAssertEqual(back.from, RelayPacket.short(a))
		XCTAssertEqual(back.to, RelayPacket.short(b))
		XCTAssertEqual(AudioPacket(back.inner)?.seq, 7)
		XCTAssertEqual(p.data.count, inner.count + RelayPacket.header)
		let sig = CallSignal.forward(from: a, to: b, signal: .state(muted: true, camera: false))
		var r = SignalReader()
		XCTAssertEqual(r.add(sig.framed), [sig])
	}
}
