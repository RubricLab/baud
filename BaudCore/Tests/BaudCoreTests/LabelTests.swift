import XCTest
@testable import BaudCore

/// A member's label in a group: their own, or an admin's word on anyone's, seen by everyone in it.
final class LabelTests: XCTestCase {
	func testOwnLabelAndAnAdminsReachEveryone() throws {
		let (_, ana, ben) = try PairCore.pair()
		// Ana makes the group, so she is its admin; Ben is a member.
		let group = try ana.create(kind: .chat, name: "hike", space: nil, users: [ben.user])
		func label(_ core: LocalCore, _ u: UserId) -> String? { core.members(group.id).first { $0.user == u }?.label }

		try ben.setLabel(group.id, ben.user, "  driver  ")
		XCTAssertEqual(label(ana, ben.user), "driver")
		XCTAssertEqual(label(ben, ben.user), "driver")

		// Ben isn't an admin: Ana's label isn't his to set.
		XCTAssertThrowsError(try ben.setLabel(group.id, ana.user, "late"))
		XCTAssertNil(label(ana, ana.user))

		// The admin may set anyone's, and an empty one takes it away.
		try ana.setLabel(group.id, ben.user, "organiser and driver for the whole weekend")
		XCTAssertEqual(label(ben, ben.user), "organiser and driver for")
		try ana.setLabel(group.id, ben.user, nil)
		XCTAssertNil(label(ben, ben.user))

		// No line in the chat for it.
		XCTAssertFalse(ben.events(group.id, before: nil, limit: 50).contains { $0.system?.contains("label") == true })
	}
}
