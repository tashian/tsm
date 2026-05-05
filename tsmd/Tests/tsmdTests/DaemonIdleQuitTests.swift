import XCTest
@testable import tsmd

final class DaemonIdleQuitTests: XCTestCase {
    private func makeVault() -> Vault {
        Vault(
            crypto: MockCrypto(),
            keychain: MockKeychain(),
            auth: MockAuth(),
            store: MockVaultStore(),
            accessLog: MockAccessLog()
        )
    }

    private func tmpSocketPath() -> String {
        NSTemporaryDirectory() + "tsmd-idle-\(UUID().uuidString).sock"
    }

    // MARK: - Predicate

    func testShouldIdleQuitWhenLockedAndIdle() async {
        let vault = makeVault()
        let tracker = IdleTracker(now: .distantPast)
        let daemon = Daemon(
            socketPath: tmpSocketPath(),
            idleQuitSeconds: 60,
            vault: vault,
            idleTracker: tracker
        )
        let shouldQuit = await daemon.shouldIdleQuit()
        XCTAssertTrue(shouldQuit, "locked vault + last activity in distant past must request quit")
    }

    func testShouldNotIdleQuitWhenLockedButRecent() async {
        let vault = makeVault()
        let tracker = IdleTracker(now: Date())
        let daemon = Daemon(
            socketPath: tmpSocketPath(),
            idleQuitSeconds: 60,
            vault: vault,
            idleTracker: tracker
        )
        let shouldQuit = await daemon.shouldIdleQuit()
        XCTAssertFalse(shouldQuit, "locked but within idle window must not request quit")
    }

    func testShouldNotIdleQuitWhenUnlockedEvenIfIdle() async throws {
        let vault = makeVault()
        try await vault.initialize(recoveryPassphrase: nil, sessionID: 1234)
        // Vault is now unlocked (data != nil).
        let tracker = IdleTracker(now: .distantPast)
        let daemon = Daemon(
            socketPath: tmpSocketPath(),
            idleQuitSeconds: 60,
            vault: vault,
            idleTracker: tracker
        )
        let shouldQuit = await daemon.shouldIdleQuit()
        XCTAssertFalse(shouldQuit, "unlocked vault must not request quit even when no recent RPCs")
    }

    // MARK: - Wiring (timer → notification → shutdown)

    func testRunReturnsWhenIdleQuitFires() async throws {
        let socketPath = tmpSocketPath()
        let vault = makeVault()
        // Starts locked (data == nil) and tracker is in distant past, so the
        // very first tick should request shutdown.
        let tracker = IdleTracker(now: .distantPast)
        let daemon = Daemon(
            socketPath: socketPath,
            idleQuitSeconds: 0.0,
            tickInterval: 0.05,
            vault: vault,
            idleTracker: tracker
        )

        let runDone = expectation(description: "Daemon.run returns after idle-quit fires")
        Task.detached {
            try? daemon.run()
            runDone.fulfill()
        }
        await fulfillment(of: [runDone], timeout: 5.0)

        // Socket file is unlinked by SocketServer.stop().
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "shutdown should unlink the socket file"
        )
    }

    func testRunDoesNotIdleQuitWhileVaultIsUnlocked() async throws {
        let socketPath = tmpSocketPath()
        let vault = makeVault()
        try await vault.initialize(recoveryPassphrase: nil, sessionID: 5555)
        // Tracker is distant past — only the unlocked-vault check should
        // keep the daemon alive.
        let tracker = IdleTracker(now: .distantPast)
        let daemon = Daemon(
            socketPath: socketPath,
            idleQuitSeconds: 0.0,
            tickInterval: 0.02,
            vault: vault,
            idleTracker: tracker
        )

        let runDone = expectation(description: "Daemon.run should NOT return")
        runDone.isInverted = true
        Task.detached {
            try? daemon.run()
            runDone.fulfill()
        }
        await fulfillment(of: [runDone], timeout: 0.3)

        // Tear down so we don't leak a running daemon into other tests.
        daemon.shutdown()
    }
}
