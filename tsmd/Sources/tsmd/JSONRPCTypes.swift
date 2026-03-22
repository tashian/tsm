import Foundation

// MARK: - Dynamic JSON type

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v } else { return nil }
    }
    var intValue: Int? {
        if case .int(let v) = self { return v } else { return nil }
    }
    var boolValue: Bool? {
        if case .bool(let v) = self { return v } else { return nil }
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v } else { return nil }
    }
}

// MARK: - JSON-RPC 2.0 types

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: [String: JSONValue]?
    let id: JSONValue

    func param(_ key: String) -> JSONValue? {
        params?[key]
    }
    func stringParam(_ key: String) -> String? {
        params?[key]?.stringValue
    }
}

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let result: JSONValue?
    let error: JSONRPCError?
    let id: JSONValue

    init(result: JSONValue, id: JSONValue) {
        self.jsonrpc = "2.0"
        self.result = result
        self.error = nil
        self.id = id
    }

    init(error: JSONRPCError, id: JSONValue) {
        self.jsonrpc = "2.0"
        self.result = nil
        self.error = error
        self.id = id
    }
}

struct JSONRPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: [String: JSONValue]?

    init(code: Int, message: String, data: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - Error codes

enum RPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    // tsm-specific
    static let vaultLocked = -32001
    static let authRequired = -32002
    static let secretNotFound = -32003
}
