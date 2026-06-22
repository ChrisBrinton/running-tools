import Foundation
import Network
import Combine

/// In-app MCP server. Listens on a local TCP port, speaks HTTP/1.1, parses
/// JSON-RPC 2.0, dispatches to MCP tools, and publishes itself on the local
/// network via Bonjour (`_mcp._tcp`).
///
/// Design notes:
///  - Foreground-only by design. iOS will tear the listener down when the app
///    is suspended; the UI shows server state so the user knows when it's up.
///  - No TLS in v1 — local-network only. Bearer auth (6-digit pairing code)
///    is the only barrier.
///  - HTTP framing is hand-rolled because Network.framework gives us TCP and
///    nothing higher-level. We only need POST /mcp (JSON in/out) and a couple
///    of GETs for liveness, so this stays manageable.
///  - Connections are short-lived: parse request → dispatch → reply → close.
///    Keep-alive is a fine v2 addition once usage justifies it.
@MainActor
final class MCPServer: ObservableObject {

    static let shared = MCPServer()

    // MARK: - Published state for the UI

    @Published private(set) var state: State = .stopped
    @Published private(set) var pairingCode: String = ""
    @Published private(set) var host: String = ""
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var connectedClients: Int = 0
    @Published private(set) var requestLog: [LogEntry] = []

    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let method: String
        let toolName: String?
        let ok: Bool
        let detail: String
    }

    // MARK: - Server internals

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mcp.server.queue")
    private let preferredPort: UInt16 = 8765
    private var dispatcher: MCPDispatcher?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard state == .stopped || isFailed else { return }
        state = .starting
        pairingCode = Self.generatePairingCode()
        host = Self.localHostName()
        let dispatcher = MCPDispatcher(token: pairingCode)
        self.dispatcher = dispatcher

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .init(rawValue: preferredPort) ?? .any)
            listener.service = NWListener.Service(name: "PaceRunner", type: "_mcp._tcp")

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    self?.handleListenerState(newState)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            state = .failed("Failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        dispatcher = nil
        connectedClients = 0
        state = .stopped
    }

    func regeneratePairingCode() {
        pairingCode = Self.generatePairingCode()
        // updateToken is actor-isolated; hop off the @MainActor sync context.
        let newCode = pairingCode
        let d = dispatcher
        Task { await d?.updateToken(newCode) }
    }

    // MARK: - Listener events

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            if let actualPort = listener?.port?.rawValue {
                port = actualPort
            }
            state = .running
            appendLog(method: "—", tool: nil, ok: true, detail: "Listening on \(host):\(port)")
        case .failed(let err):
            state = .failed(err.localizedDescription)
        case .cancelled:
            state = .stopped
        default:
            break
        }
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        Task { @MainActor in connectedClients += 1 }
        connection.start(queue: queue)
        Task.detached { [weak self] in
            defer {
                connection.cancel()
                Task { @MainActor in
                    guard let self else { return }
                    self.connectedClients = max(0, self.connectedClients - 1)
                }
            }
            await self?.handleConnection(connection)
        }
    }

    private func handleConnection(_ connection: NWConnection) async {
        do {
            let request = try await HTTPRequest.read(from: connection)
            let response = await route(request)
            try await response.send(on: connection)
            await logRequest(request: request, response: response)
        } catch {
            // Best-effort send of a generic 500 if we can; ignore secondary failures.
            let r = HTTPResponse(status: 500, contentType: "text/plain",
                                 body: Data("Server error: \(error.localizedDescription)".utf8))
            try? await r.send(on: connection)
            await MainActor.run {
                self.appendLog(method: "—", tool: nil, ok: false,
                               detail: "Connection error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Routing

    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/health"):
            return .json(["ok": true, "service": "pacerunner-mcp", "version": 1])

        case ("POST", "/mcp"):
            guard let dispatcher else {
                return .json(status: 503, ["error": "Server not initialized"])
            }
            return await dispatcher.handle(httpBody: req.body, authHeader: req.headers["Authorization"])

        default:
            return .json(status: 404, ["error": "Not found", "method": req.method, "path": req.path])
        }
    }

    // MARK: - Logging

    @MainActor
    private func logRequest(request: HTTPRequest, response: HTTPResponse) async {
        let method = "\(request.method) \(request.path)"
        let detail: String
        var toolName: String? = nil
        // Pull the tool name out of the body if this was a tools/call.
        if request.path == "/mcp", let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            if let m = body["method"] as? String {
                if m == "tools/call", let p = body["params"] as? [String: Any], let n = p["name"] as? String {
                    toolName = n
                    detail = "tools/call \(n) → \(response.status)"
                } else {
                    detail = "\(m) → \(response.status)"
                }
            } else {
                detail = "→ \(response.status)"
            }
        } else {
            detail = "→ \(response.status)"
        }
        appendLog(method: method, tool: toolName, ok: response.status < 400, detail: detail)
    }

    private func appendLog(method: String, tool: String?, ok: Bool, detail: String) {
        let entry = LogEntry(timestamp: Date(), method: method, toolName: tool, ok: ok, detail: detail)
        requestLog.insert(entry, at: 0)
        if requestLog.count > 100 {
            requestLog.removeLast(requestLog.count - 100)
        }
    }

    // MARK: - Helpers

    private static func generatePairingCode() -> String {
        // 6-digit numeric; trivially typeable into an MCP client config.
        var code = ""
        for _ in 0..<6 { code += String(Int.random(in: 0...9)) }
        return code
    }

    private static func localHostName() -> String {
        // ProcessInfo.hostName ends in ".local" on iOS — exactly what we want
        // for a Bonjour-discoverable URL like http://Christophers-iPhone.local:8765
        let raw = ProcessInfo.processInfo.hostName
        return raw.hasSuffix(".local") ? raw : "\(raw).local"
    }
}
