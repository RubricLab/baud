/// A path between two devices, made in the process: a bottleneck of `rate` with a queue behind it
/// (drop-tail, at most `queue` seconds of it), `delay` one way, and `loss` of what gets through,
/// at random. Datagrams go in before the QUIC connection and come out into it, so QUIC itself sees a
/// clean loopback; only the media sees the path. `steps` change the rate partway through.
/// `CALLTEST_SHAPE=rate=3mbit,delay=40ms,loss=1%,queue=150ms,jitter=2ms,step=15s:2mbit`
import Foundation

public final class Shaper: @unchecked Sendable {
	public struct Spec: Sendable, CustomStringConvertible {
		/// Bits a second; 0 for no bottleneck.
		public var rate = 0.0
		public var delay = 0.0
		public var loss = 0.0
		public var queue = 0.15
		public var jitter = 0.0
		public var steps: [(at: Double, rate: Double)] = []
		public init() {}

		public static func parse(_ s: String) -> Spec? {
			var spec = Spec()
			for part in s.split(separator: ",") {
				let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
				guard kv.count == 2 else { return nil }
				switch kv[0] {
				case "rate": guard let r = bits(kv[1]) else { return nil }; spec.rate = r
				case "delay": guard let d = seconds(kv[1]) else { return nil }; spec.delay = d
				case "jitter": guard let d = seconds(kv[1]) else { return nil }; spec.jitter = d
				case "queue": guard let d = seconds(kv[1]) else { return nil }; spec.queue = d
				case "loss": guard let l = Double(kv[1].replacingOccurrences(of: "%", with: "")) else { return nil }; spec.loss = kv[1].hasSuffix("%") ? l / 100 : l
				case "step":
					let p = kv[1].split(separator: ":").map(String.init)
					guard p.count == 2, let at = seconds(p[0]), let r = bits(p[1]) else { return nil }
					spec.steps.append((at, r))
				default: return nil
				}
			}
			return spec
		}

		static func bits(_ s: String) -> Double? {
			let l = s.lowercased()
			for (suffix, k) in [("gbit", 1e9), ("mbit", 1e6), ("kbit", 1e3), ("bit", 1.0)] where l.hasSuffix(suffix) {
				return Double(l.dropLast(suffix.count)).map { $0 * k }
			}
			return Double(l)
		}

		static func seconds(_ s: String) -> Double? {
			if s.hasSuffix("ms") { return Double(s.dropLast(2)).map { $0 / 1000 } }
			if s.hasSuffix("s") { return Double(s.dropLast()) }
			return Double(s)
		}

		public var description: String {
			var p: [String] = []
			p.append(rate > 0 ? String(format: "%.1f Mbit", rate / 1e6) : "unlimited")
			if delay > 0 { p.append(String(format: "%.0f ms each way", delay * 1000)) }
			if jitter > 0 { p.append(String(format: "±%.0f ms", jitter * 1000)) }
			if loss > 0 { p.append(String(format: "%.1f%% loss", loss * 100)) }
			if rate > 0 { p.append(String(format: "%.0f ms queue", queue * 1000)) }
			for s in steps { p.append(String(format: "→ %.1f Mbit at %.0f s", s.rate / 1e6, s.at)) }
			return p.joined(separator: ", ")
		}
	}

	public let spec: Spec
	private let deliver: @Sendable (Data) -> Void
	private let cond = NSCondition()
	private var line: [(at: Double, data: Data)] = []
	private var free = 0.0
	private var running = true
	private let started = Shaper.now()
	/// What happened to everything that went in.
	public private(set) var sent = 0, delivered = 0, bytes = 0, overflowed = 0, lost = 0
	public private(set) var maxQueue = 0.0

	public init(_ spec: Spec, deliver: @escaping @Sendable (Data) -> Void) {
		self.spec = spec; self.deliver = deliver
		let t = Thread { [weak self] in self?.run() }
		t.qualityOfService = .userInteractive
		t.name = "shaper"
		t.start()
	}

	public static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

	/// The bottleneck's rate now.
	public var rate: Double {
		let t = Self.now() - started
		return spec.steps.last { t >= $0.at }?.rate ?? spec.rate
	}

	public func send(_ d: Data) {
		let now = Self.now()
		cond.lock()
		defer { cond.unlock() }
		sent += 1
		var at = now
		let r = rate
		if r > 0 {
			let start = max(now, free)
			if start - now > spec.queue { overflowed += 1; return }
			free = start + Double(d.count * 8) / r
			maxQueue = max(maxQueue, start - now)
			at = free
		}
		if spec.loss > 0, Double.random(in: 0..<1) < spec.loss { lost += 1; return }
		at += spec.delay + (spec.jitter > 0 ? Double.random(in: 0...spec.jitter) : 0)
		// A path never reorders what it was given: jitter only ever adds to the one before.
		at = max(at, line.last?.at ?? 0)
		line.append((at, d))
		cond.signal()
	}

	/// Seconds of queue in front of the bottleneck now.
	public var queued: Double { cond.lock(); defer { cond.unlock() }; return max(0, free - Self.now()) }

	public func stop() { cond.lock(); running = false; cond.signal(); cond.unlock() }

	private func run() {
		cond.lock()
		while running {
			guard let first = line.first else { cond.wait(); continue }
			let now = Self.now()
			if first.at > now { cond.wait(until: Date(timeIntervalSinceNow: first.at - now)); continue }
			line.removeFirst()
			delivered += 1; bytes += first.data.count
			cond.unlock()
			deliver(first.data)
			cond.lock()
		}
		cond.unlock()
	}
}
