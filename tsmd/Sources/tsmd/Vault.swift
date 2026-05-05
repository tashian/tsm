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
    case invalidConfig(String)
    /// The named secret exists but is project-scoped to roots that do not
    /// contain the calling peer's cwd. Carries the secret name and the bound
    /// roots so the CLI can render an actionable hint.
    case secretOutOfScope(name: String, roots: [String])
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

// MARK: - Scope validation / matching

enum ScopeValidation {
    static let maxRoots = 16

    /// Validate the scope+roots tuple supplied to vault.add. Returns the
    /// normalized roots on success (trailing slash stripped, but no symlink
    /// resolution — that happens client-side at add time).
    static func validate(scope: String, roots: [String]) throws -> [String] {
        switch scope {
        case SecretScope.global:
            guard roots.isEmpty else {
                throw VaultError.invalidConfig("scope=global must have empty roots")
            }
            return []
        case SecretScope.project:
            guard !roots.isEmpty else {
                throw VaultError.invalidConfig("scope=project requires at least one root")
            }
            guard roots.count <= maxRoots else {
                throw VaultError.invalidConfig("scope=project supports at most \(maxRoots) roots")
            }
            return try roots.map { try normalizeRoot($0) }
        default:
            throw VaultError.invalidConfig("unknown scope '\(scope)' (expected 'global' or 'project')")
        }
    }

    /// Normalize a single root: must be absolute, no `..` components, no
    /// trailing slash (except the root "/").
    static func normalizeRoot(_ raw: String) throws -> String {
        guard raw.hasPrefix("/") else {
            throw VaultError.invalidConfig("root must be absolute: '\(raw)'")
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        for comp in components where comp == ".." || comp == "." {
            throw VaultError.invalidConfig("root must be normalized (no '.' or '..' components): '\(raw)'")
        }
        // Strip trailing slash unless the path *is* "/".
        if raw == "/" { return "/" }
        if raw.hasSuffix("/") { return String(raw.dropLast()) }
        return raw
    }
}

enum ScopeMatcher {
    /// True when `cwd` is inside `root` (or equal to it). Both inputs assumed
    /// to be normalized absolute paths. The boundary check guards against
    /// `/foo` matching `/foobar`.
    static func cwdMatchesRoot(cwd: String, root: String) -> Bool {
        if cwd == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return cwd.hasPrefix(prefix)
    }

    /// True when `cwd` is in any of the secret's roots.
    static func inScope(secret: Secret, cwd: String?) -> Bool {
        if secret.scope == SecretScope.global { return true }
        guard let cwd = cwd else { return false }
        return secret.roots.contains(where: { cwdMatchesRoot(cwd: cwd, root: $0) })
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

    /// List secrets visible to the calling peer.
    /// - When `includeAll` is true, returns every secret regardless of scope.
    ///   The CLI uses this for `tsm list --all`.
    /// - Otherwise, returns global secrets plus project-scoped secrets whose
    ///   roots include `peerCwd`. Project secrets bound elsewhere are filtered
    ///   out so an agent in /Users/carl/code/A doesn't even see the names of
    ///   secrets bound to /Users/carl/code/B.
    func list(sessionID: pid_t, peerCwd: String? = nil, includeAll: Bool = false) throws -> [SecretMetadata] {
        try authorized(sessionID)
        let secrets = data!.secrets.filter { secret in
            if includeAll { return true }
            return ScopeMatcher.inScope(secret: secret, cwd: peerCwd)
        }
        return secrets.map { SecretMetadata(from: $0) }
    }

    func get(name: String, sessionID: pid_t, peerCwd: String? = nil,
             clientId: String? = nil) async throws -> Secret {
        try authorized(sessionID)
        guard let secret = data!.secrets.first(where: {
            $0.name.lowercased() == name.lowercased()
        }) else {
            try? accessLog.log(method: "vault.get", secret: name, clientId: clientId, result: "not_found")
            throw VaultError.secretNotFound(name)
        }
        if !ScopeMatcher.inScope(secret: secret, cwd: peerCwd) {
            try? accessLog.log(method: "vault.get", secret: name, clientId: clientId, result: "out_of_scope")
            throw VaultError.secretOutOfScope(name: secret.name, roots: secret.roots)
        }
        if secret.confirm {
            try await auth.authenticate(reason: "Access secret '\(name)'")
        }
        try? accessLog.log(method: "vault.get", secret: name, clientId: clientId, result: "ok")
        return secret
    }

    func add(name: String, displayName: String = "", value: String, description: String,
             confirm: Bool = false, tags: [String] = [],
             scope: String = SecretScope.global, roots: [String] = [],
             sessionID: pid_t, clientId: String? = nil) async throws {
        try authorized(sessionID)
        try NameValidation.validate(name)
        try DisplayNameValidation.validate(displayName)
        let normalizedRoots = try ScopeValidation.validate(scope: scope, roots: roots)
        guard !data!.secrets.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw VaultError.secretAlreadyExists(name)
        }
        let secret = Secret(
            name: name, displayName: displayName, value: value, description: description,
            confirm: confirm, tags: tags, created: Date(),
            scope: scope, roots: normalizedRoots
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
        // A session is fresh only if it's in the map AND within TTL. The
        // 15s polling sweep means an expired entry can linger briefly; we
        // treat it as locked here so status() doesn't disagree with the
        // next CRUD call (which goes through authorized()).
        var ttl: Int? = nil
        var freshlyUnlocked = false
        if let unlocked = unlockedSessions[sessionID], let ttlSeconds = data?.config.ttlSeconds {
            let elapsed = Date().timeIntervalSince(unlocked)
            if elapsed < Double(ttlSeconds) {
                ttl = max(0, Int(Double(ttlSeconds) - elapsed))
                freshlyUnlocked = true
            }
        }
        let isSessionLocked = (data == nil) || !freshlyUnlocked
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
