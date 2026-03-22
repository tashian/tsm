import XCTest
@testable import tsmd

final class ModelsTests: XCTestCase {
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testSecretRoundTrip() throws {
        let secret = Secret(
            name: "test_key",
            value: "secret123",
            description: "A test key",
            confirm: false,
            tags: ["test"],
            created: Date(timeIntervalSince1970: 1_000_000),
            updated: nil
        )
        let data = try encoder.encode(secret)
        let decoded = try decoder.decode(Secret.self, from: data)
        XCTAssertEqual(secret, decoded)
    }

    func testVaultDataRoundTrip() throws {
        let vault = VaultData(
            secrets: [
                Secret(name: "k", value: "v", description: "d",
                       confirm: true, tags: [], created: Date(timeIntervalSince1970: 0))
            ],
            config: VaultConfig(ttlHours: 8)
        )
        let data = try encoder.encode(vault)
        let decoded = try decoder.decode(VaultData.self, from: data)
        XCTAssertEqual(vault, decoded)
    }

    func testVaultEnvelopeRoundTrip() throws {
        let envelope = VaultEnvelope(
            version: 1,
            algorithm: "aes-256-gcm",
            recovery: RecoveryParams(salt: "c2FsdA==", iterations: 600_000),
            nonce: "bm9uY2U=",
            ciphertext: "Y2lwaGVy"
        )
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(VaultEnvelope.self, from: data)
        XCTAssertEqual(envelope, decoded)
    }

    func testSecretMetadataFromSecret() {
        let secret = Secret(
            name: "key", value: "val", description: "desc",
            confirm: true, tags: ["a", "b"],
            created: Date()
        )
        let meta = SecretMetadata(from: secret)
        XCTAssertEqual(meta.name, "key")
        XCTAssertEqual(meta.description, "desc")
        XCTAssertTrue(meta.confirm)
        XCTAssertEqual(meta.tags, ["a", "b"])
    }

    func testVaultConfigDefaults() {
        let config = VaultConfig()
        XCTAssertEqual(config.ttlHours, 12)
    }

    func testVaultStatusCodingKeys() throws {
        let status = VaultStatus(locked: false, ttlRemainingSeconds: 3600, secretCount: 5)
        let data = try encoder.encode(status)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"ttl_remaining_seconds\""))
        XCTAssertTrue(json.contains("\"secret_count\""))
    }
}
