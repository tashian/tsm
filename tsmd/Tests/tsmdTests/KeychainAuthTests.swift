import XCTest
@testable import tsmd

/// Integration tests requiring real macOS Keychain access.
/// Gated behind TSM_INTEGRATION_TESTS=1 environment variable.
final class KeychainAuthTests: XCTestCase {
    let shouldRun = ProcessInfo.processInfo.environment["TSM_INTEGRATION_TESTS"] == "1"

    /// A non-default vault path so these tests get their own Keychain account
    /// and never touch the developer's real master key.
    let keychain = MacKeychain(
        vaultPath: URL(fileURLWithPath: "/tmp/tsm-keychain-auth-tests/vault.enc"))

    override func setUp() {
        guard shouldRun else { return }
        try? keychain.deleteMasterKey()
    }

    override func tearDown() {
        guard shouldRun else { return }
        try? keychain.deleteMasterKey()
    }

    func testKeychainStoreAndRetrieve() throws {
        guard shouldRun else { throw XCTSkip("Set TSM_INTEGRATION_TESTS=1 to run") }
        let key = Data(repeating: 0xAB, count: 32)
        try keychain.storeMasterKey(key)
        let retrieved = try keychain.retrieveMasterKey()
        XCTAssertEqual(key, retrieved)
    }

    func testKeychainDelete() throws {
        guard shouldRun else { throw XCTSkip("Set TSM_INTEGRATION_TESTS=1 to run") }
        let key = Data(repeating: 0xCD, count: 32)
        try keychain.storeMasterKey(key)
        try keychain.deleteMasterKey()
        XCTAssertThrowsError(try keychain.retrieveMasterKey())
    }

    func testKeychainRetrieveWhenEmptyThrows() throws {
        guard shouldRun else { throw XCTSkip("Set TSM_INTEGRATION_TESTS=1 to run") }
        XCTAssertThrowsError(try keychain.retrieveMasterKey())
    }
}
