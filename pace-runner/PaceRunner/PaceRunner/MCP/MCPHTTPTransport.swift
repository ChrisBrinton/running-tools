import Foundation
import Network

/// Minimal HTTP/1.1 framing over an `NWConnection`. We only need:
///   - Read one request: parse start line, headers, body via Content-Length.
///   - Write one response: status line, a few headers, body.
///   - No keep-alive (close after each), no chunked encoding, no compression.
///
/// This is exactly enough for an MCP JSON-RPC POST endpoint plus a couple of
/// liveness GETs. Resist the urge to grow it into a real HTTP server — if we
/// ever need more, swap in a proper library.

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Reads one full HTTP/1.1 request from the connection. Caps total bytes
    /// at 8 MB to avoid runaway allocations from a malformed client.
    static func read(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        var headersParsed = false
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var contentLength = 0
        var bodyStart = 0
        let maxBytes = 8 * 1024 * 1024

        while true {
            let chunk = try await receive(on: connection, max: 64 * 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.count > maxBytes {
                throw HTTPError.tooLarge
            }

            if !headersParsed {
                // Look for the end of headers (\r\n\r\n)
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: 0..<range.lowerBound)
                    guard let headerStr = String(data: headerData, encoding: .utf8) else {
                        throw HTTPError.invalidEncoding
                    }
                    let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
                    guard let startLine = lines.first else { throw HTTPError.invalidStartLine }
                    let parts = startLine.split(separator: " ", maxSplits: 2)
                    guard parts.count == 3 else { throw HTTPError.invalidStartLine }
                    method = String(parts[0])
                    path = String(parts[1])

                    for line in lines.dropFirst() where !line.isEmpty {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        // Case-insensitive header names — normalize once on read.
                        headers[name.lowercased()] = value
                    }
                    contentLength = Int(headers["content-length"] ?? "0") ?? 0
                    bodyStart = range.upperBound
                    headersParsed = true
                }
            }

            if headersParsed {
                if buffer.count - bodyStart >= contentLength {
                    let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                    // Surface headers under their canonical casing the rest of
                    // the code expects (Authorization, Content-Type, etc.)
                    let canonicalHeaders = Dictionary(uniqueKeysWithValues:
                        headers.map { (k, v) in (Self.canonicalize(k), v) }
                    )
                    return HTTPRequest(method: method, path: path,
                                       headers: canonicalHeaders, body: body)
                }
            }
        }
        throw HTTPError.unexpectedEOF
    }

    private static func canonicalize(_ name: String) -> String {
        // Authorization, Content-Type, Content-Length, etc. — title-case-by-dash
        name.split(separator: "-").map { part in
            part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }.joined(separator: "-")
    }

    private static func receive(on connection: NWConnection, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, _, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: content ?? Data())
            }
        }
    }
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
    let extraHeaders: [String: String]

    init(status: Int, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.extraHeaders = extraHeaders
    }

    static func json(status: Int = 200, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func jsonRaw(status: Int = 200, _ data: Data) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func text(status: Int = 200, _ s: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8",
                     body: Data(s.utf8))
    }

    func send(on connection: NWConnection) async throws {
        var head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        let payload = Data(head.utf8) + body
        try await Self.send(payload, on: connection)
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: ())
            })
        }
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return ""
        }
    }
}

enum HTTPError: LocalizedError {
    case tooLarge
    case invalidEncoding
    case invalidStartLine
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Request exceeded size limit"
        case .invalidEncoding: return "Request headers not valid UTF-8"
        case .invalidStartLine: return "Malformed HTTP start line"
        case .unexpectedEOF: return "Connection closed before request was complete"
        }
    }
}
