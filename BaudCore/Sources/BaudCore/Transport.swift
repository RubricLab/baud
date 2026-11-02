/// The seam the peer crate fills: bytes to a device now over a live connection, or handed to
/// carriers for later. The core seals every frame with the conversation's key before it goes
/// out (ChaChaPoly here; vodozemac with the Rust layer later) and signs nothing itself: the
/// crate authenticates the device on every connection and envelope.
import CryptoKit
import Foundation

public protocol Transport: AnyObject, Sendable {
	func isOnline(_ device: DeviceId) -> Bool
	func rtt(_ device: DeviceId) -> Int?
	/// Over a live connection, now. False when there isn't one.
	func send(_ bytes: Data, to device: DeviceId) async -> Bool
	/// Sealed and handed to carriers. The devices that took it; empty means it waits here.
	func post(_ bytes: Data, to device: DeviceId, ttl: TimeInterval) async -> [DeviceId]
	/// A file into the crate's blob store, for a device that asked: the id it fetches it by; nil
	/// when there is no store.
	func provide(_ file: URL) async -> String?
	/// A blob by its store id from a device, into `file`. True once all of it is there, verified.
	func fetch(_ id: String, from device: DeviceId, to file: URL) async -> Bool
	/// Whether this device may connect or post to that one at all: it holds a card naming it. A
	/// co-member of a group who isn't a friend is reached through someone who is (`relay`).
	func reaches(_ device: DeviceId) -> Bool
}

public extension Transport {
	func provide(_ file: URL) async -> String? { nil }
	func fetch(_ id: String, from device: DeviceId, to file: URL) async -> Bool { false }
	func reaches(_ device: DeviceId) -> Bool { true }
}

/// The wire's version: packets without it are from before the legacy wipe and are dropped.
let wireVersion = 2

/// What crosses the transport: a frame, sealed with its conversation's key when it has one.
/// A membership frame to a joiner carries the key so the joiner can open what follows; it
/// travels only over the crate's device-to-device encryption.
struct Packet: Codable {
	/// The wire's version. Anything older is dropped unread: 0.2.4 and before carried the legacy
	/// messages this version wiped, and they must not come back from a device that kept them.
	var v: Int?
	var conv: ConversationId?
	var key: Data?
	var nonce: Data?
	var body: Data
}

extension LocalCore {
	func convKey(_ conv: ConversationId) -> SymmetricKey {
		lock.withLock {
			if let k = store.one("select v from me where k=?", ["key:" + conv])?.string("v"), let d = Data(base64Encoded: k) { return SymmetricKey(data: d) }
			let k = SymmetricKey(size: .bits256)
			store.run("insert or replace into me(k,v) values(?,?)", ["key:" + conv, k.withUnsafeBytes { Data($0) }.base64EncodedString()])
			return k
		}
	}
	func setConvKey(_ conv: ConversationId, _ key: Data) {
		lock.withLock { store.run("insert or replace into me(k,v) values(?,?)", ["key:" + conv, key.base64EncodedString()]) }
	}

	/// Seal a frame for the wire. Membership and creation frames for `joiner` carry the key.
	func seal(_ frame: Frame, conv: ConversationId?, joiner: Bool = false) -> Data {
		let plain = Data(encode(frame).utf8)
		guard let conv else { return (try? json.encode(Packet(v: wireVersion, conv: nil, key: nil, nonce: nil, body: plain))) ?? Data() }
		let key = convKey(conv)
		let box = try! ChaChaPoly.seal(plain, using: key)
		let p = Packet(v: wireVersion, conv: conv, key: joiner ? key.withUnsafeBytes { Data($0) } : nil, nonce: Data(box.nonce), body: box.ciphertext + box.tag)
		return (try? json.encode(p)) ?? Data()
	}

	/// The key a conversation already has here; nil before its first membership frame arrives.
	func existingKey(_ conv: ConversationId) -> SymmetricKey? {
		lock.withLock { store.one("select v from me where k=?", ["key:" + conv])?.string("v").flatMap { Data(base64Encoded: $0) }.map { SymmetricKey(data: $0) } }
	}

	/// Open a packet from the wire; nil when it is from an older wire, or for a conversation this
	/// device has no key to yet: then it is kept (with who handed it over) and opened when the key
	/// comes. A message can race its conversation's creation, which carries the key; dropped, it
	/// waited for the next minute's sync.
	func open(_ bytes: Data, from: DeviceId? = nil, carriedBy: DeviceId? = nil) -> Frame? {
		guard let p = try? unjson.decode(Packet.self, from: bytes), p.v == wireVersion else { return nil }
		guard let conv = p.conv, let nonce = p.nonce else { return decode(Frame.self, String(decoding: p.body, as: UTF8.self)) }
		if let k = p.key { setConvKey(conv, k) }
		guard let key = existingKey(conv) else {
			if let from { lock.withLock { if waitingForKey.count < 500 { waitingForKey.append((conv, bytes, from, carriedBy)) } } }
			return nil
		}
		guard let n = try? ChaChaPoly.Nonce(data: nonce), let box = try? ChaChaPoly.SealedBox(nonce: n, ciphertext: p.body.dropLast(16), tag: p.body.suffix(16)),
			  let plain = try? ChaChaPoly.open(box, using: key) else { return nil }
		return decode(Frame.self, String(decoding: plain, as: UTF8.self))
	}

	/// The transport hands in bytes; the core opens them and treats them as a received frame,
	/// then opens whatever was waiting for a key this frame brought.
	public func receive(bytes: Data, from: DeviceId, carriedBy: DeviceId?) {
		guard let f = open(bytes, from: from, carriedBy: carriedBy) else { return }
		receive(f, from: from, carriedBy: carriedBy)
		let ready: [(conv: ConversationId, bytes: Data, from: DeviceId, carriedBy: DeviceId?)] = lock.withLock {
			guard !waitingForKey.isEmpty else { return [] }
			let keyed = Set(waitingForKey.map(\.conv).filter { store.one("select v from me where k=?", ["key:" + $0]) != nil })
			let r = waitingForKey.filter { keyed.contains($0.conv) }
			waitingForKey.removeAll { keyed.contains($0.conv) }
			return r
		}
		for w in ready { receive(bytes: w.bytes, from: w.from, carriedBy: w.carriedBy) }
	}

	/// A device came online on the crate: offer it my clocks for everything we share, so each
	/// side sends what the other lacks (the in-process mesh does this by reading the other core).
	public func connected(_ d: DeviceId) {
		guard transport != nil, online else { return }
		let convs: [ConversationId] = lock.withLock {
			store.query("select distinct a.conv from members a join members b on b.conv=a.conv join devices d on d.user=b.user where a.user=? and d.id=?", [user, d]).compactMap { $0.string("conv") }
		}
		for conv in convs { post(.clock(conv, clock(conv)), to: d, conv: conv) }
		retryMissing(from: d)
	}
}
