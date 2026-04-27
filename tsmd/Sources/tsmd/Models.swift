import Foundation

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

    init(name: String, displayName: String = "", value: String, description: String = "",
         confirm: Bool = false, tags: [String] = [], created: Date, updated: Date? = nil) {
        self.name = name
        self.displayName = displayName
        self.value = value
        self.description = description
        self.confirm = confirm
        self.tags = tags
        self.created = created
        self.updated = updated
    }

    // Custom decoder so vault files written before display_name was a field
    // decode cleanly with displayName == "".
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
    var ttlSeconds: Int = 1800

    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }

    // Custom decoder so old vaults written with ttl_hours (or no config key at
    // all) decode cleanly, picking up the 1800-second default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ttlSeconds = (try? c.decodeIfPresent(Int.self, forKey: .ttlSeconds)) ?? 1800
    }

    init(ttlSeconds: Int = 1800) {
        self.ttlSeconds = ttlSeconds
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
