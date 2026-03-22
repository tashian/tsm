import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Errors

enum CryptoError: Error, Equatable {
    case encryptionFailed(String)
    case decryptionFailed(String)
    case keyDerivationFailed
}

// MARK: - Protocol

protocol CryptoProvider: Sendable {
    func encrypt(data: Data, key: Data) throws -> (nonce: Data, ciphertext: Data)
    func decrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data
    func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data
    func generateKey() -> Data
    var algorithm: String { get }
}

// MARK: - AES-256-GCM implementation

struct AESGCMCrypto: CryptoProvider {
    let algorithm = "aes-256-gcm"

    func encrypt(data: Data, key: Data) throws -> (nonce: Data, ciphertext: Data) {
        let symmetricKey = SymmetricKey(data: key)
        do {
            let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
            // sealedBox.nonce is 12 bytes, sealedBox.ciphertext + sealedBox.tag
            let nonceData = Data(sealedBox.nonce)
            let ciphertextAndTag = sealedBox.ciphertext + sealedBox.tag
            return (nonce: nonceData, ciphertext: ciphertextAndTag)
        } catch {
            throw CryptoError.encryptionFailed("AES-GCM seal failed: \(error)")
        }
    }

    func decrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        // ciphertext is actually ciphertext + tag (16 bytes)
        let tagSize = 16
        guard ciphertext.count >= tagSize else {
            throw CryptoError.decryptionFailed("Ciphertext too short")
        }
        let ct = ciphertext.prefix(ciphertext.count - tagSize)
        let tag = ciphertext.suffix(tagSize)
        do {
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ct, tag: tag)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.decryptionFailed("AES-GCM open failed: \(error)")
        }
    }

    func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data {
        let passphraseData = Data(passphrase.utf8)
        var derivedKey = Data(count: 32)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            passphraseData.withUnsafeBytes { passphrasePtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphrasePtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passphraseData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }
        return derivedKey
    }

    func generateKey() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }
}
