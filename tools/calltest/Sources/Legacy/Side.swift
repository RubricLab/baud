/// calltest: the media of baud 0.2.15 (the files beside this one, as released, but for the time
/// drawn into the test pattern), behind `CallSide`. The "before", and the old client a new one has
/// to keep talking to.
import CoreMedia
import Foundation
import Lab
import PeerKit

public final class LegacySide: CallSide, @unchecked Sendable {
	public let engine = "0.2.15"
	let link: CallLink
	let route: Shaped
	var media: CallMedia?
	public var onSetup: (@Sendable (Setup) -> Void)?
	public var wire: Uplink { route.pipe }
	public var rtt: Int? { route.rtt }

	init(link: CallLink, shape: Shaper.Spec?, drop: Double) {
		self.link = link
		link.dropRate = drop
		route = Shaped(link, shape)
		link.onSignal = { [weak self] s in self?.signal(s) }
	}

	public static func dial(_ p: PeerKit.Peer, device: String, shape: Shaper.Spec?, drop: Double) async throws -> LegacySide {
		let s = LegacySide(link: try await CallLink.dial(p, device: device), shape: shape, drop: drop)
		s.link.start()
		return s
	}

	public static func accept(_ p: PeerKit.Peer, conn: UInt64, shape: Shaper.Spec?, drop: Double) async throws -> LegacySide {
		let s = LegacySide(link: try await CallLink.accept(p, conn: conn), shape: shape, drop: drop)
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

	public func send(_ s: Setup) async {
		switch s {
		case .ring: await link.send(.ring(id: "c1", conv: "conv", video: true, user: "calltest", name: "calltest"))
		case .ringing: await link.send(.ringing)
		case .accept: await link.send(.accept(video: true))
		case .end: await link.send(.end)
		}
	}

	public func startMedia(me: String, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
		let m = try CallMedia(video: true, test: true, me: me)
		m.add(route) { s in if let pb = CMSampleBufferGetImageBuffer(s) { onFrame(pb) } }
		try m.start()
		media = m
	}

	public func counters() -> Counters {
		var c = Counters()
		guard let m = media else { return c }
		if let v = m.video {
			c.videoBytes = v.bytesSent; c.encoded = v.encoded; c.keyframes = v.keyframes; c.targetKbps = v.bitrate / 1000
			c.codec = "H.264"; c.size = v.tier == .hd ? "720p" : "360p"
		}
		c.decoded = m.decoded(link.device)
		let a = m.audio.stats(link.device)
		c.audioReceived = a.received; c.audioExpected = a.expected; c.audioPlayed = a.played; c.audioConcealed = a.concealed
		return c
	}

	public func stop() {
		media?.stop()
		route.pipe.stop()
		link.close("end")
	}
}

/// The link as the media sees it: datagrams through the shaper, signals a path's delay later, and
/// a round trip that counts the shaper's queue the way QUIC's would on a real path.
final class Shaped: CallRoute, @unchecked Sendable {
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
	func close(_ reason: String) { inner.close(reason) }
}
