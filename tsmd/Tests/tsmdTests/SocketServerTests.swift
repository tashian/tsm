import XCTest
@testable import tsmd

final class SocketServerTests: XCTestCase {
    var tmpDir: String!
    var socketPath: String!
    var server: SocketServer!
    var handler: JSONRPCHandler!

    override func setUp() async throws {
        // Use short path — Unix socket paths max out at 104 bytes on macOS
        tmpDir = "/tmp/tsmd-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: tmpDir)
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        socketPath = tmpDir + "/s.sock"

        let vault = Vault(
            crypto: MockCrypto(),
            keychain: MockKeychain(),
            auth: MockAuth(),
            store: MockVaultStore(),
            accessLog: MockAccessLog()
        )
        handler = JSONRPCHandler(vault: vault)
        server = SocketServer(socketPath: socketPath, handler: handler)
        try server.start()

        // Initialize the vault via the socket so it uses the same session ID
        // as subsequent socket-level requests from this test process.
        _ = try sendRequest("""
        {"jsonrpc":"2.0","method":"vault.init","id":0}
        """)
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func sendRequest(_ json: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<min(pathBytes.count, buf.count - 1) {
                buf[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw SocketError.bindFailed(errno) }

        var data = Data(json.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, data.count)
        }

        // Give server time to process
        usleep(100_000)

        var response = Data(count: 65536)
        let bytesRead = response.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress!, 65536)
        }
        guard bytesRead > 0 else { return Data() }
        return response.prefix(bytesRead)
    }

    func testCapabilitiesOverSocket() throws {
        let json = """
        {"jsonrpc":"2.0","method":"daemon.capabilities","id":1}
        """
        let responseData = try sendRequest(json)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        XCTAssertNil(response.error)
        guard case .object(let obj) = response.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["protocol_version"], .int(1))
    }

    func testStatusOverSocket() throws {
        let json = """
        {"jsonrpc":"2.0","method":"vault.status","id":2}
        """
        let responseData = try sendRequest(json)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        XCTAssertNil(response.error)
    }

    func testAddAndGetOverSocket() throws {
        let addJson = """
        {"jsonrpc":"2.0","method":"vault.add","params":{"name":"sock_key","value":"sock_val","description":"socket test"},"id":3}
        """
        let addResp = try sendRequest(addJson)
        let addResponse = try JSONDecoder().decode(JSONRPCResponse.self, from: addResp)
        XCTAssertNil(addResponse.error)

        let getJson = """
        {"jsonrpc":"2.0","method":"vault.get","params":{"name":"sock_key"},"id":4}
        """
        let getResp = try sendRequest(getJson)
        let getResponse = try JSONDecoder().decode(JSONRPCResponse.self, from: getResp)
        XCTAssertNil(getResponse.error)
        guard case .object(let obj) = getResponse.result else {
            XCTFail("Expected object"); return
        }
        XCTAssertEqual(obj["value"], .string("sock_val"))
    }

    func testInvalidJsonReturnsParseError() throws {
        let responseData = try sendRequest("not valid json")
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        XCTAssertEqual(response.error?.code, RPCErrorCode.parseError)
    }

    func testDaemonShutdownPostsShutdownNotification() async throws {
        let expectation = XCTestExpectation(description: "shutdown notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .tsmdShutdown, object: nil, queue: nil
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let json = """
        {"jsonrpc":"2.0","method":"daemon.shutdown","id":99}
        """
        let responseData = try sendRequest(json)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        XCTAssertNil(response.error)
        guard case .object(let obj) = response.result else {
            XCTFail("Expected object result"); return
        }
        XCTAssertEqual(obj["ok"], .bool(true))

        await fulfillment(of: [expectation], timeout: 2.0)
    }
}
