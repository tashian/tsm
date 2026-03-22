import XCTest
@testable import tsmd

final class JSONRPCHandlerTests: XCTestCase {
    var handler: JSONRPCHandler!
    var vault: Vault!
    var auth: MockAuth!

    override func setUp() {
        auth = MockAuth()
        vault = Vault(
            crypto: MockCrypto(),
            keychain: MockKeychain(),
            auth: auth,
            store: MockVaultStore(),
            accessLog: MockAccessLog()
        )
        handler = JSONRPCHandler(vault: vault)
    }

    private func makeRequest(method: String, params: [String: JSONValue]? = nil, id: Int = 1) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", method: method, params: params, id: .int(id))
    }

    // MARK: - Init + Status

    func testVaultInit() async {
        let resp = await handler.handle(makeRequest(method: "vault.init"))
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)
    }

    func testVaultStatus() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let resp = await handler.handle(makeRequest(method: "vault.status"))
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object result"); return
        }
        XCTAssertEqual(obj["locked"], .bool(false))
    }

    // MARK: - CRUD

    func testVaultAddAndGet() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let addResp = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("key1"), "value": .string("secret"), "description": .string("test")]
        ))
        XCTAssertNil(addResp.error)

        let getResp = await handler.handle(makeRequest(
            method: "vault.get",
            params: ["name": .string("key1")]
        ))
        guard case .object(let obj) = getResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("secret"))
    }

    func testVaultList() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("v1"), "description": .string("d1")]
        ))
        let resp = await handler.handle(makeRequest(method: "vault.list"))
        guard case .array(let arr) = resp.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertEqual(arr.count, 1)
    }

    func testVaultRemove() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("v1"), "description": .string("d1")]
        ))
        let resp = await handler.handle(makeRequest(
            method: "vault.remove",
            params: ["name": .string("k1")]
        ))
        XCTAssertNil(resp.error)

        let listResp = await handler.handle(makeRequest(method: "vault.list"))
        guard case .array(let arr) = listResp.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertTrue(arr.isEmpty)
    }

    func testVaultEdit() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("old"), "description": .string("old desc")]
        ))
        let resp = await handler.handle(makeRequest(
            method: "vault.edit",
            params: ["name": .string("k1"), "value": .string("new"), "description": .string("new desc")]
        ))
        XCTAssertNil(resp.error)

        let getResp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k1")]
        ))
        guard case .object(let obj) = getResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("new"))
    }

    // MARK: - Lock / Unlock

    func testLockAndUnlock() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k"), "value": .string("v"), "description": .string("d")]
        ))

        _ = await handler.handle(makeRequest(method: "vault.lock"))
        let statusResp = await handler.handle(makeRequest(method: "vault.status"))
        guard case .object(let locked) = statusResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(locked["locked"], .bool(true))

        let getResp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k")]
        ))
        XCTAssertEqual(getResp.error?.code, RPCErrorCode.vaultLocked)

        _ = await handler.handle(makeRequest(method: "vault.unlock"))
        let getResp2 = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k")]
        ))
        XCTAssertNil(getResp2.error)
    }

    // MARK: - Error cases

    func testMethodNotFound() async {
        let resp = await handler.handle(makeRequest(method: "nonexistent"))
        XCTAssertNotNil(resp.error)
    }

    func testGetMissingNameParam() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let resp = await handler.handle(makeRequest(method: "vault.get"))
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, RPCErrorCode.invalidParams)
    }

    func testGetSecretNotFound() async {
        _ = await handler.handle(makeRequest(method: "vault.init"))
        let resp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("nope")]
        ))
        XCTAssertEqual(resp.error?.code, RPCErrorCode.secretNotFound)
    }

    // MARK: - Capabilities + Shutdown

    func testDaemonCapabilities() async {
        let resp = await handler.handle(makeRequest(method: "daemon.capabilities"))
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["protocol_version"], .int(1))
    }

    func testDaemonShutdownReturnsOk() async {
        let resp = await handler.handle(makeRequest(method: "daemon.shutdown"))
        XCTAssertNil(resp.error)
    }
}
