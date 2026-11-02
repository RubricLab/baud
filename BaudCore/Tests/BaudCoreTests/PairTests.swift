/// Two and three devices in one process: meet by link, converge, carry for each other, and say
/// so truthfully. These guard the shapes the crate has to fill, not the crate.
import XCTest
@testable import BaudCore

final class PairTests: XCTestCase {
	func testMeetAndChat() throws {
		let (_, ana, ben) = try PairCore.pair()
		XCTAssertEqual(ana.contacts().map(\.name), ["Ben"])
		XCTAssertEqual(ben.contacts().map(\.name), ["Ana"])
		XCTAssertTrue(ben.contacts()[0].online)
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		XCTAssertTrue(chat.isDirect)
		XCTAssertEqual(ben.conversations(.chat).first?.id, chat.id)

		let e = try ana.send(chat.id, Draft(text: "hi ben"))
		XCTAssertEqual(ben.events(chat.id, before: nil, limit: 10).last?.text, "hi ben")
		XCTAssertEqual(ana.delivery(chat.id, e.id).sentence, "delivered to Ben's Mac")
		try ben.markRead(chat.id, e.id)
		XCTAssertEqual(ana.delivery(chat.id, e.id).sentence, "read")
		XCTAssertEqual(ana.conversation(chat.id)?.unread, 0)
	}

	/// Both sides opened a direct chat before seeing the other's (Dexter's two "TEST" chats, 0.1.10):
	/// each side shows one chat, the same one, with everything said in either.
	func testOneDirectChatPerPerson() throws {
		let (_, ana, ben) = try PairCore.pair()
		let first = try XCTUnwrap(ana.conversations(.chat).first)
		let second = try ben.create(kind: .chat, name: nil, space: nil, users: [ana.user])
		XCTAssertNotEqual(first.id, second.id)
		_ = try ana.send(first.id, Draft(text: "in the first"))
		_ = try ben.send(second.id, Draft(text: "in the second"))
		for core in [ana, ben] {
			let chats = core.conversations(.chat)
			XCTAssertEqual(chats.count, 1)
			XCTAssertEqual(chats.first?.id, min(first.id, second.id))
			let texts = core.events(chats[0].id, before: nil, limit: 50).compactMap(\.text)
			XCTAssertTrue(texts.contains("in the first") && texts.contains("in the second"), "\(texts)")
		}
		XCTAssertEqual(try ben.createChat([ana.user]).id, min(first.id, second.id))
	}

	/// Deleting a direct chat hides it until a newer message; my chat with myself is only cleared.
	func testDeleteAndNotes() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		try ana.delete(chat.id)
		XCTAssertTrue(ana.conversations(.chat).isEmpty)
		XCTAssertEqual(ana.contacts().count, 1)
		_ = try ben.send(chat.id, Draft(text: "still there?"))
		XCTAssertEqual(ana.conversations(.chat).first?.id, chat.id)
		let notes = try XCTUnwrap(ana.notes())
		_ = try ana.send(notes.id, Draft(text: "a note"))
		XCTAssertEqual(ana.events(notes.id, before: nil, limit: 10).compactMap(\.text).last, "a note")
		try ana.delete(notes.id)
		XCTAssertNotNil(ana.notes())
		XCTAssertFalse(ana.events(notes.id, before: nil, limit: 10).contains { $0.text == "a note" })
	}

	/// Unfriending: they leave the friends list and our chat leaves the list.
	func testUnfriend() throws {
		let (_, ana, ben) = try PairCore.pair()
		XCTAssertEqual(ana.conversations(.chat).count, 1)
		ana.unfriend(ben.me().user)
		XCTAssertTrue(ana.contacts().isEmpty)
		XCTAssertTrue(ana.conversations(.chat).isEmpty)
	}

	/// A friend's two identities become one: one contact, one chat with every message, vouched.
	func testRedirectMergesChats() throws {
		let (_, ana, ben) = try PairCore.pair()
		let old = ben.me().user
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		_ = try ben.send(chat.id, Draft(text: "from the old key"))
		let new = "new-" + old
		ana.lock.withLock { ana.store.run("insert into people(user,name,fingerprint,verified,contact,met_at) values(?,?,?,0,1,?)", [new, "", "", Date()]) }
		_ = try ana.createChat([new])
		ana.redirect(from: old, to: new)
		XCTAssertEqual(ana.contacts().map(\.user), [new])
		XCTAssertEqual(ana.contacts().first?.name, "Ben")
		XCTAssertEqual(ana.contacts().first?.vouched, true)
		XCTAssertEqual(ana.conversations(.chat).count, 1)
	}

	/// Every message knows how it travelled: theirs came directly; mine waits until it arrives.
	func testEveryMessageHasItsPath() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		let sent = try ana.send(chat.id, Draft(text: "hello"))
		XCTAssertNotNil(ana.event(sent.id)?.via)
		let got = try XCTUnwrap(ben.events(chat.id, before: nil, limit: 10).last { $0.text == "hello" })
		XCTAssertEqual(got.via, .direct)
	}

	/// The colour follows me: a profile line in my own chat, never shown in it.
	func testProfileFollowsMe() throws {
		let (_, ana, _) = try PairCore.pair()
		ana.setProfile("accent", "0090FF")
		ana.setProfile("accent", "E5484D")
		XCTAssertEqual(ana.profile("accent"), "E5484D")
		let notes = try XCTUnwrap(ana.notes())
		XCTAssertTrue(ana.events(notes.id, before: nil, limit: 20).filter { $0.type == .state }.isEmpty)
	}

	func testOfflineWaitsThenDelivers() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = ana.conversations(.chat)[0].id
		ben.setOnline(false)
		XCTAssertFalse(ana.contacts()[0].online)
		let e = try ana.send(chat, Draft(text: "are you there"))
		XCTAssertEqual(ana.delivery(chat, e.id).sentence, "sent, nobody online to carry it")
		XCTAssertEqual(ben.events(chat, before: nil, limit: 10).count, 1) // only the create line
		ben.setOnline(true)
		XCTAssertEqual(ben.events(chat, before: nil, limit: 10).last?.text, "are you there")
		XCTAssertEqual(ana.delivery(chat, e.id).sentence, "delivered to Ben's Mac")
	}

	func testCarriedByYourMac() throws {
		let (mesh, ana, ben) = try PairCore.pair()
		let mac = try PairCore.linkDevice(of: ana, deviceName: "Ana's Mac", kind: .mac, on: mesh)
		XCTAssertEqual(mac.me().user, ana.me().user)
		XCTAssertEqual(mac.contacts().map(\.name), ["Ben"])
		XCTAssertEqual(ben.contacts()[0].devices.count, 2)
		let chat = ana.conversations(.chat)[0].id
		XCTAssertEqual(mac.conversations(.chat).first?.id, chat)

		ben.setOnline(false)
		let e = try ana.send(chat, Draft(text: "from the train"))
		XCTAssertEqual(ana.delivery(chat, e.id).sentence, "carried by your Mac · waiting for Ben's Mac")
		XCTAssertEqual(mac.carrying().envelopes, 1)
		XCTAssertEqual(mac.carrying().sentence, "Holding 1 envelope (\(bytesText(mac.carrying().bytes)) of 200.0 MB): 1 for Ben's Mac.")
		ana.setOnline(false)
		ben.setOnline(true)
		let got = try XCTUnwrap(ben.events(chat, before: nil, limit: 10).last)
		XCTAssertEqual(got.text, "from the train")
		XCTAssertEqual(got.carriedBy, mac.device)
		// Ben's receipt rides back the same way: the Mac holds it until Ana's phone returns.
		XCTAssertEqual(mac.carrying().held.map(\.name), ["your iPhone"])
		ana.setOnline(true)
		XCTAssertEqual(mac.carrying().envelopes, 0)
		XCTAssertEqual(ana.delivery(chat, e.id).sentence, "delivered to Ben's Mac")
	}

	func testGroupSpaceChannelAndSearch() throws {
		let (mesh, ana, ben) = try PairCore.pair()
		let cal = try PairCore.make(name: "Cal", deviceName: "Cal's iPhone", kind: .iphone, on: mesh)
		try PairCore.meet(ana, cal)
		let group = try ana.createGroup("weekend", users: [ben.me().user, cal.me().user])
		XCTAssertEqual(ben.conversation(group.id)?.name, "weekend")
		XCTAssertEqual(cal.members(group.id).count, 3)
		// Ben and Cal are not contacts but are co-members: Ben's message reaches Cal.
		_ = try ben.send(group.id, Draft(text: "saturday?"))
		XCTAssertEqual(cal.events(group.id, before: nil, limit: 20).last?.text, "saturday?")
		XCTAssertTrue(cal.peers().contains { $0.device.name == "Ben's Mac" })

		let space = try ana.createSpace("rubric")
		let general = try ana.createChannel(space: space.id, name: "general")
		let random = try ana.createChannel(space: space.id, name: "random")
		_ = try ana.send(general.id, Draft(text: "welcome to the space"))
		try ana.addMember(space.id, ben.me().user)
		XCTAssertEqual(ben.conversations(.channel).map(\.name), ["general"])
		XCTAssertEqual(ben.channels(space: space.id).map(\.name), ["general", "random"])
		XCTAssertTrue(ben.events(general.id, before: nil, limit: 20).contains { $0.text == "welcome to the space" }, "a channel shares its history")
		try ben.join(space: space.id, channel: random.id)
		XCTAssertEqual(Set(ben.conversations(.channel).map(\.name)), ["general", "random"])
		XCTAssertEqual(ben.search("welcome", scope: nil).first?.conversation.name, "general")
		XCTAssertEqual(ben.search("saturday", scope: SearchScope(space: space.id)).count, 0)
	}

	func testThreadReactEditRedact() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = ana.conversations(.chat)[0].id
		let root = try ana.send(chat, Draft(text: "plan"))
		_ = try ben.send(chat, Draft(text: "yes", thread: root.id))
		_ = try ben.react(chat, root.id, "👍", on: true)
		let shown = try XCTUnwrap(ana.events(chat, before: nil, limit: 10).last)
		XCTAssertEqual(shown.replies, 1)
		XCTAssertEqual(shown.lastRepliers, [ben.me().user])
		XCTAssertEqual(shown.reactions.map(\.key), ["👍"])
		XCTAssertEqual(ana.thread(chat, root.id, before: nil, limit: 10).count, 2)
		try ana.edit(chat, root.id, text: "plan, updated")
		XCTAssertEqual(ben.events(chat, before: nil, limit: 10).last?.text, "plan, updated")
		XCTAssertTrue(ben.events(chat, before: nil, limit: 10).last!.edited)
		try ana.redact(chat, root.id)
		XCTAssertNil(ben.events(chat, before: nil, limit: 10).last?.text)
		XCTAssertEqual(ben.search("plan", scope: nil).count, 0)
	}

	func testPagingAndSpeed() throws {
		let (_, ana, _) = try PairCore.pair()
		let chat = ana.conversations(.chat)[0].id
		let t0 = Date()
		ana.store.transaction {
			for i in 0..<10_000 { _ = try? ana.write(chat, .message, body: encode(MessageBody(text: "message \(i)", attachments: nil, reply: nil, thread: nil, mentions: nil)), text: "message \(i)") }
		}
		let wrote = Date().timeIntervalSince(t0)
		let t1 = Date()
		let page = ana.events(chat, before: nil, limit: 200)
		let read = Date().timeIntervalSince(t1)
		XCTAssertEqual(page.count, 200)
		XCTAssertEqual(page.last?.text, "message 9999")
		let older = ana.events(chat, before: page.first!.id, limit: 200)
		XCTAssertEqual(older.last?.text, "message 9799")
		let t2 = Date()
		let hits = ana.search("message 42", scope: nil)
		let searched = Date().timeIntervalSince(t2)
		let t3 = Date(); _ = ana.search("mess", scope: nil); print("prefix search in \(Int(Date().timeIntervalSince(t3) * 1000)) ms")
		XCTAssertFalse(hits.isEmpty)
		print("wrote 10k in \(Int(wrote * 1000)) ms, page of 200 in \(Int(read * 1000)) ms, search in \(Int(searched * 1000)) ms")
		XCTAssertLessThan(read, 0.1)
		XCTAssertLessThan(searched, 0.05)
	}

	/// A card listing a device of a kind this version doesn't know still reads (as a node), and an
	/// Android phone reads as one.
	func testUnknownDeviceKindReads() throws {
		let json = #"{"id":"d1","name":"Glasses","kind":"glasses","addedAt":0}"#
		let d = try JSONDecoder().decode(WireDevice.self, from: Data(json.utf8))
		XCTAssertEqual(d.kind, .node)
		XCTAssertEqual(d.name, "Glasses")
		let a = try JSONDecoder().decode(WireDevice.self, from: Data(#"{"id":"d2","name":"Pixel","kind":"android","addedAt":0}"#.utf8))
		XCTAssertEqual(a.kind, .android)
	}
}
