/// Datagrams out to each device at a pace its path can take rather than all at once: a frame's
/// pieces spread over the time they take at half again the link's rate (a keyframe's at three
/// times it: rare, big, and everything behind it waits; and anything at twice the pace once it has
/// waited 40 ms, so the pacer never becomes the queue it's there to prevent), voice and feedback
/// straight through. One thread for every link in the call. For a
/// device on media 2 each datagram is numbered and stamped here, the moment it leaves, and its rate
/// control told; the rate it paces at comes from that rate control. A queue that grows past 300 ms
/// (the encoder well over what the path takes) is thrown away rather than sent late: the receiver
/// sees the gap and asks for a refresh.
import BaudCore
import Foundation

final class Pacer: @unchecked Sendable {
	/// One device's way out.
	final class Lane: @unchecked Sendable {
		let link: CallRoute
		/// Media 2: numbered and stamped, and how fast to go comes from here (set under the lock).
		var control: RateControl?
		/// Without a rate control (media 1), the rate it was last given.
		var rate: Double
		fileprivate var queue: [(data: Data, frame: UInt32, at: Double, fast: Bool)] = []
		fileprivate var head = 0
		fileprivate var free = 0.0
		fileprivate var seq: UInt16 = 0
		/// Datagrams and bytes out, frames thrown away for being too late, ever.
		fileprivate(set) var sent = 0, bytes = 0, dropped = 0
		/// How long each frame's last piece waited here (ms), the last hundred.
		fileprivate(set) var waits: [Double] = []
		init(link: CallRoute, control: RateControl?, rate: Double) { self.link = link; self.control = control; self.rate = rate }
		/// Media 2 at a quarter over its rate; media 1, never measured (0.2.15 didn't pace at all),
		/// at a generous pace that only takes the edge off bursts.
		var pace: Double { control.map { $0.rate * 1.5 } ?? max(rate * 2.5, 4_000_000) }
		fileprivate var waiting: Int { queue.count - head }
		/// Seconds the oldest waiting datagram has waited.
		fileprivate func age(_ now: Double) -> Double { head < queue.count ? now - queue[head].at : 0 }
	}

	private let cond = NSCondition()
	private var lanes: [ObjectIdentifier: Lane] = [:]
	private var running = true

	init() {
		let t = Thread { [weak self] in self?.run() }
		t.qualityOfService = .userInteractive
		t.name = "baud.pacer"
		t.start()
	}

	func add(_ lane: Lane) { cond.withLock { lanes[ObjectIdentifier(lane)] = lane } }
	func remove(_ lane: Lane) { cond.withLock { lanes[ObjectIdentifier(lane)] = nil } }
	func stop() { cond.withLock { running = false; lanes = [:]; cond.signal() } }

	/// Under the pacer's lock: everything about a lane's rate control happens here.
	func withLock<T>(_ f: () -> T) -> T { cond.withLock(f) }

	/// A frame's datagrams, to go out at the lane's pace behind whatever is waiting.
	func frame(_ ds: [Data], id: UInt32, key: Bool = false, to lane: Lane) {
		let now = seconds()
		cond.withLock {
			if lane.age(now) > 0.3 {
				// Too far behind to catch up: what's waiting would arrive stale. Throw it away.
				let frames = Set(lane.queue[lane.head...].map(\.frame))
				lane.dropped += frames.count
				lane.queue = []; lane.head = 0
			}
			for d in ds { lane.queue.append((d, id, now, key)) }
			cond.signal()
		}
	}

	/// Voice and feedback: out now, counted against the pace. Feedback goes unnumbered.
	func now(_ d: Data, to lane: Lane, numbered: Bool = true) {
		let out = cond.withLock { () -> Data in
			let now = seconds()
			lane.free = max(lane.free, now - 0.002) + Double(d.count * 8) / lane.pace
			return numbered ? stamp(d, lane) : d
		}
		lane.link.datagram(out)
	}

	/// Numbered and stamped, for media 2 (under the lock).
	private func stamp(_ d: Data, _ lane: Lane) -> Data {
		lane.sent += 1; lane.bytes += d.count
		guard let c = lane.control else { return d }
		let at = micros()
		let s = Sequenced(seq: lane.seq, sent: at, inner: d).data
		c.sent(seq: lane.seq, at: at, bytes: s.count)
		lane.seq &+= 1
		return s
	}

	var stats: [(device: String, waiting: Int, dropped: Int, wait: Double)] {
		cond.withLock { lanes.values.map { l in (l.link.device, l.waiting, l.dropped, l.waits.isEmpty ? 0 : l.waits.sorted()[l.waits.count / 2]) } }
	}

	private func run() {
		var out: [(Lane, Data)] = []
		cond.lock()
		while running {
			let now = seconds()
			var wake = Double.infinity
			for lane in lanes.values {
				// Two milliseconds of slack: a lane that sat idle may catch up that much at once.
				lane.free = max(lane.free, now - 0.002)
				while lane.head < lane.queue.count, lane.free <= now + 0.0005 {
					let (d, frame, at, fast) = lane.queue[lane.head]
					lane.head += 1
					if lane.head == lane.queue.count || lane.queue[lane.head].frame != frame {
						lane.waits.append((now - at) * 1000); if lane.waits.count > 100 { lane.waits.removeFirst() }
					}
					if fast { lane.control?.burst(d.count) }
					lane.free += Double(d.count * 8) / (lane.pace * (fast || now - at > 0.04 ? 2 : 1))
					out.append((lane, stamp(d, lane)))
				}
				if lane.head == lane.queue.count { lane.queue = []; lane.head = 0 } else { wake = min(wake, lane.free) }
				if lane.head > 512 { lane.queue.removeFirst(lane.head); lane.head = 0 }
			}
			if !out.isEmpty {
				cond.unlock()
				for (lane, d) in out { lane.link.datagram(d) }
				out.removeAll(keepingCapacity: true)
				cond.lock()
				continue
			}
			if wake == .infinity { cond.wait() } else { cond.wait(until: Date(timeIntervalSinceNow: max(0.0002, wake - seconds()))) }
		}
		cond.unlock()
	}
}
