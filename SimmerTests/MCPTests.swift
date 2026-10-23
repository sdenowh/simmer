//
//  MCPTests.swift
//  SimmerTests
//

import Foundation
import Testing
@testable import Simmer

final class FakeMCPBackend: MCPBackend {
    var createdName: String?
    var restoredSnapshot: String?
    var pushedPayload: String?
    var pushedName: String?

    func mcpListSimulators() throws -> [[String: Any]] {
        [["udid": "SIM", "name": "iPhone 16", "booted": true]]
    }

    func mcpListApps(simulator: String) throws -> [[String: Any]] {
        [["bundleId": "com.example.app", "name": "Example", "ready": true]]
    }

    func mcpListSnapshots(simulator: String, bundleId: String) throws -> [[String: Any]] {
        [["id": "snapshot_1", "name": "Before"]]
    }

    func mcpCreateSnapshot(simulator: String, bundleId: String, displayName: String?) throws -> [String: Any] {
        createdName = displayName
        return ["id": "snapshot_new", "name": displayName ?? "snapshot_new", "bundleId": bundleId, "udid": simulator]
    }

    func mcpRestoreSnapshot(simulator: String, bundleId: String, snapshot: String) throws -> [String: Any] {
        restoredSnapshot = snapshot
        return ["id": snapshot, "bundleId": bundleId, "udid": simulator]
    }

    func mcpSendPush(simulator: String, bundleId: String, payloadJSON: String, name: String?) throws -> [String: Any] {
        pushedPayload = payloadJSON
        pushedName = name
        return ["sent": true, "bundleId": bundleId, "udid": simulator]
    }
}

struct MCPMatchTests {
    @Test func prefersAnExactIdOverASharedName() {
        let items = [
            MCPMatchItem(id: "AAA", names: ["Phone"]),
            MCPMatchItem(id: "BBB", names: ["Phone"])
        ]
        #expect(mcpMatch(query: "aaa", items: items) == .match("AAA"))
        #expect(mcpMatch(query: "Phone", items: items) == .ambiguous(["AAA", "BBB"]))
        #expect(mcpMatch(query: "missing", items: items) == .none)
    }

    @Test func oneDisplayNameMatches() {
        let items = [MCPMatchItem(id: "snapshot_1", names: ["snapshot_1", "Before release"])]
        #expect(mcpMatch(query: "before release", items: items) == .match("snapshot_1"))
    }
}

struct MCPFrameTests {
    @Test func roundTripsAMessageAndKeepsTheRemainder() {
        let first = MCPFrame.encode(Data("{\"a\":1}".utf8))
        let second = MCPFrame.encode(Data("{\"b\":2}".utf8))
        var buffer = Data(first.prefix(4))
        #expect(MCPFrame.extract(&buffer) == .needMore)
        buffer.append(first.dropFirst(4))
        buffer.append(second)
        guard case .message(let payload) = MCPFrame.extract(&buffer) else {
            Issue.record("Expected the first message")
            return
        }
        #expect(String(data: payload, encoding: .utf8) == "{\"a\":1}")
        guard case .message(let next) = MCPFrame.extract(&buffer) else {
            Issue.record("Expected the second message")
            return
        }
        #expect(String(data: next, encoding: .utf8) == "{\"b\":2}")
        #expect(buffer.isEmpty)
    }
}

struct MCPDispatcherTests {
    @Test func initializeEchoesASupportedProtocolVersion() throws {
        let response = MCPDispatcher.respond(to: [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"]
        ], backend: FakeMCPBackend(), serverVersion: "2.0.0")
        let result = try #require(response?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "Simmer")
        #expect(info["version"] as? String == "2.0.0")
    }

    @Test func initializedNotificationHasNoResponse() {
        let response = MCPDispatcher.respond(to: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ], backend: FakeMCPBackend(), serverVersion: "2.0.0")
        #expect(response == nil)
    }

    @Test func toolsCoverSnapshotsAndPush() throws {
        let response = MCPDispatcher.respond(to: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ], backend: FakeMCPBackend(), serverVersion: "2.0.0")
        let result = try #require(response?["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.contains("create_snapshot"))
        #expect(names.contains("restore_snapshot"))
        #expect(names.contains("send_push_notification"))
        #expect(names.contains("list_simulators"))
    }

    @Test func createRestoreAndPushReachTheBackend() throws {
        let backend = FakeMCPBackend()
        _ = MCPDispatcher.respond(to: call("create_snapshot", [
            "simulator": "SIM",
            "bundleId": "com.example.app",
            "name": "Before"
        ], id: 2), backend: backend, serverVersion: "2.0.0")
        #expect(backend.createdName == "Before")

        _ = MCPDispatcher.respond(to: call("restore_snapshot", [
            "udid": "SIM",
            "bundleIdentifier": "com.example.app",
            "snapshot": "snapshot_1"
        ], id: 3), backend: backend, serverVersion: "2.0.0")
        #expect(backend.restoredSnapshot == "snapshot_1")

        let push = MCPDispatcher.respond(to: call("send_push_notification", [
            "simulator": "SIM",
            "bundleId": "com.example.app",
            "title": "Hi",
            "body": "There"
        ], id: 4), backend: backend, serverVersion: "2.0.0")
        let payload = try #require(backend.pushedPayload)
        let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let aps = try #require(json["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Hi")
        #expect(alert["body"] as? String == "There")
        #expect(toolIsError(push) == false)
    }

    @Test func missingArgumentsAndUnknownToolsAreToolErrors() throws {
        let missing = MCPDispatcher.respond(to: call("create_snapshot", [:], id: 5), backend: FakeMCPBackend(), serverVersion: "2.0.0")
        #expect(toolIsError(missing))
        #expect(try #require(toolText(missing)).contains("simulator"))

        let unknown = MCPDispatcher.respond(to: call("delete_everything", [:], id: 6), backend: FakeMCPBackend(), serverVersion: "2.0.0")
        #expect(toolIsError(unknown))
    }
}

struct MCPHTTPTests {
    @Test func rejectsARemoteOrigin() throws {
        let request = MCPHTTPRequest(method: "POST", path: "/mcp", headers: ["origin": "https://evil.example"], body: Data("{}".utf8))
        let response = mcpHTTPHandle(request, backend: FakeMCPBackend())
        #expect(response.status == 403)
    }

    @Test func postsJSONRPCOverTheLoopbackServer() throws {
        let backend = FakeMCPBackend()
        let server = MCPHTTPServer(backend: backend, publishesStatus: false)
        let ready = DispatchSemaphore(value: 0)
        var bound: UInt16 = 0
        server.onReady = { port in
            bound = port
            ready.signal()
        }
        try server.start(port: 0)
        defer { server.stop() }
        #expect(ready.wait(timeout: .now() + 3) == .success)
        #expect(bound != 0)

        let payload = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"restore_snapshot","arguments":{"simulator":"SIM","bundleId":"com.example.app","snapshot":"snapshot_1"}}}"#.utf8)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(bound)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = payload
        let (data, response) = try blockingHTTP(request)
        #expect(response.statusCode == 200)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(toolIsError(decoded) == false)
        #expect(backend.restoredSnapshot == "snapshot_1")
    }
}

private func call(_ name: String, _ arguments: [String: Any], id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": ["name": name, "arguments": arguments]
    ]
}

private func toolText(_ response: [String: Any]?) -> String? {
    let result = response?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String
}

private func toolIsError(_ response: [String: Any]?) -> Bool {
    (response?["result"] as? [String: Any])?["isError"] as? Bool ?? false
}

private func blockingHTTP(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, URLResponse), Error>?
    let session = URLSession(configuration: .ephemeral)
    session.dataTask(with: request) { data, response, error in
        if let error {
            result = .failure(error)
        } else if let data, let response {
            result = .success((data, response))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        semaphore.signal()
    }.resume()
    if semaphore.wait(timeout: .now() + 3) == .timedOut {
        throw URLError(.timedOut)
    }
    let (data, response) = try result!.get()
    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    return (data, http)
}
