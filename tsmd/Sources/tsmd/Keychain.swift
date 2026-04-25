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
    let service = "com.tsm.vault"
    let account = "master-key"

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
