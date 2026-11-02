import Foundation
import Security

/// The keychain the crate asks for its three items. Stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background wakeups can open the node.
/// Each app passes its own access group (`J43C4UHCR4.<bundle id>`); never a shared one.
public final class AppleKeychain: Keychain {
    let service: String
    let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ item: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item,
        ]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    public func get(item: String) throws -> Data? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PeerError.Failed(message: "keychain get \(status)") }
        return out as? Data
    }

    public func put(item: String, bytes: Data) throws {
        try? delete(item: item)
        var q = query(item)
        q[kSecValueData as String] = bytes
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw PeerError.Failed(message: "keychain put \(status)") }
    }

    public func delete(item: String) throws {
        let status = SecItemDelete(query(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PeerError.Failed(message: "keychain delete \(status)") }
    }
}

/// For tests and previews: nothing leaves the process.
public final class MemoryKeychain: Keychain {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(item: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[item] }
    public func put(item: String, bytes: Data) throws { lock.lock(); defer { lock.unlock() }; items[item] = bytes }
    public func delete(item: String) throws { lock.lock(); defer { lock.unlock() }; items[item] = nil }
}
