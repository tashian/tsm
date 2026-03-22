import Foundation

// MARK: - Errors

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

// MARK: - Dependency protocols

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

// MARK: - Name validation

enum NameValidation {
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

// MARK: - Vault actor

actor Vault {
    private let crypto: CryptoProvider
    private let keychain: KeychainProvider
    private let auth: AuthProvider
    private let store: VaultStoreProvider
    private let accessLog: AccessLogProvider

    private var data: VaultData?
    private var masterKey: Data?
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

        let key: Data
        var recovery: RecoveryParams? = nil

        if let passphrase = recoveryPassphrase {
            let salt = crypto.generateKey() // 32 random bytes
            recovery = RecoveryParams(salt: salt.base64EncodedString(), iterations: 600_000)
            key = try crypto.deriveKey(passphrase: passphrase, salt: salt, iterations: 600_000)
        } else {
            key = crypto.generateKey()
        }

        try keychain.storeMasterKey(key)
        self.masterKey = key
        self.data = VaultData()
        self.unlockTime = Date()
        try persist(recovery: recovery)
    }

    // MARK: - Unlock / Lock

    func unlock(passphrase: String? = nil) async throws {
        guard store.exists() else { throw VaultError.notInitialized }
        guard isLocked else { return }

        let key: Data
        if let passphrase = passphrase {
            let envelope = try store.read()
            guard let recovery = envelope.recovery,
                  let salt = Data(base64Encoded: recovery.salt) else {
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
