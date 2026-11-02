/// `CALLTEST_MESH=1`: three of this checkout's media in one call, the way a group call is a mesh:
/// Ana, Bo and Cy each hold a link to the other two and send one encoding to both. Each link goes
/// through its own shaper when `CALLTEST_SHAPE` is set (so `rate=` is each link's, not a shared
/// uplink). It prints, for each of the six streams, what was shown and how late, and each one's
/// uplink in all: what a home connection has to carry for a call of three.
import CoreMedia
import CoreVideo
import Foundation
import Lab
import PeerKit

func meshTest(root: URL, shape: Shaper.Spec?, duration: Double) async throws {
	let names = ["Ana", "Bo", "Cy"]
	var nodes: [(PeerKit.Peer, Events)] = []
	for n in names { nodes.append(try await node(n)) }
	// Everyone a contact of everyone, by invite.
	for i in 0..<3 { for j in 0..<3 where i < j { _ = try await nodes[j].0.add(link: try nodes[i].0.invite()) } }
	try await Task.sleep(for: .milliseconds(500))
	callLog = { print("    " + $0) }
	let start = Shaper.now()
	let medias = try names.indices.map { i in try CallMedia(video: true, test: true, me: nodes[i].0.me().thisDevice) }
	final class Box: @unchecked Sendable { var routes: [(node: Int, route: ShapedRoute)] = []; var screens: [String: Screen] = [:] }
	let box = Box()
	let lock = NSLock()
	func attach(_ i: Int, _ link: CallLink, from j: Int) {
		let route = ShapedRoute(link, shape)
		let screen = Screen(start: start)
		lock.withLock { box.routes.append((i, route)); box.screens["\(names[j])→\(names[i])"] = screen }
		link.onSignal = { s in _ = medias[i].handle(s, from: link.device) }
		medias[i].add(route) { s in if let pb = CMSampleBufferGetImageBuffer(s) { screen.frame(pb) } }
	}
	// The one with the smaller index answers; the other dials.
	for i in 0..<3 {
		let me = i
		nodes[i].1.inbound = { conn in
			Task {
				guard let l = try? await CallLink.accept(nodes[me].0, conn: conn) else { return }
				guard let from = names.indices.first(where: { nodes[$0].0.me().thisDevice == l.device }) else { return }
				attach(me, l, from: from)
				l.start()
			}
		}
	}
	for i in 0..<3 { for j in 0..<3 where i > j {
		let l = try await CallLink.dial(nodes[i].0, device: nodes[j].0.me().thisDevice)
		attach(i, l, from: j)
		l.start()
	} }
	for m in medias { try m.start() }
	print("mesh of three · path per link: \(shape?.description ?? "loopback, unshaped")")
	try await Task.sleep(for: .seconds(duration))
	let t = Shaper.now() - start
	print("")
	for (k, screen) in lock.withLock({ box.screens }).sorted(by: { $0.key < $1.key }) {
		let snap = screen.snapshot()
		let late = snap.latency.filter { $0.t > t / 2 }.map(\.ms)
		let fps = Double(snap.shown.filter { $0 > t / 2 }.count) / (t / 2)
		print(String(format: "%@: %@ · %.0f fps shown · latency p50 %@ p95 %@ ms", k, snap.sizes.last?.size ?? "-", fps, f0(pct(late, 0.5)), f0(pct(late, 0.95))))
	}
	let routes = lock.withLock { box.routes }
	for (i, m) in medias.enumerated() {
		let up = routes.filter { $0.node == i }.reduce(0) { $0 + $1.route.pipe.bytes }
		print(String(format: "%@ sends %@ %@ at %d kbps to each · its uplink: %.0f kbps on average, everything", names[i], m.video?.codec ?? "-", m.video?.size ?? "-", (m.video?.bitrate ?? 0) / 1000, Double(up) * 8 / (t - 0.5) / 1000))
	}
	for m in medias { m.stop() }
	for r in routes { r.route.pipe.stop(); r.route.inner.close("end") }
	for (p, _) in nodes { await p.close() }
}
