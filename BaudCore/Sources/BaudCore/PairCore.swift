/// Several devices in one process, for tests and the demo: a `Mesh` and the cores on it. `pair()`
/// is two people with one device each; `trio()` adds a second device to the first person, so an
/// envelope can be carried by "your Mac" and arrive marked that way on the other side.
import Foundation

public enum PairCore {
	public static func make(name: String, deviceName: String, kind: DeviceKind, on mesh: Mesh, keys: Keys = MemoryKeys()) throws -> LocalCore {
		let c = try LocalCore(dir: nil, keys: keys, deviceName: deviceName, kind: kind)
		mesh.join(c)
		try c.setName(name)
		return c
	}

	/// Two people, one device each, already contacts with a chat between them, both online.
	public static func pair(_ a: String = "Ana", _ b: String = "Ben") throws -> (Mesh, LocalCore, LocalCore) {
		let mesh = Mesh()
		let x = try make(name: a, deviceName: "\(a)'s iPhone", kind: .iphone, on: mesh)
		let y = try make(name: b, deviceName: "\(b)'s Mac", kind: .mac, on: mesh)
		try meet(x, y)
		return (mesh, x, y)
	}

	/// Two online cores become contacts through a real invite link.
	public static func meet(_ x: LocalCore, _ y: LocalCore) throws {
		x.setOnline(true); y.setOnline(true)
		let link = try x.invite()
		let sem = DispatchSemaphore(value: 0)
		nonisolated(unsafe) var err: Error?
		Task { do { _ = try await y.add(link) } catch { err = error }; sem.signal() }
		sem.wait()
		if let err { throw err }
	}

	/// A second device of `of`, linked through a real device link.
	public static func linkDevice(of old: LocalCore, deviceName: String, kind: DeviceKind, on mesh: Mesh, keys: Keys = MemoryKeys(), dir: URL? = nil) throws -> LocalCore {
		let new = try LocalCore(dir: dir, keys: keys, deviceName: deviceName, kind: kind)
		mesh.join(new)
		old.setOnline(true); new.setOnline(true)
		let link = try old.linkDevice()
		let sem = DispatchSemaphore(value: 0)
		nonisolated(unsafe) var err: Error?
		Task { do { try await new.link(link) } catch { err = error }; sem.signal() }
		sem.wait()
		if let err { throw err }
		return new
	}
}
