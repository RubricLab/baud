/// Sharing where I am: only to the chat I chose, gone when I stop or the time is up.
import XCTest
@testable import BaudCore

final class PlacesTests: XCTestCase {
	func testAShareReachesTheChatAndStops() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		XCTAssertFalse(ana.wantsPlace)
		// A fix before any share goes nowhere.
		ana.moved(lat: 40.7128, lon: -74.0060, accuracy: 12)
		XCTAssertTrue(ben.places(chat.id).isEmpty)

		ana.share(place: chat.id, until: Date().addingTimeInterval(3600))
		XCTAssertTrue(ana.wantsPlace)
		let first = try XCTUnwrap(ben.places(chat.id).first)
		XCTAssertEqual(first.user, ana.user)
		XCTAssertEqual(first.lat, 40.7128, accuracy: 1e-9)
		XCTAssertNotNil(first.until)

		ana.moved(lat: 40.7265, lon: -73.9817, accuracy: 8)
		XCTAssertEqual(ben.places(chat.id).count, 1)
		XCTAssertEqual(ben.places(chat.id).first?.lat ?? 0, 40.7265, accuracy: 1e-9)

		ana.stopSharing(chat.id)
		XCTAssertFalse(ana.wantsPlace)
		XCTAssertTrue(ben.places(chat.id).isEmpty)
		// Moving after stopping sends nothing.
		ana.moved(lat: 1, lon: 1, accuracy: 5)
		XCTAssertTrue(ben.places(chat.id).isEmpty)
	}

	func testAShareEndsOnItsOwn() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		ana.moved(lat: 51.5, lon: -0.12, accuracy: 20)
		ana.share(place: chat.id, until: Date().addingTimeInterval(0.4))
		XCTAssertEqual(ben.places(chat.id).count, 1)
		Thread.sleep(forTimeInterval: 0.6)
		XCTAssertTrue(ben.places(chat.id).isEmpty)
		XCTAssertTrue(ana.sharing().isEmpty)
	}

	/// A place claimed for someone else, or for a chat its sender isn't in, is dropped.
	func testOnlyTheSenderAndOnlyItsChat() throws {
		let (_, ana, ben) = try PairCore.pair()
		let chat = try XCTUnwrap(ana.conversations(.chat).first)
		let forged = Place(user: "someone-else", device: ana.device, lat: 0, lon: 0, accuracy: 1, at: Date().timeIntervalSince1970, until: nil)
		ben.keep(place: forged, conv: chat.id, from: ana.device)
		XCTAssertTrue(ben.places(chat.id).isEmpty)
		let elsewhere = Place(user: ana.user, device: ana.device, lat: 0, lon: 0, accuracy: 1, at: Date().timeIntervalSince1970, until: nil)
		ben.keep(place: elsewhere, conv: "not-a-chat-ben-is-in", from: ana.device)
		XCTAssertTrue(ben.places("not-a-chat-ben-is-in").isEmpty)
	}
}
