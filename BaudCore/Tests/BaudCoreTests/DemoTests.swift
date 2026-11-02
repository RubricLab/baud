import XCTest
@testable import BaudCore

final class DemoTests: XCTestCase {
	func testSeedTwiceComesBackTheSame() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let keys = MemoryKeys()
		var me = try LocalCore(dir: dir, keys: keys, deviceName: "Mac", kind: .mac)
		try me.setName("Dex")
		let t = Date()
		let people = try Demo.seed(around: me, on: Mesh(), events: 2000)
		print("seeded 2000 in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
		XCTAssertEqual(me.contacts().map(\.name), ["Ana", "Jo", "Sam"])
		XCTAssertEqual(me.contacts()[0].devices.count, 2)
		XCTAssertEqual(me.contacts()[0].sentence, "online on their Mac")
		XCTAssertEqual(me.contacts()[2].sentence, "last online 1 d ago")
		let general = try XCTUnwrap(me.conversations(.channel).first { $0.name == "general" })
		XCTAssertGreaterThan(general.eventCount, 1900)
		XCTAssertGreaterThan(general.unread, 0)
		let dmSam = try XCTUnwrap(me.conversations(.chat).first { $0.isDirect && $0.members.contains(people.sam.user) })
		let last = try XCTUnwrap(me.events(dmSam.id, before: nil, limit: 5).last)
		XCTAssertEqual(me.delivery(dmSam.id, last.id).sentence, "carried by Ana's Mac and Jo's iPhone · waiting for Sam's Mac", "Jo is a co-member in the space, so Jo's iPhone carries too")
		me.setOnline(false)
		people.sam.setOnline(true)
		XCTAssertTrue([people.ana.device, people.jo.device].contains(people.sam.events(dmSam.id, before: nil, limit: 5).last?.carriedBy ?? ""))
		me.setOnline(true)
		XCTAssertEqual(me.delivery(dmSam.id, last.id).sentence, "delivered to Sam's Mac")
		let samMac = try XCTUnwrap(me.peers().first { $0.device.name == "Sam's Mac" })
		XCTAssertTrue(samMac.sentence.hasPrefix("online, direct"))

		// Relaunch: a new core on the same store, new demo cores, same ids, same conversations.
		me = try LocalCore(dir: dir, keys: keys, deviceName: "Mac", kind: .mac)
		let again = try Demo.seed(around: me, on: Mesh(), events: 2000)
		XCTAssertEqual(again.ana.device, people.ana.device)
		XCTAssertEqual(me.contacts().map(\.name), ["Ana", "Jo", "Sam"])
		XCTAssertEqual(again.ana.conversations(.channel).count, 3)
		let e = try me.send(general.id, Draft(text: "after relaunch"))
		XCTAssertEqual(again.jo.events(general.id, before: nil, limit: 3).last?.text, "after relaunch")
		XCTAssertTrue(me.delivery(general.id, e.id).sentence.contains("delivered to") && me.delivery(general.id, e.id).sentence.contains("Ana's Mac"), me.delivery(general.id, e.id).sentence)
	}
}
