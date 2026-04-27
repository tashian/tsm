import XCTest
@testable import tsmd

final class IntegrationTests: XCTestCase {
    var tmpDir: String!
    var handler: JSONRPCHandler!

    override func setUp() async throws {
        tmpDir = NSTemporaryDirectory() + "tsmd-integration-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let storePath = URL(fileURLWithPath: tmpDir).appendingPathComponent("vault.enc")
        let logPath = URL(fileURLWithPath: tmpDir).appendingPathComponent("access.log")

        let vault = Vault(
            crypto: AESGCMCrypto(),
            keychain: MockKeychain(),
            auth: MockAuth(),
            store: FileVaultStore(path: storePath),
            accessLog: FileAccessLog(path: logPath)
        )
        handler = JSONRPCHandler(vault: vault)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func rpc(_ method: String, params: [String: JSONValue]? = nil, sessionID: pid_t = 1001) async -> JSONRPCResponse {
        await handler.handle(JSONRPCRequest(jsonrpc: "2.0", method: method, params: params, id: .int(1)), sessionID: sessionID)
    }

    func testFullLifecycle() async throws {
        // 1. Init
        let initResp = await rpc("vault.init")
        XCTAssertNil(initResp.error, "Init failed: \(String(describing: initResp.error))")

        // 2. Add secrets
        let add1 = await rpc("vault.add", params: [
            "name": .string("api_key"),
            "value": .string("sk-12345"),
            "description": .string("OpenAI API key"),
            "confirm": .bool(false),
            "tags": .array([.string("openai"), .string("ai")])
        ])
        XCTAssertNil(add1.error)

        let add2 = await rpc("vault.add", params: [
            "name": .string("admin_token"),
            "value": .string("admin-secret"),
            "description": .string("Admin access"),
            "confirm": .bool(true)
        ])
        XCTAssertNil(add2.error)

        // 3. List
        let list = await rpc("vault.list")
        guard case .array(let arr) = list.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertEqual(arr.count, 2)

        // 4. Get
        let get = await rpc("vault.get", params: [
            "name": .string("api_key"),
            "client_id": .string("test/pid:999")
        ])
        guard case .object(let getObj) = get.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(getObj["value"], .string("sk-12345"))

        // 5. Edit
        let edit = await rpc("vault.edit", params: [
            "name": .string("api_key"),
            "value": .string("sk-67890")
        ])
        XCTAssertNil(edit.error)

        // 6. Verify edit
        let getEdited = await rpc("vault.get", params: ["name": .string("api_key")])
        guard case .object(let editedObj) = getEdited.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(editedObj["value"], .string("sk-67890"))

        // 7. Lock
        let lockResp = await rpc("vault.lock")
        XCTAssertNil(lockResp.error)

        // 8. Get should fail when locked
        let lockedGet = await rpc("vault.get", params: ["name": .string("api_key")])
        XCTAssertEqual(lockedGet.error?.code, RPCErrorCode.vaultLocked)

        // 9. Unlock
        let unlockResp = await rpc("vault.unlock")
        XCTAssertNil(unlockResp.error)

        // 10. Data survives lock/unlock (real crypto + real file I/O)
        let getAfterUnlock = await rpc("vault.get", params: ["name": .string("api_key")])
        guard case .object(let unlockObj) = getAfterUnlock.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(unlockObj["value"], .string("sk-67890"))

        // 11. Remove
        let remove = await rpc("vault.remove", params: ["name": .string("admin_token")])
        XCTAssertNil(remove.error)

        // 12. Status
        let status = await rpc("vault.status")
        guard case .object(let statusObj) = status.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(statusObj["locked"], .bool(false))
        XCTAssertEqual(statusObj["secret_count"], .int(1))

        // 13. Access log was written
        let logPath = URL(fileURLWithPath: tmpDir).appendingPathComponent("access.log")
        let logContent = try String(contentsOf: logPath, encoding: .utf8)
        let logLines = logContent.split(separator: "\n")
        XCTAssertGreaterThan(logLines.count, 0)
    }

    func testInitWithRecoveryAndRecover() async throws {
        let initResp = await rpc("vault.init", params: [
            "recovery_passphrase": .string("my-secret-recovery-phrase")
        ])
        XCTAssertNil(initResp.error)

        _ = await rpc("vault.add", params: [
            "name": .string("precious"),
            "value": .string("diamond"),
            "description": .string("very important")
        ])

        _ = await rpc("vault.lock")

        let unlockResp = await rpc("vault.unlock", params: [
            "passphrase": .string("my-secret-recovery-phrase")
        ])
        XCTAssertNil(unlockResp.error, "Passphrase unlock failed: \(String(describing: unlockResp.error))")

        let get = await rpc("vault.get", params: ["name": .string("precious")])
        guard case .object(let obj) = get.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("diamond"))
    }

    func testCapabilities() async {
        let resp = await rpc("daemon.capabilities")
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["protocol_version"], .int(1))
        guard case .array(let backends) = obj["auth_backends"] else {
            XCTFail("Expected auth_backends array"); return
        }
        XCTAssertTrue(backends.contains(.string("touchid")))
    }

    func testNameValidationOverProtocol() async {
        _ = await rpc("vault.init")
        let resp = await rpc("vault.add", params: [
            "name": .string("../etc/passwd"),
            "value": .string("evil"),
            "description": .string("path traversal attempt")
        ])
        XCTAssertEqual(resp.error?.code, RPCErrorCode.invalidParams)
    }
}
