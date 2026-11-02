/// `CALLTEST_DATAGRAMS=20`: the transport alone, no media. Bo sends Ana frame-sized bursts of
/// 1200-byte datagrams, sixty a second, `20` Mbps in all, each stamped with when it went; Ana says
/// how long each took to come out of her receive loop. `CALLTEST_BURST=1` sends each burst all at
/// once rather than over 5 ms. What it measures is the peer package's datagram path on loopback
/// (QUIC, its congestion control and send buffer, the async receive), with nothing else running.
import Foundation
import PeerKit

func datagramBench(bo: PeerKit.Peer, ana: PeerKit.Peer, anaEvents: Events, mbps: Double, duration: Double, burst: Bool) async throws {
	let got = Got()
	anaEvents.inbound = { conn in
		Task {
			guard let l = try? await CallLink.accept(ana, conn: conn) else { return }
			l.onDatagram = { d in
				guard d.count >= 8 else { return }
				let b = [UInt8](d.prefix(8))
				let sent = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
				got.add(Double(since(micros(), sent)) / 1000)
			}
			l.start()
			got.link = l
		}
	}
	let link = try await CallLink.dial(bo, device: ana.me().thisDevice)
	link.start()
	await link.send(.ringing)
	try await Task.sleep(for: .milliseconds(300))
	let perFrame = max(1, Int(mbps * 1e6 / 60 / 8 / 1200))
	print("datagrams: \(perFrame) of 1200 B sixty times a second (\(String(format: "%.1f", Double(perFrame * 1200 * 8 * 60) / 1e6)) Mbps), \(burst ? "all at once" : "over 5 ms") · mtu \(link.mtu)")
	var seq: UInt32 = 0
	let start = seconds()
	var next = start
	var lastPrint = start
	while seconds() - start < duration {
		for i in 0..<perFrame {
			var d = Data(count: 1200)
			let at = micros()
			d[0] = UInt8(seq >> 24); d[1] = UInt8(seq >> 16 & 0xff); d[2] = UInt8(seq >> 8 & 0xff); d[3] = UInt8(seq & 0xff)
			d[4] = UInt8(at >> 24); d[5] = UInt8(at >> 16 & 0xff); d[6] = UInt8(at >> 8 & 0xff); d[7] = UInt8(at & 0xff)
			link.datagram(d)
			seq &+= 1
			if !burst, i < perFrame - 1 { usleep(useconds_t(5000 / perFrame)) }
		}
		next += 1.0 / 60
		let wait = next - seconds()
		if wait > 0 { usleep(useconds_t(wait * 1e6)) }
		if seconds() - lastPrint >= 1 {
			lastPrint = seconds()
			let (n, p) = got.second()
			print(String(format: "  %2.0fs  %5d in · transit p50 %.2f p95 %.2f p99 %.2f max %.2f ms", lastPrint - start, n, p.0, p.1, p.2, p.3))
		}
	}
	try await Task.sleep(for: .milliseconds(300))
	let (n, p) = got.all()
	print(String(format: "datagrams: %d sent, %d came (%.2f%%) · transit p50 %.2f p95 %.2f p99 %.2f max %.2f ms", Int(seq), n, Double(n) / Double(max(1, seq)) * 100, p.0, p.1, p.2, p.3))
	link.close("end")
}

final class Got: @unchecked Sendable {
	private let lock = NSLock()
	private var now: [Double] = [], ever: [Double] = []
	var link: CallLink?
	func add(_ ms: Double) { lock.withLock { now.append(ms); ever.append(ms) } }
	private static func p(_ xs: [Double]) -> (Double, Double, Double, Double) {
		let s = xs.sorted()
		guard !s.isEmpty else { return (.nan, .nan, .nan, .nan) }
		return (s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)], s[min(s.count - 1, s.count * 99 / 100)], s.last!)
	}
	func second() -> (Int, (Double, Double, Double, Double)) { lock.withLock { defer { now = [] }; return (now.count, Self.p(now)) } }
	func all() -> (Int, (Double, Double, Double, Double)) { lock.withLock { (ever.count, Self.p(ever)) } }
}
