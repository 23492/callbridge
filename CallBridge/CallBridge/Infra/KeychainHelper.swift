import Foundation
import Security

// MARK: - Keychain

struct KeychainHelper {
    private static let service = "com.welisa.CallBridge"

    static func save(key: String, value: String) {
        if read(key: key) != nil {
            update(key: key, value: value)
            return
        }
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        debugLog("KeychainHelper: save key=\(key) status=\(status)")
        // read() returns nil for *any* failure (e.g. a denied access prompt), not
        // just "not found" — the item may exist after all, so update it instead.
        if status == errSecDuplicateItem { update(key: key, value: value) }
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        debugLog("KeychainHelper: read key=\(key) status=\(status)")
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func update(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        debugLog("KeychainHelper: update key=\(key) status=\(status)")
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            debugLog("KeychainHelper: delete key=\(key) status=\(status)")
        }
    }

    static func allPresent(keys: [String]) -> Bool {
        return keys.allSatisfy { read(key: $0) != nil }
    }
}
