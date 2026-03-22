import XCTest
@testable import tsmd

final class CryptoTests: XCTestCase {
    let crypto = AESGCMCrypto()

    func testEncryptDecryptRoundTrip() throws {
        let key = crypto.generateKey()
        XCTAssertEqual(key.count, 32)

        let plaintext = Data("hello, vault!".utf8)
        let (nonce, ciphertext) = try crypto.encrypt(data: plaintext, key: key)

        XCTAssertEqual(nonce.count, 12)
        XCTAssertNotEqual(ciphertext, plaintext)

        let decrypted = try crypto.decrypt(ciphertext: ciphertext, key: key, nonce: nonce)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptWithWrongKeyFails() throws {
        let key1 = crypto.generateKey()
        let key2 = crypto.generateKey()
        let plaintext = Data("secret".utf8)
        let (nonce, ciphertext) = try crypto.encrypt(data: plaintext, key: key1)

        XCTAssertThrowsError(try crypto.decrypt(ciphertext: ciphertext, key: key2, nonce: nonce))
    }

    func testDecryptWithTruncatedCiphertextFails() throws {
        let key = crypto.generateKey()
        // Ciphertext shorter than GCM tag (16 bytes) should fail
        let shortData = Data(repeating: 0xAB, count: 10)
        XCTAssertThrowsError(try crypto.decrypt(ciphertext: shortData, key: key, nonce: Data(repeating: 0, count: 12)))
    }

    func testEmptyDataRoundTrip() throws {
        let key = crypto.generateKey()
        let (nonce, ciphertext) = try crypto.encrypt(data: Data(), key: key)
        let decrypted = try crypto.decrypt(ciphertext: ciphertext, key: key, nonce: nonce)
        XCTAssertEqual(decrypted, Data())
    }

    func testLargeDataRoundTrip() throws {
        let key = crypto.generateKey()
        let plaintext = Data(repeating: 0xAB, count: 1_000_000)
        let (nonce, ciphertext) = try crypto.encrypt(data: plaintext, key: key)
        let decrypted = try crypto.decrypt(ciphertext: ciphertext, key: key, nonce: nonce)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testPBKDF2DeriveKey() throws {
        let salt = Data(repeating: 0x42, count: 32)
        let key = try crypto.deriveKey(passphrase: "my-recovery-passphrase", salt: salt, iterations: 1000)
        XCTAssertEqual(key.count, 32)

        // Same inputs produce same key
        let key2 = try crypto.deriveKey(passphrase: "my-recovery-passphrase", salt: salt, iterations: 1000)
        XCTAssertEqual(key, key2)

        // Different passphrase produces different key
        let key3 = try crypto.deriveKey(passphrase: "different-passphrase", salt: salt, iterations: 1000)
        XCTAssertNotEqual(key, key3)
    }

    func testAlgorithmIdentifier() {
        XCTAssertEqual(crypto.algorithm, "aes-256-gcm")
    }

    func testGenerateKeyRandomness() {
        let key1 = crypto.generateKey()
        let key2 = crypto.generateKey()
        XCTAssertNotEqual(key1, key2)
    }
}
