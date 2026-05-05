import XCTest
@testable import tsmd

final class JSONRPCHandlerTests: XCTestCase {
    var handler: JSONRPCHandler!
    var vault: Vault!
    var auth: MockAuth!

    let sid: pid_t = 5000

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
        let resp = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)
    }

    func testVaultStatus() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        let resp = await handler.handle(makeRequest(method: "vault.status"), sessionID: sid)
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object result"); return
        }
        XCTAssertEqual(obj["locked"], .bool(false))
    }

    // MARK: - CRUD

    func testVaultAddAndGet() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        let addResp = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("key1"), "value": .string("secret"), "description": .string("test")]
        ), sessionID: sid)
        XCTAssertNil(addResp.error)

        let getResp = await handler.handle(makeRequest(
            method: "vault.get",
            params: ["name": .string("key1")]
        ), sessionID: sid)
        guard case .object(let obj) = getResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("secret"))
    }

    func testVaultList() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("v1"), "description": .string("d1")]
        ), sessionID: sid)
        let resp = await handler.handle(makeRequest(method: "vault.list"), sessionID: sid)
        guard case .array(let arr) = resp.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertEqual(arr.count, 1)
    }

    func testVaultRemove() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("v1"), "description": .string("d1")]
        ), sessionID: sid)
        let resp = await handler.handle(makeRequest(
            method: "vault.remove",
            params: ["name": .string("k1")]
        ), sessionID: sid)
        XCTAssertNil(resp.error)

        let listResp = await handler.handle(makeRequest(method: "vault.list"), sessionID: sid)
        guard case .array(let arr) = listResp.result else {
            XCTFail("Expected array"); return
        }
        XCTAssertTrue(arr.isEmpty)
    }

    func testVaultEdit() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k1"), "value": .string("old"), "description": .string("old desc")]
        ), sessionID: sid)
        let resp = await handler.handle(makeRequest(
            method: "vault.edit",
            params: ["name": .string("k1"), "value": .string("new"), "description": .string("new desc")]
        ), sessionID: sid)
        XCTAssertNil(resp.error)

        let getResp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k1")]
        ), sessionID: sid)
        guard case .object(let obj) = getResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("new"))
    }

    // MARK: - Lock / Unlock

    func testLockAndUnlock() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: ["name": .string("k"), "value": .string("v"), "description": .string("d")]
        ), sessionID: sid)

        _ = await handler.handle(makeRequest(method: "vault.lock"), sessionID: sid)
        let statusResp = await handler.handle(makeRequest(method: "vault.status"), sessionID: sid)
        guard case .object(let locked) = statusResp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(locked["locked"], .bool(true))

        let getResp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k")]
        ), sessionID: sid)
        XCTAssertEqual(getResp.error?.code, RPCErrorCode.vaultLocked)

        _ = await handler.handle(makeRequest(method: "vault.unlock"), sessionID: sid)
        let getResp2 = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("k")]
        ), sessionID: sid)
        XCTAssertNil(getResp2.error)
    }

    // MARK: - Error cases

    func testMethodNotFound() async {
        let resp = await handler.handle(makeRequest(method: "nonexistent"), sessionID: sid)
        XCTAssertNotNil(resp.error)
    }

    func testGetMissingNameParam() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        let resp = await handler.handle(makeRequest(method: "vault.get"), sessionID: sid)
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, RPCErrorCode.invalidParams)
    }

    func testGetSecretNotFound() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        let resp = await handler.handle(makeRequest(
            method: "vault.get", params: ["name": .string("nope")]
        ), sessionID: sid)
        XCTAssertEqual(resp.error?.code, RPCErrorCode.secretNotFound)
    }

    // MARK: - Capabilities + Shutdown

    func testDaemonCapabilities() async {
        let resp = await handler.handle(makeRequest(method: "daemon.capabilities"), sessionID: sid)
        guard case .object(let obj) = resp.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["protocol_version"], .int(1))
    }

    func testDaemonShutdownReturnsOk() async {
        let resp = await handler.handle(makeRequest(method: "daemon.shutdown"), sessionID: sid)
        XCTAssertNil(resp.error)
    }

    // MARK: - Project scoping (peer cwd plumbed through dispatch)

    func testAddProjectScopeAndGetInScope() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        let addResp = await handler.handle(makeRequest(
            method: "vault.add",
            params: [
                "name": .string("proj-key"),
                "value": .string("v"),
                "description": .string("d"),
                "scope": .string("project"),
                "roots": .array([.string("/tmp/foo")]),
            ]
        ), sessionID: sid)
        XCTAssertNil(addResp.error, addResp.error?.message ?? "")

        let getInScope = await handler.handle(makeRequest(
            method: "vault.get",
            params: ["name": .string("proj-key")]
        ), sessionID: sid, peerCwd: "/tmp/foo/sub")
        XCTAssertNil(getInScope.error)
    }

    func testGetProjectScopedSecretOutOfScopeReturnsErrorWithRootsData() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: [
                "name": .string("proj-key"),
                "value": .string("v"),
                "description": .string("d"),
                "scope": .string("project"),
                "roots": .array([.string("/tmp/foo")]),
            ]
        ), sessionID: sid)

        let resp = await handler.handle(makeRequest(
            method: "vault.get",
            params: ["name": .string("proj-key")]
        ), sessionID: sid, peerCwd: "/tmp/elsewhere")

        XCTAssertEqual(resp.error?.code, RPCErrorCode.secretOutOfScope)
        XCTAssertEqual(resp.error?.code, -32010, "the wire-format error code is part of the contract")
        guard let data = resp.error?.data else { return XCTFail("expected data field") }
        XCTAssertEqual(data["name"], .string("proj-key"))
        XCTAssertEqual(data["roots"], .array([.string("/tmp/foo")]))
    }

    func testListWithIncludeAllReturnsOutOfScopeProjectSecrets() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        _ = await handler.handle(makeRequest(
            method: "vault.add",
            params: [
                "name": .string("proj-key"),
                "value": .string("v"),
                "description": .string("d"),
                "scope": .string("project"),
                "roots": .array([.string("/tmp/foo")]),
            ]
        ), sessionID: sid)

        // Without include_all and from out-of-scope cwd, the project secret is hidden.
        let filtered = await handler.handle(makeRequest(method: "vault.list"), sessionID: sid, peerCwd: "/elsewhere")
        if case .array(let arr) = filtered.result {
            XCTAssertTrue(arr.isEmpty, "out-of-scope project secret leaked into default list")
        } else {
            XCTFail("expected array")
        }

        // With include_all, the project secret comes back.
        let all = await handler.handle(makeRequest(
            method: "vault.list",
            params: ["include_all": .bool(true)]
        ), sessionID: sid, peerCwd: "/elsewhere")
        if case .array(let arr) = all.result {
            XCTAssertEqual(arr.count, 1)
        } else {
            XCTFail("expected array")
        }
    }

    func testAddProjectScopeWithEmptyRootsReturnsInvalidParams() async {
        _ = await handler.handle(makeRequest(method: "vault.init"), sessionID: sid)
        let resp = await handler.handle(makeRequest(
            method: "vault.add",
            params: [
                "name": .string("k"),
                "value": .string("v"),
                "description": .string("d"),
                "scope": .string("project"),
                "roots": .array([]),
            ]
        ), sessionID: sid)
        XCTAssertEqual(resp.error?.code, RPCErrorCode.invalidParams)
    }

    // MARK: - Session isolation

    func testHandlerThreadsSessionIDIntoVaultCalls() async throws {
        let vault = Vault(
            crypto: MockCrypto(),
            keychain: MockKeychain(),
            auth: MockAuth(),
            store: MockVaultStore(),
            accessLog: MockAccessLog()
        )
        let handler = JSONRPCHandler(vault: vault)
        let sid: pid_t = 4242

        let initReq = JSONRPCRequest(jsonrpc: "2.0", method: "vault.init", params: nil, id: .int(1))
        let initResp = await handler.handle(initReq, sessionID: sid)
        XCTAssertNil(initResp.error)

        let statusReq = JSONRPCRequest(jsonrpc: "2.0", method: "vault.status", params: nil, id: .int(2))
        let statusResp = await handler.handle(statusReq, sessionID: sid)
        if case .object(let obj) = statusResp.result, case .bool(let locked)? = obj["locked"] {
            XCTAssertFalse(locked)
        } else {
            XCTFail("expected locked field in status response")
        }

        let otherStatusResp = await handler.handle(statusReq, sessionID: 9999)
        if case .object(let obj) = otherStatusResp.result, case .bool(let locked)? = obj["locked"] {
            XCTAssertTrue(locked)
        } else {
            XCTFail("expected locked field in other-session status response")
        }
    }
}
