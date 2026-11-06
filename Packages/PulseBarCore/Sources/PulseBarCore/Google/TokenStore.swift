import Foundation
import Security

/// Where secrets live. Real app: macOS Keychain. Tests: in memory.
public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?) throws
}

public enum SecretKey {
    public static let refreshToken = "google.refresh_token"
    public static let clientSecret = "google.client_secret"
}

/// Generic-password items in the login Keychain (spec F3.3: tokens only in the Keychain).
/// Encrypted at rest by macOS; accessible only after the Mac is unlocked, never synced to iCloud.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.pulsebar") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String?) throws {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> String? { lock.withLock { values[key] } }
    public func set(_ key: String, _ value: String?) throws { lock.withLock { values[key] = value } }
}
