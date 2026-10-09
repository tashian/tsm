import XCTest
@testable import tsmd

final class VaultDialogTests: XCTestCase {
    private let sid: pid_t = 1001
    var auth: MockAuth!
    var accessLog: MockAccessLog!
    var vault: Vault!

    override func setUp() async throws {
        auth = MockAuth()
        accessLog = MockAccessLog()
        vault = Vault(crypto: MockCrypto(), keychain: MockKeychain(), auth: auth,
                      store: MockVaultStore(), accessLog: accessLog)
        try await vault.initialize(recoveryPassphrase: nil, sessionID: sid)
        try await vault.add(name: "gh-pat", value: "v", description: "", sessionID: sid)
        try await vault.add(name: "openai-key", value: "v", description: "", confirm: true, sessionID: sid)
        try await vault.add(name: "anthropic-key", value: "v", description: "", confirm: true, sessionID: sid)
        auth.reasons = []
    }

    private let evalPeer = PeerInfo(command: "python3 scripts/eval.py",
                                    secrets: ["openai-key", "anthropic-key", "gh-pat"])

    func testUnlockDialogNamesSecretsAndCommand() async throws {
        await vault.lock(sessionID: sid)
        let peer = PeerInfo(command: "gh pr list", secrets: ["gh-pat"])
        try await vault.unlock(sessionID: sid, peer: peer, approvals: ApprovalSet())
        XCTAssertEqual(auth.reasons, ["unlock the vault and access 'gh-pat':\n\ngh pr list"])
    }

    func testUnlockDialogPlainWithoutPeer() async throws {
        await vault.lock(sessionID: sid)
        try await vault.unlock(sessionID: sid)
        XCTAssertEqual(auth.reasons, ["unlock the vault"])
    }

    func testOneAccessDialogForAllGatedSecrets() async throws {
        let approvals = ApprovalSet()
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: evalPeer, approvals: approvals)
        _ = try await vault.get(name: "anthropic-key", sessionID: sid, peer: evalPeer, approvals: approvals)
        _ = try await vault.get(name: "gh-pat", sessionID: sid, peer: evalPeer, approvals: approvals)
        XCTAssertEqual(auth.reasons,
                       ["access 'openai-key' and 'anthropic-key':\n\npython3 scripts/eval.py"])
    }

    func testUnnamedGatedSecretStillPrompts() async throws {
        let approvals = ApprovalSet()
        let peer = PeerInfo(command: "x", secrets: ["openai-key"])
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: peer, approvals: approvals)
        _ = try await vault.get(name: "anthropic-key", sessionID: sid, peer: peer, approvals: approvals)
        XCTAssertEqual(auth.reasons, ["access 'openai-key':\n\nx", "access 'anthropic-key':\n\nx"])
    }

    func testUnlockDialogApprovesNamedGatedSecret() async throws {
        await vault.lock(sessionID: sid)
        let approvals = ApprovalSet()
        let peer = PeerInfo(command: "x", secrets: ["openai-key"])
        try await vault.unlock(sessionID: sid, peer: peer, approvals: approvals)
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: peer, approvals: approvals)
        XCTAssertEqual(auth.reasons, ["unlock the vault and access 'openai-key':\n\nx"])
    }

    func testNewConnectionPromptsAgain() async throws {
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: evalPeer, approvals: ApprovalSet())
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: evalPeer, approvals: ApprovalSet())
        XCTAssertEqual(auth.reasons.count, 2)
    }

    func testCanceledDialogApprovesNothing() async throws {
        let approvals = ApprovalSet()
        auth.shouldFail = true
        do {
            _ = try await vault.get(name: "openai-key", sessionID: sid, peer: evalPeer, approvals: approvals)
            XCTFail("Expected authFailed")
        } catch VaultError.authFailed {}
        auth.shouldFail = false
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: evalPeer, approvals: approvals)
        XCTAssertEqual(auth.reasons.count, 2)
    }

    func testApprovalIgnoresCase() async throws {
        let approvals = ApprovalSet()
        let peer = PeerInfo(command: "x", secrets: ["OpenAI-Key"])
        _ = try await vault.get(name: "OpenAI-Key", sessionID: sid, peer: peer, approvals: approvals)
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: peer, approvals: approvals)
        XCTAssertEqual(auth.reasons.count, 1)
    }

    func testLogRecordsFullCommand() async throws {
        let command = "python3 " + String(repeating: "a", count: 500)
        let peer = PeerInfo(command: command, secrets: ["openai-key"])
        _ = try await vault.get(name: "openai-key", sessionID: sid, peer: peer, approvals: ApprovalSet())
        XCTAssertEqual(accessLog.entries.last?.command, command)
        XCTAssertTrue(auth.reasons[0].contains("…"))
    }
}
