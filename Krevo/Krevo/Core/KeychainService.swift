import Foundation
import LocalAuthentication
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

nonisolated enum KeychainService: Sendable {
    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KrevoConstants.keychainService,
            kSecAttrAccount as String: KrevoConstants.keychainTokenKey,
        ]
    }

    private static func dataProtectionQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private static func legacyQuery(disallowInteraction: Bool) -> [String: Any] {
        var query = baseQuery()
        if disallowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }

    // MARK: - Save

    nonisolated static func save(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        deleteToken()

        var query = dataProtectionQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    // MARK: - Load

    nonisolated static func loadToken() -> String? {
        if let token = readToken(matching: dataProtectionQuery(), label: "data-protection") {
            return token
        }

        guard let legacyToken = readToken(
            matching: legacyQuery(disallowInteraction: true),
            label: "legacy",
            suppressInteractionLogs: false
        ) else {
            return nil
        }

        migrateLegacyTokenIfNeeded(legacyToken)
        return legacyToken
    }

    // MARK: - Delete

    nonisolated static func deleteToken() {
        deleteToken(matching: dataProtectionQuery(), label: "data-protection")
        deleteToken(matching: legacyQuery(disallowInteraction: true), label: "legacy")
    }

    private static func readToken(
        matching query: [String: Any],
        label: String,
        suppressInteractionLogs: Bool = true
    ) -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                KrevoConstants.authLogger.error("Keychain token decode failed for \(label, privacy: .public)")
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed:
            if !suppressInteractionLogs {
                KrevoConstants.authLogger.notice(
                    "Skipping \(label, privacy: .public) keychain token because it requires user interaction"
                )
            }
            return nil
        default:
            KrevoConstants.authLogger.error(
                "Keychain read failed for \(label, privacy: .public) with status \(status, privacy: .public)"
            )
            return nil
        }
    }

    private static func migrateLegacyTokenIfNeeded(_ token: String) {
        do {
            var query = dataProtectionQuery()
            query[kSecValueData as String] = Data(token.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            deleteToken(matching: dataProtectionQuery(), label: "data-protection")

            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.saveFailed(status)
            }

            deleteToken(matching: legacyQuery(disallowInteraction: true), label: "legacy")
            KrevoConstants.authLogger.info("Migrated stored session token to data-protection keychain")
        } catch {
            KrevoConstants.authLogger.error("Keychain migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func deleteToken(matching query: [String: Any], label: String) {
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound, errSecInteractionNotAllowed:
            return
        default:
            KrevoConstants.authLogger.error(
                "Keychain delete failed for \(label, privacy: .public) with status \(status, privacy: .public)"
            )
        }
    }
}
