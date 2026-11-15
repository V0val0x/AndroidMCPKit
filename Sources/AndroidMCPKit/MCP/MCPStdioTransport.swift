import Foundation

/// Headless newline-delimited JSON-RPC 2.0 stdio transport for `android-mcp --stdio`.
/// Reads from `stdin`, writes JSON-RPC responses strictly to `stdout`, and logs only to `stderr`.
public enum MCPStdioTransport {
    public static func runBlocking(serverCore: MCPServerCore = .shared) {
        logError("\(serverCore.serverName) MCP stdio server started (protocol \(MCPServerCore.protocolVersion))")

        let stdinHandle = FileHandle.standardInput
        let stdoutHandle = FileHandle.standardOutput
        var buffer = Data()

        while true {
            let chunk = stdinHandle.availableData
            if chunk.isEmpty {
                break // EOF
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)

                let trimmed = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmed.isEmpty, let reqData = trimmed.data(using: .utf8) else { continue }

                let semaphore = DispatchSemaphore(value: 0)
                final class Box: @unchecked Sendable { var data: Data? }
                let box = Box()
                Task {
                    box.data = await serverCore.handleRawRequestData(reqData)
                    semaphore.signal()
                }
                semaphore.wait()

                if var resp = box.data {
                    resp.append(0x0A) // newline delimiter
                    stdoutHandle.write(resp)
                }
            }
        }
        logError("\(serverCore.serverName) MCP stdio server exiting on EOF")
    }

    private static func logError(_ message: String) {
        if let data = "[AndroidMCPKit] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
