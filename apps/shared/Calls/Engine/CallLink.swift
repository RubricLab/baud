/// One call's way to one device. Its own Live connection on `baud-call/1` (direct, or through a
/// device of either person's own; the crate refuses friends' relays for Live), one stream for the
/// signals, datagrams for the media: `CallLink`, the only call file that names the peer package's
/// types. The first thing it says is what this device's media can do (`caps`), and it keeps what
/// the other end says of its own, so the media knows before the first frame what to send. Or, for a device in a group call this one can't reach (two members who aren't friends
/// hold each other's cards but not each other's addresses), through someone in the call who
/// reaches both: `RelayedLink`. That someone hears the call anyway; it passes the bytes on.
import BaudCore
import Foundation
import PeerKit

protocol CallRoute: AnyObject, Sendable {
	var device: String { get }
	var onSignal: (@Sendable (CallSignal) -> Void)? { get set }
	var onDatagram: (@Sendable (Data) -> Void)? { get set }
	var onClose: (@Sendable () -> Void)? { get set }
	@discardableResult func send(_ s: CallSignal) async -> Bool
	/// A last signal, then let go.
	func last(_ s: CallSignal, reason: String) async
	func datagram(_ d: Data)
	/// Room in one datagram.
	var mtu: Int { get }
	var rtt: Int? { get }
	/// The crate's relay it goes through, by device id; nil when direct.
	var relay: String? { get }
	/// The one in the call it goes through, by device id; nil when it's a connection of its own.
	var via: String? { get }
	/// What the other end's media said it can do; nil until it says (0.2.15 never does).
	var caps: MediaCaps? { get }
	func close(_ reason: String)
}

final class CallLink: CallRoute, @unchecked Sendable {
	static let alpn = "baud-call/1"

	let device: String
	private let conn: Conn
	private let stream: PeerKit.Stream
	private let lock = NSLock()
	private var closed = false
	private var _caps: MediaCaps?
	var caps: MediaCaps? { lock.withLock { _caps } }
	var onSignal: (@Sendable (CallSignal) -> Void)?
	var onDatagram: (@Sendable (Data) -> Void)?
	/// The connection ended, by either side or the network.
	var onClose: (@Sendable () -> Void)?
	/// Testing only: the share of outgoing datagrams to drop, to prove concealment and recovery.
	var dropRate: Double = 0

	private init(device: String, conn: Conn, stream: PeerKit.Stream) { self.device = device; self.conn = conn; self.stream = stream }

	/// Dial a device and open the signal stream, saying first what my media can do (the other side
	/// sees the stream only when bytes arrive on it, so something has to go at once anyway).
	static func dial(_ p: PeerKit.Peer, device: String) async throws -> CallLink {
		let c = try await p.connect(device: device, class: .live, alpn: alpn)
		let s = try await c.open()
		try? await s.setPriority(priority: 10)
		let l = CallLink(device: device, conn: c, stream: s)
		await l.send(.caps(CallMedia.mine))
		return l
	}

	/// A device dialed this one for a call: its connection, then its signal stream; what my media
	/// can do goes back before anything else.
	static func accept(_ p: PeerKit.Peer, conn id: UInt64) async throws -> CallLink {
		let c = try p.accept(conn: id)
		let s = try await c.acceptStream()
		let l = CallLink(device: c.identity().device, conn: c, stream: s)
		await l.send(.caps(CallMedia.mine))
		return l
	}

	/// Read signals and datagrams until the connection goes.
	func start() {
		Task.detached(priority: .userInitiated) { [self] in
			var reader = SignalReader()
			while let d = try? await stream.recv(max: 64 << 10) {
				for s in reader.add(d) {
					if case .caps(let c) = s { lock.withLock { _caps = c } }
					onSignal?(s)
				}
			}
			finish()
		}
		Task.detached(priority: .userInitiated) { [self] in
			while let d = try? await conn.recvDatagram() { onDatagram?(d) }
			finish()
		}
	}

	private func finish() {
		let first: Bool = lock.withLock { let f = !closed; closed = true; return f }
		if first { onClose?() }
	}

	@discardableResult
	func send(_ s: CallSignal) async -> Bool {
		do { try await stream.send(bytes: s.framed); return true } catch { return false }
	}

	/// A last signal, then the connection: a beat between, so the signal isn't cut off by the close.
	func last(_ s: CallSignal, reason: String) async {
		await send(s)
		try? await Task.sleep(for: .milliseconds(400))
		close(reason)
	}

	func datagram(_ d: Data) {
		if dropRate > 0, Double.random(in: 0..<1) < dropRate { return }
		try? conn.sendDatagram(bytes: d)
	}

	/// Room in one datagram, a little under the path's limit.
	var mtu: Int { Int(conn.maxDatagram() ?? 1200) - 8 }
	var rtt: Int? { conn.rttMs().map(Int.init) }
	/// Direct, or through which device (by id).
	var relay: String? { if case .relay(let d) = conn.path() { return d }; return nil }
	var via: String? { nil }

	func close(_ reason: String = "end") {
		lock.withLock { closed = true }
		let (s, c) = (stream, conn)
		Task { try? await s.finish(); c.close(reason: reason) }
	}
}

/// To a device in the call through another that reaches us both: signals wrapped in `forward`,
/// datagrams in a relay packet, both passed on by the one in the middle.
final class RelayedLink: CallRoute, @unchecked Sendable {
	let device: String
	let me: String
	let helper: CallLink
	var onSignal: (@Sendable (CallSignal) -> Void)?
	var onDatagram: (@Sendable (Data) -> Void)?
	var onClose: (@Sendable () -> Void)?
	init(device: String, me: String, helper: CallLink) { self.device = device; self.me = me; self.helper = helper }
	@discardableResult func send(_ s: CallSignal) async -> Bool { await helper.send(.forward(from: me, to: device, signal: s)) }
	func last(_ s: CallSignal, reason: String) async { await send(s) }
	func datagram(_ d: Data) { helper.datagram(RelayPacket(from: me, to: device, inner: d).data) }
	var mtu: Int { helper.mtu - RelayPacket.header }
	/// Two hops; the second is about as long as the first.
	var rtt: Int? { helper.rtt.map { $0 * 2 } }
	var relay: String? { nil }
	var via: String? { helper.device }
	/// Heard through the helper as a signal (CallMedia.handle), not kept here.
	var caps: MediaCaps? { nil }
	/// The other end hears `end`; the helper's connection is the call's, and stays.
	func close(_ reason: String) {}
}
