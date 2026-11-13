// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Stores credentials in the current macOS user's Keychain. No password is stored in UserDefaults or a sync file.
public enum WebDAVPassword {
    private static let service = "org.tokenmoon.desktop.WebDAV"

    public static func read(url: URL, username: String) throws -> String? {
        var query = key(url: url, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// File-based macOS Keychain lookups can otherwise wait on an authorization
    /// dialog even before the app opens a window.
    public static func withoutUserInteraction<T>(_ action: () throws -> T) throws -> T {
        var wasAllowed: DarwinBoolean = false
        try check(SecKeychainGetUserInteractionAllowed(&wasAllowed))
        if wasAllowed.boolValue { try check(SecKeychainSetUserInteractionAllowed(false)) }
        defer { if wasAllowed.boolValue { _ = SecKeychainSetUserInteractionAllowed(true) } }
        return try action()
    }

    /// An empty value removes credentials for this exact endpoint and username.
    public static func save(_ password: String, url: URL, username: String) throws {
        let query = key(url: url, username: username)
        if password.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let values = [kSecValueData as String: Data(password.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated != errSecItemNotFound { return try check(updated) }
        var entry = query
        entry[kSecValueData as String] = values[kSecValueData as String]
        try check(SecItemAdd(entry as CFDictionary, nil))
    }

    private static func key(url: URL, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: url.absoluteString + "\n" + username,
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    private struct KeychainFailure: LocalizedError {
        let status: OSStatus

        var errorDescription: String? { "无法访问 macOS 钥匙串（\(status)）。" }
    }
}
