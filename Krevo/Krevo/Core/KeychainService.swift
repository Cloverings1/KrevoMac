import Foundation
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

nonisolated enum KeychainService: Sendable {

    // MARK: - Save

    nonisolated static func save(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        // Delete any existing item first
        deleteToken()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KrevoConstants.keychainService,
            kSecAttrAccount as String: KrevoConstants.keychainTokenKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    // MARK: - Load

    nonisolated static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KrevoConstants.keychainService,
            kSecAttrAccount as String: KrevoConstants.keychainTokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    // MARK: - Delete

    nonisolated static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KrevoConstants.keychainService,
            kSecAttrAccount as String: KrevoConstants.keychainTokenKey,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
