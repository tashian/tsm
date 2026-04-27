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
            config: VaultConfig(ttlSeconds: 28800)
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

    func testVaultStatusCodingKeys() throws {
        let status = VaultStatus(locked: false, ttlRemainingSeconds: 3600, secretCount: 5)
        let data = try encoder.encode(status)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"ttl_remaining_seconds\""))
        XCTAssertTrue(json.contains("\"secret_count\""))
    }

    func testSecret_DisplayName_RoundTrip() throws {
        let secret = Secret(
            name: "openai-api-key",
            displayName: "OpenAI API key",
            value: "sk-...",
            description: "",
            confirm: false,
            tags: [],
            created: Date(timeIntervalSince1970: 1_700_000_000),
            updated: nil
        )
        let data = try encoder.encode(secret)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"display_name\":\"OpenAI API key\""))
        let decoded = try decoder.decode(Secret.self, from: data)
        XCTAssertEqual(decoded.displayName, "OpenAI API key")
        XCTAssertEqual(decoded.name, "openai-api-key")
    }

    func testSecret_DisplayName_BackwardCompat() throws {
        // A secret JSON written before display_name was added has no such key.
        let oldJSON = #"""
        {"name":"old-secret","value":"v","description":"d","confirm":false,"tags":[],"created":"2025-01-01T00:00:00Z"}
        """#.data(using: .utf8)!
        let s = try decoder.decode(Secret.self, from: oldJSON)
        XCTAssertEqual(s.displayName, "")
        XCTAssertEqual(s.name, "old-secret")
    }

    func testSecretMetadata_CarriesDisplayName() throws {
        let secret = Secret(
            name: "k", displayName: "Kebab Display",
            value: "v", description: "d", confirm: false, tags: [],
            created: Date()
        )
        let meta = SecretMetadata(from: secret)
        XCTAssertEqual(meta.displayName, "Kebab Display")
        let data = try encoder.encode(meta)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"display_name\":\"Kebab Display\""))
    }
}

final class VaultConfigDecodingTests: XCTestCase {
    func testDecodesTTLSeconds() throws {
        let json = #"{"ttl_seconds": 1200}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(VaultConfig.self, from: json)
        XCTAssertEqual(cfg.ttlSeconds, 1200)
    }

    func testDefaultIs1800Seconds() {
        let cfg = VaultConfig()
        XCTAssertEqual(cfg.ttlSeconds, 1800)
    }

    func testIgnoresLegacyTTLHoursField() throws {
        // Old vaults wrote ttl_hours; new code should silently drop it
        // and use the default rather than crashing.
        let json = #"{"ttl_hours": 12}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(VaultConfig.self, from: json)
        XCTAssertEqual(cfg.ttlSeconds, 1800)
    }
}
