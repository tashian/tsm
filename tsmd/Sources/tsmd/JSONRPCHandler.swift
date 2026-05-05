import Foundation

actor JSONRPCHandler {
    let vault: Vault

    init(vault: Vault) {
        self.vault = vault
    }

    func handle(_ request: JSONRPCRequest, sessionID: pid_t, peerCwd: String? = nil) async -> JSONRPCResponse {
        do {
            let result = try await dispatch(request, sessionID: sessionID, peerCwd: peerCwd)
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

    private func dispatch(_ req: JSONRPCRequest, sessionID: pid_t, peerCwd: String?) async throws -> JSONValue {
        switch req.method {
        case "vault.init":
            let passphrase = req.stringParam("recovery_passphrase")
            try await vault.initialize(recoveryPassphrase: passphrase, sessionID: sessionID)
            return .object(["ok": .bool(true)])

        case "vault.unlock":
            let passphrase = req.stringParam("passphrase")
            try await vault.unlock(passphrase: passphrase, sessionID: sessionID)
            let status = await vault.status(sessionID: sessionID)
            var resp: [String: JSONValue] = ["ok": .bool(true)]
            if let ttl = status.ttlRemainingSeconds {
                resp["ttl_remaining_seconds"] = .int(ttl)
            }
            return .object(resp)

        case "vault.lock":
            await vault.lock(sessionID: sessionID)
            return .object(["ok": .bool(true)])

        case "vault.status":
            let status = await vault.status(sessionID: sessionID)
            return encodeToJSONValue(status)

        case "vault.list":
            // include_all bypasses the cwd filter and returns every secret —
            // the CLI uses it for `tsm list --all`. Default is the safer
            // cwd-filtered view.
            let includeAll = req.param("include_all")?.boolValue ?? false
            let secrets = try await vault.list(sessionID: sessionID, peerCwd: peerCwd, includeAll: includeAll)
            return encodeToJSONValue(secrets)

        case "vault.get":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            let secret = try await vault.get(name: name, sessionID: sessionID,
                                             peerCwd: peerCwd, clientId: clientId)
            return .object(["name": .string(secret.name), "value": .string(secret.value)])

        case "vault.add":
            guard let name = req.stringParam("name"),
                  let value = req.stringParam("value") else {
                throw VaultError.invalidName("Missing 'name' or 'value' parameter")
            }
            let displayName = req.stringParam("display_name") ?? ""
            let description = req.stringParam("description") ?? ""
            let confirm = req.param("confirm")?.boolValue ?? false
            let tags: [String] = {
                if case .array(let arr) = req.param("tags") {
                    return arr.compactMap { $0.stringValue }
                }
                return []
            }()
            let scope = req.stringParam("scope") ?? SecretScope.global
            let roots: [String] = {
                if case .array(let arr) = req.param("roots") {
                    return arr.compactMap { $0.stringValue }
                }
                return []
            }()
            let clientId = req.stringParam("client_id")
            try await vault.add(name: name, displayName: displayName, value: value,
                               description: description, confirm: confirm, tags: tags,
                               scope: scope, roots: roots,
                               sessionID: sessionID, clientId: clientId)
            return .object(["ok": .bool(true)])

        case "vault.remove":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            try await vault.remove(name: name, sessionID: sessionID, clientId: clientId)
            return .object(["ok": .bool(true)])

        case "vault.edit":
            guard let name = req.stringParam("name") else {
                throw VaultError.invalidName("Missing 'name' parameter")
            }
            let clientId = req.stringParam("client_id")
            try await vault.edit(
                name: name,
                displayName: req.stringParam("display_name"),
                value: req.stringParam("value"),
                description: req.stringParam("description"),
                confirm: req.param("confirm")?.boolValue,
                tags: {
                    if case .array(let arr) = req.param("tags") {
                        return arr.compactMap { $0.stringValue }
                    }
                    return nil
                }(),
                sessionID: sessionID,
                clientId: clientId
            )
            return .object(["ok": .bool(true)])

        case "vault.config.get":
            let cfg = try await vault.getConfig(sessionID: sessionID)
            return .object(["ttl_seconds": .int(cfg.ttlSeconds)])

        case "vault.config.set":
            guard let ttl = req.param("ttl_seconds")?.intValue else {
                throw VaultError.invalidConfig("Missing or non-integer 'ttl_seconds' parameter")
            }
            let cfg = try await vault.setConfig(ttlSeconds: ttl, sessionID: sessionID)
            return .object(["ttl_seconds": .int(cfg.ttlSeconds)])

        case "vault.reset":
            // sessionID intentionally omitted: reset is gated by Touch ID
            // alone and must remain reachable while the vault is locked, so
            // a user with a forgotten passphrase can recover.
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
        case .invalidConfig(let msg):
            return JSONRPCError(
                code: RPCErrorCode.invalidParams,
                message: msg
            )
        case .secretOutOfScope(let name, let roots):
            // The CLI reads `name` and `roots` out of `data` to render the
            // hint message. Keeping the data structured (not folded into the
            // human-readable `message`) lets future tools localize or format
            // it differently.
            return JSONRPCError(
                code: RPCErrorCode.secretOutOfScope,
                message: "Secret '\(name)' is project-scoped to a different directory",
                data: [
                    "name": .string(name),
                    "roots": .array(roots.map { .string($0) }),
                ]
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
