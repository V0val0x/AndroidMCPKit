import Foundation
import Dispatch
import AndroidMCPKit

private enum CLITransport {
    case stdio
    case http(port: UInt16)
}

private struct CLIConfig {
    var transport: CLITransport?
    var adbPath: String?
    var toolsDirectory: URL?
    var bearerToken: String?
    var showHelp: Bool = false
    var showVersion: Bool = false
}

private func printUsage() {
    let usage = """
    android-mcp — Zero-dependency Android MCP server & Self-Healing Visual Macro Engine

    USAGE:
      android-mcp --stdio [--adb-path <path>] [--tools-dir <path>]
      android-mcp --http [port] [--adb-path <path>] [--tools-dir <path>] [--bearer-token <token>]

    OPTIONS:
      --stdio                 Run newline-delimited JSON-RPC 2.0 over stdin/stdout (Claude Desktop, Cursor)
      --http [port]           Run loopback-only HTTP/SSE MCP server on 127.0.0.1 (default port: 8765)
      --adb-path <path>       Explicit path to the adb binary (defaults to auto-discovery)
      --tools-dir <path>      Directory for custom visual tool JSONs (default: ~/.android-mcp/mcp_tools)
      --bearer-token <token>  Optional Bearer token required by HTTP/SSE requests
      -v, --version           Print version information
      -h, --help              Show this help message

    EXAMPLES:
      android-mcp --stdio
      android-mcp --http 8765
      android-mcp --stdio --adb-path /opt/homebrew/bin/adb
    """
    print(usage)
}

private func writeStderr(_ message: String) {
    if let data = "\(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private struct CLIParseError: Error {
    let message: String
}

private func parseArguments(_ args: [String]) -> Result<CLIConfig, CLIParseError> {
    var config = CLIConfig()
    var i = 1

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            config.showHelp = true
            return .success(config)
        case "-v", "--version":
            config.showVersion = true
            return .success(config)
        case "--stdio":
            config.transport = .stdio
        case "--http":
            var port: UInt16 = 8765
            if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                guard let parsed = UInt16(args[i + 1]), parsed > 0 else {
                    return .failure(CLIParseError(message: "Invalid port '\(args[i + 1])' for --http. Expected 1...65535."))
                }
                port = parsed
                i += 1
            }
            config.transport = .http(port: port)
        case let s where s.hasPrefix("--http="):
            let rawPort = String(s.dropFirst("--http=".count))
            guard let parsed = UInt16(rawPort), parsed > 0 else {
                return .failure(CLIParseError(message: "Invalid port '\(rawPort)' for --http. Expected 1...65535."))
            }
            config.transport = .http(port: parsed)
        case "--adb-path":
            guard i + 1 < args.count else {
                return .failure(CLIParseError(message: "Missing value after --adb-path."))
            }
            config.adbPath = args[i + 1]
            i += 1
        case let s where s.hasPrefix("--adb-path="):
            config.adbPath = String(s.dropFirst("--adb-path=".count))
        case "--tools-dir":
            guard i + 1 < args.count else {
                return .failure(CLIParseError(message: "Missing value after --tools-dir."))
            }
            config.toolsDirectory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            i += 1
        case let s where s.hasPrefix("--tools-dir="):
            config.toolsDirectory = URL(fileURLWithPath: String(s.dropFirst("--tools-dir=".count)), isDirectory: true)
        case "--bearer-token":
            guard i + 1 < args.count else {
                return .failure(CLIParseError(message: "Missing value after --bearer-token."))
            }
            config.bearerToken = args[i + 1]
            i += 1
        case let s where s.hasPrefix("--bearer-token="):
            config.bearerToken = String(s.dropFirst("--bearer-token=".count))
        default:
            return .failure(CLIParseError(message: "Unknown argument '\(arg)'. Run with --help for usage."))
        }
        i += 1
    }

    return .success(config)
}

switch parseArguments(CommandLine.arguments) {
case .failure(let err):
    writeStderr("Error: \(err.message)")
    exit(1)
case .success(let config):
    if config.showHelp {
        printUsage()
        exit(0)
    }
    if config.showVersion {
        print("AndroidMCPKit 1.0.0 (MCP protocol \(MCPServerCore.protocolVersion))")
        exit(0)
    }

    guard let transport = config.transport else {
        writeStderr("No transport specified. Pass --stdio or --http [port]. Run --help for usage.")
        exit(1)
    }

    let driver = StandaloneADBAutomationDriver(adbPath: config.adbPath)
    let registry = config.toolsDirectory.map { CustomMCPToolRegistry(directoryURL: $0) } ?? CustomMCPToolRegistry.shared
    let core = MCPServerCore(driver: driver, registry: registry)
    core.onSelfHealingNotice = { (event: MCPSelfHealingEvent) in
        writeStderr("[AndroidMCPKit][SelfHealing] tool=\(event.toolName) expected='\(event.expectedLabel)' matched='\(event.matchedText)' at (\(event.x), \(event.y))")
    }

    switch transport {
    case .stdio:
        MCPStdioTransport.runBlocking(serverCore: core)
        exit(0)
    case .http(let port):
        let server = MCPHTTPServer(serverCore: core)
        server.bearerToken = config.bearerToken

        let semaphore = DispatchSemaphore(value: 0)
        final class StartState: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            var ok = false
            func complete(_ value: Bool, signal sem: DispatchSemaphore) {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                ok = value
                lock.unlock()
                sem.signal()
            }
        }
        let state = StartState()
        server.start(port: port) { running in
            state.complete(running, signal: semaphore)
        }
        semaphore.wait()

        guard state.ok else {
            writeStderr("Failed to bind MCP HTTP/SSE server to 127.0.0.1:\(port)")
            exit(1)
        }

        writeStderr("[AndroidMCPKit] HTTP/SSE MCP server listening on http://127.0.0.1:\(port)/sse (protocol \(MCPServerCore.protocolVersion))")

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let shutdown: () -> Void = {
            writeStderr("[AndroidMCPKit] Shutting down HTTP/SSE MCP server...")
            server.stop()
            ProcessSupervisor.shared.terminateAllProcesses(synchronousWait: true)
            exit(0)
        }
        sigintSrc.setEventHandler(handler: shutdown)
        sigtermSrc.setEventHandler(handler: shutdown)
        sigintSrc.resume()
        sigtermSrc.resume()

        dispatchMain()
    }
}
