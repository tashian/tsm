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
    case invalidConfig(String)   // NEW
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

enum DisplayNameValidation {
    static func validate(_ s: String) throws {
        guard s.count <= 256 else {
            throw VaultError.invalidName("Display name must be 256 characters or fewer")
        }
        for ch in s.unicodeScalars where ch.value < 0x20 || ch.value == 0x7F {
            throw VaultError.invalidName("Display name cannot contain control characters")
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
    private var unlockedSessions: [pid_t: Date] = [:]

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

    func initialize(recoveryPassphrase: String?, sessionID: pid_t) async throws {
        guard !store.exists() else { throw VaultError.alreadyInitialized }
        try await auth.authenticate(reason: "Create new tsm vault")

        let key: Data
        var recovery: RecoveryParams? = nil

        if let passphrase = recoveryPassphrase {
            let salt = crypto.generateKey()
            recovery = RecoveryParams(salt: salt.base64EncodedString(), iterations: 600_000)
            key = try crypto.deriveKey(passphrase: passphrase, salt: salt, iterations: 600_000)
        } else {
            key = crypto.generateKey()
        }

        try keychain.storeMasterKey(key)
        self.masterKey = key
        self.data = VaultData()
        self.unlockedSessions[sessionID] = Date()
        try persist(recovery: recovery)
    }

    // MARK: - Unlock / Lock

    func unlock(passphrase: String? = nil, sessionID: pid_t) async throws {
        guard store.exists() else { throw VaultError.notInitialized }

        if data == nil {
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
        } else {
            // Data is loaded. Decide whether this session needs to (re-)authenticate.
            let needsAuth: Bool = {
                guard let unlocked = unlockedSessions[sessionID] else { return true }
                // Same session already in map — but check it hasn't silently expired.
                let ttlSeconds = data?.config.ttlSeconds ?? 1800
                return Date().timeIntervalSince(unlocked) >= Double(ttlSeconds)
            }()
            if needsAuth {
                // Passphrase-based recovery only makes sense on cold load. With data
                // already loaded, require Touch ID regardless of passphrase argument.
                try await auth.authenticate(reason: "Unlock tsm vault")
            }
        }

        self.unlockedSessions[sessionID] = Date()
    }

    func lock(sessionID: pid_t) {
        unlockedSessions.removeValue(forKey: sessionID)
        if unlockedSessions.isEmpty {
            zeroState()
        }
    }

    func lockAll() {
        unlockedSessions.removeAll()
        zeroState()
    }

    private func zeroState() {
        data = nil
        if masterKey != nil {
            let count = masterKey!.count
            masterKey!.resetBytes(in: 0..<count)
            masterKey = nil
        }
    }

    // MARK: - Authorization helper

    private func authorized(_ sessionID: pid_t) throws {
        guard data != nil else { throw VaultError.locked }
        guard let unlocked = unlockedSessions[sessionID] else { throw VaultError.locked }
        let ttlSeconds = data!.config.ttlSeconds
        let elapsed = Date().timeIntervalSince(unlocked)
        if elapsed >= Double(ttlSeconds) {
            unlockedSessions.removeValue(forKey: sessionID)
            if unlockedSessions.isEmpty { zeroState() }
            throw VaultError.locked
        }
    }

    // MARK: - CRUD

    func list(sessionID: pid_t) throws -> [SecretMetadata] {
        try authorized(sessionID)
        return data!.secrets.map { SecretMetadata(from: $0) }
    }

    func get(name: String, sessionID: pid_t, clientId: String? = nil) async throws -> Secret {
        try authorized(sessionID)
        guard let secret = data!.secrets.first(where: {
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

    func add(name: String, displayName: String = "", value: String, description: String,
             confirm: Bool = false, tags: [String] = [],
             sessionID: pid_t, clientId: String? = nil) async throws {
        try authorized(sessionID)
        try NameValidation.validate(name)
        try DisplayNameValidation.validate(displayName)
        guard !data!.secrets.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw VaultError.secretAlreadyExists(name)
        }
        let secret = Secret(
            name: name, displayName: displayName, value: value, description: description,
            confirm: confirm, tags: tags, created: Date()
        )
        data!.secrets.append(secret)
        try persist()
        try? accessLog.log(method: "vault.add", secret: name, clientId: clientId, result: "ok")
    }

    func remove(name: String, sessionID: pid_t, clientId: String? = nil) async throws {
        try authorized(sessionID)
        guard let index = data!.secrets.firstIndex(where: {
            $0.name.lowercased() == name.lowercased()
        }) else {
            throw VaultError.secretNotFound(name)
        }
        data!.secrets.remove(at: index)
        try persist()
        try? accessLog.log(method: "vault.remove", secret: name, clientId: clientId, result: "ok")
    }

    func edit(name: String, displayName: String? = nil, value: String? = nil,
              description: String? = nil, confirm: Bool? = nil, tags: [String]? = nil,
              sessionID: pid_t, clientId: String? = nil) async throws {
        try authorized(sessionID)
        guard let index = data!.secrets.firstIndex(where: {
            $0.name.lowercased() == name.lowercased()
        }) else {
            throw VaultError.secretNotFound(name)
        }
        if let dn = displayName {
            try DisplayNameValidation.validate(dn)
            data!.secrets[index].displayName = dn
        }
        if let v = value { data!.secrets[index].value = v }
        if let d = description { data!.secrets[index].description = d }
        if let c = confirm { data!.secrets[index].confirm = c }
        if let t = tags { data!.secrets[index].tags = t }
        data!.secrets[index].updated = Date()
        try persist()
        try? accessLog.log(method: "vault.edit", secret: name, clientId: clientId, result: "ok")
    }

    // MARK: - Config

    func getConfig(sessionID: pid_t) throws -> VaultConfig {
        try authorized(sessionID)
        return data!.config
    }

    func setConfig(ttlSeconds: Int, sessionID: pid_t) async throws -> VaultConfig {
        try authorized(sessionID)
        guard ttlSeconds >= 1 else { throw VaultError.invalidConfig("ttl_seconds must be >= 1") }
        data!.config.ttlSeconds = ttlSeconds
        try persist()
        return data!.config
    }

    // MARK: - Status

    func status(sessionID: pid_t) -> VaultStatus {
        let ttl: Int?
        if let unlocked = unlockedSessions[sessionID], let ttlSeconds = data?.config.ttlSeconds {
            let elapsed = Date().timeIntervalSince(unlocked)
            let remaining = Double(ttlSeconds) - elapsed
            ttl = max(0, Int(remaining))
        } else {
            ttl = nil
        }
        let isSessionLocked = (data == nil) || (unlockedSessions[sessionID] == nil)
        return VaultStatus(
            locked: isSessionLocked,
            ttlRemainingSeconds: ttl,
            secretCount: data?.secrets.count ?? 0
        )
    }

    func checkTTL() {
        guard let ttlSeconds = data?.config.ttlSeconds else { return }
        let cutoff = Date().addingTimeInterval(-Double(ttlSeconds))
        unlockedSessions = unlockedSessions.filter { $0.value > cutoff }
        if unlockedSessions.isEmpty && data != nil {
            zeroState()
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
        lockAll()
        try? store.delete()
        try? keychain.deleteMasterKey()
    }

    // MARK: - Test helper (DEBUG-only)

    #if DEBUG
    func _testForceUnlockTime(sessionID: pid_t, to date: Date) {
        unlockedSessions[sessionID] = date
    }
    #endif

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
