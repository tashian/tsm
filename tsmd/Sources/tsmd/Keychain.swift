import CryptoKit
import Foundation
import Security

enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case notFound
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Keychain store failed: \(secErrorMessage(status)) (OSStatus \(status))"
        case .retrieveFailed(let status):
            return "Keychain retrieve failed: \(secErrorMessage(status)) (OSStatus \(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed: \(secErrorMessage(status)) (OSStatus \(status))"
        case .notFound:
            return "Keychain item not found"
        case .unexpectedData:
            return "Keychain returned unexpected data type"
        }
    }
}

private func secErrorMessage(_ status: OSStatus) -> String {
    if let cfMsg = SecCopyErrorMessageString(status, nil) {
        return cfMsg as String
    }
    return "unknown error"
}

struct MacKeychain: KeychainProvider, Sendable {
    static let legacyAccount = "master-key"

    let service = "com.tsm.vault"
    /// Keychain account for this vault's master key.
    ///
    /// The default vault path keeps the legacy fixed account so existing
    /// installs are untouched. Any other path (e.g. a temp vault selected via
    /// `XDG_DATA_HOME`) gets an account derived from the path, so initializing
    /// a secondary vault can't overwrite the primary vault's key.
    let account: String

    init(vaultPath: URL = Paths.vaultFile) {
        self.account = Self.account(forVaultPath: vaultPath)
    }

    static func account(forVaultPath path: URL) -> String {
        let resolved = path.standardizedFileURL.path
        if resolved == Paths.defaultVaultFile.standardizedFileURL.path {
            return legacyAccount
        }
        let digest = SHA256.hash(data: Data(resolved.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(legacyAccount):\(hex)"
    }

    func storeMasterKey(_ key: Data) throws {
        try? deleteMasterKey()

        // Note: Touch ID is enforced by the Auth layer (LAContext) before any
        // sensitive operation. We do not gate the Keychain item itself with
        // `.biometryCurrentSet` because that requires the restricted
        // `keychain-access-groups` entitlement, which in turn requires
        // Developer ID signing or an Xcode-managed provisioning profile.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    func retrieveMasterKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.notFound
            }
            throw KeychainError.retrieveFailed(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }
        return data
    }

    func deleteMasterKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
