import Foundation
import Security

/// A small shared space the app, the widgets and the Share button can all read and write.
///
/// It lives in the iPhone's keychain, in a group only Agenda's own parts can see. (This avoids
/// a separate "App Group" set-up step on Apple's developer website.)
enum SharedVault {
    static let accessGroup: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "AgendaKeychainGroup") as? String
        // In unsigned simulator builds the team prefix is missing; fall back to the app's own keychain.
        guard let value, !value.hasPrefix("."), !value.contains("$(") else { return nil }
        return value
    }()

    private static func baseQuery(service: String, account: String?, useGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if useGroup, let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    @discardableResult
    static func write(_ data: Data, service: String, account: String) -> Bool {
        for useGroup in [true, false] {
            var query = baseQuery(service: service, account: account, useGroup: useGroup)
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { return true }
            if status != errSecMissingEntitlement { return false }
        }
        return false
    }

    static func read(service: String, account: String) -> Data? {
        for useGroup in [true, false] {
            var query = baseQuery(service: service, account: account, useGroup: useGroup)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess { return result as? Data }
            if status != errSecMissingEntitlement { return nil }
        }
        return nil
    }

    /// All items stored under a service, as (account, data) pairs.
    static func readAll(service: String) -> [(String, Data)] {
        for useGroup in [true, false] {
            var query = baseQuery(service: service, account: nil, useGroup: useGroup)
            query[kSecReturnData as String] = true
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let items = result as? [[String: Any]] {
                return items.compactMap { item in
                    guard let account = item[kSecAttrAccount as String] as? String,
                          let data = item[kSecValueData as String] as? Data else { return nil }
                    return (account, data)
                }
            }
            if status != errSecMissingEntitlement { return [] }
        }
        return []
    }

    static func delete(service: String, account: String) {
        for useGroup in [true, false] {
            SecItemDelete(baseQuery(service: service, account: account, useGroup: useGroup) as CFDictionary)
        }
    }
}
