import Foundation
import HealthKit

/// Parses JSON-RPC 2.0 messages and routes the three MCP methods we
/// implement — `initialize`, `tools/list`, and `tools/call` — to handlers.
/// Stays transport-agnostic: takes an HTTP body in, returns an HTTP response.
/// Bearer-auth is enforced here so we can return a JSON-RPC error rather than
/// a raw 401, which is friendlier to MCP client logs.
actor MCPDispatcher {

    private var token: String

    init(token: String) {
        self.token = token
    }

    func updateToken(_ newToken: String) {
        self.token = newToken
    }

    // MARK: - HTTP entry point

    func handle(httpBody: Data, authHeader: String?) async -> HTTPResponse {
        // Validate bearer first — JSON-RPC errors are returned with 200 + an
        // error payload (per JSON-RPC). HTTP 401 is reserved for the case
        // where we couldn't parse a JSON-RPC envelope at all.
        guard let auth = authHeader, auth.hasPrefix("Bearer ") else {
            return .json(status: 401, ["error": "Missing bearer token"])
        }
        let provided = String(auth.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard provided == token else {
            return .json(status: 401, ["error": "Invalid bearer token"])
        }

        // Parse JSON-RPC envelope
        guard let obj = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
            return .json(status: 400, [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error"]
            ])
        }
        let id = obj["id"] ?? NSNull()
        guard let method = obj["method"] as? String else {
            return .json([
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32600, "message": "Invalid Request — missing 'method'"]
            ])
        }
        let params = (obj["params"] as? [String: Any]) ?? [:]

        let result: Result<Any, MCPError>
        switch method {
        case "initialize":
            result = await handleInitialize(params: params)
        case "notifications/initialized":
            // No response required for notifications per JSON-RPC; clients
            // sometimes still wait for one, so we return an empty 204.
            return HTTPResponse(status: 204, contentType: "application/json", body: Data())
        case "tools/list":
            result = await handleToolsList()
        case "tools/call":
            result = await handleToolsCall(params: params)
        default:
            result = .failure(MCPError(code: -32601, message: "Method not found: \(method)"))
        }

        switch result {
        case .success(let payload):
            return .json([
                "jsonrpc": "2.0",
                "id": id,
                "result": payload
            ])
        case .failure(let err):
            return .json([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": err.code, "message": err.message]
            ])
        }
    }

    // MARK: - MCP method handlers

    private func handleInitialize(params: [String: Any]) async -> Result<Any, MCPError> {
        // We accept any client protocolVersion for v1 — just echo a recent one.
        return .success([
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [String: Any]()
            ],
            "serverInfo": [
                "name": "pacerunner-mcp",
                "version": "0.1"
            ]
        ])
    }

    private func handleToolsList() async -> Result<Any, MCPError> {
        return .success([
            "tools": MCPTools.descriptors
        ])
    }

    private func handleToolsCall(params: [String: Any]) async -> Result<Any, MCPError> {
        guard let name = params["name"] as? String else {
            return .failure(MCPError(code: -32602, message: "Missing 'name'"))
        }
        let args = (params["arguments"] as? [String: Any]) ?? [:]

        do {
            let payload = try await MCPTools.call(name: name, arguments: args)
            // MCP tools/call result wraps content blocks. We use a single text
            // block holding JSON-stringified output — that's what most clients
            // expect right now (binary/image content types are optional).
            let json = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: json, encoding: .utf8) ?? "{}"
            return .success([
                "content": [
                    ["type": "text", "text": text]
                ]
            ])
        } catch let err as MCPError {
            return .failure(err)
        } catch {
            return .failure(MCPError(code: -32000, message: error.localizedDescription))
        }
    }
}

struct MCPError: Error {
    let code: Int
    let message: String
}
