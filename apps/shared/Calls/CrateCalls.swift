/// The crate's side of calls, for the app: dial a device for a call, take one that arrived. Kept
/// apart from CallLink so the test harness can use CallLink without the app's Crate.
import Foundation
import PeerKit

extension Crate.Node {
	func dialCall(_ device: String) async throws -> CallLink { try await CallLink.dial(p, device: device) }
	func acceptCall(_ conn: UInt64) async throws -> CallLink { try await CallLink.accept(p, conn: conn) }
}
