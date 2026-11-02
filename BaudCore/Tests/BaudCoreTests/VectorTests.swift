/// Golden vectors for baud-core (the Rust core in core/): every frame, body and packet
/// shape this core puts on the wire, written to `core/vectors/swift.json` for the Rust tests to
/// decode and re-encode; and the Rust core's own (`rust.json`), decoded here. JSON key order is
/// random per process in Swift's encoder, so the two sides compare values, never bytes.
import CryptoKit
import Foundation
import Testing
@testable import BaudCore

struct VectorTests {
	static let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("core/vectors")

	static let ana = String(repeating: "a1", count: 32), ben = String(repeating: "b2", count: 32)
	static let anaMac = String(repeating: "c3", count: 32), anaPhone = String(repeating: "d4", count: 32), benMac = String(repeating: "e5", count: 32)
	static let conv = String(repeating: "f6", count: 32), space = String(repeating: "07", count: 32)
	static let at = 1792191121.909131, whole = 1792191121.0
	static let peerCard = Data([0xfb, 0xff, 0xfe, 0x00, 0x01, 0x02, 0x03, 0x7f, 0x80, 0xbf])

	static func id(_ seq: Int, _ dev: String = anaMac) -> EventId { stableId("\(conv)/\(dev)/\(seq)") }
	static let anaCard = WireCard(user: ana, name: "Ana Zoë", fingerprint: fingerprint(ana), devices: [
		WireDevice(id: anaMac, name: "Ana's Mac", kind: .mac, addedAt: 1792100000.25),
		WireDevice(id: anaPhone, name: "Ana's iPhone", kind: .iphone, addedAt: 1792100500.0),
	], avatar: String(repeating: "9a", count: 32), peerCard: peerCard)
	static let benCard = WireCard(user: ben, name: "Ben", fingerprint: fingerprint(ben), devices: [WireDevice(id: benMac, name: "Ben's Mac", kind: .mac, addedAt: 1792000000.5)], avatar: nil, peerCard: nil)

	static func ev(_ seq: Int, _ type: EventType, _ body: String, text: String? = nil, reply: EventId? = nil, thread: EventId? = nil, target: EventId? = nil, at: Double = at, dev: String = anaMac, user: String = ana) -> WireEvent {
		WireEvent(id: id(seq, dev), conv: conv, device: dev, seq: seq, user: user, at: at, lamport: seq, type: type, text: text, reply: reply, thread: thread, target: target, body: body)
	}

	static var events: [(String, WireEvent)] {
		let text = "See https://x.y/z — café é 😀\n\"quoted\" \\ back/slash\ttab"
		let photo = Attachment(hash: String(repeating: "ab", count: 32), key: "0011223344556677", mime: "image/jpeg", size: 2_345_678, name: "IMG_0001.jpg", width: 4032, height: 3024, duration: nil)
		let clip = Attachment(hash: String(repeating: "cd", count: 32), key: "8899aabbccddeeff", mime: "video/quicktime", size: 12_000_000, name: "clip.mov", width: 1920, height: 1080, duration: 12.48)
		let bare = Attachment(hash: String(repeating: "ef", count: 32), mime: "application/octet-stream", size: 3)
		let full = MessageBody(text: text, attachments: [photo, clip, bare], reply: id(1), thread: id(2), mentions: [ben])
		let call = encode(CallRecord(video: true, outcome: "talked", seconds: 245))
		return [
			("message-full", ev(3, .message, encode(full), text: text, reply: id(1), thread: id(2))),
			("message-text", ev(4, .message, encode(MessageBody(text: "hi", attachments: nil, reply: nil, thread: nil, mentions: nil)), text: "hi", at: whole)),
			("message-photo-only", ev(5, .message, encode(MessageBody(text: nil, attachments: [bare], reply: nil, thread: nil, mentions: nil)))),
			("edit", ev(6, .edit, encode(EditBody(target: id(4), text: "hi again")), text: "hi again", target: id(4))),
			("reaction-on", ev(7, .reaction, encode(ReactionBody(target: id(4), key: "👍", on: true)), target: id(4))),
			("reaction-off", ev(8, .reaction, encode(ReactionBody(target: id(4), key: "👍", on: false)), target: id(4))),
			("redact", ev(9, .redact, encode(RedactBody(target: id(5))), target: id(5))),
			("member-add", ev(10, .member, encode(MemberBody(user: ana, card: anaCard, action: "add", admin: false)), text: "add")),
			("member-remove", ev(11, .member, encode(MemberBody(user: ben, card: nil, action: "remove", admin: nil)), text: "remove")),
			("member-leave", ev(12, .member, encode(MemberBody(user: ana, card: nil, action: "leave", admin: nil)), text: "leave")),
			("state-name", ev(13, .state, encode(StateBody(key: "name", value: "Weekend / plans")), text: "name")),
			("state-topic", ev(14, .state, encode(StateBody(key: "topic", value: "Saturday")), text: "topic")),
			("state-pin", ev(15, .state, encode(StateBody(key: "pin", value: id(4))), text: "pin", target: id(4))),
			("state-unpin", ev(16, .state, encode(StateBody(key: "pin", value: "-" + id(4))), text: "pin", target: id(4))),
			("state-call", ev(17, .state, encode(StateBody(key: "call", value: call)), text: "call")),
			("state-profile-colour", ev(18, .state, encode(StateBody(key: "profile.colour", value: "0090FF")))),
			("state-profile-hidden", ev(19, .state, encode(StateBody(key: "profile.hidden." + conv, value: "42")))),
			("create-group", ev(1, .create, encode(CreateBody(kind: .chat, name: "Weekend", space: nil, history: "members", creator: anaCard, isDefault: nil)), text: "Weekend")),
			("create-default", ev(1, .create, encode(CreateBody(kind: .chat, name: nil, space: nil, history: "members", creator: benCard, isDefault: true)), dev: benMac, user: ben)),
			("card", ev(20, .card, encode(anaCard))),
			("message-ttl", ev(21, .message, encode(MessageBody(text: "gone a day after it's read", ttl: 86_400)), text: "gone a day after it's read")),
			("state-disappear", ev(22, .state, encode(StateBody(key: "disappear", value: "86400")), text: "disappear")),
			("state-disappear-off", ev(23, .state, encode(StateBody(key: "disappear", value: "0")), text: "disappear")),
		]
	}

	/// The timeline's line for the setting and its words, as both cores make them.
	static var sentences: [[String: Any]] {
		[0, 1, 45, 60, 300, 3600, 28_800, 86_400, 172_800, 604_800, 2_419_200, 90, 5400].flatMap { s in
			["Ana", "You"].map { who in ["by": who, "seconds": s, "line": disappearLine(by: who, seconds: s), "after": disappearAfter(s), "short": disappearShort(s)] as [String: Any] }
		}
	}

	static var frames: [(String, Frame)] {
		var out: [(String, Frame)] = events.map { ("events-" + $0.0, Frame.events([$0.1])) }
		out.append(("events-several", .events(events.prefix(5).map(\.1))))
		out.append(("events-empty", .events([])))
		out.append(("receipt-delivered", .receipt(WireReceipt(conv: conv, device: benMac, user: ben, event: id(4), lamport: 4, kind: "delivered", at: at))))
		out.append(("receipt-read", .receipt(WireReceipt(conv: conv, device: benMac, user: ben, event: id(4), lamport: 4, kind: "read", at: whole))))
		out.append(("typing", .typing(conv, ana)))
		out.append(("hello", .hello(secret: String(repeating: "5e", count: 16), card: benCard)))
		out.append(("welcome", .welcome(card: anaCard)))
		out.append(("link", .link(secret: String(repeating: "6f", count: 16), device: WireDevice(id: anaPhone, name: "Ana's iPhone", kind: .iphone, addedAt: at))))
		out.append(("card-bare", .card(benCard)))
		out.append(("card-full", .card(anaCard)))
		out.append(("envelope", .envelope(WireEnvelope(id: "0123456789abcdef", to: benMac, from: anaMac, conv: conv, frame: .events([events[1].1]), size: 321, expires: 1793400721.5, hops: 1))))
		out.append(("ack", .ack("0123456789abcdef")))
		out.append(("clock", .clock(conv, [anaMac: 20, benMac: 3])))
		out.append(("clock-empty", .clock(conv, [:])))
		out.append(("clockReply", .clockReply(conv, [anaMac: 19])))
		out.append(("inCall", .inCall(conv, CallPresence(id: "call-1", video: true, peers: [CallPeer(device: anaMac, user: ana, name: "Ana"), CallPeer(device: benMac, user: ben, name: "Ben")], until: 1792191181.909131))))
		out.append(("inCall-over", .inCall(conv, CallPresence(id: "call-1", video: false, peers: [], until: whole))))
		out.append(("want", .want(String(repeating: "ab", count: 32))))
		out.append(("offer", .offer(String(repeating: "ab", count: 32), String(repeating: "12", count: 32))))
		out.append(("relay", .relay(benMac, Data("{\"v\":2}".utf8) + peerCard)))
		return out
	}

	static var bodies: [(String, String)] {
		[
			("MessageBody", encode(MessageBody(text: "a/b", attachments: [Attachment(hash: "h", mime: "image/png", size: 1, name: nil, width: 2, height: 3, duration: nil)], reply: "r", thread: "t", mentions: [ben]))),
			("MessageBody-empty", encode(MessageBody(text: nil, attachments: nil, reply: nil, thread: nil, mentions: nil))),
			("MessageBody-ttl", encode(MessageBody(text: "x", attachments: nil, reply: nil, thread: nil, mentions: nil, ttl: 300))),
			("EditBody", encode(EditBody(target: id(4), text: "x"))),
			("ReactionBody", encode(ReactionBody(target: id(4), key: "❤️", on: true))),
			("RedactBody", encode(RedactBody(target: id(4)))),
			("MemberBody", encode(MemberBody(user: ben, card: benCard, action: "add", admin: true))),
			("StateBody", encode(StateBody(key: "name", value: "Ö"))),
			("CreateBody", encode(CreateBody(kind: .channel, name: "general", space: space, history: "shared", creator: benCard, isDefault: true))),
			("CallRecord", encode(CallRecord(video: false, outcome: "missed", seconds: 0))),
			("ChannelRefs", encode([ChannelRef(conv: conv, name: "general", isDefault: true), ChannelRef(conv: space, name: "random", isDefault: false)])),
		]
	}

	static let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) }), nonce = Data((0..<12).map { UInt8(0xa0 &+ $0) })

	/// `LocalCore.seal` with a fixed key and nonce.
	/// `plain` is the frame's JSON as sealed: Swift orders keys anew on every encode, so the vector
	/// keeps the very bytes it sealed.
	static func packet(_ frame: Frame, conv: ConversationId?, joiner: Bool, plain s: String) throws -> Data {
		let plain = Data(s.utf8)
		guard let conv else { return try json.encode(Packet(v: wireVersion, conv: nil, key: nil, nonce: nil, body: plain)) }
		let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key), nonce: try ChaChaPoly.Nonce(data: nonce))
		return try json.encode(Packet(v: wireVersion, conv: conv, key: joiner ? key : nil, nonce: Data(box.nonce), body: box.ciphertext + box.tag))
	}

	static func same(_ a: String, _ b: String) -> Bool {
		guard let x = try? JSONSerialization.jsonObject(with: Data(a.utf8), options: [.fragmentsAllowed]) as? NSObject,
			  let y = try? JSONSerialization.jsonObject(with: Data(b.utf8), options: [.fragmentsAllowed]) as? NSObject else { return false }
		return x.isEqual(y)
	}

	@Test func writeVectors() throws {
		var frameRows: [[String: Any]] = []
		for (name, f) in Self.frames {
			let s = encode(f)
			#expect(decode(Frame.self, s) == f, "\(name) round-trips")
			frameRows.append(["name": name, "json": s])
		}
		let bodyRows: [[String: Any]] = Self.bodies.map { ["name": $0.0, "json": $0.1] }

		let sealedFrame = Frame.events([Self.events[0].1, Self.events[1].1])
		let joinFrame = Frame.events([Self.events[17].1, Self.events[7].1])
		let cases: [(String, Frame, ConversationId?, Bool)] = [
			("sealed", sealedFrame, Self.conv, false),
			("sealed-joiner", joinFrame, Self.conv, true),
			("open", .want(String(repeating: "ab", count: 32)), nil, false),
		]
		var packetRows: [[String: Any]] = []
		for (name, f, conv, joiner) in cases {
			let plain = encode(f)
			let p = try Self.packet(f, conv: conv, joiner: joiner, plain: plain)
			// The core opens it back to the same frame: with the key set beforehand, or from the packet.
			let core = try LocalCore(dir: nil, keys: MemoryKeys(), deviceName: "t", kind: .mac)
			if let conv, !joiner { core.setConvKey(conv, Self.key) }
			#expect(core.open(p) == f, "\(name) opens")
			packetRows.append([
				"name": name, "key": conv == nil ? NSNull() : Self.key.base64EncodedString(), "nonce": conv == nil ? NSNull() : Self.nonce.base64EncodedString(),
				"conv": conv ?? NSNull(), "joiner": joiner, "frame": plain, "packet": String(decoding: p, as: UTF8.self),
			])
		}

		let inputs = ["", "a", "home:" + Self.ana, "home2:" + Self.ana, "\(Self.conv)/\(Self.anaMac)/1", "conv:\(Self.anaMac):6F9619FF-8B86-D011-B42D-00CF4FC964FF", "Zoë 😀 ünïcödé", "device:" + String(repeating: "00", count: 32)]
		let ids: [[String: Any]] = inputs.map { ["input": $0, "stableId": stableId($0)] }
		let homes: [[String: Any]] = [Self.ana, Self.ben, "user-x"].map { ["user": $0, "home": stableId("home:" + $0) + stableId("home2:" + $0)] }
		let prints: [[String: Any]] = [Self.ana, Self.ben, "c0ffee"].map { ["user": $0, "fingerprint": fingerprint($0)] }

		let exp = 1792194721, secret = String(repeating: "7a", count: 16)
		let zoe = Data("Zoë".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
		var dotless = Data([1, UInt8(ascii: "f"), UInt8(Data("Zoë".utf8).count)]) + Data("Zoë".utf8)
		dotless += Data((0..<32).map { UInt8($0) })
		dotless += withUnsafeBytes(of: UInt64(exp).bigEndian) { Data($0) }
		dotless += Data(repeating: 0x42, count: 32) + Data("relay=http://203.0.113.7:4101".utf8)
		let token = dotless.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
		// The grouped form (peer's `Link::grouped`): a device link, base32 in dash-joined groups.
		var g = Data([2, UInt8(ascii: "m"), UInt8(Data("Zoë".utf8).count)]) + Data("Zoë".utf8)
		g += Data((0..<32).map { UInt8($0) })
		g += withUnsafeBytes(of: UInt64(exp).bigEndian) { Data($0) }
		g += Data(repeating: 0x42, count: 32) + Data(repeating: 0xcd, count: 32) + Data([0, 4, 203, 0, 113, 7, 0x10, 0x05])
		let grouped = base32(g).enumerated().map { $0.offset > 0 && $0.offset % 48 == 0 ? "-" + String($0.element) : String($0.element) }.joined()
		let plain = "baud://add#peer1.f.Ana.\(Self.ana).\(exp).\(Self.anaMac).\(secret)"
		let linkCases: [(String, Link?)] = [
			(plain, parseLink(url: plain)),
			("baud://add#peer1.f.\(zoe).\(Self.ana).\(exp).\(Self.anaMac).\(secret)", parseLink(url: "baud://add#peer1.f.\(zoe).\(Self.ana).\(exp).\(Self.anaMac).\(secret)")),
			("baud://link#peer1.m.\(zoe).\(Self.ana).\(exp).\(Self.anaMac).\(secret)", parseLink(url: "baud://link#peer1.m.\(zoe).\(Self.ana).\(exp).\(Self.anaMac).\(secret)")),
			("https://baud.rubric.sh/add#peer1.f.Ana.\(Self.ana).\(exp).\(Self.anaMac).\(secret)", parseLink(url: "https://baud.rubric.sh/add#peer1.f.Ana.\(Self.ana).\(exp).\(Self.anaMac).\(secret)")),
			("  peer1.f.Ana.\(Self.ana).\(exp).\(Self.anaMac).\(secret)\n", Code.parse("  peer1.f.Ana.\(Self.ana).\(exp).\(Self.anaMac).\(secret)\n")),
			("baud://add#" + token, parseLink(url: "baud://add#" + token)),
			(token, Code.parse(token)),
			("baud://add#nonsense", parseLink(url: "baud://add#nonsense")),
			("hello", Code.parse("hello")),
			("https://baud.rubric.sh/link#" + grouped, parseLink(url: "https://baud.rubric.sh/link#" + grouped)),
			(grouped.uppercased(), Code.parse(grouped.uppercased())),
		]
		#expect(linkCases[1].1?.name == "Zoë" && linkCases[5].1?.name == "Zoë" && linkCases[6].1?.url.hasPrefix("baud://add#") == true)
		#expect(linkCases[7].1 == nil && linkCases[8].1 == nil)
		#expect(linkCases[9].1?.name == "Zoë" && linkCases[9].1?.kind == .device && linkCases[10].1?.url.hasPrefix("baud://link#") == true)
		let links: [[String: Any]] = linkCases.map { input, l in
			["input": input, "url": l?.url ?? NSNull(), "kind": l?.kind.rawValue ?? NSNull(), "name": l?.name ?? NSNull(), "expires": l.map { $0.expires.timeIntervalSince1970 } ?? NSNull()]
		}

		#expect(disappearLine(by: "Ana", seconds: 86_400) == "Ana set messages to disappear 1 day after they're read")
		#expect(disappearLine(by: "You", seconds: 0) == "You turned off disappearing messages")
		#expect([300, 3600, 28_800, 86_400, 604_800, 2_419_200].map(disappearShort) == ["5m", "1h", "8h", "1d", "1w", "4w"])

		let all: [String: Any] = ["frames": frameRows, "bodies": bodyRows, "packets": packetRows, "ids": ids, "homes": homes, "fingerprints": prints, "links": links, "sentences": Self.sentences, "wireVersion": wireVersion]
		let out = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
		try FileManager.default.createDirectory(at: Self.vectors, withIntermediateDirectories: true)
		try out.write(to: Self.vectors.appendingPathComponent("swift.json"))
	}

	@Test func readRustVectors() throws {
		let url = Self.vectors.appendingPathComponent("rust.json")
		guard let d = try? Data(contentsOf: url) else { return }
		let all = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
		for row in all["frames"] as? [[String: Any]] ?? [] {
			let name = row["name"] as? String ?? "?", s = row["json"] as? String ?? ""
			let f = decode(Frame.self, s)
			#expect(f != nil, "rust frame \(name) decodes")
			if let f { #expect(Self.same(encode(f), s), "rust frame \(name) re-encodes to the same value") }
		}
		for row in all["packets"] as? [[String: Any]] ?? [] {
			let name = row["name"] as? String ?? "?"
			let core = try LocalCore(dir: nil, keys: MemoryKeys(), deviceName: "t", kind: .mac)
			if let conv = row["conv"] as? String, (row["joiner"] as? Bool) != true, let k = (row["key"] as? String).flatMap({ Data(base64Encoded: $0) }) { core.setConvKey(conv, k) }
			let opened = core.open(Data((row["packet"] as? String ?? "").utf8))
			#expect(opened != nil, "rust packet \(name) opens")
			if let opened { #expect(Self.same(encode(opened), row["frame"] as? String ?? ""), "rust packet \(name) holds its frame") }
		}
		for row in all["sentences"] as? [[String: Any]] ?? [] {
			let who = row["by"] as? String ?? "", s = row["seconds"] as? Int ?? -1
			#expect(disappearLine(by: who, seconds: s) == row["line"] as? String, "rust's line for \(s) s")
			#expect(disappearAfter(s) == row["after"] as? String && disappearShort(s) == row["short"] as? String, "rust's words for \(s) s")
		}
	}
}

/// RFC 4648 base32, lowercase, unpadded: peer's grouped links.
private func base32(_ d: Data) -> String {
	let a = Array("abcdefghijklmnopqrstuvwxyz234567")
	var out = "", acc = 0, bits = 0
	for b in d {
		acc = (acc << 8 | Int(b)) & 0xFFFF; bits += 8
		while bits >= 5 { bits -= 5; out.append(a[acc >> bits & 31]) }
	}
	if bits > 0 { out.append(a[acc << (5 - bits) & 31]) }
	return out
}
