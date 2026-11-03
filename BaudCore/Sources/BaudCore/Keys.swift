/// The keychain seam the crate takes (`Baud.open(dir, keys)`): `user-key`, `device-key`,
/// `olm-account` under service `sh.rubric.baud`. The stub keeps random 32-byte secrets there
/// so the real core finds its seeds where it expects them; tests use `MemoryKeys`.
import Foundation
import Security

public protocol Keys: AnyObject, Sendable {
	func get(_ item: String) -> Data?
	func put(_ item: String, _ bytes: Data)
	func delete(_ item: String)
	/// The keys are there but can't be read yet (an iPhone not unlocked since it restarted): a
	/// missing key now means "wait", never "make a new one".
	var locked: Bool { get }
}
public extension Keys { var locked: Bool { false } }

/// The keychain can't be read yet; the store waits rather than making a new identity.
public struct KeysLocked: Error {}

public final class MemoryKeys: Keys, @unchecked Sendable {
	private var d: [String: Data] = [:]
	private let lock = NSLock()
	public init() {}
	public func get(_ item: String) -> Data? { lock.withLock { d[item] } }
	public func put(_ item: String, _ bytes: Data) { lock.withLock { d[item] = bytes } }
	public func delete(_ item: String) { lock.withLock { _ = d.removeValue(forKey: item) } }
}

/// The data-protection keychain on both platforms (no legacy-keychain prompts on the Mac). A build
/// signed without a team can't use it; then the secrets sit in `<dir>/keys`, mode 0600, and the
/// Settings screen says so.
public final class AppleKeychain: Keys, @unchecked Sendable {
	/// The keychain service; a dev build appends ".dev" so it never shares items with the shipped app.
	nonisolated(unsafe) public static var service = "sh.rubric.baud"
	let fallback: URL
	public private(set) var usingFile = false
	/// `fileOnly`: the secrets go straight to the file, never the keychain (lab copies, each its own).
	let fileOnly: Bool
	public init(fallbackDir: URL, fileOnly: Bool = false) { fallback = fallbackDir.appendingPathComponent("keys"); self.fileOnly = fileOnly; usingFile = fileOnly }
	/// The last read found the keychain locked (before the first unlock after a restart).
	public private(set) var locked = false
	private func q(_ item: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: item, kSecUseDataProtectionKeychain as String: true]
	}
	public func get(_ item: String) -> Data? {
		if fileOnly { return try? Data(contentsOf: fallback.appendingPathComponent(item)) }
		var query = q(item); query[kSecReturnData as String] = true
		var out: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &out)
		if status == errSecSuccess { locked = false; return out as? Data }
		// Locked, not missing: nothing is read from the file and nothing new is written in its place.
		if status == errSecInteractionNotAllowed { locked = true; return nil }
		if status == errSecMissingEntitlement { usingFile = true }
		// Not in the keychain: a build that fell back to the file last time still has it there.
		if let d = try? Data(contentsOf: fallback.appendingPathComponent(item)) { usingFile = true; return d }
		return nil
	}
	public func put(_ item: String, _ bytes: Data) {
		if locked { return }
		if !usingFile {
			SecItemDelete(q(item) as CFDictionary)
			var add = q(item)
			add[kSecValueData as String] = bytes
			add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return }
			usingFile = true
		}
		try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		// File protection is an iPhone thing: on the Mac the write with it fails, and nothing was kept.
		do { try bytes.write(to: fallback.appendingPathComponent(item), options: .completeFileProtection) }
		catch { try? bytes.write(to: fallback.appendingPathComponent(item), options: .atomic) }
		try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallback.appendingPathComponent(item).path)
	}
	/// Every item of this app's service, and the fallback files: starting over.
	public func wipe() {
		if fileOnly { try? FileManager.default.removeItem(at: fallback); return }
		SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecUseDataProtectionKeychain as String: true] as CFDictionary)
		SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service] as CFDictionary)
	}
	public func delete(_ item: String) { if !fileOnly { SecItemDelete(q(item) as CFDictionary) }; try? FileManager.default.removeItem(at: fallback.appendingPathComponent(item)) }
}

func randomBytes(_ n: Int) -> Data {
	var d = Data(count: n)
	_ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
	return d
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// A stable id from a string: 32 hex chars of a cheap hash. The crate's BLAKE3 ids replace it.
func stableId(_ s: String) -> String {
	var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
	for b in s.utf8 { h1 = (h1 ^ UInt64(b)) &* 0x100000001b3; h2 = (h2 &+ UInt64(b)) &* 0x9E3779B97F4A7C15 }
	return String(format: "%016llx%016llx", h1, h2)
}

/// 60 digits from a user key, in groups of five, the way the safety number is shown.
func fingerprint(_ user: UserId) -> String {
	var digits = ""
	var x = user.utf8.reduce(UInt64(0x9E3779B97F4A7C15)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
	while digits.count < 60 { x = x &* 6364136223846793005 &+ 1442695040888963407; digits += String(format: "%05llu", (x >> 33) % 100_000) }
	return stride(from: 0, to: 60, by: 5).map { i in let s = digits.index(digits.startIndex, offsetBy: i); return String(digits[s..<digits.index(s, offsetBy: 5)]) }.joined(separator: " ")
}
