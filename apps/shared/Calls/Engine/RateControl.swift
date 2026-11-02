/// How fast to send to one device on media 2, from what it says arrived (`Feedback`, every 50 ms or
/// so). Every datagram to it is numbered and stamped as it leaves (the pacer); the feedback says
/// when each came. From that: the one-way delay against the lowest seen lately (the queue we're
/// building somewhere on the path), what the path actually delivered, the loss, and the round trip.
/// A queue that stands (its smallest in the last 100 ms, so a burst passing through doesn't count)
/// is the only thing that slows it: past 20 ms it drops to 85% of what was delivered. Then it looks
/// again a round trip later (what was already on its way still lands in the queue till then), and
/// cuts again only if the queue grows past that, or hasn't drained by when it should have at the
/// lower rate: cutting every round trip while an old queue drains would take it far below the
/// path. With a queue standing, what was delivered is what the path carries, however little we
/// sent; a cut still never takes it below a quarter of what it was. A keyframe is a queue of our
/// own making: for as long as it takes to drain at the rate, the
/// queue it builds doesn't count. Between 8 and 20 it holds; under 8 it climbs: two and a half
/// times a second until the path first pushes back, then for ten seconds 5% a second from 70% of
/// where it did, 50% a second below that. Loss with no queue is noise on the path, for parity to cover, not a
/// reason to slow down (unless a quarter of the last half second's goes: a policer). It never climbs more than 3 Mbps, or twice, past what the encoder
/// actually gives it: a still picture that suddenly moves can't flood a path nobody has measured.
/// `Arrivals` is the other end of it: what came in, said back as feedback.
import BaudCore
import Foundation

/// The host clock in µs, wrapping: what the wire stamps carry.
func micros() -> UInt32 { UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000) }
func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
/// a − b in µs, for stamps that wrap.
func since(_ a: UInt32, _ b: UInt32) -> Int64 { Int64(Int32(bitPattern: a &- b)) }

final class RateControl: @unchecked Sendable {
	let floor: Double
	var ceiling: Double
	private(set) var rate: Double
	/// The queue standing on the path now (ms), the delivered rate (bps), loss (0…1), round trip (ms).
	private(set) var queue = 0.0, delivered = 0.0, loss = 0.0, rtt: Double?
	/// Their clock minus mine, µs, from the round trip that was quickest lately.
	private(set) var offset: Int64?
	/// Datagrams sent and acknowledged, ever.
	private(set) var acked = 0, lostCount = 0, decreases = 0
	/// What the encoder actually gives (bps over the last half second).
	private(set) var sending = 0.0

	private struct Sent { var seq: UInt16 = 0, at: UInt32 = 0, bytes: Int32 = 0, valid = false }
	private var history = [Sent](repeating: Sent(), count: 8192)
	private var reported: UInt16?
	private var origin: UInt32?
	/// Lowest one-way delay in each of the last 15 seconds (relative µs).
	private var minima: [(second: Int, owd: Int64)] = []
	/// The last 300 ms of arrivals: when (their clock), the queue it saw (µs), bytes.
	private var recent: [(at: UInt32, queue: Int64, bytes: Int)] = []
	private var outgoing: [(at: Double, bytes: Int)] = []
	private var losses: [(at: Double, lost: Int, of: Int)] = []
	private var clocks: [(at: Double, rtt: Int64, offset: Int64)] = []
	private var lastDecrease = 0.0, lastUpdate = 0.0
	/// The queue a round trip after the last cut, once seen.
	private var queueAfter: Double?
	/// Until when a keyframe of ours is still draining through the path (and word of it coming back).
	private var burstUntil = 0.0, drained = 0.0

	/// A keyframe's bytes just went out: its queue is ours, not the path's, for as long as it
	/// takes to drain at the rate (and a round trip for word of it to come back).
	func burst(_ bytes: Int) {
		let now = seconds()
		drained = max(drained, now) + Double(bytes * 8) / rate
		burstUntil = drained + (rtt ?? 100) / 1000
	}
	/// Where the path last pushed back (bps), and when.
	private var capacity: (rate: Double, at: Double)?

	init(start: Double, floor: Double = 150_000, ceiling: Double) {
		rate = start; self.floor = floor; self.ceiling = ceiling
	}

	/// One datagram out, as the pacer stamps it.
	func sent(seq: UInt16, at: UInt32, bytes: Int) {
		history[Int(seq) & 8191] = Sent(seq: seq, at: at, bytes: Int32(bytes), valid: true)
		let now = seconds()
		outgoing.append((now, bytes))
		while let f = outgoing.first, now - f.at > 0.5 { outgoing.removeFirst() }
	}

	/// What the other end says arrived.
	func feedback(_ f: Feedback) {
		let now = seconds(), nowUs = micros()
		// The round trip, and the two clocks against each other: their clock when my newest came,
		// less when I sent it, less the way there (half the round trip).
		let sample = since(nowUs, f.echo) - Int64(f.held)
		if f.echo != 0, sample > 0, sample < 5_000_000 {
			let ms = Double(sample) / 1000
			rtt = rtt.map { $0 * 0.875 + ms * 0.125 } ?? ms
			clocks.append((now, sample, since(f.now &- f.held, f.echo) - sample / 2))
			clocks.removeAll { now - $0.at > 10 }
			offset = clocks.min { $0.rtt < $1.rtt }?.offset
		}
		var lost = 0, got = 0
		for (i, arrival) in f.arrivals.enumerated() {
			let seq = f.first &+ UInt16(i)
			// Each datagram counts once: the feedback may say it again.
			if let r = reported, Int16(bitPattern: seq &- r) <= 0 { continue }
			reported = seq
			let s = history[Int(seq) & 8191]
			guard s.valid, s.seq == seq else { continue }
			guard let arrival else { lost += 1; continue }
			got += 1
			if origin == nil { origin = arrival &- s.at }
			let owd = since(arrival &- s.at, origin!)
			let second = Int(now)
			if let last = minima.last, last.second == second { minima[minima.count - 1].owd = min(last.owd, owd) } else { minima.append((second, owd)) }
			minima.removeAll { second - $0.second > 15 }
			let base = minima.map(\.owd).min() ?? owd
			recent.append((arrival, owd - base, Int(s.bytes)))
		}
		acked += got; lostCount += lost
		if let newest = recent.last?.at { recent.removeAll { since(newest, $0.at) > 300_000 } }
		if got + lost > 0 { losses.append((now, lost, got + lost)) }
		losses.removeAll { now - $0.at > 2 }
		let all = losses.reduce(0) { $0 + $1.of }
		loss = all == 0 ? 0 : Double(losses.reduce(0) { $0 + $1.lost }) / Double(all)
		if let newest = recent.last?.at {
			// Standing: the least any datagram waited in the last 100 ms.
			queue = Double(recent.filter { since(newest, $0.at) <= 100_000 }.map(\.queue).min() ?? 0) / 1000
			if let oldest = recent.first, since(newest, oldest.at) >= 80_000 {
				delivered = Double(recent.dropFirst().reduce(0) { $0 + $1.bytes } * 8) / (Double(since(newest, oldest.at)) / 1e6)
			}
		}
		let span = (outgoing.last?.at ?? now) - (outgoing.first?.at ?? now)
		sending = span > 0.2 ? Double(outgoing.dropFirst().reduce(0) { $0 + $1.bytes } * 8) / span : sending
		if got > 0 { adapt(now) }
	}

	private func adapt(_ now: Double) {
		let dt = lastUpdate == 0 ? 0.05 : min(0.2, now - lastUpdate)
		lastUpdate = now
		let roundTrip = (rtt ?? 100) / 1000
		// A round trip after a cut, what the queue is then; cut again only past that, or once it
		// should have drained.
		let looked = now - lastDecrease > roundTrip + 0.15
		if looked, queueAfter == nil, decreases > 0 { queueAfter = queue }
		let settled = lastDecrease == 0 || looked && (queue > (queueAfter ?? 0) + 10 || now - lastDecrease > roundTrip + 0.15 + (queueAfter ?? 0) / 1000 * 2)
		// Loss alone (a policer, not a queue) counts when it's now, not the overflow just dealt with.
		let recentAll = losses.filter { now - $0.at <= 0.5 }.reduce(0) { $0 + $1.of }
		let recentLoss = recentAll == 0 ? 0 : Double(losses.filter { now - $0.at <= 0.5 }.reduce(0) { $0 + $1.lost }) / Double(recentAll)
		let ours = now < burstUntil && queue < 250
		if queue > 20 && !ours || recentLoss > 0.25 {
			guard settled else { return }
			// What was delivered is what the path carries; never below a quarter in one cut.
			let base = max(rate * 0.25 / 0.85, delivered > 0 ? min(rate, delivered) : rate)
			callLog(String(format: "call rate: %d → %d kbps · queue %.0f ms (%.0f a round trip after the last cut) · delivered %d kbps · lost %.1f%%", Int(rate / 1000), Int(max(floor, base * 0.85) / 1000), queue, queueAfter ?? -1, Int(delivered / 1000), recentLoss * 100))
			rate = max(floor, base * 0.85)
			if queue > 20 { capacity = (base, now) }
			lastDecrease = now; queueAfter = nil; decreases += 1
			return
		}
		guard queue < 8 || ours else { return }
		// Room the encoder isn't using can't be proven: no further than this past what it gives.
		if sending > 0, rate > max(2 * sending, sending + 3_000_000) { return }
		if let c = capacity, now - c.at > 10 { capacity = nil }
		let grow: Double
		if let c = capacity { grow = rate >= c.rate * 0.7 ? max(rate * 0.05, 50_000) * dt : rate * (pow(1.5, dt) - 1) }
		else { grow = decreases == 0 ? rate * (pow(2.5, dt) - 1) : rate * (pow(1.5, dt) - 1) }
		rate = min(ceiling, rate + grow)
	}

	/// A floor or ceiling moved (the call grew, the path changed): keep within them.
	func clamp() { rate = min(ceiling, max(floor, rate)) }
}

/// Media 2, receiving: when each numbered datagram from one device came, said back as feedback,
/// with the clock echo and (from the video side) where decoding stands.
struct Arrivals {
	private var pending: [(seq: UInt16, at: UInt32)] = []
	private var next: UInt16?
	private var newest: (sent: UInt32, at: UInt32)?
	private(set) var lastSent = 0.0
	/// Datagrams numbered and received, ever.
	private(set) var count = 0

	mutating func add(_ s: Sequenced, at: UInt32) {
		count += 1
		pending.append((s.seq, at))
		newest = (s.sent, at)
	}

	var waiting: Int { pending.count }

	/// Feedback for what came since the last, in pieces that each fit `room` bytes.
	mutating func feedback(room: Int, decoded: UInt32?, chain: UInt32, want: Feedback.Want) -> [Feedback] {
		lastSent = seconds()
		let now = micros()
		let echo = newest?.sent ?? 0, held = newest.map { UInt32(clamping: max(0, since(now, $0.at))) } ?? 0
		// In order from the oldest not yet said; what's older than that came too late to count.
		var byOffset: [UInt16: UInt32] = [:]
		let oldest: UInt16 = pending.map(\.seq).min { Int16(bitPattern: $0 &- $1) < 0 } ?? 0
		let first: UInt16 = next ?? oldest
		var last = first
		for p in pending where Int16(bitPattern: p.seq &- first) >= 0 {
			byOffset[p.seq &- first] = p.at
			if Int16(bitPattern: p.seq &- last) > 0 { last = p.seq }
		}
		pending = []
		guard !byOffset.isEmpty else { return [Feedback(first: first, arrivals: [], now: now, echo: echo, held: held, decoded: decoded, chain: chain, want: want)] }
		let n = Int(last &- first) + 1
		next = last &+ 1
		let most = Feedback.most(room)
		return stride(from: 0, to: n, by: most).map { start in
			let arrivals = (start..<min(n, start + most)).map { byOffset[UInt16($0)] }
			return Feedback(first: first &+ UInt16(start), arrivals: arrivals, now: now, echo: echo, held: held, decoded: decoded, chain: chain, want: want)
		}
	}
}
