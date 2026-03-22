/// Shared mock implementations for testing.
/// Used by VaultTests, JSONRPCHandlerTests, SocketServerTests, and IntegrationTests.

import Foundation
@testable import tsmd

final class MockCrypto: CryptoProvider, @unchecked Sendable {
    let algorithm = "mock"

    func encrypt(data: Data, key: Data) throws -> (nonce: Data, ciphertext: Data) {
        let nonce = Data(repeating: 0xAA, count: 12)
        var ciphertext = data
        for i in 0..<ciphertext.count {
            ciphertext[i] ^= key[i % key.count]
        }
        // Append a fake 16-byte tag so decrypt can split it
        let tag = Data(repeating: 0xBB, count: 16)
        return (nonce, ciphertext + tag)
    }

    func decrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        // Strip the 16-byte fake tag
        let tagSize = 16
        guard ciphertext.count >= tagSize else {
            throw CryptoError.decryptionFailed("Too short")
        }
        var plaintext = Data(ciphertext.prefix(ciphertext.count - tagSize))
        for i in 0..<plaintext.count {
            plaintext[i] ^= key[i % key.count]
        }
        return plaintext
    }

    func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data {
        var result = Data(count: 32)
        let input = Data(passphrase.utf8) + salt
        for i in 0..<32 {
            result[i] = input[i % input.count]
        }
        return result
    }

    func generateKey() -> Data { Data(repeating: 0x42, count: 32) }
}

final class MockKeychain: KeychainProvider, @unchecked Sendable {
    var storedKey: Data?
    var shouldFail = false

    func storeMasterKey(_ key: Data) throws {
        if shouldFail { throw VaultError.authFailed }
        storedKey = key
    }
    func retrieveMasterKey() throws -> Data {
        guard let key = storedKey else { throw VaultError.authFailed }
        return key
    }
    func deleteMasterKey() throws { storedKey = nil }
}

final class MockAuth: AuthProvider, @unchecked Sendable {
    var shouldFail = false
    var authenticateCalled = false

    func authenticate(reason: String) async throws {
        authenticateCalled = true
        if shouldFail { throw VaultError.authFailed }
    }
}

final class MockVaultStore: VaultStoreProvider, @unchecked Sendable {
    var envelope: VaultEnvelope?

    func exists() -> Bool { envelope != nil }
    func read() throws -> VaultEnvelope {
        guard let e = envelope else { throw VaultError.notInitialized }
        return e
    }
    func write(_ envelope: VaultEnvelope) throws { self.envelope = envelope }
    func delete() throws { envelope = nil }
}

final class MockAccessLog: AccessLogProvider, @unchecked Sendable {
    var entries: [(method: String, secret: String?, clientId: String?, result: String)] = []
    func log(method: String, secret: String?, clientId: String?, result: String) throws {
        entries.append((method, secret, clientId, result))
    }
}
