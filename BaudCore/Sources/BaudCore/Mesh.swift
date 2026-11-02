/// An in-process network of `LocalCore`s: who is online, and frames between them, delivered on
/// the caller's thread. This is the whole transport the peer crate replaces. It knows nothing
/// about conversations; it moves frames and tells cores who came and went.
import Foundation

public final class Mesh: @unchecked Sendable {
	private let lock = NSLock()
	private var cores: [DeviceId: LocalCore] = [:]
	private var online: Set<DeviceId> = []
	/// Simulated round trips so paths read "Direct, 14 ms" and not "0 ms".
	private var rtt: [DeviceId: Int] = [:]
	public init() {}

	public func join(_ core: LocalCore) {
		lock.withLock { cores[core.device] = core; rtt[core.device] = Int.random(in: 4...40) }
		core.mesh = self
	}
	public func core(_ device: DeviceId) -> LocalCore? { lock.withLock { cores[device] } }
	public var devices: [DeviceId] { lock.withLock { Array(cores.keys) } }
	public func isOnline(_ device: DeviceId) -> Bool { lock.withLock { online.contains(device) } }
	func rtt(_ device: DeviceId) -> Int { lock.withLock { rtt[device] ?? 10 } }

	/// `sync: false` (the demo's "Sending…" picture): online, but nothing handed over yet.
	func setOnline(_ core: LocalCore, _ on: Bool, sync: Bool = true) {
		let others: [LocalCore] = lock.withLock {
			if on { online.insert(core.device) } else { online.remove(core.device) }
			return cores.values.filter { $0.device != core.device }
		}
		for o in others { o.peerChanged(core.device, online: on) }
		guard on, sync else { return }
		// Coming online: dial everyone I know who is online, exchange what each is missing, and
		// hand over what we hold for each other.
		for o in others where isOnline(o.device) && (core.knows(o.device) || o.knows(core.device)) {
			core.sync(with: o)
			o.sync(with: core)
		}
	}

	/// Deliver now if the device is online; the receiver handles the frame synchronously.
	@discardableResult
	func send(_ frame: Frame, from: DeviceId, to: DeviceId) -> Bool {
		guard isOnline(to), isOnline(from), let c = core(to) else { return false }
		c.receive(frame, from: from, carriedBy: nil)
		return true
	}
}
