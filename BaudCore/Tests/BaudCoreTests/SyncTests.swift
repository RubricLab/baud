/// My own devices converge over the crate's seam (sealed bytes through a `Transport`, the path the
/// real apps take), not the in-process mesh: a conversation one device never saw, read state,
/// deletes and clears, and nothing from before the wipe.
import XCTest
@testable import BaudCore

/// A pretend crate: bytes between cores while both are up. A post to a device that is away is
/// dropped (no carrier took it), so only the sync on connect can bring it.
final class FakeNet: @unchecked Sendable {
	let lock = NSLock()
	var cores: [DeviceId: LocalCore] = [:]
	var up: Set<DeviceId> = []
	func add(_ c: LocalCore) { lock.withLock { cores[c.device] = c }; c.transport = Port(net: self, me: c.device) }
	func isUp(_ d: DeviceId) -> Bool { lock.withLock { up.contains(d) } }
	/// A device comes up: it and every device already up connect, and each offers its clocks.
	func online(_ c: LocalCore) {
		let others: [LocalCore] = lock.withLock { up.insert(c.device); return up.filter { $0 != c.device }.compactMap { cores[$0] } }
		c.setOnline(true)
		for o in others { c.connected(o.device); o.connected(c.device) }
	}
	func offline(_ c: LocalCore) { _ = lock.withLock { up.remove(c.device) }; c.setOnline(false) }
	/// The crate connects a device whose app is not active yet (a relaunch connects in ~70 ms,
	/// its window comes later): connected on the wire, the core still offline.
	func connectedBeforeActive(_ c: LocalCore) {
		let others: [LocalCore] = lock.withLock { up.insert(c.device); return up.filter { $0 != c.device }.compactMap { cores[$0] } }
		for o in others { c.connected(o.device); o.connected(c.device) }
	}
	/// The crate's blob store, pretended: a provided file is fetched by copying it, while both are up.
	var provided: [String: URL] = [:]
	func provide(_ file: URL, by d: DeviceId) -> String { let id = "blob-\(file.lastPathComponent)"; lock.withLock { provided[d + "/" + id] = file }; return id }
	func fetch(_ id: String, from: DeviceId, by: DeviceId, to: URL) -> Bool {
		guard isUp(from), isUp(by), let f = lock.withLock({ provided[from + "/" + id] }) else { return false }
		return (try? FileManager.default.copyItem(at: f, to: to)) != nil
	}
	func deliver(_ bytes: Data, from: DeviceId, to: DeviceId) -> Bool {
		guard isUp(from), isUp(to), let c = lock.withLock({ cores[to] }) else { return false }
		c.receive(bytes: bytes, from: from, carriedBy: nil)
		return true
	}
}

final class Port: Transport, @unchecked Sendable {
	let net: FakeNet, me: DeviceId
	init(net: FakeNet, me: DeviceId) { self.net = net; self.me = me }
	func isOnline(_ device: DeviceId) -> Bool { net.isUp(device) && net.isUp(me) }
	func rtt(_ device: DeviceId) -> Int? { 5 }
	func send(_ bytes: Data, to device: DeviceId) async -> Bool { net.deliver(bytes, from: me, to: device) }
	func post(_ bytes: Data, to device: DeviceId, ttl: TimeInterval) async -> [DeviceId] { [] }
	func provide(_ file: URL) async -> String? { net.provide(file, by: me) }
	func fetch(_ id: String, from device: DeviceId, to file: URL) async -> Bool { net.fetch(id, from: device, by: me, to: file) }
}

final class SyncTests: XCTestCase {
	/// Two devices of one person ("Dee"), each knowing the other, on a fake network.
	func twoOfMine() throws -> (FakeNet, LocalCore, LocalCore) {
		let userKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
		func keys() -> MemoryKeys { let k = MemoryKeys(); k.put("user-key", userKey); return k }
		let a = try LocalCore(dir: nil, keys: keys(), deviceName: "Dee's Mac", kind: .mac)
		let b = try LocalCore(dir: nil, keys: keys(), deviceName: "Dee's iPhone", kind: .iphone)
		XCTAssertEqual(a.user, b.user)
		let both = [(id: a.device, name: "Dee's Mac", kind: DeviceKind.mac), (id: b.device, name: "Dee's iPhone", kind: DeviceKind.iphone)]
		a.adoptIdentity(user: a.user, name: "Dee", thisDevice: a.device, devices: both)
		b.adoptIdentity(user: b.user, name: "Dee", thisDevice: b.device, devices: both)
		let net = FakeNet(); net.add(a); net.add(b)
		return (net, a, b)
	}

	/// A message from someone else, as both of my devices would hold it.
	func theirs(_ conv: ConversationId, _ seq: Int, lamport: Int, in cores: [LocalCore]) -> WireEvent {
		let e = WireEvent(id: "f-\(conv)-\(seq)", conv: conv, device: "friend-device", seq: seq, user: "friend", at: Date().timeIntervalSince1970, lamport: lamport, type: .message, text: "hi", reply: nil, thread: nil, target: nil, body: encode(MessageBody(text: "hi")))
		for c in cores { c.apply(e, carriedBy: nil) }
		return e
	}

	func eventually(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
		let end = Date().addingTimeInterval(timeout)
		while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
		XCTAssertTrue(cond(), what)
	}

	/// A conversation made while my other device was away, whose live post was lost: the clocks
	/// on connect bring the whole of it, though the other device had never heard of it.
	func testConversationOneSideNeverSaw() throws {
		let (net, a, b) = try twoOfMine()
		net.online(a)
		let g = try a.createGroup("Plans", users: [])
		_ = try a.send(g.id, Draft(text: "one"))
		_ = try a.send(g.id, Draft(text: "two"))
		XCTAssertNil(b.conversation(g.id))
		net.online(b)
		eventually("the group reaches the device that was away") { b.conversation(g.id) != nil && b.events(g.id, before: nil, limit: 10).filter { $0.type == .message }.count == 2 }
		// And the other way: written there while this one is away, here when it is back.
		net.offline(a)
		_ = try b.send(g.id, Draft(text: "three"))
		net.online(a)
		eventually("a message written while away arrives") { a.events(g.id, before: nil, limit: 10).filter { $0.type == .message }.count == 3 }
	}

	/// A relaunched device whose crate connected before its app turned active still offers what it
	/// holds, once it does (0.2.5's journey across two Macs: the relaunched one offered nothing).
	func testOfferWhenTheAppTurnsActive() throws {
		let (net, a, b) = try twoOfMine()
		net.online(b)
		let g = try b.createGroup("From b", users: [])
		_ = try b.send(g.id, Draft(text: "x"))
		net.offline(b)
		net.online(a)
		net.connectedBeforeActive(b)
		RunLoop.current.run(until: Date().addingTimeInterval(0.3))
		XCTAssertNil(a.conversation(g.id), "nothing offered while b's app is not active")
		b.setOnline(true)
		eventually("offered once b's app is active") { a.events(g.id, before: nil, limit: 10).filter { $0.type == .message }.count == 1 }
	}

	/// A file sent on one of my devices comes to the other by itself, verified by its hash, and is
	/// handed out only to whoever may see it.
	func testFileFollowsMe() throws {
		let (net, a, b) = try twoOfMine()
		net.online(a); net.online(b)
		let g = try a.createGroup("Photos", users: [])
		let file = FileManager.default.temporaryDirectory.appendingPathComponent("baud-test-\(UUID().uuidString).bin")
		try Data((0..<300_000).map { _ in UInt8.random(in: 0...255) }).write(to: file)
		let e = try a.send(g.id, Draft(text: "", attachments: [file]))
		let att = try XCTUnwrap(e.attachments.first)
		XCTAssertEqual(att.hash, try fileHash(file))
		eventually("the file reaches my other device on its own") { FileManager.default.fileExists(atPath: b.blobPath(att.hash).path) }
		XCTAssertEqual(try fileHash(b.blobPath(att.hash)), att.hash)
		let got = expectation(description: "blob() answers with the file")
		Task { if let u = try? await b.blob(att.hash, key: att.key), (try? fileHash(u)) == att.hash { got.fulfill() } }
		wait(for: [got], timeout: 5)
		XCTAssertTrue(a.mayHave(att.hash, b.device), "my own device may have it")
		XCTAssertFalse(a.mayHave(att.hash, "a-stranger"), "a device nobody knows may not")
		// A stranger's ask is ignored: nothing is provided for it.
		a.wanted(att.hash, by: "a-stranger")
		RunLoop.current.run(until: Date().addingTimeInterval(0.2))
		XCTAssertEqual(net.lock.withLock { net.provided.keys.filter { $0.hasPrefix(a.device) }.count }, 1, "provided once, for my other device")
	}

	/// Read on one of my devices is read on the other.
	func testReadFollowsMe() throws {
		let (net, a, b) = try twoOfMine()
		net.online(a); net.online(b)
		let g = try a.createGroup("Plans", users: [])
		eventually("the group is on both") { b.conversation(g.id) != nil }
		let e = theirs(g.id, 1, lamport: 5, in: [a, b])
		XCTAssertEqual(a.conversation(g.id)?.unread, 1)
		XCTAssertEqual(b.conversation(g.id)?.unread, 1)
		try a.markRead(g.id, e.id)
		XCTAssertEqual(a.conversation(g.id)?.unread, 0)
		eventually("read on the other device too") { b.conversation(g.id)?.unread == 0 }
	}

	/// Deleting a chat, or clearing my notes, on one device does it on the other; neither comes
	/// back on the next sync.
	func testDeleteAndClearFollowMe() throws {
		let (net, a, b) = try twoOfMine()
		net.online(a); net.online(b)
		let g = try a.createGroup("Plans", users: [])
		_ = try a.send(g.id, Draft(text: "one"))
		eventually("the group is on both") { b.conversations(nil).contains { $0.id == g.id } }
		try b.delete(g.id)
		eventually("deleted on the other device") { !a.conversations(nil).contains { $0.id == g.id } }
		let notes = try XCTUnwrap(a.notes())
		_ = try a.send(notes.id, Draft(text: "a note"))
		eventually("the note is on both") { b.events(notes.id, before: nil, limit: 10).contains { $0.text == "a note" } }
		a.clear(notes.id)
		eventually("cleared on the other device") { !b.events(notes.id, before: nil, limit: 10).contains { $0.text == "a note" } }
		// A reconnect syncs again: still deleted, still cleared.
		net.offline(b); net.online(b)
		RunLoop.current.run(until: Date().addingTimeInterval(0.3))
		XCTAssertFalse(b.conversations(nil).contains { $0.id == g.id })
		XCTAssertFalse(b.events(notes.id, before: nil, limit: 10).contains { $0.text == "a note" })
	}

	/// A packet from before wire 2 is dropped unread.
	func testOldWireIsRefused() throws {
		let (_, a, b) = try twoOfMine()
		let notes = try XCTUnwrap(a.notes())
		let e = WireEvent(id: "old", conv: notes.id, device: a.device, seq: 99, user: a.user, at: 0, lamport: 99, type: .message, text: "legacy", reply: nil, thread: nil, target: nil, body: encode(MessageBody(text: "legacy")))
		let old = try JSONEncoder().encode(Packet(v: nil, conv: nil, key: nil, nonce: nil, body: Data(encode(Frame.events([e])).utf8)))
		b.receive(bytes: old, from: a.device, carriedBy: nil)
		XCTAssertFalse(b.events(notes.id, before: nil, limit: 10).contains { $0.text == "legacy" })
		let now = a.seal(.events([e]), conv: nil)
		b.receive(bytes: now, from: a.device, carriedBy: nil)
		XCTAssertTrue(b.events(notes.id, before: nil, limit: 10).contains { $0.text == "legacy" }, "the same frame on wire 2 opens")
	}

	/// A store from before the wipe loses every message once, and keeps who I am and who I know.
	func testLegacyWipeOnce() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baud-wipe-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let keys = MemoryKeys(); keys.put("user-key", Data(repeating: 7, count: 32))
		var c: LocalCore? = try LocalCore(dir: dir, keys: keys, deviceName: "Mac", kind: .mac)
		let notes = try XCTUnwrap(c!.notes())
		_ = try c!.send(notes.id, Draft(text: "kept after a relaunch"))
		c = try LocalCore(dir: dir, keys: keys, deviceName: "Mac", kind: .mac)
		XCTAssertTrue(c!.events(notes.id, before: nil, limit: 10).contains { $0.text == "kept after a relaunch" }, "the wipe runs once, not every launch")
		c!.store.run("delete from me where k='epoch'")
		c!.store.run("insert into people(user,name,fingerprint,contact,demo) values('demo-ana','Ana','',1,1)")
		c!.store.run("insert into people(user,name,fingerprint,contact) values('friend','Jo','',1)")
		c = try LocalCore(dir: dir, keys: keys, deviceName: "Mac", kind: .mac)
		XCTAssertTrue(c!.events(notes.id, before: nil, limit: 10).isEmpty, "a legacy store loses its messages")
		XCTAssertEqual(c!.contacts().map(\.name), ["Jo"], "friends stay; demo people go")
		XCTAssertFalse(c!.user.isEmpty)
	}
}
