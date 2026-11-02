/// calltest: this checkout's media (the Engine files, linked in) behind `CallSide`.
import BaudCore
import CoreMedia
import Foundation
import Lab
import PeerKit

final class NewSide: CallSide, @unchecked Sendable {
	let engine = "new"
	let link: CallLink
	let route: ShapedRoute
	var media: CallMedia?
	var onSetup: (@Sendable (Setup) -> Void)?
	var wire: Uplink { route.pipe }
	var rtt: Int? { route.rtt }

	init(link: CallLink, shape: Shaper.Spec?, drop: Double) {
		self.link = link
		link.dropRate = drop
		route = ShapedRoute(link, shape)
		link.onSignal = { [weak self] s in self?.signal(s) }
	}

	static func dial(_ p: PeerKit.Peer, device: String, shape: Shaper.Spec?, drop: Double) async throws -> NewSide {
		let s = NewSide(link: try await CallLink.dial(p, device: device), shape: shape, drop: drop)
		s.link.start()
		return s
	}

	static func accept(_ p: PeerKit.Peer, conn: UInt64, shape: Shaper.Spec?, drop: Double) async throws -> NewSide {
		let s = NewSide(link: try await CallLink.accept(p, conn: conn), shape: shape, drop: drop)
		s.link.start()
		return s
	}

	private func signal(_ s: CallSignal) {
		switch s {
		case .ring: onSetup?(.ring)
		case .ringing: onSetup?(.ringing)
		case .accept: onSetup?(.accept)
		case .end: onSetup?(.end)
		default: _ = media?.handle(s, from: link.device)
		}
	}

	func send(_ s: Setup) async {
		switch s {
		case .ring: await link.send(.ring(id: "c1", conv: "conv", video: true, user: "calltest", name: "calltest"))
		case .ringing: await link.send(.ringing)
		case .accept: await link.send(.accept(video: true))
		case .end: await link.send(.end)
		}
	}

	func startMedia(me: String, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
		let m = try CallMedia(video: true, test: true, me: me)
		m.add(route) { s in if let pb = CMSampleBufferGetImageBuffer(s) { onFrame(pb) } }
		try m.start()
		media = m
	}

	func counters() -> Counters {
		var c = Counters()
		guard let m = media else { return c }
		if let v = m.video {
			c.videoBytes = v.bytesSent; c.encoded = v.encoded; c.keyframes = v.keyframes; c.targetKbps = v.bitrate / 1000
			c.codec = v.codec; c.size = v.size
		}
		c.decoded = m.decoded(link.device)
		let a = m.audio.stats(link.device)
		c.audioReceived = a.received; c.audioExpected = a.expected; c.audioPlayed = a.played; c.audioConcealed = a.concealed
		if let q = m.quality(link.device) {
			c.latency = m.latencies(link.device)
			let lanes = m.pacer.stats
			c.note = String(format: "· %@ %dp%d · rtt %@ loss %.1f%% · refresh %d · dropped %d · opus %d kbps", q.media2 ? "media 2" : "media 1", m.video?.height ?? 0, q.fps,
				q.rtt.map(String.init) ?? "-", q.loss * 100, m.video?.refreshes ?? 0, lanes.first?.dropped ?? 0, m.audio.bitrate / 1000)
		}
		return c
	}

	func stop() {
		media?.stop()
		route.pipe.stop()
		link.close("end")
	}
}

/// The link as the media sees it: datagrams through the shaper, signals a path's delay later, and
/// a round trip that counts the shaper's queue the way QUIC's would on a real path.
final class ShapedRoute: CallRoute, @unchecked Sendable {
	let inner: CallLink
	let pipe: Uplink
	let delay: Double
	var onSignal: (@Sendable (CallSignal) -> Void)?
	var onDatagram: (@Sendable (Data) -> Void)?
	var onClose: (@Sendable () -> Void)?

	init(_ inner: CallLink, _ spec: Shaper.Spec?) {
		self.inner = inner
		delay = spec?.delay ?? 0
		pipe = Uplink(spec) { [inner] d in inner.datagram(d) }
		inner.onDatagram = { [weak self] d in self?.onDatagram?(d) }
	}

	var device: String { inner.device }
	@discardableResult func send(_ s: CallSignal) async -> Bool {
		if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
		return await inner.send(s)
	}
	func last(_ s: CallSignal, reason: String) async { await inner.last(s, reason: reason) }
	func datagram(_ d: Data) { pipe.send(d) }
	var mtu: Int { inner.mtu }
	var rtt: Int? { inner.rtt.map { $0 + Int((2 * delay + (pipe.shaper?.queued ?? 0)) * 1000) } }
	var relay: String? { inner.relay }
	var via: String? { nil }
	var caps: MediaCaps? { inner.caps }
	func close(_ reason: String) { inner.close(reason) }
}
