import XCTest
@testable import tsmd

final class VaultTests: XCTestCase {
    private let sidA: pid_t = 1001
    private let sidB: pid_t = 1002

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
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        let status = await vault.status(sessionID: sidA)
        XCTAssertFalse(status.locked)
        XCTAssertEqual(status.secretCount, 0)
        XCTAssertTrue(store.exists())
        XCTAssertNotNil(keychain.storedKey)
    }

    func testInitWithRecoveryPassphrase() async throws {
        try await vault.initialize(recoveryPassphrase: "my-recovery", sessionID: sidA)
        XCTAssertTrue(store.exists())
        let envelope = try store.read()
        XCTAssertNotNil(envelope.recovery)
        XCTAssertEqual(envelope.recovery?.iterations, 600_000)
    }

    func testInitFailsIfAlreadyExists() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        do {
            try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
            XCTFail("Expected alreadyInitialized error")
        } catch VaultError.alreadyInitialized {
            // expected
        }
    }

    // MARK: - Lock / Unlock

    func testLockClearsState() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        await vault.lockAll()
        let status = await vault.status(sessionID: sidA)
        XCTAssertTrue(status.locked)
    }

    func testUnlockRestoredVault() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "key1", value: "val1", description: "test", sessionID: sidA)
        await vault.lockAll()

        try await vault.unlock(sessionID: sidA)
        let secrets = try await vault.list(sessionID: sidA)
        XCTAssertEqual(secrets.count, 1)
        XCTAssertEqual(secrets[0].name, "key1")
    }

    func testUnlockWhenAlreadyUnlockedIsNoop() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        auth.authenticateCalled = false
        try await vault.unlock(sessionID: sidA)
        XCTAssertFalse(auth.authenticateCalled)
    }

    // MARK: - CRUD

    func testAddAndList() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "api_key", value: "secret", description: "My API key",
                           confirm: true, tags: ["api"], sessionID: sidA)
        let list = try await vault.list(sessionID: sidA)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "api_key")
        XCTAssertEqual(list[0].description, "My API key")
        XCTAssertTrue(list[0].confirm)
        XCTAssertEqual(list[0].tags, ["api"])
    }

    func testGetReturnsValue() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "key1", value: "secret123", description: "test", sessionID: sidA)
        let secret = try await vault.get(name: "key1", sessionID: sidA)
        XCTAssertEqual(secret.value, "secret123")
    }

    func testGetIsCaseInsensitive() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "MyKey", value: "val", description: "test", sessionID: sidA)
        let secret = try await vault.get(name: "mykey", sessionID: sidA)
        XCTAssertEqual(secret.name, "MyKey")
    }

    func testGetNotFoundThrows() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        do {
            _ = try await vault.get(name: "nonexistent", sessionID: sidA)
            XCTFail("Expected secretNotFound")
        } catch VaultError.secretNotFound {
            // expected
        }
    }

    func testGetWithConfirmTriggersAuth() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "admin", value: "token", description: "admin token",
                            confirm: true, sessionID: sidA)
        auth.authenticateCalled = false
        _ = try await vault.get(name: "admin", sessionID: sidA)
        XCTAssertTrue(auth.authenticateCalled)
    }

    func testAddDuplicateNameFails() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "key1", value: "v1", description: "d1", sessionID: sidA)
        do {
            try await vault.add(name: "key1", value: "v2", description: "d2", sessionID: sidA)
            XCTFail("Expected secretAlreadyExists")
        } catch VaultError.secretAlreadyExists {
            // expected
        }
    }

    func testAddDuplicateCaseInsensitive() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "MyKey", value: "v1", description: "d1", sessionID: sidA)
        do {
            try await vault.add(name: "mykey", value: "v2", description: "d2", sessionID: sidA)
            XCTFail("Expected secretAlreadyExists")
        } catch VaultError.secretAlreadyExists {
            // expected
        }
    }

    func testRemove() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "key1", value: "v1", description: "d1", sessionID: sidA)
        try await vault.remove(name: "key1", sessionID: sidA)
        let list = try await vault.list(sessionID: sidA)
        XCTAssertTrue(list.isEmpty)
    }

    func testRemoveNotFoundThrows() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        do {
            try await vault.remove(name: "nope", sessionID: sidA)
            XCTFail("Expected secretNotFound")
        } catch VaultError.secretNotFound {
            // expected
        }
    }

    func testEdit() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "key1", value: "old", description: "old desc", sessionID: sidA)
        try await vault.edit(name: "key1", value: "new", description: "new desc",
                             confirm: true, sessionID: sidA)
        let secret = try await vault.get(name: "key1", sessionID: sidA)
        XCTAssertEqual(secret.value, "new")
        XCTAssertEqual(secret.description, "new desc")
        XCTAssertTrue(secret.confirm)
        XCTAssertNotNil(secret.updated)
    }

    func testEditPartialUpdate() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "key1", value: "val", description: "desc",
                            confirm: false, tags: ["a"], sessionID: sidA)
        try await vault.edit(name: "key1", description: "new desc", sessionID: sidA)
        let secret = try await vault.get(name: "key1", sessionID: sidA)
        XCTAssertEqual(secret.value, "val")
        XCTAssertEqual(secret.description, "new desc")
        XCTAssertFalse(secret.confirm)
        XCTAssertEqual(secret.tags, ["a"])
    }

    // MARK: - Name validation

    func testInvalidNameRejected() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        let badNames = ["", "a/b", "a b", "a\nb", String(repeating: "x", count: 129), "../etc/passwd"]
        for name in badNames {
            do {
                try await vault.add(name: name, value: "v", description: "d", sessionID: sidA)
                XCTFail("Expected invalidName for '\(name)'")
            } catch VaultError.invalidName {
                // expected
            }
        }
    }

    func testValidNamesAccepted() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        let goodNames = ["a", "api_key", "my-secret", "KEY_123", String(repeating: "x", count: 128)]
        for name in goodNames {
            try await vault.add(name: name, value: "v", description: "d", sessionID: sidA)
        }
        let list = try await vault.list(sessionID: sidA)
        XCTAssertEqual(list.count, goodNames.count)
    }

    // MARK: - Locked operations fail

    func testListWhenLockedThrows() async throws {
        do {
            _ = try await vault.list(sessionID: sidA)
            XCTFail("Expected locked")
        } catch VaultError.locked {
            // expected
        }
    }

    func testGetWhenLockedThrows() async throws {
        do {
            _ = try await vault.get(name: "x", sessionID: sidA)
            XCTFail("Expected locked")
        } catch VaultError.locked {
            // expected
        }
    }

    // MARK: - Access logging

    func testGetLogsAccess() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "k", value: "v", description: "d", sessionID: sidA)
        _ = try await vault.get(name: "k", sessionID: sidA, clientId: "test/pid:1")
        XCTAssertEqual(accessLog.entries.count, 2) // add + get
        let getEntry = accessLog.entries[1]
        XCTAssertEqual(getEntry.method, "vault.get")
        XCTAssertEqual(getEntry.secret, "k")
        XCTAssertEqual(getEntry.clientId, "test/pid:1")
        XCTAssertEqual(getEntry.result, "ok")
    }

    // MARK: - TTL

    func testStatusShowsTTL() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        let status = await vault.status(sessionID: sidA)
        XCTAssertFalse(status.locked)
        XCTAssertNotNil(status.ttlRemainingSeconds)
        XCTAssertGreaterThan(status.ttlRemainingSeconds!, 1700)
    }

    // MARK: - Reset

    func testResetDestroysEverything() async throws {
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.add(name: "key", value: "val", description: "d", sessionID: sidA)
        try await vault.reset()
        let status = await vault.status(sessionID: sidA)
        XCTAssertTrue(status.locked)
        XCTAssertFalse(store.exists())
        XCTAssertNil(keychain.storedKey)
    }

    // MARK: - Per-session unlock

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
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sidA)
        try await vault.setConfig(ttlSeconds: 1, sessionID: sidA)
        await vault._testForceUnlockTime(sessionID: sidA, to: Date(timeIntervalSinceNow: -10))
        await vault.checkTTL()
        XCTAssertTrue(await vault.status(sessionID: sidA).locked)
    }
}
