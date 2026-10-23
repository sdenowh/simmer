//
//  MCPStdio.swift
//  Simmer
//
//  Stdio transport used when the app is launched with --mcp.
//

import Foundation

final class MCPStdioServer {
    let backend: MCPBackend

    init(backend: MCPBackend) {
        self.backend = backend
    }

    func run() {
        MCPProcess.stdio = true
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        var buffer = Data()
        while true {
            do {
                guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { return }
                buffer.append(chunk)
            } catch {
                return
            }
            var extracting = true
            while extracting {
                switch MCPFrame.extract(&buffer) {
                case .needMore:
                    extracting = false
                case .invalid:
                    buffer.removeAll()
                    write(MCPDispatcher.encode([
                        "jsonrpc": "2.0",
                        "id": NSNull(),
                        "error": ["code": -32700, "message": "Parse error"]
                    ]), to: output)
                case .message(let payload):
                    if let response = MCPDispatcher.respond(toPayload: payload, backend: backend) {
                        write(response, to: output)
                    }
                }
            }
        }
    }

    private func write(_ payload: Data, to output: FileHandle) {
        do {
            try output.write(contentsOf: MCPFrame.encode(payload))
        } catch {
            NSLog("[Simmer] MCP stdout write failed: \(error.localizedDescription)")
        }
    }
}
