import Foundation

actor JSONRPCHandler {
    let vault: Vault

    init(vault: Vault) {
        self.vault = vault
    }

    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        do {
            let result = try await dispatch(request)
            return JSONRPCResponse(result: result, id: request.id)
        } catch let error as VaultError {
            return JSONRPCResponse(error: mapVaultError(error), id: request.id)
        } catch let error as CryptoError {
            return JSONRPCResponse(
                error: JSONRPCError(code: RPCErrorCode.internalError, message: "\(error)"),
                id: request.id
            )
        } catch {
            return JSONRPCResponse(
                error: JSONRPCError(code: RPCErrorCode.internalError, message: error.localizedDescription),
                id: request.id
            )
        }
    }

    private func dispatch(_ req: JSONRPCRequest) async throws -> JSONValue {
        switch req.method {
        case "vault.init":
            let passphrase = req.stringParam("recovery_passphrase")
            try await vault.initialize(recoveryPassphrase: passphrase)
            return .object(["ok": .bool(true)])

        case "vault.unlock":
            let passphrase = req.stringParam("passphrase")
            try await vault.unlock(passphrase: passphrase)
            return .object(["ok": .bool(true)])

        case "vault.lock":
            await vault.lock()
            return .object(["ok": .bool(true)])

        case "vault.status":
            let status = await vault.status()
            return encodeToJSONValue(status)

        case "vault.list":
            let secrets = try await vault.list()
            return encodeToJSONValue(secrets)

        case "vault.get":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            let secret = try await vault.get(name: name, clientId: clientId)
            return .object(["name": .string(secret.name), "value": .string(secret.value)])

        case "vault.add":
            guard let name = req.stringParam("name"),
                  let value = req.stringParam("value") else {
                throw VaultError.invalidName("Missing 'name' or 'value' parameter")
            }
            let description = req.stringParam("description") ?? ""
            let confirm = req.param("confirm")?.boolValue ?? false
            let tags: [String] = {
                if case .array(let arr) = req.param("tags") {
                    return arr.compactMap { $0.stringValue }
                }
                return []
            }()
            let clientId = req.stringParam("client_id")
            try await vault.add(name: name, value: value, description: description,
                               confirm: confirm, tags: tags, clientId: clientId)
            return .object(["ok": .bool(true)])

        case "vault.remove":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            try await vault.remove(name: name, clientId: clientId)
            return .object(["ok": .bool(true)])

        case "vault.edit":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            try await vault.edit(
                name: name,
                value: req.stringParam("value"),
                description: req.stringParam("description"),
                confirm: req.param("confirm")?.boolValue,
                tags: {
                    if case .array(let arr) = req.param("tags") {
                        return arr.compactMap { $0.stringValue }
                    }
                    return nil
                }(),
                clientId: clientId
            )
            return .object(["ok": .bool(true)])

        case "vault.reset":
            let clientId = req.stringParam("client_id")
            try await vault.reset(clientId: clientId)
            return .object(["ok": .bool(true)])

        case "daemon.capabilities":
            let caps = await vault.capabilities()
            return encodeToJSONValue(caps)

        case "daemon.shutdown":
            return .object(["ok": .bool(true)])

        default:
            throw JSONRPCHandlerError.methodNotFound(req.method)
        }
    }

    private func mapVaultError(_ error: VaultError) -> JSONRPCError {
        switch error {
        case .locked:
            return JSONRPCError(
                code: RPCErrorCode.vaultLocked,
                message: "Vault is locked",
                data: ["auth_method": .string("touchid")]
            )
        case .authRequired, .authFailed:
            return JSONRPCError(
                code: RPCErrorCode.authRequired,
                message: "Authentication required",
                data: ["auth_method": .string("touchid")]
            )
        case .secretNotFound(let name):
            return JSONRPCError(
                code: RPCErrorCode.secretNotFound,
                message: "Secret not found: \(name)"
            )
        case .notInitialized:
            return JSONRPCError(
                code: RPCErrorCode.vaultLocked,
                message: "Vault not initialized. Run 'tsm init'."
            )
        case .alreadyInitialized:
            return JSONRPCError(
                code: RPCErrorCode.internalError,
                message: "Vault already initialized"
            )
        case .secretAlreadyExists(let name):
            return JSONRPCError(
                code: RPCErrorCode.invalidParams,
                message: "Secret already exists: \(name)"
            )
        case .invalidName(let msg):
            return JSONRPCError(
                code: RPCErrorCode.invalidParams,
                message: msg
            )
        }
    }

    private func encodeToJSONValue<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let jsonValue = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return jsonValue
    }
}

enum JSONRPCHandlerError: Error {
    case methodNotFound(String)
}
