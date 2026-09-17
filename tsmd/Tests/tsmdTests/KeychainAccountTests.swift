import XCTest
@testable import tsmd

/// The Keychain account under which the master key is stored must be
/// derived from the vault path, so that a vault at a non-default location
/// (e.g. a temp vault for tests) does not share or clobber the real
/// vault's key. The default vault path keeps the legacy account so that
/// existing installs are unaffected.
final class KeychainAccountTests: XCTestCase {
    func testDefaultVaultPathUsesLegacyAccount() {
        let keychain = MacKeychain(vaultPath: Paths.defaultVaultFile)
        XCTAssertEqual(keychain.account, "master-key")
    }

    func testNonDefaultVaultPathUsesDerivedAccount() {
        let path = URL(fileURLWithPath: "/tmp/tsm-test/vault.enc")
        let keychain = MacKeychain(vaultPath: path)
        XCTAssertNotEqual(keychain.account, "master-key")
        XCTAssertTrue(keychain.account.hasPrefix("master-key:"),
                      "derived account should be namespaced under the legacy prefix, got \(keychain.account)")
    }

    func testDerivedAccountIsStableForSamePath() {
        let a = MacKeychain(vaultPath: URL(fileURLWithPath: "/tmp/tsm-test/vault.enc")).account
        let b = MacKeychain(vaultPath: URL(fileURLWithPath: "/tmp/tsm-test/vault.enc")).account
        XCTAssertEqual(a, b)
    }

    func testDerivedAccountDiffersAcrossPaths() {
        let a = MacKeychain(vaultPath: URL(fileURLWithPath: "/tmp/tsm-a/vault.enc")).account
        let b = MacKeychain(vaultPath: URL(fileURLWithPath: "/tmp/tsm-b/vault.enc")).account
        XCTAssertNotEqual(a, b)
    }

    func testDefaultInitUsesResolvedVaultFile() {
        // With no overrides, MacKeychain() must key by Paths.vaultFile, which
        // is the default path unless XDG_DATA_HOME is set in this process.
        let keychain = MacKeychain()
        let expected = MacKeychain(vaultPath: Paths.vaultFile)
        XCTAssertEqual(keychain.account, expected.account)
    }
}
