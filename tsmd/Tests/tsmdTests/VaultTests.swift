import XCTest
@testable import tsmd

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
        XCTAssertEqual(secret.value, "val")
        XCTAssertEqual(secret.description, "new desc")
        XCTAssertFalse(secret.confirm)
        XCTAssertEqual(secret.tags, ["a"])
    }

    // MARK: - Name validation

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
