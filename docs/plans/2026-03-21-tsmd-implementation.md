# tsmd (Swift Daemon) Implementation Plan — Plan 1 of 3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Swift daemon (`tsmd`) that manages encrypted vault state, authenticates via Touch ID, and serves JSON-RPC 2.0 requests over a Unix domain socket.

**Architecture:** `tsmd` is an `actor`-based Swift daemon. An async socket server accepts connections and dispatches JSON-RPC methods to a `Vault` actor that holds decrypted secrets in memory. All crypto, Keychain, and Touch ID access happens inside the daemon process. External components (the Go CLI, MCP servers) never touch secrets directly — they talk JSON-RPC over a Unix socket.

**Tech Stack:** Swift 6+, Apple CryptoKit (AES-256-GCM), Security framework (Keychain), LocalAuthentication (Touch ID), Foundation (I/O, JSON), XCTest. Zero third-party dependencies.

**Spec:** `docs/plans/2026-03-08-tsm-design.md`

---

## File Structure

```
tsmd/
├── Package.swift
├── Sources/
│   └── tsmd/
│       ├── main.swift                 # Entry point: parse args, launch daemon
│       ├── Daemon.swift               # Lifecycle: start socket, TTL timer, signal handling
│       ├── SocketServer.swift         # Unix socket listener, connection read/write
│       ├── JSONRPCTypes.swift         # JSONValue, Request, Response, Error types
│       ├── JSONRPCHandler.swift       # Method name → Vault method dispatch
│       ├── Models.swift               # Secret, VaultData, VaultEnvelope, VaultConfig
│       ├── Vault.swift                # Actor: in-memory state, CRUD, lock/unlock, TTL, confirm
│       ├── VaultStore.swift           # Read/write encrypted vault.enc file
│       ├── Crypto.swift               # Protocol + AES-256-GCM impl, PBKDF2 derivation
│       ├── Keychain.swift             # Protocol + Keychain impl (master key, biometric ACL)
│       ├── Auth.swift                 # Protocol + Touch ID impl via LocalAuthentication
│       ├── AccessLog.swift            # Append-only JSON log, rotation at 10 MB
│       └── Paths.swift                # XDG path resolution, socket/vault/config/log paths
└── Tests/
    └── tsmdTests/
        ├── JSONRPCTypesTests.swift
        ├── CryptoTests.swift
        ├── ModelsTests.swift
        ├── VaultTests.swift
        ├── VaultStoreTests.swift
        ├── AccessLogTests.swift
        ├── JSONRPCHandlerTests.swift
        ├── SocketServerTests.swift
        └── IntegrationTests.swift
```

### Key Design Decisions

**Protocols for testability.** Keychain, Auth, Crypto, VaultStore, and AccessLog are protocol-first. Tests inject mocks; production wires real implementations. The `Vault` actor depends only on protocols, never concrete types.

**`Vault` is a Swift actor.** Multiple socket connections access vault state concurrently. The actor model gives thread safety without manual locking.

**Newline-delimited JSON framing.** Each JSON-RPC message is a single line terminated by `\n`. Reader buffers until newline, enforces 1 MB max. Simple and correct.

**POSIX sockets + DispatchSource.** The listen socket uses `DispatchSource.makeReadSource` to accept connections without blocking. Each connection spawns a `Task` for async handling. Zero dependencies.

**`vault.init` method.** Not in the spec's method list but implied — the daemon must handle init because only it has Keychain/Touch ID access. The Go CLI will send `vault.init` during `tsm init`.

---

## Task 1: Swift Package Scaffold + Data Models + Paths

**Files:**
- Create: `tsmd/Package.swift`
- Create: `tsmd/Sources/tsmd/Models.swift`
- Create: `tsmd/Sources/tsmd/Paths.swift`
- Create: `tsmd/Sources/tsmd/main.swift` (placeholder)
- Test: `tsmd/Tests/tsmdTests/ModelsTests.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tsmd",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tsmd",
            path: "Sources/tsmd"
        ),
        .testTarget(
            name: "tsmdTests",
            dependencies: ["tsmd"],
            path: "Tests/tsmdTests"
        ),
    ]
)
```

- [ ] **Step 2: Create Models.swift with all data types**

```swift
import Foundation

struct Secret: Codable, Equatable {
    let name: String
    var value: String
    var description: String
    var confirm: Bool
    var tags: [String]
    let created: Date
    var updated: Date?
}

struct SecretMetadata: Codable, Equatable {
    let name: String
    let description: String
    let confirm: Bool
    let tags: [String]

    init(from secret: Secret) {
        self.name = secret.name
        self.description = secret.description
        self.confirm = secret.confirm
        self.tags = secret.tags
    }
}

struct VaultData: Codable, Equatable {
    var version: Int = 1
    var secrets: [Secret]
    var config: VaultConfig

    init(secrets: [Secret] = [], config: VaultConfig = VaultConfig()) {
        self.secrets = secrets
        self.config = config
    }
}

struct VaultConfig: Codable, Equatable {
    var ttlHours: Int = 12

    enum CodingKeys: String, CodingKey {
        case ttlHours = "ttl_hours"
    }
}

struct VaultEnvelope: Codable, Equatable {
    let version: Int
    let algorithm: String
    let recovery: RecoveryParams?
    let nonce: String   // base64
    let ciphertext: String  // base64
}

struct RecoveryParams: Codable, Equatable {
    let salt: String  // base64
    let iterations: Int
}

struct VaultStatus: Codable, Equatable {
    let locked: Bool
    let ttlRemainingSeconds: Int?
    let secretCount: Int

    enum CodingKeys: String, CodingKey {
        case locked
        case ttlRemainingSeconds = "ttl_remaining_seconds"
        case secretCount = "secret_count"
    }
}

struct DaemonCapabilities: Codable, Equatable {
    let protocolVersion: Int
    let authBackends: [String]
    let features: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case authBackends = "auth_backends"
        case features
    }
}
```

- [ ] **Step 3: Create Paths.swift**

```swift
import Foundation

enum Paths {
    static var configDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            return URL(fileURLWithPath: xdg).appendingPathComponent("tsm")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tsm")
    }

    static var dataDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
            return URL(fileURLWithPath: xdg).appendingPathComponent("tsm")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/tsm")
    }

    static var socketPath: String {
        if let sock = ProcessInfo.processInfo.environment["TSM_AUTH_SOCK"] {
            return sock
        }
        let runtimeDir: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] {
            runtimeDir = xdg
        } else if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] {
            runtimeDir = tmpdir
        } else {
            runtimeDir = NSTemporaryDirectory()
        }
        return (runtimeDir as NSString).appendingPathComponent("tsm/vault.sock")
    }

    static var vaultFile: URL { dataDir.appendingPathComponent("vault.enc") }
    static var accessLog: URL { dataDir.appendingPathComponent("access.log") }
    static var configFile: URL { configDir.appendingPathComponent("config.json") }
}
```

- [ ] **Step 4: Create placeholder main.swift**

```swift
import Foundation

// Placeholder — replaced in Task 10
print("tsmd: not yet implemented")
Foundation.exit(0)
```

- [ ] **Step 5: Write model serialization tests**

```swift
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
```

- [ ] **Step 6: Verify the package builds and tests pass**

Run: `cd tsmd && swift build 2>&1 | tail -5`
Expected: Build Succeeded

Run: `cd tsmd && swift test 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 7: Commit**

```bash
git add tsmd/
git commit -m "feat(tsmd): scaffold Swift package with data models and XDG paths"
```

---

## Task 2: JSON-RPC Types

**Files:**
- Create: `tsmd/Sources/tsmd/JSONRPCTypes.swift`
- Test: `tsmd/Tests/tsmdTests/JSONRPCTypesTests.swift`

- [ ] **Step 1: Implement JSONValue enum**

A dynamic JSON type for params/results. Supports Codable for automatic serialization:

```swift
import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    // Convenience accessors
    var stringValue: String? {
        if case .string(let v) = self { return v } else { return nil }
    }
    var intValue: Int? {
        if case .int(let v) = self { return v } else { return nil }
    }
    var boolValue: Bool? {
        if case .bool(let v) = self { return v } else { return nil }
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v } else { return nil }
    }
}
```

- [ ] **Step 2: Implement JSON-RPC Request, Response, Error types**

```swift
struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: [String: JSONValue]?
    let id: JSONValue

    func param(_ key: String) -> JSONValue? {
        params?[key]
    }
    func stringParam(_ key: String) -> String? {
        params?[key]?.stringValue
    }
}

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let result: JSONValue?
    let error: JSONRPCError?
    let id: JSONValue

    init(result: JSONValue, id: JSONValue) {
        self.jsonrpc = "2.0"
        self.result = result
        self.error = nil
        self.id = id
    }

    init(error: JSONRPCError, id: JSONValue) {
        self.jsonrpc = "2.0"
        self.result = nil
        self.error = error
        self.id = id
    }
}

struct JSONRPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: [String: JSONValue]?

    init(code: Int, message: String, data: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// Standard JSON-RPC error codes
enum RPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    // tsm-specific
    static let vaultLocked = -32001
    static let authRequired = -32002
    static let secretNotFound = -32003
}
```

- [ ] **Step 3: Write JSON-RPC type tests**

```swift
import XCTest
@testable import tsmd

final class JSONRPCTypesTests: XCTestCase {
    let decoder = JSONDecoder()
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    func testParseRequest() throws {
        let json = """
        {"jsonrpc":"2.0","method":"vault.get","params":{"name":"test_key"},"id":1}
        """.data(using: .utf8)!
        let req = try decoder.decode(JSONRPCRequest.self, from: json)
        XCTAssertEqual(req.method, "vault.get")
        XCTAssertEqual(req.stringParam("name"), "test_key")
        XCTAssertEqual(req.id, .int(1))
    }

    func testParseRequestWithStringId() throws {
        let json = """
        {"jsonrpc":"2.0","method":"vault.list","id":"abc"}
        """.data(using: .utf8)!
        let req = try decoder.decode(JSONRPCRequest.self, from: json)
        XCTAssertEqual(req.id, .string("abc"))
        XCTAssertNil(req.params)
    }

    func testSerializeSuccessResponse() throws {
        let resp = JSONRPCResponse(
            result: .object(["name": .string("key"), "value": .string("val")]),
            id: .int(1)
        )
        let data = try encoder.encode(resp)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"result\""))
        XCTAssertFalse(json.contains("\"error\""))
    }

    func testSerializeErrorResponse() throws {
        let resp = JSONRPCResponse(
            error: JSONRPCError(
                code: RPCErrorCode.vaultLocked,
                message: "Vault is locked",
                data: ["auth_method": .string("touchid")]
            ),
            id: .int(1)
        )
        let data = try encoder.encode(resp)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("-32001"))
        XCTAssertTrue(json.contains("touchid"))
    }

    func testJSONValueRoundTrip() throws {
        let values: [JSONValue] = [
            .string("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null,
            .array([.int(1), .string("two")]),
            .object(["key": .string("value")])
        ]
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(JSONValue.self, from: data)
            XCTAssertEqual(value, decoded)
        }
    }

    func testConvenienceAccessors() {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.int(1).stringValue)
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
    }

    func testErrorCodes() {
        XCTAssertEqual(RPCErrorCode.vaultLocked, -32001)
        XCTAssertEqual(RPCErrorCode.authRequired, -32002)
        XCTAssertEqual(RPCErrorCode.secretNotFound, -32003)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tsmd && swift test --filter JSONRPCTypesTests 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git add tsmd/Sources/tsmd/JSONRPCTypes.swift tsmd/Tests/tsmdTests/JSONRPCTypesTests.swift
git commit -m "feat(tsmd): add JSON-RPC 2.0 types with JSONValue dynamic type"
```

---

## Task 3: Crypto Module

**Files:**
- Create: `tsmd/Sources/tsmd/Crypto.swift`
- Test: `tsmd/Tests/tsmdTests/CryptoTests.swift`

- [ ] **Step 1: Define the CryptoProvider protocol**

```swift
import Foundation

enum CryptoError: Error, Equatable {
    case encryptionFailed(String)
    case decryptionFailed(String)
    case keyDerivationFailed
}

protocol CryptoProvider: Sendable {
    /// Encrypt plaintext data with a 256-bit key. Returns (nonce, ciphertext) as raw Data.
    func encrypt(data: Data, key: Data) throws -> (nonce: Data, ciphertext: Data)

    /// Decrypt ciphertext with a 256-bit key and nonce. Returns plaintext Data.
    func decrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data

    /// Derive a 256-bit key from a passphrase using PBKDF2-HMAC-SHA256.
    func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data

    /// Generate a random 256-bit (32-byte) key.
    func generateKey() -> Data

    /// Algorithm identifier for the vault envelope.
    var algorithm: String { get }
}
```

- [ ] **Step 2: Implement AES-256-GCM crypto using CryptoKit**

```swift
import CryptoKit

struct AESGCMCrypto: CryptoProvider {
    let algorithm = "aes-256-gcm"

    func encrypt(data: Data, key: Data) throws -> (nonce: Data, ciphertext: Data) {
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        guard let sealedBox = try? AES.GCM.seal(data, using: symmetricKey, nonce: nonce) else {
            throw CryptoError.encryptionFailed("AES-GCM seal failed")
        }
        // combined = nonce + ciphertext + tag, but we store nonce separately
        // sealedBox.ciphertext is ciphertext + tag
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed("Failed to get combined representation")
        }
        // Extract just ciphertext+tag (skip the 12-byte nonce prefix in combined)
        let ciphertextAndTag = Data(combined.dropFirst(12))
        return (nonce: Data(nonce), ciphertext: ciphertextAndTag)
    }

    func decrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else {
            throw CryptoError.decryptionFailed("Invalid nonce")
        }
        // Reconstruct combined: nonce + ciphertext + tag
        let combined = Data(nonce) + ciphertext
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(sealedBox, using: symmetricKey) else {
            throw CryptoError.decryptionFailed("AES-GCM open failed — wrong key or corrupted data")
        }
        return plaintext
    }

    func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data {
        // PBKDF2-HMAC-SHA256 via CommonCrypto
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
        return Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }
}
```

Note: Add `import CommonCrypto` at the top of the file for PBKDF2. If CommonCrypto is not directly importable, use `import Darwin` or create a shim header. In practice, on macOS, `import CommonCrypto` works in Swift packages targeting macOS.

If `import CommonCrypto` fails, add a system library target to Package.swift:

```swift
// In Package.swift targets array, add:
.systemLibrary(name: "CCommonCrypto", path: "Sources/CCommonCrypto")

// Then create: Sources/CCommonCrypto/module.modulemap
// module CCommonCrypto {
//     header "/usr/include/CommonCrypto/CommonCrypto.h"
//     export *
// }
```

And change the import to `import CCommonCrypto`.

- [ ] **Step 3: Write crypto tests**

```swift
import XCTest
@testable import tsmd

final class CryptoTests: XCTestCase {
    let crypto = AESGCMCrypto()

    func testEncryptDecryptRoundTrip() throws {
        let key = crypto.generateKey()
        XCTAssertEqual(key.count, 32)

        let plaintext = Data("hello, vault!".utf8)
        let (nonce, ciphertext) = try crypto.encrypt(data: plaintext, key: key)

        XCTAssertEqual(nonce.count, 12) // AES-GCM nonce is 12 bytes
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

    func testDecryptWithCorruptedCiphertextFails() throws {
        let key = crypto.generateKey()
        let (nonce, ciphertext) = try crypto.encrypt(data: Data("test".utf8), key: key)
        var corrupted = ciphertext
        corrupted[0] ^= 0xFF
        XCTAssertThrowsError(try crypto.decrypt(ciphertext: corrupted, key: key, nonce: nonce))
    }

    func testEmptyDataRoundTrip() throws {
        let key = crypto.generateKey()
        let (nonce, ciphertext) = try crypto.encrypt(data: Data(), key: key)
        let decrypted = try crypto.decrypt(ciphertext: ciphertext, key: key, nonce: nonce)
        XCTAssertEqual(decrypted, Data())
    }

    func testLargeDataRoundTrip() throws {
        let key = crypto.generateKey()
        let plaintext = Data(repeating: 0xAB, count: 1_000_000) // 1 MB
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
        XCTAssertNotEqual(key1, key2) // Astronomically unlikely to be equal
    }
}
```

- [ ] **Step 4: Build and run tests**

Run: `cd tsmd && swift test --filter CryptoTests 2>&1 | tail -15`
Expected: All tests passed

If `import CommonCrypto` fails, implement the shim header workaround described in Step 2 and rebuild.

- [ ] **Step 5: Commit**

```bash
git add tsmd/Sources/tsmd/Crypto.swift tsmd/Tests/tsmdTests/CryptoTests.swift
git commit -m "feat(tsmd): add AES-256-GCM encryption and PBKDF2 key derivation"
```

---

## Task 4: Vault Actor (In-Memory State + CRUD)

**Files:**
- Create: `tsmd/Sources/tsmd/Vault.swift`
- Test: `tsmd/Tests/tsmdTests/VaultTests.swift`

The Vault actor holds decrypted secrets in memory and implements all business logic: CRUD, lock/unlock, TTL expiry, and confirm checks. It depends on protocols for crypto, keychain, auth, file I/O, and logging — all injected at init.

- [ ] **Step 1: Define dependency protocols and Vault errors**

Add to `Vault.swift`:

```swift
import Foundation

enum VaultError: Error, Equatable {
    case locked
    case notInitialized
    case alreadyInitialized
    case secretNotFound(String)
    case secretAlreadyExists(String)
    case authRequired
    case authFailed
    case invalidName(String)
}

protocol KeychainProvider: Sendable {
    func storeMasterKey(_ key: Data) throws
    func retrieveMasterKey() throws -> Data
    func deleteMasterKey() throws
}

protocol AuthProvider: Sendable {
    func authenticate(reason: String) async throws
}

protocol VaultStoreProvider: Sendable {
    func exists() -> Bool
    func read() throws -> VaultEnvelope
    func write(_ envelope: VaultEnvelope) throws
    func delete() throws
}

protocol AccessLogProvider: Sendable {
    func log(method: String, secret: String?, clientId: String?, result: String) throws
}
```

- [ ] **Step 2: Implement name validation**

```swift
enum NameValidation {
    // Alphanumeric, underscores, hyphens. 1-128 chars. Case-insensitive uniqueness.
    private static let validPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]{1,128}$")

    static func validate(_ name: String) throws {
        let range = NSRange(name.startIndex..., in: name)
        guard validPattern.firstMatch(in: name, range: range) != nil else {
            throw VaultError.invalidName(
                "Name must be 1-128 characters, alphanumeric/underscore/hyphen only. Got: '\(name)'"
            )
        }
    }
}
```

- [ ] **Step 3: Implement the Vault actor**

```swift
actor Vault {
    private let crypto: CryptoProvider
    private let keychain: KeychainProvider
    private let auth: AuthProvider
    private let store: VaultStoreProvider
    private let accessLog: AccessLogProvider

    private var data: VaultData?      // nil = locked
    private var masterKey: Data?       // nil = locked
    private var unlockTime: Date?

    init(crypto: CryptoProvider, keychain: KeychainProvider, auth: AuthProvider,
         store: VaultStoreProvider, accessLog: AccessLogProvider) {
        self.crypto = crypto
        self.keychain = keychain
        self.auth = auth
        self.store = store
        self.accessLog = accessLog
    }

    var isLocked: Bool { data == nil }

    // MARK: - Init

    func initialize(recoveryPassphrase: String?) async throws {
        guard !store.exists() else { throw VaultError.alreadyInitialized }
        try await auth.authenticate(reason: "Create new tsm vault")

        let key = crypto.generateKey()
        try keychain.storeMasterKey(key)

        var vaultData = VaultData()
        var recovery: RecoveryParams? = nil
        if let passphrase = recoveryPassphrase {
            let salt = crypto.generateKey() // 32 random bytes for salt
            recovery = RecoveryParams(
                salt: salt.base64EncodedString(),
                iterations: 600_000
            )
            // We don't store the derived key — it's re-derived from the passphrase at recovery time.
            // We verify it matches the master key only if we want dual-key support, but per spec
            // the recovery passphrase IS an alternative derivation of the same key concept.
            // Actually, the spec says: "derives the master key via PBKDF2"
            // So: we derive a key from the passphrase, and that derived key must equal the master key.
            // On init: we generate a random master key AND store recovery params.
            // On recover: we derive from passphrase and use that as the master key.
            // This means init needs to ALSO derive from passphrase and verify? No --
            // The spec says "The passphrase is never stored -- only the derived key goes into Keychain."
            // So on init with recovery: derive key from passphrase, use THAT as the master key.
            let derivedKey = try crypto.deriveKey(
                passphrase: passphrase, salt: salt, iterations: 600_000
            )
            // Replace the random key with the derived key — this way recovery always works
            try keychain.storeMasterKey(derivedKey)
            self.masterKey = derivedKey
        } else {
            self.masterKey = key
        }

        self.data = vaultData
        self.unlockTime = Date()
        try persist(recovery: recovery)
    }

    // MARK: - Unlock / Lock

    func unlock(passphrase: String? = nil) async throws {
        guard store.exists() else { throw VaultError.notInitialized }
        guard isLocked else { return } // already unlocked, no-op

        let key: Data
        if let passphrase = passphrase {
            let envelope = try store.read()
            guard let recovery = envelope.recovery else {
                throw VaultError.authFailed
            }
            guard let salt = Data(base64Encoded: recovery.salt) else {
                throw VaultError.authFailed
            }
            key = try crypto.deriveKey(
                passphrase: passphrase, salt: salt, iterations: recovery.iterations
            )
        } else {
            try await auth.authenticate(reason: "Unlock tsm vault")
            key = try keychain.retrieveMasterKey()
        }

        let envelope = try store.read()
        guard let nonce = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext) else {
            throw CryptoError.decryptionFailed("Invalid base64 in vault envelope")
        }
        let plaintext = try crypto.decrypt(ciphertext: ciphertext, key: key, nonce: nonce)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.data = try decoder.decode(VaultData.self, from: plaintext)
        self.masterKey = key
        self.unlockTime = Date()
    }

    func lock() {
        data = nil
        masterKey = nil
        unlockTime = nil
    }

    // MARK: - CRUD

    func list() throws -> [SecretMetadata] {
        guard let data = data else { throw VaultError.locked }
        return data.secrets.map { SecretMetadata(from: $0) }
    }

    func get(name: String, clientId: String? = nil) async throws -> Secret {
        guard let data = data else { throw VaultError.locked }
        guard let secret = data.secrets.first(where: {
            $0.name.lowercased() == name.lowercased()
        }) else {
            try? accessLog.log(method: "vault.get", secret: name, clientId: clientId, result: "not_found")
            throw VaultError.secretNotFound(name)
        }
        if secret.confirm {
            try await auth.authenticate(reason: "Access secret '\(name)'")
        }
        try? accessLog.log(method: "vault.get", secret: name, clientId: clientId, result: "ok")
        return secret
    }

    func add(name: String, value: String, description: String,
             confirm: Bool = false, tags: [String] = [],
             clientId: String? = nil) async throws {
        guard data != nil else { throw VaultError.locked }
        try NameValidation.validate(name)
        guard !data!.secrets.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw VaultError.secretAlreadyExists(name)
        }
        let secret = Secret(
            name: name, value: value, description: description,
            confirm: confirm, tags: tags, created: Date()
        )
        data!.secrets.append(secret)
        try persist()
        try? accessLog.log(method: "vault.add", secret: name, clientId: clientId, result: "ok")
    }

    func remove(name: String, clientId: String? = nil) async throws {
        guard data != nil else { throw VaultError.locked }
        guard let index = data!.secrets.firstIndex(where: {
            $0.name.lowercased() == name.lowercased()
        }) else {
            throw VaultError.secretNotFound(name)
        }
        data!.secrets.remove(at: index)
        try persist()
        try? accessLog.log(method: "vault.remove", secret: name, clientId: clientId, result: "ok")
    }

    func edit(name: String, value: String? = nil, description: String? = nil,
              confirm: Bool? = nil, tags: [String]? = nil,
              clientId: String? = nil) async throws {
        guard data != nil else { throw VaultError.locked }
        guard let index = data!.secrets.firstIndex(where: {
            $0.name.lowercased() == name.lowercased()
        }) else {
            throw VaultError.secretNotFound(name)
        }
        if let v = value { data!.secrets[index].value = v }
        if let d = description { data!.secrets[index].description = d }
        if let c = confirm { data!.secrets[index].confirm = c }
        if let t = tags { data!.secrets[index].tags = t }
        data!.secrets[index].updated = Date()
        try persist()
        try? accessLog.log(method: "vault.edit", secret: name, clientId: clientId, result: "ok")
    }

    func status() -> VaultStatus {
        let ttl: Int?
        if let unlockTime = unlockTime, let ttlHours = data?.config.ttlHours {
            let elapsed = Date().timeIntervalSince(unlockTime)
            let remaining = (Double(ttlHours) * 3600) - elapsed
            ttl = max(0, Int(remaining))
        } else {
            ttl = nil
        }
        return VaultStatus(
            locked: isLocked,
            ttlRemainingSeconds: ttl,
            secretCount: data?.secrets.count ?? 0
        )
    }

    func checkTTL() {
        guard let unlockTime = unlockTime, let ttlHours = data?.config.ttlHours else { return }
        let elapsed = Date().timeIntervalSince(unlockTime)
        if elapsed >= Double(ttlHours) * 3600 {
            lock()
        }
    }

    func capabilities() -> DaemonCapabilities {
        DaemonCapabilities(
            protocolVersion: 1,
            authBackends: ["touchid"],
            features: ["confirm", "access-log"]
        )
    }

    func reset(clientId: String? = nil) async throws {
        try await auth.authenticate(reason: "Reset tsm vault — this destroys all secrets")
        try? accessLog.log(method: "vault.reset", secret: nil, clientId: clientId, result: "ok")
        lock()
        try? store.delete()
        try? keychain.deleteMasterKey()
    }

    // MARK: - Private

    private func persist(recovery: RecoveryParams? = nil) throws {
        guard let data = data, let key = masterKey else { throw VaultError.locked }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(data)
        let (nonce, ciphertext) = try crypto.encrypt(data: plaintext, key: key)

        // If we have existing recovery params and none were passed, preserve them
        let existingRecovery: RecoveryParams?
        if recovery != nil {
            existingRecovery = recovery
        } else if store.exists(), let existing = try? store.read().recovery {
            existingRecovery = existing
        } else {
            existingRecovery = nil
        }

        let envelope = VaultEnvelope(
            version: 1,
            algorithm: crypto.algorithm,
            recovery: existingRecovery,
            nonce: nonce.base64EncodedString(),
            ciphertext: ciphertext.base64EncodedString()
        )
        try store.write(envelope)
    }
}
```

- [ ] **Step 4: Write Vault tests with mocks**

```swift
import XCTest
@testable import tsmd

// MARK: - Mocks

final class MockCrypto: CryptoProvider, @unchecked Sendable {
    let algorithm = "mock"
    func encrypt(data: Data, key: Data) throws -> (nonce: Data, ciphertext: Data) {
        // Simple XOR "encryption" for testing
        let nonce = Data(repeating: 0xAA, count: 12)
        var ciphertext = data
        for i in 0..<ciphertext.count {
            ciphertext[i] ^= key[i % key.count]
        }
        return (nonce, ciphertext)
    }
    func decrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        var plaintext = ciphertext
        for i in 0..<plaintext.count {
            plaintext[i] ^= key[i % key.count]
        }
        return plaintext
    }
    func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data {
        // Deterministic mock: just hash the passphrase+salt together simply
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

// MARK: - Tests

final class VaultTests: XCTestCase {
    var crypto: MockCrypto!
    var keychain: MockKeychain!
    var auth: MockAuth!
    var store: MockVaultStore!
    var accessLog: MockAccessLog!
    var vault: Vault!

    override func setUp() {
        crypto = MockCrypto()
        keychain = MockKeychain()
        auth = MockAuth()
        store = MockVaultStore()
        accessLog = MockAccessLog()
        vault = Vault(crypto: crypto, keychain: keychain, auth: auth,
                      store: store, accessLog: accessLog)
    }

    // MARK: - Init

    func testInitCreatesVault() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        let status = await vault.status()
        XCTAssertFalse(status.locked)
        XCTAssertEqual(status.secretCount, 0)
        XCTAssertTrue(store.exists())
        XCTAssertNotNil(keychain.storedKey)
    }

    func testInitWithRecoveryPassphrase() async throws {
        try await vault.initialize(recoveryPassphrase: "my-recovery")
        XCTAssertTrue(store.exists())
        let envelope = try store.read()
        XCTAssertNotNil(envelope.recovery)
        XCTAssertEqual(envelope.recovery?.iterations, 600_000)
    }

    func testInitFailsIfAlreadyExists() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        do {
            try await vault.initialize(recoveryPassphrase: nil)
            XCTFail("Expected alreadyInitialized error")
        } catch VaultError.alreadyInitialized {
            // expected
        }
    }

    // MARK: - Lock / Unlock

    func testLockClearsState() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        await vault.lock()
        let status = await vault.status()
        XCTAssertTrue(status.locked)
    }

    func testUnlockRestoredVault() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "key1", value: "val1", description: "test")
        await vault.lock()

        try await vault.unlock()
        let secrets = try await vault.list()
        XCTAssertEqual(secrets.count, 1)
        XCTAssertEqual(secrets[0].name, "key1")
    }

    func testUnlockWhenAlreadyUnlockedIsNoop() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        auth.authenticateCalled = false
        try await vault.unlock()
        // Auth should not have been called again since vault is already unlocked
        XCTAssertFalse(auth.authenticateCalled)
    }

    // MARK: - CRUD

    func testAddAndList() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "api_key", value: "secret", description: "My API key",
                           confirm: true, tags: ["api"])
        let list = try await vault.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "api_key")
        XCTAssertEqual(list[0].description, "My API key")
        XCTAssertTrue(list[0].confirm)
        XCTAssertEqual(list[0].tags, ["api"])
    }

    func testGetReturnsValue() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "key1", value: "secret123", description: "test")
        let secret = try await vault.get(name: "key1")
        XCTAssertEqual(secret.value, "secret123")
    }

    func testGetIsCaseInsensitive() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "MyKey", value: "val", description: "test")
        let secret = try await vault.get(name: "mykey")
        XCTAssertEqual(secret.name, "MyKey")
    }

    func testGetNotFoundThrows() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        do {
            _ = try await vault.get(name: "nonexistent")
            XCTFail("Expected secretNotFound")
        } catch VaultError.secretNotFound {
            // expected
        }
    }

    func testGetWithConfirmTriggersAuth() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "admin", value: "token", description: "admin token", confirm: true)
        auth.authenticateCalled = false
        _ = try await vault.get(name: "admin")
        XCTAssertTrue(auth.authenticateCalled)
    }

    func testAddDuplicateNameFails() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "key1", value: "v1", description: "d1")
        do {
            try await vault.add(name: "key1", value: "v2", description: "d2")
            XCTFail("Expected secretAlreadyExists")
        } catch VaultError.secretAlreadyExists {
            // expected
        }
    }

    func testAddDuplicateCaseInsensitive() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "MyKey", value: "v1", description: "d1")
        do {
            try await vault.add(name: "mykey", value: "v2", description: "d2")
            XCTFail("Expected secretAlreadyExists")
        } catch VaultError.secretAlreadyExists {
            // expected
        }
    }

    func testRemove() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "key1", value: "v1", description: "d1")
        try await vault.remove(name: "key1")
        let list = try await vault.list()
        XCTAssertTrue(list.isEmpty)
    }

    func testRemoveNotFoundThrows() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        do {
            try await vault.remove(name: "nope")
            XCTFail("Expected secretNotFound")
        } catch VaultError.secretNotFound {
            // expected
        }
    }

    func testEdit() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "key1", value: "old", description: "old desc")
        try await vault.edit(name: "key1", value: "new", description: "new desc", confirm: true)
        let secret = try await vault.get(name: "key1")
        XCTAssertEqual(secret.value, "new")
        XCTAssertEqual(secret.description, "new desc")
        XCTAssertTrue(secret.confirm)
        XCTAssertNotNil(secret.updated)
    }

    func testEditPartialUpdate() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "key1", value: "val", description: "desc", confirm: false, tags: ["a"])
        try await vault.edit(name: "key1", description: "new desc")
        let secret = try await vault.get(name: "key1")
        XCTAssertEqual(secret.value, "val")          // unchanged
        XCTAssertEqual(secret.description, "new desc") // changed
        XCTAssertFalse(secret.confirm)                 // unchanged
        XCTAssertEqual(secret.tags, ["a"])             // unchanged
    }

    // MARK: - Name Validation

    func testInvalidNameRejected() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        let badNames = ["", "a/b", "a b", "a\nb", String(repeating: "x", count: 129), "../etc/passwd"]
        for name in badNames {
            do {
                try await vault.add(name: name, value: "v", description: "d")
                XCTFail("Expected invalidName for '\(name)'")
            } catch VaultError.invalidName {
                // expected
            }
        }
    }

    func testValidNamesAccepted() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        let goodNames = ["a", "api_key", "my-secret", "KEY_123", String(repeating: "x", count: 128)]
        for name in goodNames {
            try await vault.add(name: name, value: "v", description: "d")
        }
        let list = try await vault.list()
        XCTAssertEqual(list.count, goodNames.count)
    }

    // MARK: - Locked operations fail

    func testListWhenLockedThrows() async throws {
        do {
            _ = try await vault.list()
            XCTFail("Expected locked")
        } catch VaultError.locked {
            // expected
        }
    }

    func testGetWhenLockedThrows() async throws {
        do {
            _ = try await vault.get(name: "x")
            XCTFail("Expected locked")
        } catch VaultError.locked {
            // expected
        }
    }

    // MARK: - Access logging

    func testGetLogsAccess() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "k", value: "v", description: "d")
        _ = try await vault.get(name: "k", clientId: "test/pid:1")
        XCTAssertEqual(accessLog.entries.count, 2) // add + get
        let getEntry = accessLog.entries[1]
        XCTAssertEqual(getEntry.method, "vault.get")
        XCTAssertEqual(getEntry.secret, "k")
        XCTAssertEqual(getEntry.clientId, "test/pid:1")
        XCTAssertEqual(getEntry.result, "ok")
    }

    // MARK: - TTL

    func testStatusShowsTTL() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        let status = await vault.status()
        XCTAssertFalse(status.locked)
        XCTAssertNotNil(status.ttlRemainingSeconds)
        // Should be close to 12 hours (43200 seconds) since we just unlocked
        XCTAssertGreaterThan(status.ttlRemainingSeconds!, 43100)
    }

    // MARK: - Reset

    func testResetDestroysEverything() async throws {
        try await vault.initialize(recoveryPassphrase: nil)
        try await vault.add(name: "key", value: "val", description: "d")
        try await vault.reset()
        let status = await vault.status()
        XCTAssertTrue(status.locked)
        XCTAssertFalse(store.exists())
        XCTAssertNil(keychain.storedKey)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd tsmd && swift test --filter VaultTests 2>&1 | tail -15`
Expected: All tests passed

- [ ] **Step 6: Commit**

```bash
git add tsmd/Sources/tsmd/Vault.swift tsmd/Tests/tsmdTests/VaultTests.swift
git commit -m "feat(tsmd): add Vault actor with CRUD, lock/unlock, TTL, confirm, and name validation"
```

---

## Task 5: VaultStore (Encrypted File I/O)

**Files:**
- Create: `tsmd/Sources/tsmd/VaultStore.swift`
- Test: `tsmd/Tests/tsmdTests/VaultStoreTests.swift`

- [ ] **Step 1: Implement FileVaultStore**

```swift
import Foundation

struct FileVaultStore: VaultStoreProvider {
    let path: URL

    init(path: URL = Paths.vaultFile) {
        self.path = path
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    func read() throws -> VaultEnvelope {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(VaultEnvelope.self, from: data)
    }

    func write(_ envelope: VaultEnvelope) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        // Write atomically: write to temp file, then rename
        let tmpPath = path.appendingPathExtension("tmp")
        try data.write(to: tmpPath, options: .atomic)
        // .atomic already does the rename, but let's be explicit about permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path.path
        )
    }

    func delete() throws {
        if exists() {
            try FileManager.default.removeItem(at: path)
        }
    }
}
```

- [ ] **Step 2: Write VaultStore tests**

```swift
import XCTest
@testable import tsmd

final class VaultStoreTests: XCTestCase {
    var tmpDir: URL!
    var store: FileVaultStore!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsmd-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = FileVaultStore(path: tmpDir.appendingPathComponent("vault.enc"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testExistsReturnsFalseWhenNoFile() {
        XCTAssertFalse(store.exists())
    }

    func testWriteThenReadRoundTrip() throws {
        let envelope = VaultEnvelope(
            version: 1,
            algorithm: "aes-256-gcm",
            recovery: nil,
            nonce: "bm9uY2U=",
            ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        XCTAssertTrue(store.exists())

        let read = try store.read()
        XCTAssertEqual(read.version, 1)
        XCTAssertEqual(read.algorithm, "aes-256-gcm")
        XCTAssertEqual(read.nonce, "bm9uY2U=")
        XCTAssertEqual(read.ciphertext, "Y2lwaGVy")
    }

    func testWriteWithRecoveryParams() throws {
        let envelope = VaultEnvelope(
            version: 1,
            algorithm: "aes-256-gcm",
            recovery: RecoveryParams(salt: "c2FsdA==", iterations: 600_000),
            nonce: "bm9uY2U=",
            ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        let read = try store.read()
        XCTAssertEqual(read.recovery?.iterations, 600_000)
    }

    func testDeleteRemovesFile() throws {
        let envelope = VaultEnvelope(
            version: 1, algorithm: "aes-256-gcm", recovery: nil,
            nonce: "bm9uY2U=", ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        XCTAssertTrue(store.exists())
        try store.delete()
        XCTAssertFalse(store.exists())
    }

    func testDeleteWhenNoFileDoesNotThrow() throws {
        XCTAssertNoThrow(try store.delete())
    }

    func testFilePermissions() throws {
        let envelope = VaultEnvelope(
            version: 1, algorithm: "aes-256-gcm", recovery: nil,
            nonce: "bm9uY2U=", ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.path.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testWriteCreatesParentDirectories() throws {
        let nested = tmpDir.appendingPathComponent("a/b/c/vault.enc")
        let nestedStore = FileVaultStore(path: nested)
        let envelope = VaultEnvelope(
            version: 1, algorithm: "aes-256-gcm", recovery: nil,
            nonce: "bm9uY2U=", ciphertext: "Y2lwaGVy"
        )
        try nestedStore.write(envelope)
        XCTAssertTrue(nestedStore.exists())
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd tsmd && swift test --filter VaultStoreTests 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 4: Commit**

```bash
git add tsmd/Sources/tsmd/VaultStore.swift tsmd/Tests/tsmdTests/VaultStoreTests.swift
git commit -m "feat(tsmd): add VaultStore for encrypted vault file I/O"
```

---

## Task 6: Access Log

**Files:**
- Create: `tsmd/Sources/tsmd/AccessLog.swift`
- Test: `tsmd/Tests/tsmdTests/AccessLogTests.swift`

- [ ] **Step 1: Implement FileAccessLog**

```swift
import Foundation

struct AccessLogEntry: Codable {
    let ts: String
    let method: String
    let secret: String?
    let clientId: String?
    let result: String

    enum CodingKeys: String, CodingKey {
        case ts, method, secret, result
        case clientId = "client_id"
    }
}

final class FileAccessLog: AccessLogProvider, @unchecked Sendable {
    let path: URL
    private let maxSize: Int
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(path: URL = Paths.accessLog, maxSize: Int = 10 * 1024 * 1024) {
        self.path = path
        self.maxSize = maxSize
    }

    func log(method: String, secret: String?, clientId: String?, result: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let entry = AccessLogEntry(
            ts: dateFormatter.string(from: Date()),
            method: method,
            secret: secret,
            clientId: clientId,
            result: result
        )
        let data = try encoder.encode(entry)
        var line = data
        line.append(0x0A) // newline

        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }

        // Rotate if needed
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int, size >= maxSize {
            try rotate()
        }

        let handle = try FileHandle(forWritingTo: path)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(line)
    }

    private func rotate() throws {
        let backup = path.deletingPathExtension().appendingPathExtension("1.log")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: path, to: backup)
    }
}
```

- [ ] **Step 2: Write access log tests**

```swift
import XCTest
@testable import tsmd

final class AccessLogTests: XCTestCase {
    var tmpDir: URL!
    var logPath: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsmd-log-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logPath = tmpDir.appendingPathComponent("access.log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLogWritesEntry() throws {
        let log = FileAccessLog(path: logPath)
        try log.log(method: "vault.get", secret: "my_key", clientId: "test/pid:1", result: "ok")

        let content = try String(contentsOf: logPath, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)

        let entry = try JSONDecoder().decode(AccessLogEntry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(entry.method, "vault.get")
        XCTAssertEqual(entry.secret, "my_key")
        XCTAssertEqual(entry.clientId, "test/pid:1")
        XCTAssertEqual(entry.result, "ok")
        XCTAssertFalse(entry.ts.isEmpty)
    }

    func testMultipleEntriesAppend() throws {
        let log = FileAccessLog(path: logPath)
        try log.log(method: "vault.get", secret: "a", clientId: nil, result: "ok")
        try log.log(method: "vault.get", secret: "b", clientId: nil, result: "ok")
        try log.log(method: "vault.lock", secret: nil, clientId: nil, result: "ok")

        let content = try String(contentsOf: logPath, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
    }

    func testNilSecretOmitted() throws {
        let log = FileAccessLog(path: logPath)
        try log.log(method: "vault.lock", secret: nil, clientId: nil, result: "ok")

        let content = try String(contentsOf: logPath, encoding: .utf8)
        // "secret":null should still be present (it's Codable default) — that's fine
        let entry = try JSONDecoder().decode(AccessLogEntry.self, from: Data(content.utf8))
        XCTAssertNil(entry.secret)
    }

    func testLogRotationAt10MB() throws {
        // Use a tiny maxSize for testing rotation
        let log = FileAccessLog(path: logPath, maxSize: 500)

        // Write enough to exceed 500 bytes
        for i in 0..<20 {
            try log.log(method: "vault.get", secret: "key_\(i)", clientId: nil, result: "ok")
        }

        let backup = logPath.deletingPathExtension().appendingPathExtension("1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testLogCreatesParentDirectories() throws {
        let nested = tmpDir.appendingPathComponent("a/b/access.log")
        let log = FileAccessLog(path: nested)
        try log.log(method: "vault.get", secret: "k", clientId: nil, result: "ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd tsmd && swift test --filter AccessLogTests 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 4: Commit**

```bash
git add tsmd/Sources/tsmd/AccessLog.swift tsmd/Tests/tsmdTests/AccessLogTests.swift
git commit -m "feat(tsmd): add append-only JSON access log with rotation"
```

---

## Task 7: Keychain + Touch ID Auth

**Files:**
- Create: `tsmd/Sources/tsmd/Keychain.swift`
- Create: `tsmd/Sources/tsmd/Auth.swift`
- Test: `tsmd/Tests/tsmdTests/KeychainAuthTests.swift` (integration — only runs on macOS with Keychain access)

These modules wrap macOS-specific APIs. Unit tests for the rest of the codebase use the mock implementations from Task 4. This task adds the real implementations and light integration tests.

- [ ] **Step 1: Implement MacKeychain**

```swift
import Foundation
import Security

enum KeychainError: Error {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case notFound
    case unexpectedData
}

struct MacKeychain: KeychainProvider {
    let service = "com.tsm.vault"
    let account = "master-key"

    func storeMasterKey(_ key: Data) throws {
        // Delete any existing entry first
        try? deleteMasterKey()

        // Create access control: require biometry (current set)
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw KeychainError.storeFailed(errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessControl as String: accessControl,
            kSecAttrSynchronizable as String: false, // no iCloud sync
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
```

- [ ] **Step 2: Implement TouchIDAuth**

```swift
import Foundation
import LocalAuthentication

struct TouchIDAuth: AuthProvider {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw VaultError.authFailed
        }

        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )

        guard success else {
            throw VaultError.authFailed
        }
    }
}
```

- [ ] **Step 3: Write integration tests (guarded by availability)**

```swift
import XCTest
@testable import tsmd

/// These tests require real macOS Keychain access. They may fail in CI
/// or in sandboxed environments. They're gated behind an environment variable.
final class KeychainAuthTests: XCTestCase {
    let shouldRun = ProcessInfo.processInfo.environment["TSM_INTEGRATION_TESTS"] == "1"

    override func setUp() {
        try? MacKeychain().deleteMasterKey()
    }

    override func tearDown() {
        try? MacKeychain().deleteMasterKey()
    }

    func testKeychainStoreAndRetrieve() throws {
        guard shouldRun else { throw XCTSkip("Set TSM_INTEGRATION_TESTS=1 to run") }
        let keychain = MacKeychain()
        let key = Data(repeating: 0xAB, count: 32)
        try keychain.storeMasterKey(key)
        let retrieved = try keychain.retrieveMasterKey()
        XCTAssertEqual(key, retrieved)
    }

    func testKeychainDelete() throws {
        guard shouldRun else { throw XCTSkip("Set TSM_INTEGRATION_TESTS=1 to run") }
        let keychain = MacKeychain()
        let key = Data(repeating: 0xCD, count: 32)
        try keychain.storeMasterKey(key)
        try keychain.deleteMasterKey()
        XCTAssertThrowsError(try keychain.retrieveMasterKey())
    }

    func testKeychainRetrieveWhenEmptyThrows() throws {
        guard shouldRun else { throw XCTSkip("Set TSM_INTEGRATION_TESTS=1 to run") }
        let keychain = MacKeychain()
        XCTAssertThrowsError(try keychain.retrieveMasterKey())
    }
}
```

- [ ] **Step 4: Build and run tests**

Run: `cd tsmd && swift test --filter KeychainAuthTests 2>&1 | tail -10`
Expected: All tests skipped (unless `TSM_INTEGRATION_TESTS=1`)

Run: `cd tsmd && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 5: Commit**

```bash
git add tsmd/Sources/tsmd/Keychain.swift tsmd/Sources/tsmd/Auth.swift tsmd/Tests/tsmdTests/KeychainAuthTests.swift
git commit -m "feat(tsmd): add Keychain master key storage and Touch ID authentication"
```

---

## Task 8: JSON-RPC Handler (Method Dispatch)

**Files:**
- Create: `tsmd/Sources/tsmd/JSONRPCHandler.swift`
- Test: `tsmd/Tests/tsmdTests/JSONRPCHandlerTests.swift`

The handler maps JSON-RPC method names to Vault operations. It parses params, calls the vault, and returns JSON-RPC responses. It does NOT handle socket I/O — that's the server's job.

- [ ] **Step 1: Implement JSONRPCHandler**

```swift
import Foundation

actor JSONRPCHandler {
    let vault: Vault

    init(vault: Vault) {
        self.vault = vault
    }

    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        do {
            let result = try await dispatch(request)
            return JSONRPCResponse(result: result, id: request.id)
        } catch let error as VaultError {
            return JSONRPCResponse(error: mapVaultError(error), id: request.id)
        } catch let error as CryptoError {
            return JSONRPCResponse(
                error: JSONRPCError(code: RPCErrorCode.internalError, message: "\(error)"),
                id: request.id
            )
        } catch {
            return JSONRPCResponse(
                error: JSONRPCError(code: RPCErrorCode.internalError, message: error.localizedDescription),
                id: request.id
            )
        }
    }

    private func dispatch(_ req: JSONRPCRequest) async throws -> JSONValue {
        switch req.method {
        case "vault.init":
            let passphrase = req.stringParam("recovery_passphrase")
            try await vault.initialize(recoveryPassphrase: passphrase)
            return .object(["ok": .bool(true)])

        case "vault.unlock":
            let passphrase = req.stringParam("passphrase")
            try await vault.unlock(passphrase: passphrase)
            return .object(["ok": .bool(true)])

        case "vault.lock":
            await vault.lock()
            return .object(["ok": .bool(true)])

        case "vault.status":
            let status = await vault.status()
            return encodeToJSONValue(status)

        case "vault.list":
            let secrets = try await vault.list()
            return encodeToJSONValue(secrets)

        case "vault.get":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            let secret = try await vault.get(name: name, clientId: clientId)
            return .object(["name": .string(secret.name), "value": .string(secret.value)])

        case "vault.add":
            guard let name = req.stringParam("name"),
                  let value = req.stringParam("value") else {
                throw VaultError.invalidName("Missing 'name' or 'value' parameter")
            }
            let description = req.stringParam("description") ?? ""
            let confirm = req.param("confirm")?.boolValue ?? false
            let tags: [String] = {
                if case .array(let arr) = req.param("tags") {
                    return arr.compactMap { $0.stringValue }
                }
                return []
            }()
            let clientId = req.stringParam("client_id")
            try await vault.add(name: name, value: value, description: description,
                               confirm: confirm, tags: tags, clientId: clientId)
            return .object(["ok": .bool(true)])

        case "vault.remove":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            try await vault.remove(name: name, clientId: clientId)
            return .object(["ok": .bool(true)])

        case "vault.edit":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            try await vault.edit(
                name: name,
                value: req.stringParam("value"),
                description: req.stringParam("description"),
                confirm: req.param("confirm")?.boolValue,
                tags: {
                    if case .array(let arr) = req.param("tags") {
                        return arr.compactMap { $0.stringValue }
                    }
                    return nil
                }(),
                clientId: clientId
            )
            return .object(["ok": .bool(true)])

        case "vault.reset":
            let clientId = req.stringParam("client_id")
            try await vault.reset(clientId: clientId)
            return .object(["ok": .bool(true)])

        case "daemon.capabilities":
            let caps = await vault.capabilities()
            return encodeToJSONValue(caps)

        case "daemon.shutdown":
            // Handled by the daemon, not the vault — return ok and let caller handle exit
            return .object(["ok": .bool(true)])

        default:
            throw JSONRPCHandlerError.methodNotFound(req.method)
        }
    }

    private func mapVaultError(_ error: VaultError) -> JSONRPCError {
        switch error {
        case .locked:
            return JSONRPCError(
                code: RPCErrorCode.vaultLocked,
                message: "Vault is locked",
                data: ["auth_method": .string("touchid")]
            )
        case .authRequired, .authFailed:
            return JSONRPCError(
                code: RPCErrorCode.authRequired,
                message: "Authentication required",
                data: ["auth_method": .string("touchid")]
            )
        case .secretNotFound(let name):
            return JSONRPCError(
                code: RPCErrorCode.secretNotFound,
                message: "Secret not found: \(name)"
            )
        case .notInitialized:
            return JSONRPCError(
                code: RPCErrorCode.vaultLocked,
                message: "Vault not initialized. Run 'tsm init'."
            )
        case .alreadyInitialized:
            return JSONRPCError(
                code: RPCErrorCode.internalError,
                message: "Vault already initialized"
            )
        case .secretAlreadyExists(let name):
            return JSONRPCError(
                code: RPCErrorCode.invalidParams,
                message: "Secret already exists: \(name)"
            )
        case .invalidName(let msg):
            return JSONRPCError(
                code: RPCErrorCode.invalidParams,
                message: msg
            )
        }
    }

    /// Encode any Codable to JSONValue via round-trip through JSON data.
    private func encodeToJSONValue<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let jsonValue = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return jsonValue
    }
}

enum JSONRPCHandlerError: Error {
    case methodNotFound(String)
}
```

- [ ] **Step 2: Write handler tests using mocks from Task 4**

```swift
import XCTest
@testable import tsmd

final class JSONRPCHandlerTests: XCTestCase {
    var handler: JSONRPCHandler!
    var vault: Vault!
    var auth: MockAuth!

    override func setUp() {
        auth = MockAuth()
        vault = Vault(
            crypto: MockCrypto(),
            keychain: MockKeychain(),
            auth: auth,
            store: MockVaultStore(),
            accessLog: MockAccessLog()
        )
        handler = JSONRPCHandler(vault: vault)
    }

    private func makeRequest(method: String, params: [String: JSONValue]? = nil, id: Int = 1) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", method: method, params: params, id: .int(id))
    }

    // MARK: - Init + Status

    func testVaultInit() async {
        let resp = await handler.handle(makeRequest(method: "vault.init"))
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)
    }

    func testVaultStatus() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let resp = await handler.handle(makeRequest(method: "vault.status"))
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object result"); return
        }
        XCTAssertEqual(obj["locked"], .bool(false))
    }

    // MARK: - CRUD

    func testVaultAddAndGet() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let addResp = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("key1"), "value": .string("secret"), "description": .string("test")]
        ))
        XCTAssertNil(addResp.error)

        let getResp = await handler.handle(makeRequest(
            method: "vault.get",
            params: ["name": .string("key1")]
        ))
        guard case .object(let obj) = getResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("secret"))
    }

    func testVaultList() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("v1"), "description": .string("d1")]
        ))
        let resp = await handler.handle(makeRequest(method: "vault.list"))
        guard case .array(let arr) = resp.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertEqual(arr.count, 1)
    }

    func testVaultRemove() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("v1"), "description": .string("d1")]
        ))
        let resp = await handler.handle(makeRequest(
            method: "vault.remove",
            params: ["name": .string("k1")]
        ))
        XCTAssertNil(resp.error)

        let listResp = await handler.handle(makeRequest(method: "vault.list"))
        guard case .array(let arr) = listResp.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertTrue(arr.isEmpty)
    }

    func testVaultEdit() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("old"), "description": .string("old desc")]
        ))
        let resp = await handler.handle(makeRequest(
            method: "vault.edit",
            params: ["name": .string("k1"), "value": .string("new"), "description": .string("new desc")]
        ))
        XCTAssertNil(resp.error)

        let getResp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k1")]
        ))
        guard case .object(let obj) = getResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("new"))
    }

    // MARK: - Lock / Unlock

    func testLockAndUnlock() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k"), "value": .string("v"), "description": .string("d")]
        ))

        _ = await handler.handle(makeRequest(method: "vault.lock"))
        let statusResp = await handler.handle(makeRequest(method: "vault.status"))
        guard case .object(let locked) = statusResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(locked["locked"], .bool(true))

        // Get should fail when locked
        let getResp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k")]
        ))
        XCTAssertEqual(getResp.error?.code, RPCErrorCode.vaultLocked)

        // Unlock
        _ = await handler.handle(makeRequest(method: "vault.unlock"))
        let getResp2 = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k")]
        ))
        XCTAssertNil(getResp2.error)
    }

    // MARK: - Error cases

    func testMethodNotFound() async {
        let resp = await handler.handle(makeRequest(method: "nonexistent"))
        XCTAssertNotNil(resp.error)
    }

    func testGetMissingNameParam() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let resp = await handler.handle(makeRequest(method: "vault.get"))
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, RPCErrorCode.invalidParams)
    }

    func testGetSecretNotFound() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let resp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("nope")]
        ))
        XCTAssertEqual(resp.error?.code, RPCErrorCode.secretNotFound)
    }

    // MARK: - Capabilities

    func testDaemonCapabilities() async {
        let resp = await handler.handle(makeRequest(method: "daemon.capabilities"))
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["protocol_version"], .int(1))
    }

    // MARK: - Shutdown

    func testDaemonShutdownReturnsOk() async {
        let resp = await handler.handle(makeRequest(method: "daemon.shutdown"))
        XCTAssertNil(resp.error)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd tsmd && swift test --filter JSONRPCHandlerTests 2>&1 | tail -15`
Expected: All tests passed

- [ ] **Step 4: Commit**

```bash
git add tsmd/Sources/tsmd/JSONRPCHandler.swift tsmd/Tests/tsmdTests/JSONRPCHandlerTests.swift
git commit -m "feat(tsmd): add JSON-RPC method dispatch handler with full vault operation coverage"
```

---

## Task 9: Socket Server

**Files:**
- Create: `tsmd/Sources/tsmd/SocketServer.swift`
- Test: `tsmd/Tests/tsmdTests/SocketServerTests.swift`

The socket server listens on a Unix domain socket, accepts connections, reads newline-delimited JSON-RPC requests, dispatches to the handler, and writes responses.

- [ ] **Step 1: Implement SocketServer**

```swift
import Foundation

final class SocketServer: @unchecked Sendable {
    let socketPath: String
    let handler: JSONRPCHandler
    private var serverFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "tsmd.socket", attributes: .concurrent)
    private let maxMessageSize = 1_048_576 // 1 MB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isRunning = false

    init(socketPath: String, handler: JSONRPCHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        // Remove stale socket file
        unlink(socketPath)

        // Create parent directory
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        // Create socket
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw SocketError.createFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw SocketError.bindFailed(errno)
        }

        // Set permissions on socket file: owner-only
        chmod(socketPath, 0o700)

        // Listen
        guard listen(serverFd, 5) == 0 else {
            close(serverFd)
            throw SocketError.listenFailed(errno)
        }

        // Accept loop via DispatchSource
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let clientFd = accept(self.serverFd, nil, nil)
            guard clientFd >= 0 else { return }
            Task { await self.handleConnection(clientFd) }
        }
        source.setCancelHandler { [serverFd = self.serverFd] in
            close(serverFd)
        }
        source.resume()
        readSource = source
        isRunning = true
    }

    func stop() {
        isRunning = false
        readSource?.cancel()
        readSource = nil
        unlink(socketPath)
    }

    private func handleConnection(_ fd: Int32) async {
        defer { close(fd) }

        // Read until newline (one request per connection line)
        var buffer = Data()
        let chunkSize = 4096
        var chunk = Data(count: chunkSize)

        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!, chunkSize)
            }
            if bytesRead <= 0 { break }
            buffer.append(chunk.prefix(bytesRead))

            if buffer.count > maxMessageSize {
                let errorResp = JSONRPCResponse(
                    error: JSONRPCError(code: RPCErrorCode.parseError, message: "Message too large"),
                    id: .null
                )
                writeResponse(errorResp, to: fd)
                return
            }

            // Check for newline — process each complete line
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer = Data(buffer.suffix(from: buffer.index(after: newlineIndex)))

                guard let request = try? decoder.decode(JSONRPCRequest.self, from: lineData) else {
                    let errorResp = JSONRPCResponse(
                        error: JSONRPCError(code: RPCErrorCode.parseError, message: "Invalid JSON"),
                        id: .null
                    )
                    writeResponse(errorResp, to: fd)
                    continue
                }

                let response = await handler.handle(request)
                writeResponse(response, to: fd)

                // Check if this was a shutdown request
                if request.method == "daemon.shutdown" {
                    // The daemon will handle actual shutdown
                    NotificationCenter.default.post(name: .tsmdShutdown, object: nil)
                }
            }
        }
    }

    private func writeResponse(_ response: JSONRPCResponse, to fd: Int32) {
        guard var data = try? encoder.encode(response) else { return }
        data.append(0x0A) // newline
        data.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, data.count)
        }
    }
}

extension Notification.Name {
    static let tsmdShutdown = Notification.Name("tsmdShutdown")
}

enum SocketError: Error {
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}
```

- [ ] **Step 2: Write socket server tests**

```swift
import XCTest
@testable import tsmd

final class SocketServerTests: XCTestCase {
    var tmpDir: String!
    var socketPath: String!
    var server: SocketServer!

    override func setUp() async throws {
        tmpDir = NSTemporaryDirectory() + "tsmd-socket-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        socketPath = tmpDir + "/test.sock"

        let vault = Vault(
            crypto: MockCrypto(),
            keychain: MockKeychain(),
            auth: MockAuth(),
            store: MockVaultStore(),
            accessLog: MockAccessLog()
        )
        let handler = JSONRPCHandler(vault: vault)
        server = SocketServer(socketPath: socketPath, handler: handler)
        try server.start()

        // Initialize the vault so we can test operations
        _ = await handler.handle(JSONRPCRequest(
            jsonrpc: "2.0", method: "vault.init", params: nil, id: .int(0)
        ))
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    /// Helper: connect to socket, send a JSON-RPC request, read response
    private func sendRequest(_ json: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw SocketError.bindFailed(errno) }

        // Send request + newline
        var data = Data(json.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, data.count)
        }

        // Read response
        // Give the server a moment to process
        usleep(100_000) // 100ms

        var response = Data(count: 65536)
        let bytesRead = response.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress!, 65536)
        }
        guard bytesRead > 0 else { return Data() }
        return response.prefix(bytesRead)
    }

    func testCapabilitiesOverSocket() throws {
        let json = """
        {"jsonrpc":"2.0","method":"daemon.capabilities","id":1}
        """
        let responseData = try sendRequest(json)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        XCTAssertNil(response.error)
        guard case .object(let obj) = response.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["protocol_version"], .int(1))
    }

    func testStatusOverSocket() throws {
        let json = """
        {"jsonrpc":"2.0","method":"vault.status","id":2}
        """
        let responseData = try sendRequest(json)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        XCTAssertNil(response.error)
    }

    func testAddAndGetOverSocket() throws {
        // Add
        let addJson = """
        {"jsonrpc":"2.0","method":"vault.add","params":{"name":"sock_key","value":"sock_val","description":"socket test"},"id":3}
        """
        let addResp = try sendRequest(addJson)
        let addResponse = try JSONDecoder().decode(JSONRPCResponse.self, from: addResp)
        XCTAssertNil(addResponse.error)

        // Get
        let getJson = """
        {"jsonrpc":"2.0","method":"vault.get","params":{"name":"sock_key"},"id":4}
        """
        let getResp = try sendRequest(getJson)
        let getResponse = try JSONDecoder().decode(JSONRPCResponse.self, from: getResp)
        XCTAssertNil(getResponse.error)
        guard case .object(let obj) = getResponse.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("sock_val"))
    }

    func testInvalidJsonReturnsParseError() throws {
        let responseData = try sendRequest("not valid json")
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        XCTAssertEqual(response.error?.code, RPCErrorCode.parseError)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd tsmd && swift test --filter SocketServerTests 2>&1 | tail -15`
Expected: All tests passed

- [ ] **Step 4: Commit**

```bash
git add tsmd/Sources/tsmd/SocketServer.swift tsmd/Tests/tsmdTests/SocketServerTests.swift
git commit -m "feat(tsmd): add Unix socket server with newline-delimited JSON-RPC framing"
```

---

## Task 10: Daemon Lifecycle + main.swift

**Files:**
- Create: `tsmd/Sources/tsmd/Daemon.swift`
- Modify: `tsmd/Sources/tsmd/main.swift`

The Daemon wires everything together: creates real implementations, starts the socket server, manages the TTL timer, and handles signals for graceful shutdown.

- [ ] **Step 1: Implement Daemon**

```swift
import Foundation

final class Daemon {
    let socketPath: String
    let vault: Vault
    let server: SocketServer
    private var ttlTimer: DispatchSourceTimer?
    private var shutdownObserver: NSObjectProtocol?
    private let shutdownSemaphore = DispatchSemaphore(value: 0)

    init(socketPath: String? = nil) {
        let path = socketPath ?? Paths.socketPath

        let crypto = AESGCMCrypto()
        let keychain = MacKeychain()
        let auth = TouchIDAuth()
        let store = FileVaultStore()
        let accessLog = FileAccessLog()

        self.vault = Vault(
            crypto: crypto,
            keychain: keychain,
            auth: auth,
            store: store,
            accessLog: accessLog
        )
        let handler = JSONRPCHandler(vault: vault)
        self.server = SocketServer(socketPath: path, handler: handler)
        self.socketPath = path
    }

    func run() throws {
        try server.start()

        // Print socket path for parent process to capture
        print(socketPath)
        fflush(stdout)

        // TTL check every 60 seconds
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { await self.vault.checkTTL() }
        }
        timer.resume()
        ttlTimer = timer

        // Listen for shutdown notification (from daemon.shutdown RPC)
        shutdownObserver = NotificationCenter.default.addObserver(
            forName: .tsmdShutdown, object: nil, queue: nil
        ) { [weak self] _ in
            self?.shutdown()
        }

        // Handle SIGTERM and SIGINT for graceful shutdown
        signal(SIGTERM) { _ in
            NotificationCenter.default.post(name: .tsmdShutdown, object: nil)
        }
        signal(SIGINT) { _ in
            NotificationCenter.default.post(name: .tsmdShutdown, object: nil)
        }

        // Block until shutdown
        shutdownSemaphore.wait()
    }

    func shutdown() {
        ttlTimer?.cancel()
        server.stop()
        if let observer = shutdownObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        shutdownSemaphore.signal()
    }
}
```

- [ ] **Step 2: Implement main.swift**

```swift
import Foundation

@main
struct TSMDMain {
    static func main() throws {
        // Usage: tsmd [--socket <path>]
        let args = CommandLine.arguments
        var socketPath: String? = nil

        var i = 1
        while i < args.count {
            if args[i] == "--socket" && i + 1 < args.count {
                socketPath = args[i + 1]
                i += 2
            } else {
                fputs("Usage: tsmd [--socket <path>]\n", stderr)
                Foundation.exit(1)
            }
        }

        let daemon = Daemon(socketPath: socketPath)
        try daemon.run()
    }
}
```

Note: Using `@main` attribute requires removing any top-level code from main.swift. Delete the placeholder from Task 1.

- [ ] **Step 3: Verify build succeeds**

Run: `cd tsmd && swift build 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 4: Commit**

```bash
git add tsmd/Sources/tsmd/Daemon.swift tsmd/Sources/tsmd/main.swift
git commit -m "feat(tsmd): add daemon lifecycle with TTL timer, signal handling, and graceful shutdown"
```

---

## Task 11: End-to-End Integration Tests

**Files:**
- Test: `tsmd/Tests/tsmdTests/IntegrationTests.swift`

These tests spin up a real daemon process (with mock Keychain/Auth), connect over a Unix socket, and verify the full request/response flow.

- [ ] **Step 1: Write integration tests**

Since the real daemon uses `MacKeychain` and `TouchIDAuth` which need hardware, the integration tests reuse the mock-based socket test pattern from Task 9 but exercise longer multi-step flows.

```swift
import XCTest
@testable import tsmd

final class IntegrationTests: XCTestCase {
    var tmpDir: String!
    var socketPath: String!
    var server: SocketServer!
    var handler: JSONRPCHandler!

    override func setUp() async throws {
        tmpDir = NSTemporaryDirectory() + "tsmd-integration-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        socketPath = tmpDir + "/test.sock"

        let storePath = URL(fileURLWithPath: tmpDir).appendingPathComponent("vault.enc")
        let logPath = URL(fileURLWithPath: tmpDir).appendingPathComponent("access.log")

        let vault = Vault(
            crypto: AESGCMCrypto(),  // real crypto!
            keychain: MockKeychain(),
            auth: MockAuth(),
            store: FileVaultStore(path: storePath),  // real file I/O!
            accessLog: FileAccessLog(path: logPath)   // real logging!
        )
        handler = JSONRPCHandler(vault: vault)
        server = SocketServer(socketPath: socketPath, handler: handler)
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func rpc(_ method: String, params: [String: JSONValue]? = nil, id: Int = 1) async -> JSONRPCResponse {
        await handler.handle(JSONRPCRequest(jsonrpc: "2.0", method: method, params: params, id: .int(id)))
    }

    func testFullLifecycle() async throws {
        // 1. Init vault
        let initResp = await rpc("vault.init")
        XCTAssertNil(initResp.error, "Init failed: \(String(describing: initResp.error))")

        // 2. Add secrets
        let add1 = await rpc("vault.add", params: [
            "name": .string("api_key"),
            "value": .string("sk-12345"),
            "description": .string("OpenAI API key"),
            "confirm": .bool(false),
            "tags": .array([.string("openai"), .string("ai")])
        ])
        XCTAssertNil(add1.error)

        let add2 = await rpc("vault.add", params: [
            "name": .string("admin_token"),
            "value": .string("admin-secret"),
            "description": .string("Admin access"),
            "confirm": .bool(true)
        ])
        XCTAssertNil(add2.error)

        // 3. List secrets (no values)
        let list = await rpc("vault.list")
        guard case .array(let arr) = list.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertEqual(arr.count, 2)

        // 4. Get a secret
        let get = await rpc("vault.get", params: [
            "name": .string("api_key"),
            "client_id": .string("test/pid:999")
        ])
        guard case .object(let getObj) = get.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(getObj["value"], .string("sk-12345"))

        // 5. Edit a secret
        let edit = await rpc("vault.edit", params: [
            "name": .string("api_key"),
            "value": .string("sk-67890")
        ])
        XCTAssertNil(edit.error)

        // 6. Verify edit
        let getEdited = await rpc("vault.get", params: ["name": .string("api_key")])
        guard case .object(let editedObj) = getEdited.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(editedObj["value"], .string("sk-67890"))

        // 7. Lock vault
        let lockResp = await rpc("vault.lock")
        XCTAssertNil(lockResp.error)

        // 8. Verify locked — get should fail
        let lockedGet = await rpc("vault.get", params: ["name": .string("api_key")])
        XCTAssertEqual(lockedGet.error?.code, RPCErrorCode.vaultLocked)

        // 9. Unlock vault
        let unlockResp = await rpc("vault.unlock")
        XCTAssertNil(unlockResp.error)

        // 10. Verify data survived lock/unlock cycle (real crypto + real file I/O)
        let getAfterUnlock = await rpc("vault.get", params: ["name": .string("api_key")])
        guard case .object(let unlockObj) = getAfterUnlock.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(unlockObj["value"], .string("sk-67890"))

        // 11. Remove a secret
        let remove = await rpc("vault.remove", params: ["name": .string("admin_token")])
        XCTAssertNil(remove.error)

        // 12. Status
        let status = await rpc("vault.status")
        guard case .object(let statusObj) = status.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(statusObj["locked"], .bool(false))
        XCTAssertEqual(statusObj["secret_count"], .int(1))

        // 13. Verify access log was written
        let logPath = URL(fileURLWithPath: tmpDir).appendingPathComponent("access.log")
        let logContent = try String(contentsOf: logPath, encoding: .utf8)
        let logLines = logContent.split(separator: "\n")
        XCTAssertGreaterThan(logLines.count, 0)
    }

    func testInitWithRecoveryAndRecover() async throws {
        // Init with recovery passphrase
        let initResp = await rpc("vault.init", params: [
            "recovery_passphrase": .string("my-secret-recovery-phrase")
        ])
        XCTAssertNil(initResp.error)

        // Add a secret
        _ = await rpc("vault.add", params: [
            "name": .string("precious"),
            "value": .string("diamond"),
            "description": .string("very important")
        ])

        // Lock
        _ = await rpc("vault.lock")

        // Unlock with passphrase (simulating recovery)
        let unlockResp = await rpc("vault.unlock", params: [
            "passphrase": .string("my-secret-recovery-phrase")
        ])
        XCTAssertNil(unlockResp.error, "Passphrase unlock failed: \(String(describing: unlockResp.error))")

        // Verify data is intact
        let get = await rpc("vault.get", params: ["name": .string("precious")])
        guard case .object(let obj) = get.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("diamond"))
    }

    func testCapabilities() async {
        let resp = await rpc("daemon.capabilities")
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["protocol_version"], .int(1))
        guard case .array(let backends) = obj["auth_backends"] else {
            XCTFail("Expected auth_backends array"); return
        }
        XCTAssertTrue(backends.contains(.string("touchid")))
    }

    func testNameValidationOverProtocol() async {
        _ = await rpc("vault.init")
        let resp = await rpc("vault.add", params: [
            "name": .string("../etc/passwd"),
            "value": .string("evil"),
            "description": .string("path traversal attempt")
        ])
        XCTAssertEqual(resp.error?.code, RPCErrorCode.invalidParams)
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `cd tsmd && swift test 2>&1 | tail -20`
Expected: All tests passed (Keychain tests skipped)

- [ ] **Step 3: Commit**

```bash
git add tsmd/Tests/tsmdTests/IntegrationTests.swift
git commit -m "test(tsmd): add end-to-end integration tests with real crypto and file I/O"
```

---

## Summary

| Task | Component | Key Files |
|------|-----------|-----------|
| 1 | Scaffold + Models + Paths | Package.swift, Models.swift, Paths.swift |
| 2 | JSON-RPC Types | JSONRPCTypes.swift |
| 3 | Crypto (AES-256-GCM + PBKDF2) | Crypto.swift |
| 4 | Vault Actor (CRUD + TTL) | Vault.swift |
| 5 | VaultStore (File I/O) | VaultStore.swift |
| 6 | Access Log | AccessLog.swift |
| 7 | Keychain + Touch ID | Keychain.swift, Auth.swift |
| 8 | JSON-RPC Handler | JSONRPCHandler.swift |
| 9 | Socket Server | SocketServer.swift |
| 10 | Daemon + main | Daemon.swift, main.swift |
| 11 | Integration Tests | IntegrationTests.swift |

After completing this plan, the daemon is fully functional. **Plan 2** (Go CLI) will implement the CLI that communicates with this daemon over the Unix socket. **Plan 3** (Claude Code Plugin) will package the integration.

---

## Addendum: Display Name Field

> **Added 2026-04-25** — extends the original plan after completion. Pairs with the [Plan 2 Display Name Addendum](2026-03-22-tsm-cli-implementation.md#addendum-display-name-support).

**Goal:** Each secret gains an optional `display_name` (free-text, cosmetic). The existing `name` stays the validated kebab-case id. The CLI shows the display name in `tsm list`; the id is what every programmatic path uses (audit log, env var derivation, MCP, `tsm get`).

**Architecture:** Backward-compatible field addition. `Secret.displayName` defaults to `""`. A custom decoder treats a missing `display_name` key as `""`, so vault files written before this change decode cleanly. The on-disk envelope `version` is unchanged because nothing about the envelope format changed; old daemons reading new vaults will simply ignore the unknown field (Swift's default decoder behavior).

### Task 12: Display Name Field

**Files:**
- Modify: `tsmd/Sources/tsmd/Models.swift`
- Modify: `tsmd/Sources/tsmd/Vault.swift`
- Modify: `tsmd/Sources/tsmd/JSONRPCHandler.swift`
- Test: `tsmd/Tests/tsmdTests/ModelsTests.swift`
- Test: `tsmd/Tests/tsmdTests/VaultTests.swift`
- Test: `tsmd/Tests/tsmdTests/JSONRPCHandlerTests.swift`

- [ ] **Step 1: Write failing tests for `Secret` round-trip + backward compat**

In `ModelsTests.swift`, add:

```swift
func testSecret_DisplayName_RoundTrip() throws {
    let s = Secret(
        name: "openai-api-key",
        displayName: "OpenAI API key",
        value: "sk-...",
        description: "",
        confirm: false,
        tags: [],
        created: Date(timeIntervalSince1970: 1_700_000_000),
        updated: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(s)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Secret.self, from: data)
    XCTAssertEqual(decoded.displayName, "OpenAI API key")
    XCTAssertEqual(decoded.name, "openai-api-key")
}

func testSecret_DisplayName_BackwardCompat() throws {
    // Vault files written before display_name was added omit the field.
    let oldJSON = #"""
    {"name":"openai-api-key","value":"sk-...","description":"","confirm":false,"tags":[],"created":"2025-01-01T00:00:00Z"}
    """#.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let s = try decoder.decode(Secret.self, from: oldJSON)
    XCTAssertEqual(s.displayName, "")
}
```

Run: `swift test --filter testSecret_DisplayName`
Expected: FAIL — `displayName` not in `Secret`.

- [ ] **Step 2: Add `displayName` to `Secret` and `SecretMetadata`**

In `Models.swift`, replace `Secret`:

```swift
struct Secret: Codable, Equatable, Sendable {
    let name: String
    var displayName: String
    var value: String
    var description: String
    var confirm: Bool
    var tags: [String]
    let created: Date
    var updated: Date?

    enum CodingKeys: String, CodingKey {
        case name, value, description, confirm, tags, created, updated
        case displayName = "display_name"
    }

    init(name: String, displayName: String = "", value: String, description: String = "", confirm: Bool = false, tags: [String] = [], created: Date, updated: Date? = nil) {
        self.name = name
        self.displayName = displayName
        self.value = value
        self.description = description
        self.confirm = confirm
        self.tags = tags
        self.created = created
        self.updated = updated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        self.value = try c.decode(String.self, forKey: .value)
        self.description = try c.decode(String.self, forKey: .description)
        self.confirm = try c.decode(Bool.self, forKey: .confirm)
        self.tags = try c.decode([String].self, forKey: .tags)
        self.created = try c.decode(Date.self, forKey: .created)
        self.updated = try c.decodeIfPresent(Date.self, forKey: .updated)
    }
}
```

Replace `SecretMetadata`:

```swift
struct SecretMetadata: Codable, Equatable, Sendable {
    let name: String
    let displayName: String
    let description: String
    let confirm: Bool
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case name, description, confirm, tags
        case displayName = "display_name"
    }

    init(from secret: Secret) {
        self.name = secret.name
        self.displayName = secret.displayName
        self.description = secret.description
        self.confirm = secret.confirm
        self.tags = secret.tags
    }
}
```

Run: `swift test --filter testSecret_DisplayName`
Expected: PASS.

- [ ] **Step 3: Add `DisplayNameValidation`**

In `Vault.swift`, alongside `NameValidation`:

```swift
enum DisplayNameValidation {
    static func validate(_ s: String) throws {
        guard s.count <= 256 else {
            throw VaultError.invalidName("Display name must be ≤256 characters")
        }
        for ch in s.unicodeScalars where ch.value < 0x20 || ch.value == 0x7F {
            throw VaultError.invalidName("Display name cannot contain control characters")
        }
    }
}
```

- [ ] **Step 4: Wire `display_name` through `vault.add`**

Update `Vault.add` to accept and validate `displayName`:

```swift
func add(name: String, displayName: String = "", value: String, description: String = "", confirm: Bool = false, tags: [String] = []) throws {
    try requireUnlocked()
    try NameValidation.validate(name)
    try DisplayNameValidation.validate(displayName)
    guard data!.secrets.allSatisfy({ $0.name.lowercased() != name.lowercased() }) else {
        throw VaultError.duplicateName(name)
    }
    let secret = Secret(
        name: name,
        displayName: displayName,
        value: value,
        description: description,
        confirm: confirm,
        tags: tags,
        created: Date()
    )
    data!.secrets.append(secret)
    try persist()
}
```

In `JSONRPCHandler.swift`, in the `vault.add` case, extract `display_name` from params (default `""`) and pass it through.

- [ ] **Step 5: Wire `display_name` through `vault.edit`**

Update `Vault.edit` to accept `displayName: String?` (nil = leave unchanged, "" = clear):

```swift
func edit(name: String, displayName: String? = nil, value: String? = nil, description: String? = nil, confirm: Bool? = nil, tags: [String]? = nil) throws {
    try requireUnlocked()
    guard let idx = data!.secrets.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
        throw VaultError.notFound(name)
    }
    if let dn = displayName {
        try DisplayNameValidation.validate(dn)
        data!.secrets[idx].displayName = dn
    }
    // ... existing field mutations unchanged ...
    data!.secrets[idx].updated = Date()
    try persist()
}
```

In `JSONRPCHandler.swift`, the `vault.edit` case passes `display_name` through as `nil` when absent, otherwise the string value.

- [ ] **Step 6: Write failing test for `vault.add` + `vault.list` carrying display_name**

In `JSONRPCHandlerTests.swift`, add:

```swift
func testVaultAdd_DisplayName_StoredAndReturned() async throws {
    let h = makeHandler()
    _ = try await h.handle(.init(jsonrpc: "2.0", method: "vault.init", params: nil, id: .int(1)))
    _ = try await h.handle(.init(jsonrpc: "2.0", method: "vault.unlock", params: nil, id: .int(2)))
    let addParams: [String: JSONValue] = [
        "name": .string("openai-api-key"),
        "display_name": .string("OpenAI API key"),
        "value": .string("sk-..."),
    ]
    _ = try await h.handle(.init(jsonrpc: "2.0", method: "vault.add", params: .object(addParams), id: .int(3)))
    let listResp = try await h.handle(.init(jsonrpc: "2.0", method: "vault.list", params: nil, id: .int(4)))
    let str = String(data: try JSONEncoder().encode(listResp), encoding: .utf8)!
    XCTAssertTrue(str.contains("\"display_name\":\"OpenAI API key\""))
}
```

Run: `swift test --filter testVaultAdd_DisplayName`
Expected: PASS.

- [ ] **Step 7: Run full test suite and commit**

```bash
swift test
git add tsmd/Sources/tsmd/Models.swift tsmd/Sources/tsmd/Vault.swift tsmd/Sources/tsmd/JSONRPCHandler.swift tsmd/Tests/tsmdTests/
git commit -m "feat(tsmd): add display_name field to secrets with backward-compatible decode"
```

Expected: all existing tests still pass; 3 new tests pass.

---

### Addendum Summary

| Task | Component | Key Files |
|------|-----------|-----------|
| 12 | Display name field | Models.swift, Vault.swift, JSONRPCHandler.swift |
