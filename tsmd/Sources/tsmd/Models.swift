import Foundation

struct Secret: Codable, Equatable, Sendable {
    let name: String
    var value: String
    var description: String
    var confirm: Bool
    var tags: [String]
    let created: Date
    var updated: Date?
}

struct SecretMetadata: Codable, Equatable, Sendable {
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

struct VaultData: Codable, Equatable, Sendable {
    var version: Int = 1
    var secrets: [Secret]
    var config: VaultConfig

    init(secrets: [Secret] = [], config: VaultConfig = VaultConfig()) {
        self.secrets = secrets
        self.config = config
    }
}

struct VaultConfig: Codable, Equatable, Sendable {
    var ttlHours: Int = 12

    enum CodingKeys: String, CodingKey {
        case ttlHours = "ttl_hours"
    }
}

struct VaultEnvelope: Codable, Equatable, Sendable {
    let version: Int
    let algorithm: String
    let recovery: RecoveryParams?
    let nonce: String
    let ciphertext: String
}

struct RecoveryParams: Codable, Equatable, Sendable {
    let salt: String
    let iterations: Int
}

struct VaultStatus: Codable, Equatable, Sendable {
    let locked: Bool
    let ttlRemainingSeconds: Int?
    let secretCount: Int

    enum CodingKeys: String, CodingKey {
        case locked
        case ttlRemainingSeconds = "ttl_remaining_seconds"
        case secretCount = "secret_count"
    }
}

struct DaemonCapabilities: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let authBackends: [String]
    let features: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case authBackends = "auth_backends"
        case features
    }
}
