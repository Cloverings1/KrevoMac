import Foundation
import os
import Security

nonisolated enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status \(status)"
        case .unexpectedData:
            return "Unexpected data format in Keychain"
        }
    }
}

/// Keychain access is scoped exclusively to the sandboxed data-protection keychain.
/// This keychain is app-specific and never prompts the user — no "allow access"
/// dialogs on first launch, sign-in, or sign-out.
nonisolated enum KeychainService: Sendable {
    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KrevoConstants.keychainService,
            kSecAttrAccount as String: KrevoConstants.keychainTokenKey,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    nonisolated static func save(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        deleteToken()

        var insert = query()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    nonisolated static func loadToken() -> String? {
        var lookup = query()
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                KrevoConstants.authLogger.error("Keychain token decoded to invalid UTF-8")
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            KrevoConstants.authLogger.error("Keychain read failed with status \(status, privacy: .public)")
            return nil
        }
    }

    nonisolated static func deleteToken() {
        let status = SecItemDelete(query() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            KrevoConstants.authLogger.error("Keychain delete failed with status \(status, privacy: .public)")
        }
    }
}
