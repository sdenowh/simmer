//
//  MCPHTTPServer.swift
//  Simmer
//
//  Loopback HTTP transport for MCP clients.
//

import Foundation
import Network
import SwiftUI

final class MCPRuntimeStatus: ObservableObject {
    static let shared = MCPRuntimeStatus()

    @Published var isRunning = false
    @Published var detail = "Starting…"

    func noteReady(port: UInt16) {
        DispatchQueue.main.async {
            self.isRunning = true
            self.detail = "127.0.0.1:\(port)"
        }
    }

    func noteFailure(_ message: String) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.detail = message
        }
    }
}

struct MCPHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> MCPHTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return MCPHTTPRequest(method: String(parts[0]), path: pathOnly(String(parts[1])), headers: headers, body: Data())
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 else { return nil }
        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        return MCPHTTPRequest(
            method: String(parts[0]),
            path: pathOnly(String(parts[1])),
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        )
    }

    private static func pathOnly(_ raw: String) -> String {
        let path = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}

struct MCPHTTPResponse {
    var status: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(reason)"]
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        for key in fields.keys.sorted() {
            lines.append("\(key): \(fields[key] ?? "")")
        }
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }
}

func mcpHTTPHandle(_ request: MCPHTTPRequest, backend: MCPBackend) -> MCPHTTPResponse {
    if !mcpOriginAllowed(request.headers["origin"]) {
        return mcpTextResponse(403, "Forbidden", "Simmer MCP only accepts local clients.")
    }
    if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
        return mcpTextResponse(400, "Bad Request", "Chunked transfer is not supported.")
    }

    let path = request.path
    if request.method == "OPTIONS" {
        return MCPHTTPResponse(status: 204, reason: "No Content", headers: mcpCORSHeaders(allow: "POST, GET, DELETE, OPTIONS", origin: request.headers["origin"]), body: Data())
    }
    if request.method == "GET", path == "/" {
        let body = Data(SimmerMCPConfig.pretty([
            "name": "Simmer",
            "version": SimmerMCPConfig.marketingVersion,
            "endpoint": SimmerMCPConfig.httpURL
        ]).utf8)
        return mcpJSONResponse(200, "OK", body, origin: request.headers["origin"])
    }
    if request.method == "GET", path == SimmerMCPConfig.endpointPath {
        var response = mcpTextResponse(405, "Method Not Allowed", "POST JSON-RPC messages to this path.")
        response.headers["Allow"] = "POST"
        return response
    }
    if request.method == "DELETE", path == SimmerMCPConfig.endpointPath {
        return MCPHTTPResponse(status: 204, reason: "No Content", headers: mcpCORSHeaders(allow: "POST, GET, DELETE, OPTIONS", origin: request.headers["origin"]), body: Data())
    }
    guard request.method == "POST", path == "/" || path == SimmerMCPConfig.endpointPath else {
        return mcpTextResponse(404, "Not Found", "MCP endpoint is \(SimmerMCPConfig.endpointPath)")
    }
    if request.body.count > MCPFrame.maxMessageBytes {
        return mcpTextResponse(413, "Payload Too Large", "Payload is too large.")
    }
    guard let responseBody = MCPDispatcher.respond(toPayload: request.body, backend: backend) else {
        return MCPHTTPResponse(status: 202, reason: "Accepted", headers: mcpCORSHeaders(allow: "POST, GET, DELETE, OPTIONS", origin: request.headers["origin"]), body: Data())
    }
    return mcpJSONResponse(200, "OK", responseBody, origin: request.headers["origin"])
}

func mcpOriginAllowed(_ origin: String?) -> Bool {
    guard let origin, !origin.isEmpty, origin != "null" else { return true }
    guard let components = URLComponents(string: origin), let host = components.host?.lowercased() else { return false }
    guard components.scheme == "http" || components.scheme == "https" else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1"
}

private func mcpCORSHeaders(allow: String, origin: String?) -> [String: String] {
    var headers = [
        "Access-Control-Allow-Methods": allow,
        "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version",
        "Cache-Control": "no-store"
    ]
    if let origin, mcpOriginAllowed(origin), origin != "null" {
        headers["Access-Control-Allow-Origin"] = origin
    }
    return headers
}

private func mcpJSONResponse(_ status: Int, _ reason: String, _ body: Data, origin: String?) -> MCPHTTPResponse {
    var headers = mcpCORSHeaders(allow: "POST, GET, DELETE, OPTIONS", origin: origin)
    headers["Content-Type"] = "application/json; charset=utf-8"
    return MCPHTTPResponse(status: status, reason: reason, headers: headers, body: body)
}

private func mcpTextResponse(_ status: Int, _ reason: String, _ text: String) -> MCPHTTPResponse {
    var headers = mcpCORSHeaders(allow: "POST, GET, DELETE, OPTIONS", origin: nil)
    headers["Content-Type"] = "text/plain; charset=utf-8"
    return MCPHTTPResponse(status: status, reason: reason, headers: headers, body: Data(text.utf8))
}

final class MCPHTTPServer {
    let backend: MCPBackend
    let publishesStatus: Bool
    private let queue = DispatchQueue(label: "com.simmer.mcp.http")
    private let toolQueue = DispatchQueue(label: "com.simmer.mcp.tools")
    private var listener: NWListener?
    var onReady: ((UInt16) -> Void)?

    init(backend: MCPBackend, publishesStatus: Bool = false) {
        self.backend = backend
        self.publishesStatus = publishesStatus
    }

    func start(port: UInt16 = SimmerMCPConfig.port) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let bound = self.listener?.port?.rawValue ?? port
                if self.publishesStatus {
                    MCPRuntimeStatus.shared.noteReady(port: bound)
                }
                self.onReady?(bound)
            case .failed(let error):
                if self.publishesStatus {
                    MCPRuntimeStatus.shared.noteFailure(error.localizedDescription)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection: connection, buffer: Data())
    }

    private func read(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = MCPHTTPRequest.parse(buffer) {
                self.toolQueue.async {
                    let response = mcpHTTPHandle(request, backend: self.backend).serialized()
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }
            if isComplete || error != nil || buffer.count > MCPFrame.maxMessageBytes + 16_384 {
                connection.cancel()
                return
            }
            self.read(connection: connection, buffer: buffer)
        }
    }
}
