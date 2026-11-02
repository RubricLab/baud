/// Disappearing messages: the setting as a state line, each message carrying its own time, my
/// own going `ttl` after I sent them and everyone else's `ttl` after I first read them (on any
/// device of mine), and what goes with a message: its words, its edits, its pin, its files.
import XCTest
@testable import BaudCore

final class DisappearTests: XCTestCase {
	func row(_ c: LocalCore, _ id: EventId) -> Row? { c.lock.withLock { c.store.one("select * from events where id=?", [id]) } }
	func texts(_ c: LocalCore, _ conv: ConversationId) -> [String] { c.events(conv, before: nil, limit: 50).compactMap(\.text) }
	func later(_ s: TimeInterval) -> Date { Date().addingTimeInterval(s) }
	func eventually(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
		let end = Date().addingTimeInterval(timeout)
		while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
		XCTAssertTrue(cond(), what)
	}
	/// Two devices of one person on the fake network (SyncTests.swift), both knowing the other.
	func twoOfMine() throws -> (FakeNet, LocalCore, LocalCore) {
		let userKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
		func keys() -> MemoryKeys { let k = MemoryKeys(); k.put("user-key", userKey); return k }
		let a = try LocalCore(dir: nil, keys: keys(), deviceName: "Dee's Mac", kind: .mac)
		let b = try LocalCore(dir: nil, keys: keys(), deviceName: "Dee's iPhone", kind: .iphone)
		let both = [(id: a.device, name: "Dee's Mac", kind: DeviceKind.mac), (id: b.device, name: "Dee's iPhone", kind: DeviceKind.iphone)]
		a.adoptIdentity(user: a.user, name: "Dee", thisDevice: a.device, devices: both)
		b.adoptIdentity(user: b.user, name: "Dee", thisDevice: b.device, devices: both)
		let net = FakeNet(); net.add(a); net.add(b)
		return (net, a, b)
	}

	/// The setting travels as a state line both sides read, and only messages written while it's
	/// on carry a `ttl`; turned off, the next one carries none.
	func testTheSettingAndItsLines() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		let before = try ana.send(chat.id, Draft(text: "before"))
		try ben.setDisappear(chat.id, 86_400)
		XCTAssertEqual(ana.conversation(chat.id)?.disappear, 86_400)
		XCTAssertEqual(ben.conversation(chat.id)?.disappear, 86_400)
		XCTAssertEqual(ana.events(chat.id, before: nil, limit: 10).compactMap(\.system).last, "Ben set messages to disappear 1 day after they're read")
		XCTAssertEqual(ben.events(chat.id, before: nil, limit: 10).compactMap(\.system).last, "You set messages to disappear 1 day after they're read")
		let during = try ana.send(chat.id, Draft(text: "during"))
		XCTAssertNil(decode(MessageBody.self, row(ben, before.id)?.string("body"))?.ttl)
		XCTAssertEqual(decode(MessageBody.self, row(ben, during.id)?.string("body"))?.ttl, 86_400)
		try ana.setDisappear(chat.id, 0)
		XCTAssertEqual(ben.conversation(chat.id)?.disappear, 0)
		XCTAssertEqual(ben.events(chat.id, before: nil, limit: 10).compactMap(\.system).last, "Ana turned off disappearing messages")
		let after = try ana.send(chat.id, Draft(text: "after"))
		XCTAssertFalse(row(ben, after.id)?.string("body")?.contains("ttl") ?? true, "today's bytes when it's off")
	}

	/// In a channel only an admin changes it; in a chat, anyone.
	func testOnlyAdminsInAChannel() throws {
		let (_, ana, ben) = try PairCore.pair()
		let space = try ana.createSpace("team")
		let general = try ana.createChannel(space: space.id, name: "general")
		try ana.addMember(space.id, ben.user)
		XCTAssertTrue(ben.conversation(general.id)?.members.contains(ben.user) ?? false)
		XCTAssertThrowsError(try ben.setDisappear(general.id, 3600)) { XCTAssertEqual($0 as? CoreError, .notAdmin) }
		try ana.setDisappear(general.id, 3600)
		XCTAssertEqual(ben.conversation(general.id)?.disappear, 3600)
	}

	/// Mine goes `ttl` after I sent it, from my timeline, search and the list's last line; theirs
	/// waits, unread, however long it takes.
	func testMineGoesAtSendTheirsWaitsUnread() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		try ana.setDisappear(chat.id, 60)
		let e = try ana.send(chat.id, Draft(text: "the door code is 4471"))
		let at = try XCTUnwrap(row(ana, e.id)?.double("at"))
		XCTAssertEqual(try XCTUnwrap(row(ana, e.id)?.double("expires_at")), at + 60, accuracy: 0.001)
		XCTAssertNil(row(ben, e.id)?.double("expires_at"), "theirs: unread, no clock yet")

		XCTAssertEqual(ana.expire(now: later(30)), 0)
		XCTAssertTrue(texts(ana, chat.id).contains("the door code is 4471"))
		XCTAssertEqual(ana.expire(now: later(61)), 1)
		XCTAssertFalse(texts(ana, chat.id).contains("the door code is 4471"))
		XCTAssertTrue(ana.search("4471", scope: nil).isEmpty)
		XCTAssertNotEqual(ana.conversation(chat.id)?.lastEvent, e.id)
		XCTAssertEqual(row(ana, e.id)?.string("body"), "{}", "blanked as a redaction is")
		XCTAssertNil(row(ana, e.id)?.string("text"))
		XCTAssertEqual(row(ana, e.id)?.int("seq"), e.seq, "the feed row stays")

		// Ben hasn't read it: a year on, it is still there for him.
		XCTAssertEqual(ben.expire(now: later(365 * 86_400)), 0)
		XCTAssertTrue(texts(ben, chat.id).contains("the door code is 4471"))
		XCTAssertEqual(ben.conversation(chat.id)?.unread, 1)
	}

	/// Theirs starts when I first read it, on any device of mine; its edits and its pin go with it.
	func testTheirsGoesAfterMyFirstRead() throws {
		let (mesh, ana, ben) = try PairCore.pair()
		let benPhone = try PairCore.linkDevice(of: ben, deviceName: "Ben's iPhone", kind: .iphone, on: mesh)
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		try ana.setDisappear(chat.id, 3600)
		let e = try ana.send(chat.id, Draft(text: "meet at the north gate"))
		try ana.edit(chat.id, e.id, text: "meet at the south gate")
		try ana.pin(chat.id, e.id, on: true)
		XCTAssertTrue(texts(benPhone, chat.id).contains("meet at the south gate"))
		XCTAssertEqual(benPhone.conversation(chat.id)?.pinned, [e.id])
		XCTAssertNil(row(benPhone, e.id)?.double("expires_at"))

		// Read on Ben's Mac: both of his devices start the clock from that read.
		try ben.markRead(chat.id, e.id)
		let read = try XCTUnwrap(ben.lock.withLock { ben.store.one("select at from receipts where event=? and kind='read'", [e.id])?.double("at") })
		XCTAssertEqual(try XCTUnwrap(row(ben, e.id)?.double("expires_at")), read + 3600, accuracy: 0.001)
		XCTAssertEqual(try XCTUnwrap(row(benPhone, e.id)?.double("expires_at")), read + 3600, accuracy: 0.001)
		XCTAssertEqual(benPhone.expire(now: later(1800)), 0)
		XCTAssertEqual(benPhone.expire(now: later(3601)), 1)
		XCTAssertFalse(texts(benPhone, chat.id).contains { $0.contains("gate") })
		let edit = try XCTUnwrap(benPhone.lock.withLock { benPhone.store.one("select * from events where type='edit' and target=?", [e.id]) })
		XCTAssertNil(edit.string("text"), "the edit carried the words too")
		XCTAssertEqual(edit.string("body"), "{}")
		XCTAssertTrue(benPhone.search("gate", scope: nil).isEmpty)
		XCTAssertEqual(benPhone.conversation(chat.id)?.pinned, [], "unpinned")
		// Each device on its own: Ben's Mac hasn't swept yet.
		XCTAssertTrue(texts(ben, chat.id).contains("meet at the south gate"))

		// An edit that comes after the message is gone here goes too.
		benPhone.apply(WireEvent(id: "late-edit", conv: chat.id, device: ana.device, seq: 999, user: ana.user, at: Date().timeIntervalSince1970, lamport: 999, type: .edit, text: "meet at the west gate", reply: nil, thread: nil, target: e.id, body: encode(EditBody(target: e.id, text: "meet at the west gate"))), carriedBy: nil)
		XCTAssertNil(row(benPhone, "late-edit")?.string("text"))
		XCTAssertTrue(benPhone.search("west", scope: nil).isEmpty)
	}

	/// A body that isn't JSON in the same conversation doesn't stop the clocks.
	func testABrokenBodyDoesntStopTheClocks() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		ben.apply(WireEvent(id: "broken", conv: chat.id, device: "friend-device", seq: 1, user: ana.user, at: Date().timeIntervalSince1970, lamport: 1, type: .message, text: nil, reply: nil, thread: nil, target: nil, body: "{\"ttl\":60,"), carriedBy: nil)
		try ana.setDisappear(chat.id, 60)
		let e = try ana.send(chat.id, Draft(text: "still goes"))
		try ben.markRead(chat.id, e.id)
		XCTAssertNotNil(row(ben, e.id)?.double("expires_at"))
		XCTAssertNil(row(ben, "broken")?.double("expires_at"))
	}

	/// The sweep runs on its own at the next message's time while the core runs.
	func testTheSweepRunsOnItsOwn() throws {
		let (_, ana, _) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		try ana.setDisappear(chat.id, 1)
		_ = try ana.send(chat.id, Draft(text: "gone in a second"))
		XCTAssertTrue(texts(ana, chat.id).contains("gone in a second"))
		let end = Date().addingTimeInterval(5)
		while texts(ana, chat.id).contains("gone in a second") && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
		XCTAssertFalse(texts(ana, chat.id).contains("gone in a second"))
	}

	/// A message already gone on another device of mine reaches this one by the clocks, blanked:
	/// it is kept (the feed stays whole and nobody sends it again) and never shown. One that
	/// arrives whole after my read already ran out goes the moment it lands.
	func testGoneElsewhereArrivesHidden() throws {
		let (net, a, b) = try twoOfMine()
		net.online(a)
		let g = try a.createGroup("Plans", users: [])
		let body = encode(MessageBody(text: "the safe word is plum", ttl: 60))
		let theirs = WireEvent(id: "f-1", conv: g.id, device: "friend-device", seq: 1, user: "friend", at: Date().timeIntervalSince1970, lamport: 50, type: .message, text: "the safe word is plum", reply: nil, thread: nil, target: nil, body: body)
		a.apply(theirs, carriedBy: nil)
		try a.markRead(g.id, theirs.id)
		XCTAssertEqual(a.expire(now: later(61)), 1)
		XCTAssertEqual(row(a, theirs.id)?.string("body"), "{}")

		net.online(b)
		eventually("it came by the clocks") { row(b, theirs.id) != nil }
		let kept = try XCTUnwrap(row(b, theirs.id), "stored, by the clocks")
		XCTAssertEqual(kept.string("body"), "{}")
		XCTAssertFalse(texts(b, g.id).contains("the safe word is plum"))
		XCTAssertFalse(b.events(g.id, before: nil, limit: 10).contains { $0.id == theirs.id }, "never shown")
		XCTAssertEqual(b.conversation(g.id)?.unread, 0)
		XCTAssertNotEqual(b.conversation(g.id)?.lastEvent, theirs.id)
		XCTAssertEqual(b.clock(g.id)["friend-device"], 1, "the feed is whole: nobody sends it again")

		// Whole, but read here a minute and more ago: gone on arrival.
		let old = Date().timeIntervalSince1970 - 120
		let b2 = WireEvent(id: "f-2", conv: g.id, device: "friend-device", seq: 2, user: "friend", at: old, lamport: 51, type: .message, text: "and the door is blue", reply: nil, thread: nil, target: nil, body: encode(MessageBody(text: "and the door is blue", ttl: 60)))
		b.apply(receipt: WireReceipt(conv: g.id, device: a.device, user: a.user, event: b2.id, lamport: 51, kind: "read", at: old))
		b.apply(b2, carriedBy: nil)
		XCTAssertEqual(row(b, b2.id)?.string("body"), "{}")
		XCTAssertTrue(b.search("blue", scope: nil).isEmpty)
	}

	/// Its files leave the blob store, unless another message still here names the same file.
	func testFilesGo() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		let other = try ana.createGroup("other", users: [ben.user])
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("disappear-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let only = dir.appendingPathComponent("only.txt"), shared = dir.appendingPathComponent("shared.txt")
		try Data("only here".utf8).write(to: only)
		try Data("in two places".utf8).write(to: shared)
		try ana.setDisappear(chat.id, 60)
		let e = try ana.send(chat.id, Draft(text: "", attachments: [only, shared]))
		_ = try ana.send(other.id, Draft(text: "kept", attachments: [shared]))
		let (a, b) = (e.attachments[0].hash, e.attachments[1].hash)
		XCTAssertTrue(FileManager.default.fileExists(atPath: ana.blobPath(a).path))
		XCTAssertEqual(ana.expire(now: later(61)), 1)
		XCTAssertFalse(FileManager.default.fileExists(atPath: ana.blobPath(a).path), "nobody else names it")
		XCTAssertTrue(FileManager.default.fileExists(atPath: ana.blobPath(b).path), "the other chat still names it")
	}
}
