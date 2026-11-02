/// Waking a sleeping iPhone. The iPhone seals its push tokens to the wake relay's key (a ticket no
/// one else can open: HPKE, X25519 · HKDF-SHA256 · ChaCha20-Poly1305) and hands one to every device
/// it connects to, mine and my friends'. A device whose message or call can't reach that iPhone
/// live hands the ticket to the relay, which asks Apple to wake the phone and keeps nothing; the
/// phone then comes online and takes what's waiting peer to peer. The relay is `wake/` in this
/// repository; the ticket's bytes are spelled out in `wake/src/ticket.rs`.
import CryptoKit
import Foundation

public enum WakeKind: String, Sendable { case message, call }

/// This iPhone's two push addresses, as Apple issued them: one for alerts, one for VoIP (calls).
public struct WakeTokens: Equatable, Sendable {
	public var alert: Data?
	public var voip: Data?
	/// A development build talks to Apple's sandbox.
	public var sandbox: Bool
	public init(alert: Data?, voip: Data?, sandbox: Bool) { self.alert = alert; self.voip = voip; self.sandbox = sandbox }
}

enum WakeTicket {
	/// The relay's public key (id 1), pinned: a ticket sealed to it opens only there.
	static let keyID: UInt8 = 1
	static let relayKey = "imSLppnRS8t1y7dzAfiXuvtGTTdVdYBDIZ9bZgfjVWw"
	static let relay = URL(string: ProcessInfo.processInfo.environment["BAUD_WAKE_URL"] ?? "https://wake.baud.rubric.sh")!
	static let info = Data("baud wake ticket".utf8)
	/// A ticket lasts three days and is refreshed once it's past half: a friend I stop seeing (or
	/// block) can't wake me for long.
	static let life: TimeInterval = 72 * 3600

	static func mint(_ t: WakeTokens, expires: Date, to key: Curve25519.KeyAgreement.PublicKey? = nil, id: Data = randomBytes(16)) throws -> Data {
		let pk = try key ?? Curve25519.KeyAgreement.PublicKey(rawRepresentation: base64url(relayKey) ?? Data())
		let alert = t.alert ?? Data(), voip = t.voip ?? Data()
		var flags: UInt8 = t.sandbox ? 1 : 0
		if !alert.isEmpty { flags |= 2 }
		if !voip.isEmpty { flags |= 4 }
		var body = Data([flags])
		withUnsafeBytes(of: UInt32(expires.timeIntervalSince1970).bigEndian) { body.append(contentsOf: $0) }
		body.append(id)
		body.append(UInt8(alert.count)); body.append(alert)
		body.append(UInt8(voip.count)); body.append(voip)
		let head = Data([1, keyID])
		var sender = try HPKE.Sender(recipientKey: pk, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
		let sealed = try sender.seal(body, authenticating: head)
		return head + sender.encapsulatedKey + sealed
	}
}

func base64url(_ s: String) -> Data? {
	var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
	while b.count % 4 != 0 { b += "=" }
	return Data(base64Encoded: b)
}

extension LocalCore {
	/// This iPhone's push addresses, once Apple has issued them (nil on a Mac). New ones make every
	/// ticket I've handed out stale: each device connected now gets a fresh one at once.
	public func setWakeTokens(_ t: WakeTokens?) {
		let changed = lock.withLock { () -> Bool in
			guard wakeTokens != t else { return false }
			wakeTokens = t
			store.run("delete from me where k like 'wakeGiven:%'")
			return true
		}
		guard changed, t != nil, let tr = transport else { return }
		let all = lock.withLock { store.query("select id from devices where id<>?", [device]).compactMap { $0.string("id") } }
		for d in all where tr.isOnline(d) { offerWake(to: d) }
	}

	/// A device I'm connected to holds a ticket to wake me, fresh enough for the next day and a half.
	func offerWake(to d: DeviceId) {
		guard d != device, let t = lock.withLock({ wakeTokens }) else { return }
		let given = lock.withLock { store.one("select v from me where k=?", ["wakeGiven:" + d])?.string("v").flatMap(Double.init) } ?? 0
		guard given < Date().addingTimeInterval(WakeTicket.life / 2).timeIntervalSince1970 else { return }
		let expires = Date().addingTimeInterval(WakeTicket.life)
		guard let ticket = try? WakeTicket.mint(t, expires: expires) else { return }
		post(.wake(ticket, expires.timeIntervalSince1970), to: d, conv: "")
		lock.withLock { store.run("insert or replace into me(k,v) values(?,?)", ["wakeGiven:" + d, String(expires.timeIntervalSince1970)]) }
		trace("wake ticket to \(d.prefix(8)), good for 72 h")
	}

	/// A ticket from one of the devices I know, to wake it when it's asleep.
	func keepWake(_ ticket: Data, expires: Double, from d: DeviceId) {
		guard knows(d), expires > Date().timeIntervalSince1970, ticket.count < 512 else { return }
		lock.withLock { store.run("insert or replace into me(k,v) values(?,?)", ["wake:" + d, ticket.base64EncodedString() + " " + String(expires)]) }
	}

	/// Whether I could wake that device.
	public func canWake(_ d: DeviceId) -> Bool { wakeTicket(for: d) != nil }

	func wakeTicket(for d: DeviceId) -> Data? {
		guard let v = lock.withLock({ store.one("select v from me where k=?", ["wake:" + d])?.string("v") }) else { return nil }
		let parts = v.split(separator: " ")
		guard parts.count == 2, let exp = Double(parts[1]), exp > Date().timeIntervalSince1970 else { return nil }
		return Data(base64Encoded: String(parts[0]))
	}

	/// Ask the relay to wake that device, if I hold a ticket for it; true once Apple has it. A
	/// message wake is asked for at most every 20 s per device, a ring every 10 s: the relay
	/// folds and limits too, this only spares it the asking.
	@discardableResult
	public func wake(_ d: DeviceId, _ kind: WakeKind) async -> Bool {
		guard let ticket = wakeTicket(for: d) else { return false }
		let gap: TimeInterval = kind == .message ? 20 : 10
		let ok = lock.withLock { () -> Bool in
			let key = d + kind.rawValue
			if let last = lastWake[key], Date().timeIntervalSince(last) < gap { return false }
			lastWake[key] = Date()
			return true
		}
		guard ok else { return false }
		var req = URLRequest(url: WakeTicket.relay.appendingPathComponent("v1/wake"))
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "content-type")
		req.timeoutInterval = 10
		req.httpBody = try? JSONSerialization.data(withJSONObject: ["ticket": ticket.base64EncodedString(), "kind": kind.rawValue])
		let code = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
		// Expired, or the phone isn't there any more: forget it, and wait for a fresh one.
		if code == 410 { lock.withLock { store.run("delete from me where k=?", ["wake:" + d]) } }
		trace("wake \(kind.rawValue) for \(d.prefix(8)): \(code)")
		return code == 202
	}
}
