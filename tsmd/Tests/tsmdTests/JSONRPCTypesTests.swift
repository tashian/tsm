import XCTest
@testable import tsmd

final class JSONRPCTypesTests: XCTestCase {
    let decoder = JSONDecoder()
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    func testParseRequest() throws {
        let json = """
        {"jsonrpc":"2.0","method":"vault.get","params":{"name":"test_key"},"id":1}
        """.data(using: .utf8)!
        let req = try decoder.decode(JSONRPCRequest.self, from: json)
        XCTAssertEqual(req.method, "vault.get")
        XCTAssertEqual(req.stringParam("name"), "test_key")
        XCTAssertEqual(req.id, .int(1))
    }

    func testParseRequestWithStringId() throws {
        let json = """
        {"jsonrpc":"2.0","method":"vault.list","id":"abc"}
        """.data(using: .utf8)!
        let req = try decoder.decode(JSONRPCRequest.self, from: json)
        XCTAssertEqual(req.id, .string("abc"))
        XCTAssertNil(req.params)
    }

    func testSerializeSuccessResponse() throws {
        let resp = JSONRPCResponse(
            result: .object(["name": .string("key"), "value": .string("val")]),
            id: .int(1)
        )
        let data = try encoder.encode(resp)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"result\""))
        XCTAssertFalse(json.contains("\"error\""))
    }

    func testSerializeErrorResponse() throws {
        let resp = JSONRPCResponse(
            error: JSONRPCError(
                code: RPCErrorCode.vaultLocked,
                message: "Vault is locked",
                data: ["auth_method": .string("touchid")]
            ),
            id: .int(1)
        )
        let data = try encoder.encode(resp)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("-32001"))
        XCTAssertTrue(json.contains("touchid"))
    }

    func testJSONValueRoundTrip() throws {
        let values: [JSONValue] = [
            .string("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null,
            .array([.int(1), .string("two")]),
            .object(["key": .string("value")])
        ]
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(JSONValue.self, from: data)
            XCTAssertEqual(value, decoded)
        }
    }

    func testConvenienceAccessors() {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.int(1).stringValue)
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
    }

    func testErrorCodes() {
        XCTAssertEqual(RPCErrorCode.vaultLocked, -32001)
        XCTAssertEqual(RPCErrorCode.authRequired, -32002)
        XCTAssertEqual(RPCErrorCode.secretNotFound, -32003)
    }
}
