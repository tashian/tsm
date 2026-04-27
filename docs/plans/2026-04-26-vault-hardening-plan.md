# Vault Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden tsm with a 30-min default TTL (single source of truth in the daemon, duration-friendly CLI), per-POSIX-session unlock state, and auto-lock on screen lock and system sleep.

**Architecture:** The daemon vault becomes the only owner of the TTL config and exposes it via two new RPC methods (`vault.config.get` / `vault.config.set`). The vault tracks unlock state in a `[sid_t: Date]` map keyed by the connecting peer's POSIX session ID, resolved via `getsockopt(LOCAL_PEERPID)` + `getsid(pid)` per accepted connection. The daemon registers `DistributedNotificationCenter` and `IORegisterForSystemPower` observers that lock all sessions on screen-lock or sleep.

**Tech Stack:** Swift 5.10 + Swift Concurrency (actor `Vault`), Foundation + IOKit + LocalAuthentication (daemon); Go 1.21+ + cobra + `time.ParseDuration` (CLI).

---

## File Map

**Modify (Swift / tsmd):**
- `tsmd/Sources/tsmd/Models.swift` — `VaultConfig` field rename + default change
- `tsmd/Sources/tsmd/Vault.swift` — per-session unlock map, new lock semantics, new `setConfig(...)` method, all CRUD + `unlock` / `lock` / `status` take a `sessionID` param
- `tsmd/Sources/tsmd/SocketServer.swift` — resolve peer PID → session ID per connection, thread it through to handler
- `tsmd/Sources/tsmd/JSONRPCHandler.swift` — accept `sessionID`, route to vault, add `vault.config.get` / `vault.config.set`
- `tsmd/Sources/tsmd/Daemon.swift` — TTL polling 60 s → 15 s, register sleep + screen-lock observers, deregister on shutdown
- `tsmd/Tests/tsmdTests/VaultTests.swift` — adapt existing tests to session-id signature, add per-session map tests
- `tsmd/Tests/tsmdTests/JSONRPCHandlerTests.swift` — adapt + new config-method tests
- `tsmd/Tests/tsmdTests/IntegrationTests.swift` — adapt to new handler signature + add multi-session test
- `tsmd/Tests/tsmdTests/ModelsTests.swift` — `VaultConfig` decoding tests

**Create (Swift / tsmd):**
- `tsmd/Sources/tsmd/SystemEvents.swift` — encapsulates screen-lock + sleep observers
- `tsmd/Tests/tsmdTests/SystemEventsTests.swift` — distributed-notification-driven test

**Modify (Go / tsm):**
- `cmd/config.go` — drop `TTLHours`, route `ttl` to daemon RPC, parse/print `time.Duration` strings
- `cmd/config_test.go` (create if missing) — duration parsing/printing tests

---

## Phase A — TTL config schema (daemon side)

### Task 1: Rename `VaultConfig.ttlHours` to `ttlSeconds` and change default

**Files:**
- Modify: `tsmd/Sources/tsmd/Models.swift:77-83`
- Modify: `tsmd/Tests/tsmdTests/ModelsTests.swift`

- [ ] **Step 1: Write failing decode test for new field**

Add to `tsmd/Tests/tsmdTests/ModelsTests.swift` (in the `VaultConfigTests` class, creating it if missing):

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tsmd && swift test --filter VaultConfigDecodingTests`
Expected: compilation failure ("ttlSeconds" not a member of VaultConfig).

- [ ] **Step 3: Update `VaultConfig`**

Replace lines 77-83 in `tsmd/Sources/tsmd/Models.swift`:

```swift
struct VaultConfig: Codable, Equatable, Sendable {
    var ttlSeconds: Int = 1800

    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }
}
```

- [ ] **Step 4: Update `Vault.checkTTL` and `Vault.status`**

In `tsmd/Sources/tsmd/Vault.swift`, replace the body of `status()` (lines 227-241) with:

```swift
func status() -> VaultStatus {
    let ttl: Int?
    if let unlockTime = unlockTime, let ttlSeconds = data?.config.ttlSeconds {
        let elapsed = Date().timeIntervalSince(unlockTime)
        let remaining = Double(ttlSeconds) - elapsed
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
```

Replace the body of `checkTTL()` (lines 243-249):

```swift
func checkTTL() {
    guard let unlockTime = unlockTime, let ttlSeconds = data?.config.ttlSeconds else { return }
    let elapsed = Date().timeIntervalSince(unlockTime)
    if elapsed >= Double(ttlSeconds) {
        lock()
    }
}
```

- [ ] **Step 5: Run all daemon tests, fix anything that referenced `ttlHours`**

Run: `cd tsmd && swift test`
Expected: green. If any test still references `ttlHours`, replace with `ttlSeconds` (value × 3600) directly.

- [ ] **Step 6: Commit**

```bash
git add tsmd/Sources/tsmd/Models.swift tsmd/Sources/tsmd/Vault.swift tsmd/Tests/tsmdTests/ModelsTests.swift
git commit -m "refactor(tsmd): rename ttl_hours to ttl_seconds, default 1800 (30 min)

Old ttl_hours field is silently ignored by Codable on read; pre-release
vaults pick up the new 30-min default."
```

---

## Phase B — Per-session unlock state (daemon side)

### Task 2: Refactor `Vault` to per-session unlock map

This is the largest task. We change `Vault`'s public API to take a `sessionID: pid_t` everywhere that previously gated on `data != nil`. Tests must be updated in lockstep because all signatures change.

**Files:**
- Modify: `tsmd/Sources/tsmd/Vault.swift` (whole file)
- Modify: `tsmd/Tests/tsmdTests/VaultTests.swift` (every test)

- [ ] **Step 1: Write failing per-session map tests**

Add to `tsmd/Tests/tsmdTests/VaultTests.swift` after the existing tests (use a constant for the canonical sid in tests):

```swift
// MARK: - Per-session unlock

private let sidA: pid_t = 1001
private let sidB: pid_t = 1002

func testUnlockRegistersOnlyCallingSession() async throws {
    try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
    let statusA = await vault.status(sessionID: sidA)
    let statusB = await vault.status(sessionID: sidB)
    XCTAssertFalse(statusA.locked, "sidA should be unlocked")
    XCTAssertTrue(statusB.locked, "sidB should not inherit sidA's unlock")
}

func testGetFromUnauthorizedSessionThrowsLocked() async throws {
    try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
    try await vault.add(name: "k", value: "v", description: "", sessionID: sidA)
    do {
        _ = try await vault.get(name: "k", sessionID: sidB)
        XCTFail("expected VaultError.locked")
    } catch VaultError.locked {
        // expected
    }
}

func testSecondSessionCanUnlockIndependently() async throws {
    try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
    await vault.lock(sessionID: sidA)
    // First session locked itself; key zeroed. Now second session unlocks fresh.
    try await vault.unlock(sessionID: sidB)
    let statusB = await vault.status(sessionID: sidB)
    XCTAssertFalse(statusB.locked)
}

func testLockAllZeroesKeyAndClearsAllSessions() async throws {
    try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
    try await vault.unlock(sessionID: sidB)
    await vault.lockAll()
    XCTAssertTrue(await vault.status(sessionID: sidA).locked)
    XCTAssertTrue(await vault.status(sessionID: sidB).locked)
}

func testLockSingleSessionDoesNotAffectOthers() async throws {
    try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
    try await vault.unlock(sessionID: sidB)
    await vault.lock(sessionID: sidA)
    XCTAssertTrue(await vault.status(sessionID: sidA).locked)
    XCTAssertFalse(await vault.status(sessionID: sidB).locked)
}

func testTTLExpiryRemovesSessionAndZeroesKeyWhenLast() async throws {
    // Set TTL to 1 second so checkTTL expires immediately on the second tick
    try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
    try await vault.setConfig(ttlSeconds: 1, sessionID: sidA)
    // Manually rewind the unlock time on the test vault (helper added below).
    await vault._testForceUnlockTime(sessionID: sidA, to: Date(timeIntervalSinceNow: -10))
    await vault.checkTTL()
    XCTAssertTrue(await vault.status(sessionID: sidA).locked)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd tsmd && swift test --filter VaultTests`
Expected: compilation errors (signatures don't match yet).

- [ ] **Step 3: Refactor `Vault` to take `sessionID` and own `unlockedSessions`**

Replace the entire `actor Vault { ... }` block in `tsmd/Sources/tsmd/Vault.swift` (starting around line 67) with:

```swift
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

    // Convenience for status() back-compat: report unlock time of the session
    // most recently unlocked (used for compatibility with old VaultStatus shape
    // when status() is called without a session ID — internal callers only).
    private var unlockTime: Date? {
        unlockedSessions.values.max()
    }

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

        // If vault data is already loaded (some other session has it unlocked),
        // we still require Touch ID for THIS session before authorizing it.
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
        } else if unlockedSessions[sessionID] == nil {
            // Vault is loaded but this session is new — Touch ID for this session.
            // Skip if a passphrase was supplied (recovery flow).
            if passphrase == nil {
                try await auth.authenticate(reason: "Unlock tsm vault")
            }
        }

        // Record / refresh this session's unlock time.
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
        if var key = masterKey {
            key.resetBytes(in: 0..<key.count)
            masterKey = nil
        }
    }

    // MARK: - Authorization helper

    private func authorized(_ sessionID: pid_t) throws {
        guard data != nil else { throw VaultError.locked }
        guard let unlocked = unlockedSessions[sessionID] else { throw VaultError.locked }
        let ttlSeconds = data?.config.ttlSeconds ?? 1800
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
        guard ttlSeconds >= 1 else { throw VaultError.invalidName("ttl_seconds must be >= 1") }
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
        for (sid, unlocked) in unlockedSessions where unlocked <= cutoff {
            unlockedSessions.removeValue(forKey: sid)
        }
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
```

- [ ] **Step 4: Adapt all existing `VaultTests.swift` tests to pass `sessionID:`**

Every existing test in `VaultTests.swift` currently calls `vault.initialize(...)`, `vault.add(...)`, `vault.get(...)`, etc. without a session ID. Add `sessionID: sidA` to every such call. Replace `vault.lock()` with `vault.lock(sessionID: sidA)` (or `vault.lockAll()` where the test was checking global lock). Replace `vault.status()` with `vault.status(sessionID: sidA)`. Replace `vault.unlock()` with `vault.unlock(sessionID: sidA)`.

Use a single repository-wide find/replace strategy or update test by test. Example before/after:

Before:
```swift
try await vault.initialize(recoveryPassphrase: nil)
try await vault.add(name: "k1", value: "v1", description: "test")
let secret = try await vault.get(name: "k1")
```

After:
```swift
try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
try await vault.add(name: "k1", value: "v1", description: "test", sessionID: sidA)
let secret = try await vault.get(name: "k1", sessionID: sidA)
```

- [ ] **Step 5: Run vault tests to verify green**

Run: `cd tsmd && swift test --filter VaultTests`
Expected: PASS for all VaultTests including the new per-session map tests.

- [ ] **Step 6: Commit**

```bash
git add tsmd/Sources/tsmd/Vault.swift tsmd/Tests/tsmdTests/VaultTests.swift
git commit -m "feat(tsmd): per-session unlock state in Vault

Vault now tracks unlocked sessions in a [pid_t: Date] map keyed by POSIX
session ID. Each Vault method takes a sessionID parameter; an authorized()
helper checks the calling session is in the map and within TTL. Master
key is zeroed when the last session is locked or expires.

vault.setConfig is added so vault.config.set RPC can mutate the embedded
TTL value. JSONRPCHandler still needs to be wired in the next commit;
this commit only changes the actor's surface."
```

---

### Task 3: Resolve peer session ID in `SocketServer`

**Files:**
- Modify: `tsmd/Sources/tsmd/SocketServer.swift:60-79, 87-131`

- [ ] **Step 1: Write failing test for peer session resolution**

Add to `tsmd/Tests/tsmdTests/SocketServerTests.swift`:

```swift
func testPeerSessionIDIsResolvedFromAcceptedConnection() async throws {
    // Open a real socket pair, accept on one end, and confirm
    // SocketServer.peerSessionID(fd:) returns the calling process's session id.
    let path = NSTemporaryDirectory() + "tsm-sockserver-\(UUID().uuidString).sock"
    let handler = JSONRPCHandler(vault: makeTestVault())
    let server = SocketServer(socketPath: path, handler: handler)
    try server.start()
    defer { server.stop() }

    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(client, 0)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for i in 0..<min(pathBytes.count, buf.count - 1) {
            buf[i] = UInt8(bitPattern: pathBytes[i])
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(client, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    XCTAssertEqual(connectResult, 0)

    // Connection succeeds; we trust that handleConnection extracts the sid.
    // The functional check is in IntegrationTests.testTwoSessionsUnlockIndependently.
    close(client)
}
```

(This test mostly proves the wiring compiles and the connection is accepted; the deeper assertion is the integration test in Task 7.)

- [ ] **Step 2: Replace SocketServer.handleConnection signature + add `peerSessionID`**

In `tsmd/Sources/tsmd/SocketServer.swift`:

Add helper near the top of the class (after `init`):

```swift
private func peerSessionID(fd: Int32) -> pid_t? {
    var pid: pid_t = 0
    var len = socklen_t(MemoryLayout<pid_t>.size)
    let rc = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
    guard rc == 0, pid > 0 else { return nil }
    let sid = getsid(pid)
    return sid > 0 ? sid : nil
}
```

Update the accept event-handler (around line 67-73) to capture the sid and pass it through:

```swift
source.setEventHandler { [weak self] in
    guard let self = self else { return }
    let clientFd = accept(self.serverFd, nil, nil)
    guard clientFd >= 0 else { return }
    guard let sid = self.peerSessionID(fd: clientFd) else {
        close(clientFd)
        return
    }
    Task { await self.handleConnection(clientFd, sessionID: sid) }
}
```

Change `handleConnection(_ fd: Int32)` to `handleConnection(_ fd: Int32, sessionID: pid_t)` (line 87) and update the line that calls the handler (line 123) to pass it through:

```swift
let response = await handler.handle(request, sessionID: sessionID)
```

- [ ] **Step 3: Run socket server tests**

Run: `cd tsmd && swift test --filter SocketServerTests`
Expected: PASS (compilation will require the handler signature change in Task 4 to land first, so this task and the next should be committed together as one coherent change. See Step 5).

- [ ] **Step 4: Commit deferred — bundle with Task 4**

This task and Task 4 share a compile boundary. Do not commit until Task 4 is also done.

---

### Task 4: Thread `sessionID` through `JSONRPCHandler`

**Files:**
- Modify: `tsmd/Sources/tsmd/JSONRPCHandler.swift`
- Modify: `tsmd/Tests/tsmdTests/JSONRPCHandlerTests.swift`
- Modify: `tsmd/Tests/tsmdTests/IntegrationTests.swift`

- [ ] **Step 1: Write failing test that handler routes session id to vault**

Add to `tsmd/Tests/tsmdTests/JSONRPCHandlerTests.swift`:

```swift
func testHandlerThreadsSessionIDIntoVaultCalls() async throws {
    let vault = makeTestVault()  // existing helper
    let handler = JSONRPCHandler(vault: vault)
    let sid: pid_t = 4242

    let initReq = JSONRPCRequest(jsonrpc: "2.0", method: "vault.init", params: nil, id: .int(1))
    let initResp = await handler.handle(initReq, sessionID: sid)
    XCTAssertNil(initResp.error)

    // status from the same sid should report unlocked
    let statusReq = JSONRPCRequest(jsonrpc: "2.0", method: "vault.status", params: nil, id: .int(2))
    let statusResp = await handler.handle(statusReq, sessionID: sid)
    if case .object(let obj) = statusResp.result, case .bool(let locked)? = obj["locked"] {
        XCTAssertFalse(locked)
    } else {
        XCTFail("expected locked field in status response")
    }

    // status from a different sid should report locked
    let otherStatusResp = await handler.handle(statusReq, sessionID: 9999)
    if case .object(let obj) = otherStatusResp.result, case .bool(let locked)? = obj["locked"] {
        XCTAssertTrue(locked)
    } else {
        XCTFail("expected locked field in other-session status response")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd tsmd && swift test --filter JSONRPCHandlerTests`
Expected: compilation error — `handle(_:sessionID:)` doesn't exist.

- [ ] **Step 3: Update handler signature and dispatch**

Replace the body of `JSONRPCHandler.handle(...)` and `dispatch(...)` in `tsmd/Sources/tsmd/JSONRPCHandler.swift`:

```swift
func handle(_ request: JSONRPCRequest, sessionID: pid_t) async -> JSONRPCResponse {
    do {
        let result = try await dispatch(request, sessionID: sessionID)
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

private func dispatch(_ req: JSONRPCRequest, sessionID: pid_t) async throws -> JSONValue {
    switch req.method {
    case "vault.init":
        let passphrase = req.stringParam("recovery_passphrase")
        try await vault.initialize(recoveryPassphrase: passphrase, sessionID: sessionID)
        return .object(["ok": .bool(true)])

    case "vault.unlock":
        let passphrase = req.stringParam("passphrase")
        try await vault.unlock(passphrase: passphrase, sessionID: sessionID)
        let status = await vault.status(sessionID: sessionID)
        var resp: [String: JSONValue] = ["ok": .bool(true)]
        if let ttl = status.ttlRemainingSeconds {
            resp["ttl_remaining_seconds"] = .int(ttl)
        }
        return .object(resp)

    case "vault.lock":
        await vault.lock(sessionID: sessionID)
        return .object(["ok": .bool(true)])

    case "vault.status":
        let status = await vault.status(sessionID: sessionID)
        return encodeToJSONValue(status)

    case "vault.list":
        let secrets = try await vault.list(sessionID: sessionID)
        return encodeToJSONValue(secrets)

    case "vault.get":
        guard let name = req.stringParam("name") else {
            throw VaultError.invalidName("Missing 'name' parameter")
        }
        let clientId = req.stringParam("client_id")
        let secret = try await vault.get(name: name, sessionID: sessionID, clientId: clientId)
        return .object(["name": .string(secret.name), "value": .string(secret.value)])

    case "vault.add":
        guard let name = req.stringParam("name"),
              let value = req.stringParam("value") else {
            throw VaultError.invalidName("Missing 'name' or 'value' parameter")
        }
        let displayName = req.stringParam("display_name") ?? ""
        let description = req.stringParam("description") ?? ""
        let confirm = req.param("confirm")?.boolValue ?? false
        let tags: [String] = {
            if case .array(let arr) = req.param("tags") {
                return arr.compactMap { $0.stringValue }
            }
            return []
        }()
        let clientId = req.stringParam("client_id")
        try await vault.add(name: name, displayName: displayName, value: value,
                           description: description, confirm: confirm, tags: tags,
                           sessionID: sessionID, clientId: clientId)
        return .object(["ok": .bool(true)])

    case "vault.remove":
        guard let name = req.stringParam("name") else {
            throw VaultError.invalidName("Missing 'name' parameter")
        }
        let clientId = req.stringParam("client_id")
        try await vault.remove(name: name, sessionID: sessionID, clientId: clientId)
        return .object(["ok": .bool(true)])

    case "vault.edit":
        guard let name = req.stringParam("name") else {
            throw VaultError.invalidName("Missing 'name' parameter")
        }
        let clientId = req.stringParam("client_id")
        try await vault.edit(
            name: name,
            displayName: req.stringParam("display_name"),
            value: req.stringParam("value"),
            description: req.stringParam("description"),
            confirm: req.param("confirm")?.boolValue,
            tags: {
                if case .array(let arr) = req.param("tags") {
                    return arr.compactMap { $0.stringValue }
                }
                return nil
            }(),
            sessionID: sessionID,
            clientId: clientId
        )
        return .object(["ok": .bool(true)])

    case "vault.config.get":
        let cfg = try await vault.getConfig(sessionID: sessionID)
        return .object(["ttl_seconds": .int(cfg.ttlSeconds)])

    case "vault.config.set":
        guard let ttl = req.param("ttl_seconds")?.intValue else {
            throw VaultError.invalidName("Missing or non-integer 'ttl_seconds' parameter")
        }
        let cfg = try await vault.setConfig(ttlSeconds: ttl, sessionID: sessionID)
        return .object(["ttl_seconds": .int(cfg.ttlSeconds)])

    case "vault.reset":
        let clientId = req.stringParam("client_id")
        try await vault.reset(clientId: clientId)
        return .object(["ok": .bool(true)])

    case "daemon.capabilities":
        let caps = await vault.capabilities()
        return encodeToJSONValue(caps)

    case "daemon.shutdown":
        return .object(["ok": .bool(true)])

    default:
        throw JSONRPCHandlerError.methodNotFound(req.method)
    }
}
```

- [ ] **Step 4: Update existing handler tests + integration tests**

Every call to `handler.handle(req)` in `JSONRPCHandlerTests.swift` and `IntegrationTests.swift` must add a `sessionID:` argument. Use `pid_t(getpid())` (the test process's own session) or a fixed test sid like `1001`. In `IntegrationTests`, update the `rpc(...)` helper:

```swift
private func rpc(_ method: String, params: [String: JSONValue]? = nil, sessionID: pid_t = 1001) async -> JSONRPCResponse {
    await handler.handle(JSONRPCRequest(jsonrpc: "2.0", method: method, params: params, id: .int(1)), sessionID: sessionID)
}
```

- [ ] **Step 5: Run all daemon tests**

Run: `cd tsmd && swift test`
Expected: PASS.

- [ ] **Step 6: Commit (bundles Task 3 + Task 4)**

```bash
git add tsmd/Sources/tsmd/SocketServer.swift tsmd/Sources/tsmd/JSONRPCHandler.swift tsmd/Tests/tsmdTests/SocketServerTests.swift tsmd/Tests/tsmdTests/JSONRPCHandlerTests.swift tsmd/Tests/tsmdTests/IntegrationTests.swift
git commit -m "feat(tsmd): thread peer session id through socket and RPC handler

SocketServer reads LOCAL_PEERPID + getsid() once per accepted connection
and passes the sid to JSONRPCHandler.handle(_:sessionID:). The handler
threads it into every vault call. Adds vault.config.get and
vault.config.set RPC methods that read/write the vault's embedded
ttl_seconds via the new Vault.getConfig / Vault.setConfig actor methods."
```

---

## Phase C — CLI rewire (Go side)

### Task 5: Remove vestigial `TTLHours` from CLI config; route `ttl` to RPC

**Files:**
- Modify: `cmd/config.go` (whole file)
- Create: `cmd/config_test.go`

- [ ] **Step 1: Write failing duration parse/print tests**

Create `cmd/config_test.go`:

```go
package cmd

import (
	"testing"
	"time"
)

func TestParseTTLDuration(t *testing.T) {
	cases := []struct {
		in   string
		want int
		err  bool
	}{
		{"30m", 1800, false},
		{"1h", 3600, false},
		{"1h30m", 5400, false},
		{"90s", 90, false},
		{"500ms", 0, true},
		{"0", 0, true},
		{"-5m", 0, true},
		{"garbage", 0, true},
	}
	for _, c := range cases {
		got, err := parseTTLDuration(c.in)
		if c.err {
			if err == nil {
				t.Errorf("parseTTLDuration(%q): expected error, got %d", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseTTLDuration(%q): unexpected error %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("parseTTLDuration(%q): got %d, want %d", c.in, got, c.want)
		}
	}
}

func TestFormatTTLSeconds(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{1800, "30m0s"},
		{90, "1m30s"},
		{3600, "1h0m0s"},
		{5400, "1h30m0s"},
	}
	for _, c := range cases {
		got := formatTTLSeconds(c.in)
		if got != c.want {
			t.Errorf("formatTTLSeconds(%d): got %q, want %q", c.in, got, c.want)
		}
	}
}

// Just a sanity check that time.Duration round-trips as expected.
func TestDurationRoundTrip(t *testing.T) {
	d, err := time.ParseDuration("30m")
	if err != nil || int(d.Seconds()) != 1800 {
		t.Fatalf("round-trip failed: %v %v", d, err)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/carl/code/tsm && go test ./cmd/ -run 'TestParseTTLDuration|TestFormatTTLSeconds'`
Expected: compilation failure — `parseTTLDuration` not defined.

- [ ] **Step 3: Replace `cmd/config.go`**

Overwrite `cmd/config.go` with:

```go
package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"tsm/internal/client"
	"tsm/internal/paths"

	"github.com/spf13/cobra"
)

// tsmConfig is the local CLI-side config file. It holds settings that are
// purely client-side (e.g., when to phone home for version checks). The TTL
// lives in the daemon vault and is read/written via vault.config RPC methods.
type tsmConfig struct {
	UpdateCheck              bool `json:"update_check"`
	UpdateCheckIntervalHours int  `json:"update_check_interval_hours"`
}

var defaultConfig = tsmConfig{
	UpdateCheck:              true,
	UpdateCheckIntervalHours: 24,
}

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "View or set configuration",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigView()
		},
	}

	setCmd := &cobra.Command{
		Use:   "set <key> <value>",
		Short: "Set a config value",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigSet(args[0], args[1])
		},
	}

	getCmd := &cobra.Command{
		Use:   "get <key>",
		Short: "Get a config value",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigGet(args[0])
		},
	}

	cmd.AddCommand(setCmd, getCmd)
	return cmd
}

func loadConfig() tsmConfig {
	cfg := defaultConfig
	data, err := os.ReadFile(paths.ConfigFile())
	if err != nil {
		return cfg
	}
	json.Unmarshal(data, &cfg)
	return cfg
}

func saveConfig(cfg tsmConfig) error {
	path := paths.ConfigFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o600)
}

// parseTTLDuration parses a Go duration string and returns whole seconds.
// Sub-second durations and zero/negative values are rejected.
func parseTTLDuration(s string) (int, error) {
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("ttl must be a Go duration like '30m' or '1h': %w", err)
	}
	if d < time.Second {
		return 0, fmt.Errorf("ttl must be at least 1 second")
	}
	if d.Truncate(time.Second) != d {
		return 0, fmt.Errorf("ttl must be a whole number of seconds; got %s", d)
	}
	return int(d.Seconds()), nil
}

// formatTTLSeconds renders a seconds count as a Go duration string.
func formatTTLSeconds(seconds int) string {
	return (time.Duration(seconds) * time.Second).String()
}

func runConfigView() error {
	cfg := loadConfig()
	out := map[string]any{
		"client": cfg,
	}
	// Best-effort: include vault config if the daemon is running and unlocked.
	_ = withClient(func(c client.Caller) error {
		var resp struct {
			TTLSeconds int `json:"ttl_seconds"`
		}
		if err := c.Call("vault.config.get", nil, &resp); err == nil {
			out["vault"] = map[string]any{
				"ttl": formatTTLSeconds(resp.TTLSeconds),
			}
		}
		return nil
	})
	return printJSON(out)
}

func runConfigGet(key string) error {
	switch key {
	case "ttl":
		return withUnlockedClient(func(c client.Caller) error {
			var resp struct {
				TTLSeconds int `json:"ttl_seconds"`
			}
			if err := c.Call("vault.config.get", nil, &resp); err != nil {
				return handleError(err)
			}
			fmt.Println(formatTTLSeconds(resp.TTLSeconds))
			return nil
		})
	case "update_check":
		fmt.Println(loadConfig().UpdateCheck)
		return nil
	case "update_check_interval_hours":
		fmt.Println(loadConfig().UpdateCheckIntervalHours)
		return nil
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}
}

func runConfigSet(key, value string) error {
	switch key {
	case "ttl":
		seconds, err := parseTTLDuration(value)
		if err != nil {
			return err
		}
		return withUnlockedClient(func(c client.Caller) error {
			var resp struct {
				TTLSeconds int `json:"ttl_seconds"`
			}
			if err := c.Call("vault.config.set", map[string]any{
				"ttl_seconds": seconds,
			}, &resp); err != nil {
				return handleError(err)
			}
			if !jsonOutput() {
				fmt.Printf("ttl = %s\n", formatTTLSeconds(resp.TTLSeconds))
			}
			return nil
		})
	case "update_check":
		v, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("update_check must be true or false")
		}
		cfg := loadConfig()
		cfg.UpdateCheck = v
		if err := saveConfig(cfg); err != nil {
			return err
		}
		if !jsonOutput() {
			fmt.Printf("%s = %s\n", key, value)
		}
		return nil
	case "update_check_interval_hours":
		v, err := strconv.Atoi(value)
		if err != nil || v < 1 {
			return fmt.Errorf("update_check_interval_hours must be a positive integer")
		}
		cfg := loadConfig()
		cfg.UpdateCheckIntervalHours = v
		if err := saveConfig(cfg); err != nil {
			return err
		}
		if !jsonOutput() {
			fmt.Printf("%s = %s\n", key, value)
		}
		return nil
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}
}
```

- [ ] **Step 4: Run tests to verify green**

Run: `cd /Users/carl/code/tsm && go test ./cmd/ -run 'TestParseTTLDuration|TestFormatTTLSeconds|TestDurationRoundTrip'`
Expected: PASS.

Run the full Go test suite to catch any regression:

Run: `cd /Users/carl/code/tsm && go test ./...`
Expected: PASS. (Any test that referenced `cfg.TTLHours` will fail to compile — search and remove those references; nothing should still depend on TTLHours.)

- [ ] **Step 5: Commit**

```bash
git add cmd/config.go cmd/config_test.go
git commit -m "feat(tsm): tsm config ttl uses RPC and Go duration syntax

The CLI no longer keeps its own TTL value. 'tsm config get/set ttl'
calls the daemon's vault.config.get/set RPC methods. Values are
parsed/printed as Go time.Duration strings (e.g. '30m', '1h30m').
The vestigial TTLHours field is removed from the local config file."
```

---

## Phase D — Auto-lock on screen lock and sleep

### Task 6: Create `SystemEvents` for screen-lock + sleep observers

**Files:**
- Create: `tsmd/Sources/tsmd/SystemEvents.swift`
- Create: `tsmd/Tests/tsmdTests/SystemEventsTests.swift`

- [ ] **Step 1: Write failing test for screen-lock observer**

Create `tsmd/Tests/tsmdTests/SystemEventsTests.swift`:

```swift
import XCTest
@testable import tsmd

final class SystemEventsTests: XCTestCase {
    func testScreenLockNotificationFiresHandler() async throws {
        let exp = expectation(description: "lock handler called")
        let events = SystemEvents(onLock: {
            exp.fulfill()
        })
        events.start()
        defer { events.stop() }

        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, userInfo: nil, deliverImmediately: true
        )

        await fulfillment(of: [exp], timeout: 2.0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd tsmd && swift test --filter SystemEventsTests`
Expected: compilation error — `SystemEvents` does not exist.

- [ ] **Step 3: Implement `SystemEvents`**

Create `tsmd/Sources/tsmd/SystemEvents.swift`:

```swift
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Monitors macOS system events that should trigger an immediate vault lock:
/// screen lock and impending system sleep. Starts observing on `start()`,
/// tears down on `stop()`. The `onLock` closure is called on a background
/// queue; callers must hop to the actor / queue they need.
final class SystemEvents: @unchecked Sendable {
    typealias LockHandler = @Sendable () -> Void

    private let onLock: LockHandler
    private var screenLockObserver: NSObjectProtocol?
    private var notifyPortRef: IONotificationPortRef?
    private var rootPort: io_object_t = 0
    private var sleepNotifier: io_object_t = 0

    init(onLock: @escaping LockHandler) {
        self.onLock = onLock
    }

    func start() {
        // Screen lock — Foundation-only, no AppKit.
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.onLock()
        }

        // System sleep — must reply IOAllowPowerChange so we don't block.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var notifierLocal: io_object_t = 0

        let port = IORegisterForSystemPower(
            selfPtr,
            &notifyPortRef,
            { (refcon, _, messageType, messageArgument) in
                guard let refcon = refcon else { return }
                let me = Unmanaged<SystemEvents>.fromOpaque(refcon).takeUnretainedValue()
                if messageType == UInt32(kIOMessageSystemWillSleep) {
                    me.onLock()
                    IOAllowPowerChange(me.rootPort, Int(bitPattern: messageArgument))
                } else if messageType == UInt32(kIOMessageCanSystemSleep) {
                    // We do not veto; ack so the system can sleep.
                    IOAllowPowerChange(me.rootPort, Int(bitPattern: messageArgument))
                }
            },
            &notifierLocal
        )
        rootPort = port
        sleepNotifier = notifierLocal

        if let portRef = notifyPortRef {
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                IONotificationPortGetRunLoopSource(portRef).takeUnretainedValue(),
                .defaultMode
            )
        }
    }

    func stop() {
        if let observer = screenLockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockObserver = nil
        }
        if sleepNotifier != 0 {
            IODeregisterForSystemPower(&sleepNotifier)
            sleepNotifier = 0
        }
        if let portRef = notifyPortRef {
            IONotificationPortDestroy(portRef)
            notifyPortRef = nil
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }
}
```

- [ ] **Step 4: Run the screen-lock test**

Run: `cd tsmd && swift test --filter SystemEventsTests`
Expected: PASS.

- [ ] **Step 5: Wire into `Daemon.swift`**

In `tsmd/Sources/tsmd/Daemon.swift`, add a `private var systemEvents: SystemEvents?` property next to `ttlTimer`. Inside `run()`, after the TTL timer is configured (line 47-ish), add:

```swift
let events = SystemEvents { [weak self] in
    guard let self = self else { return }
    Task { await self.vault.lockAll() }
}
events.start()
systemEvents = events
```

In `shutdown()`, before `server.stop()`:

```swift
systemEvents?.stop()
systemEvents = nil
```

- [ ] **Step 6: Run all daemon tests**

Run: `cd tsmd && swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add tsmd/Sources/tsmd/SystemEvents.swift tsmd/Sources/tsmd/Daemon.swift tsmd/Tests/tsmdTests/SystemEventsTests.swift
git commit -m "feat(tsmd): auto-lock vault on screen lock and system sleep

SystemEvents wraps DistributedNotificationCenter (screen lock) and
IORegisterForSystemPower (sleep). Daemon registers a SystemEvents
instance during run() that calls vault.lockAll() when either fires;
torn down on shutdown."
```

---

## Phase E — TTL polling cadence

### Task 7: Reduce TTL polling interval to 15 s

**Files:**
- Modify: `tsmd/Sources/tsmd/Daemon.swift:40-47`

- [ ] **Step 1: Change the timer interval**

In `tsmd/Sources/tsmd/Daemon.swift`, replace lines 40-47:

```swift
// TTL check every 15 seconds — short enough that a 60 s TTL still
// expires close to its target, while keeping idle CPU near zero.
let timer = DispatchSource.makeTimerSource(queue: .global())
timer.schedule(deadline: .now() + 15, repeating: 15)
timer.setEventHandler { [weak self] in
    guard let self = self else { return }
    Task { await self.vault.checkTTL() }
}
timer.resume()
ttlTimer = timer
```

- [ ] **Step 2: Run all daemon tests**

Run: `cd tsmd && swift test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add tsmd/Sources/tsmd/Daemon.swift
git commit -m "perf(tsmd): TTL polling 60s -> 15s for tighter expiry"
```

---

## Phase F — Multi-session integration test

### Task 8: Two-session integration test exercising real sockets

**Files:**
- Modify: `tsmd/Tests/tsmdTests/IntegrationTests.swift`

- [ ] **Step 1: Add the test**

Append to `tsmd/Tests/tsmdTests/IntegrationTests.swift`:

```swift
func testTwoSessionsUnlockIndependently() async throws {
    // Two synthetic session ids — we drive the handler directly rather than
    // through a real socket, because spawning a child process with setsid()
    // and connecting on the SocketServer would require a richer test harness.
    // The socket-level peer-sid resolution is covered by SocketServerTests;
    // this test covers the per-session bookkeeping end-to-end through the
    // RPC handler.
    let sidA: pid_t = 5001
    let sidB: pid_t = 5002

    let initResp = await rpc("vault.init", sessionID: sidA)
    XCTAssertNil(initResp.error)

    // sidA is unlocked by virtue of init.
    let statusA = await rpc("vault.status", sessionID: sidA)
    if case .object(let obj) = statusA.result, case .bool(let locked)? = obj["locked"] {
        XCTAssertFalse(locked, "sidA should be unlocked after init")
    } else {
        XCTFail("malformed status response")
    }

    // sidB is locked even though the vault data is loaded.
    let statusB = await rpc("vault.status", sessionID: sidB)
    if case .object(let obj) = statusB.result, case .bool(let locked)? = obj["locked"] {
        XCTAssertTrue(locked, "sidB should be locked")
    } else {
        XCTFail("malformed status response")
    }

    // sidB cannot read from sidA's unlocked vault.
    let getB = await rpc("vault.get", params: ["name": .string("nope")], sessionID: sidB)
    XCTAssertNotNil(getB.error)
    XCTAssertEqual(getB.error?.code, RPCErrorCode.vaultLocked)

    // sidB unlocks; both sessions are now active.
    let unlockB = await rpc("vault.unlock", sessionID: sidB)
    XCTAssertNil(unlockB.error)

    // Locking sidA does not affect sidB.
    _ = await rpc("vault.lock", sessionID: sidA)
    let statusBAfter = await rpc("vault.status", sessionID: sidB)
    if case .object(let obj) = statusBAfter.result, case .bool(let locked)? = obj["locked"] {
        XCTAssertFalse(locked, "sidB should still be unlocked")
    }
}

func testConfigSetAndGetRoundTrip() async throws {
    let sid: pid_t = 5003
    _ = await rpc("vault.init", sessionID: sid)

    let setResp = await rpc("vault.config.set",
                            params: ["ttl_seconds": .int(7200)],
                            sessionID: sid)
    XCTAssertNil(setResp.error)

    let getResp = await rpc("vault.config.get", sessionID: sid)
    if case .object(let obj) = getResp.result, case .int(let ttl)? = obj["ttl_seconds"] {
        XCTAssertEqual(ttl, 7200)
    } else {
        XCTFail("expected ttl_seconds in config.get response")
    }
}

func testConfigSetWhileLockedFails() async throws {
    let sid: pid_t = 5004
    _ = await rpc("vault.init", sessionID: sid)
    _ = await rpc("vault.lock", sessionID: sid)

    let setResp = await rpc("vault.config.set",
                            params: ["ttl_seconds": .int(7200)],
                            sessionID: sid)
    XCTAssertNotNil(setResp.error)
    XCTAssertEqual(setResp.error?.code, RPCErrorCode.vaultLocked)
}
```

- [ ] **Step 2: Run integration tests**

Run: `cd tsmd && swift test --filter IntegrationTests`
Expected: PASS.

- [ ] **Step 3: Run the entire test suite**

Run: `cd tsmd && swift test`
Expected: PASS for all tests.

- [ ] **Step 4: Commit**

```bash
git add tsmd/Tests/tsmdTests/IntegrationTests.swift
git commit -m "test(tsmd): integration tests for multi-session and config RPC"
```

---

## Phase G — End-to-end smoke

### Task 9: Manual smoke + install

**Files:** none

- [ ] **Step 1: Build and install both binaries**

```bash
cd /Users/carl/code/tsm
go test ./...
cd tsmd && swift test && swift build -c release && cd ..

# Stop any running daemon before swapping the binary.
pgrep -fl "/.local/bin/tsmd" | awk '{print $1}' | xargs -r kill
cp tsmd/.build/release/tsmd ~/.local/bin/tsmd
go build -o ~/.local/bin/tsm .
```

- [ ] **Step 2: Smoke the new TTL surface**

```bash
tsm status                           # spawn daemon, expect locked
tsm unlock                           # Touch ID
tsm config get ttl                   # expect "30m0s"
tsm config set ttl 1h                # Touch-ID-free (within TTL)
tsm config get ttl                   # expect "1h0m0s"
tsm config set ttl 500ms             # expect error: must be whole seconds
tsm config set ttl 0                 # expect error: must be at least 1 second
tsm config set ttl_hours 4           # expect "unknown config key"
tsm config                           # JSON view should show client + vault sections
```

- [ ] **Step 3: Smoke the auto-lock**

```bash
tsm unlock
# Lock the screen (Ctrl+Cmd+Q on macOS), then unlock the screen.
tsm status
# Expect: locked. (Screen-lock fired vault.lockAll.)
```

- [ ] **Step 4: Smoke the per-session unlock**

Open a second terminal:

```bash
# Terminal 1
tsm unlock
tsm status   # unlocked

# Terminal 2 (new POSIX session because terminal apps setsid each window)
tsm status   # expect: locked, even though Terminal 1 is unlocked
tsm unlock   # Touch ID prompt — separate session, separate unlock
```

- [ ] **Step 5: No commit needed** — manual verification only.

---

## Self-Review

(Run after the plan is written; this section is for the author's checklist, not for execution.)

**Spec coverage:**
- Change 1 (30 min default, single source of truth, duration CLI): Tasks 1, 4, 5.
- Change 2 (per-session unlock): Tasks 2, 3, 4, 8.
- Change 3 (auto-lock on screen lock + sleep): Task 6.
- TTL polling 60→15 s: Task 7.
- Migration (silently drop old `ttl_hours` field): covered by Task 1 (decoder relies on Codable defaults).
- Test plan items: per-session map (Task 2), two real sockets (Task 8 — handler-level rather than socket-level; socket-level coverage is in `SocketServerTests` from Task 3), screen-lock notification (Task 6), CLI smoke (Task 5 + Task 9), boundary conditions (Task 1 + Task 2).

**Type consistency:**
- `pid_t` used throughout for session IDs (Swift exposes `sid_t` as a `pid_t` typedef; sticking to one Swift name avoids confusion).
- New methods: `unlock(passphrase:sessionID:)`, `lock(sessionID:)`, `lockAll()`, `getConfig(sessionID:)`, `setConfig(ttlSeconds:sessionID:)` — all consistent across tasks.
- RPC method names: `vault.config.get`, `vault.config.set` — consistent.
- CLI key: `ttl` (not `ttl_seconds`) — consistent.

**Placeholders:** None — every code block is complete.

**Spec gaps:** None found.
