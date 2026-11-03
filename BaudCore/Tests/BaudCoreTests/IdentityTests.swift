import XCTest
@testable import BaudCore

/// Who I am survives a relaunch before the network is up: the identity the network handed over
/// (a device linked into a person has no user key of its own) is what the store opens as.
final class IdentityTests: XCTestCase {
	func testAnAdoptedIdentityIsKnownAtOnceOnTheNextOpen() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baud-identity-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let keys = MemoryKeys()
		var core = try LocalCore(dir: dir, keys: keys, deviceName: "iPhone", kind: .iphone)
		XCTAssertFalse(core.named, "a linked device has no user key of its own")
		core.adoptIdentity(user: "network-user", name: "Ana", thisDevice: "network-device", devices: [(id: "network-device", name: "iPhone", kind: .iphone)])
		core = try LocalCore(dir: dir, keys: keys, deviceName: "iPhone", kind: .iphone)
		XCTAssertTrue(core.named)
		XCTAssertEqual(core.me().user, "network-user")
		XCTAssertEqual(core.me().name, "Ana")
		XCTAssertEqual(core.me().thisDevice, "network-device")
	}

	func testALockedKeychainWaitsInsteadOfMakingNewKeys() {
		final class Locked: Keys, @unchecked Sendable {
			var puts = 0
			func get(_ item: String) -> Data? { nil }
			func put(_ item: String, _ bytes: Data) { puts += 1 }
			func delete(_ item: String) {}
			var locked: Bool { true }
		}
		let keys = Locked()
		XCTAssertThrowsError(try LocalCore(dir: nil, keys: keys, deviceName: "iPhone", kind: .iphone)) { XCTAssertTrue($0 is KeysLocked) }
		XCTAssertEqual(keys.puts, 0, "nothing new is written over keys that are only locked")
	}
}
