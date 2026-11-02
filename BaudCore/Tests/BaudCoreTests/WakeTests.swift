import CryptoKit
import Foundation
import Testing
@testable import BaudCore

/// A ticket sealed here must open on the relay (Rust, `wake/src/ticket.rs`). The relay's tests open
/// `wake/tests/swift-ticket.json`, which `BAUD_WAKE_VECTOR=<path> swift test` writes from this one.
@Test func aTicketSealedHereOpensWithTheRelaysKeyAndReadsBack() throws {
	let relay = Curve25519.KeyAgreement.PrivateKey()
	let tokens = WakeTokens(alert: Data(repeating: 0xaa, count: 32), voip: Data(repeating: 0xbb, count: 32), sandbox: true)
	let expires = Date(timeIntervalSince1970: 2_000_000_000)
	let id = Data(repeating: 7, count: 16)
	let ticket = try WakeTicket.mint(tokens, expires: expires, to: relay.publicKey, id: id)
	#expect(ticket[0] == 1 && ticket[1] == 1)
	var r = try HPKE.Recipient(privateKey: relay, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: WakeTicket.info, encapsulatedKey: ticket[2..<34])
	let body = try r.open(ticket[34...], authenticating: ticket[0..<2])
	#expect(body[body.startIndex] == 1 | 2 | 4)
	#expect(body[(body.startIndex + 1)..<(body.startIndex + 5)] == Data([0x77, 0x35, 0x94, 0x00]))
	#expect(body[(body.startIndex + 5)..<(body.startIndex + 21)] == id)
	#expect(body.count == 1 + 4 + 16 + 1 + 32 + 1 + 32)
	if let path = ProcessInfo.processInfo.environment["BAUD_WAKE_VECTOR"] {
		let v: [String: Any] = ["key": relay.rawRepresentation.base64EncodedString(), "ticket": ticket.base64EncodedString(), "flags": 7, "expires": 2_000_000_000, "id": "07070707070707070707070707070707", "alert": String(repeating: "aa", count: 32), "voip": String(repeating: "bb", count: 32)]
		try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
	}
}

/// The pinned relay key is a real X25519 key, and a ticket for it is the size the relay expects.
@Test func thePinnedKeyMakesATicket() throws {
	let t = try WakeTicket.mint(WakeTokens(alert: Data(repeating: 1, count: 32), voip: nil, sandbox: false), expires: Date().addingTimeInterval(60))
	#expect(t.count == 2 + 32 + (1 + 4 + 16 + 1 + 32 + 1) + 16)
}
