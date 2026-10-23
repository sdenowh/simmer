//
//  MCPProtocol.swift
//  Simmer
//
//  JSON-RPC and stdio framing for the Model Context Protocol.
//

import Foundation

enum MCPProcess {
    static var stdio = false
}

enum SimmerMCPConfig {
    static let port: UInt16 = 8787
    static let endpointPath = "/mcp"
    static let instructions = "Simmer manages iOS Simulator app data. List simulators, then apps, then snapshots. create_snapshot copies Documents and leaves the live folder unchanged. restore_snapshot terminates the app and replaces its Documents folder. send_push_notification delivers an APNs payload to a booted simulator."

    static var httpURL: String { "http://127.0.0.1:\(port)\(endpointPath)" }

    static var marketingVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version.contains(".") {
            return version
        }
        return "2.0.0"
    }

    static func httpServerEntry() -> [String: Any] {
        ["mcpServers": ["simmer": ["url": httpURL]]]
    }

    static func stdioServerEntry(executablePath: String) -> [String: Any] {
        ["mcpServers": ["simmer": ["command": executablePath, "args": ["--mcp"]]]]
    }

    static func pretty(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

struct MCPBackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol MCPBackend: AnyObject {
    func mcpListSimulators() throws -> [[String: Any]]
    func mcpListApps(simulator: String) throws -> [[String: Any]]
    func mcpListSnapshots(simulator: String, bundleId: String) throws -> [[String: Any]]
    func mcpCreateSnapshot(simulator: String, bundleId: String, displayName: String?) throws -> [String: Any]
    func mcpRestoreSnapshot(simulator: String, bundleId: String, snapshot: String) throws -> [String: Any]
    func mcpSendPush(simulator: String, bundleId: String, payloadJSON: String, name: String?) throws -> [String: Any]
}

struct MCPMatchItem: Equatable {
    var id: String
    var names: [String]
}

enum MCPMatch: Equatable {
    case match(String)
    case none
    case ambiguous([String])
}

func mcpMatch(query: String, items: [MCPMatchItem]) -> MCPMatch {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return .none }

    let exactIDs = items.filter { $0.id.compare(query, options: .caseInsensitive) == .orderedSame }
    if exactIDs.count == 1 { return .match(exactIDs[0].id) }
    if exactIDs.count > 1 { return .ambiguous(exactIDs.map(\.id)) }

    let named = items.filter { item in
        item.names.contains { $0.compare(query, options: .caseInsensitive) == .orderedSame }
    }
    if named.count == 1 { return .match(named[0].id) }
    if named.count > 1 { return .ambiguous(named.map(\.id)) }
    return .none
}

enum MCPFrameResult: Equatable {
    case needMore
    case message(Data)
    case invalid
}

enum MCPFrame {
    static let maxMessageBytes = 2_000_000

    static func encode(_ payload: Data) -> Data {
        var frame = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        frame.append(payload)
        return frame
    }

    static func extract(_ buffer: inout Data) -> MCPFrameResult {
        guard let separator = headerSeparator(in: buffer) else {
            if buffer.count > 16_384 { return .invalid }
            return .needMore
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8),
              let length = contentLength(in: header),
              length >= 0,
              length <= maxMessageBytes else {
            return .invalid
        }
        let bodyStart = separator.upperBound
        if buffer.distance(from: bodyStart, to: buffer.endIndex) < length {
            return .needMore
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let message = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return .message(message)
    }

    private static func headerSeparator(in buffer: Data) -> Range<Data.Index>? {
        let crlf = Data("\r\n\r\n".utf8)
        let lf = Data("\n\n".utf8)
        let crlfRange = buffer.range(of: crlf)
        let lfRange = buffer.range(of: lf)
        switch (crlfRange, lfRange) {
        case let (crlf?, lf?):
            return crlf.lowerBound <= lf.lowerBound ? crlf : lf
        case let (crlf?, nil):
            return crlf
        case let (nil, lf?):
            return lf
        case (nil, nil):
            return nil
        }
    }

    private static func contentLength(in header: String) -> Int? {
        let lines = header.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

enum MCPDispatcher {
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    static let preferredProtocolVersion = "2025-03-26"

    static func respond(toPayload payload: Data, backend: MCPBackend, serverVersion: String = SimmerMCPConfig.marketingVersion) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) else {
            return encode(rpcError(id: nil, code: -32700, message: "Parse error"))
        }
        guard let request = object as? [String: Any] else {
            return encode(rpcError(id: nil, code: -32600, message: "Invalid request"))
        }
        guard let response = respond(to: request, backend: backend, serverVersion: serverVersion) else {
            return nil
        }
        return encode(response)
    }

    static func respond(to request: [String: Any], backend: MCPBackend, serverVersion: String = SimmerMCPConfig.marketingVersion) -> [String: Any]? {
        let method = request["method"] as? String
        if method?.hasPrefix("notifications/") == true || request["id"] == nil {
            return nil
        }
        guard let method else {
            return rpcError(id: request["id"], code: -32600, message: "Invalid request")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = (requested != nil && supportedProtocolVersions.contains(requested!)) ? requested! : preferredProtocolVersion
            return rpcResult(id: request["id"], result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "Simmer", "version": serverVersion],
                "instructions": SimmerMCPConfig.instructions
            ])
        case "ping":
            return rpcResult(id: request["id"], result: [String: Any]())
        case "tools/list":
            return rpcResult(id: request["id"], result: ["tools": toolDefinitions])
        case "tools/call":
            do {
                return rpcResult(id: request["id"], result: try callTool(params: params, backend: backend))
            } catch {
                return rpcResult(id: request["id"], result: toolContent(text: error.localizedDescription, isError: true))
            }
        default:
            return rpcError(id: request["id"], code: -32601, message: "Method not found")
        }
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func rpcResult(id: Any?, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private static func rpcError(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
    }

    private static func toolContent(text: String, isError: Bool) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ]
    }

    private static func callTool(params: [String: Any], backend: MCPBackend) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPBackendError(message: "Tool name is required.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let value: Any
        switch name {
        case "list_simulators":
            value = try backend.mcpListSimulators()
        case "list_apps":
            guard let simulator = stringArg(arguments, "simulator", "udid") else {
                throw MCPBackendError(message: "Pass a simulator UDID or unique simulator name.")
            }
            value = try backend.mcpListApps(simulator: simulator)
        case "list_snapshots":
            guard let simulator = stringArg(arguments, "simulator", "udid") else {
                throw MCPBackendError(message: "Pass a simulator UDID or unique simulator name.")
            }
            guard let bundleId = stringArg(arguments, "bundleId", "bundleIdentifier") else {
                throw MCPBackendError(message: "Pass a bundle id or unique app name.")
            }
            value = try backend.mcpListSnapshots(simulator: simulator, bundleId: bundleId)
        case "create_snapshot":
            guard let simulator = stringArg(arguments, "simulator", "udid") else {
                throw MCPBackendError(message: "Pass a simulator UDID or unique simulator name.")
            }
            guard let bundleId = stringArg(arguments, "bundleId", "bundleIdentifier") else {
                throw MCPBackendError(message: "Pass a bundle id or unique app name.")
            }
            value = try backend.mcpCreateSnapshot(
                simulator: simulator,
                bundleId: bundleId,
                displayName: stringArg(arguments, "name")
            )
        case "restore_snapshot":
            guard let simulator = stringArg(arguments, "simulator", "udid") else {
                throw MCPBackendError(message: "Pass a simulator UDID or unique simulator name.")
            }
            guard let bundleId = stringArg(arguments, "bundleId", "bundleIdentifier") else {
                throw MCPBackendError(message: "Pass a bundle id or unique app name.")
            }
            guard let snapshot = stringArg(arguments, "snapshot", "id") else {
                throw MCPBackendError(message: "Pass a snapshot id or display name.")
            }
            value = try backend.mcpRestoreSnapshot(simulator: simulator, bundleId: bundleId, snapshot: snapshot)
        case "send_push_notification":
            guard let simulator = stringArg(arguments, "simulator", "udid") else {
                throw MCPBackendError(message: "Pass a simulator UDID or unique simulator name.")
            }
            guard let bundleId = stringArg(arguments, "bundleId", "bundleIdentifier") else {
                throw MCPBackendError(message: "Pass a bundle id or unique app name.")
            }
            let (payload, name) = try pushPayload(from: arguments)
            value = try backend.mcpSendPush(simulator: simulator, bundleId: bundleId, payloadJSON: payload, name: name)
        default:
            throw MCPBackendError(message: "Unknown tool \(name).")
        }
        return toolContent(text: SimmerMCPConfig.pretty(value), isError: false)
    }

    private static func stringArg(_ arguments: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            guard let value = arguments[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func pushPayload(from arguments: [String: Any]) throws -> (String, String?) {
        let name = stringArg(arguments, "name")
        if let payload = arguments["payload"] {
            if let text = payload as? String {
                return (text, name)
            }
            guard let object = payload as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
                throw MCPBackendError(message: "Payload must be a JSON object or a JSON string.")
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            guard let text = String(data: data, encoding: .utf8) else {
                throw MCPBackendError(message: "Payload could not be encoded.")
            }
            return (text, name)
        }
        let title = stringArg(arguments, "title")
        let body = stringArg(arguments, "body")
        if title == nil && body == nil {
            throw MCPBackendError(message: "Pass a payload object, or a title and body.")
        }
        var alert: [String: String] = [:]
        if let title { alert["title"] = title }
        if let body { alert["body"] = body }
        let object: [String: Any] = ["aps": ["alert": alert, "sound": "default"]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return (text, name ?? title)
    }

    private static var toolDefinitions: [[String: Any]] {
        [
            tool(
                "list_simulators",
                "List iOS Simulators that have apps installed, including UDID, name, runtime, and whether the simulator is booted.",
                required: [],
                properties: [:]
            ),
            tool(
                "list_apps",
                "List apps installed on a simulator.",
                required: ["simulator"],
                properties: [
                    "simulator": stringProp("Simulator UDID or unique simulator name.")
                ]
            ),
            tool(
                "list_snapshots",
                "List Documents snapshots for an app on a simulator.",
                required: ["simulator", "bundleId"],
                properties: [
                    "simulator": stringProp("Simulator UDID or unique simulator name."),
                    "bundleId": stringProp("App bundle identifier or unique app name.")
                ]
            ),
            tool(
                "create_snapshot",
                "Copy an app's Documents folder into a new snapshot. The live Documents folder is left unchanged.",
                required: ["simulator", "bundleId"],
                properties: [
                    "simulator": stringProp("Simulator UDID or unique simulator name."),
                    "bundleId": stringProp("App bundle identifier or unique app name."),
                    "name": stringProp("Optional display name stored with the snapshot.")
                ]
            ),
            tool(
                "restore_snapshot",
                "Terminate the app and replace its live Documents folder with a snapshot. The previous Documents contents are removed after the copy is checked.",
                required: ["simulator", "bundleId", "snapshot"],
                properties: [
                    "simulator": stringProp("Simulator UDID or unique simulator name."),
                    "bundleId": stringProp("App bundle identifier or unique app name."),
                    "snapshot": stringProp("Snapshot id or display name.")
                ]
            ),
            tool(
                "send_push_notification",
                "Send a push notification to an app on a booted simulator.",
                required: ["simulator", "bundleId"],
                properties: [
                    "simulator": stringProp("Simulator UDID or unique simulator name."),
                    "bundleId": stringProp("App bundle identifier or unique app name."),
                    "payload": [
                        "type": "object",
                        "description": "APNs payload. Optional when title or body is set.",
                        "additionalProperties": true
                    ],
                    "title": stringProp("Alert title used when payload is omitted."),
                    "body": stringProp("Alert body used when payload is omitted."),
                    "name": stringProp("Optional label saved in Simmer's push history.")
                ]
            )
        ]
    }

    private static func tool(_ name: String, _ description: String, required: [String], properties: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }

    private static func stringProp(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }
}
