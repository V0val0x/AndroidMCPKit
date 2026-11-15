import Foundation

// MARK: - JSON-RPC 2.0 & MCP Types

public enum MCPJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([MCPJSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: MCPJSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: [String: MCPJSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

public struct MCPJSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String?
    public let id: MCPJSONValue?
    public let method: String
    public let params: [String: MCPJSONValue]?

    public init(jsonrpc: String? = "2.0", id: MCPJSONValue?, method: String, params: [String: MCPJSONValue]? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct MCPJSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct MCPJSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: MCPJSONValue
    public let result: MCPJSONValue?
    public let error: MCPJSONRPCError?

    public init(id: MCPJSONValue, result: MCPJSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: MCPJSONValue, error: MCPJSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct MCPToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: MCPJSONValue

    public init(name: String, description: String, inputSchema: MCPJSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public func toJSONValue() -> MCPJSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

public enum MCPContentBlock: Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)

    public func toJSONValue() -> MCPJSONValue {
        switch self {
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        case .image(let base64, let mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(base64),
                "mimeType": .string(mimeType)
            ])
        }
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public let content: [MCPContentBlock]
    public let isError: Bool

    public init(content: [MCPContentBlock], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String, isError: Bool = false) -> MCPToolResult {
        MCPToolResult(content: [.text(text)], isError: isError)
    }

    public func toJSONValue() -> MCPJSONValue {
        .object([
            "content": .array(content.map { $0.toJSONValue() }),
            "isError": .bool(isError)
        ])
    }
}

// MARK: - MCP Server Core

public final class MCPServerCore: @unchecked Sendable {
    public static let shared = MCPServerCore()
    public static let protocolVersion = "2024-11-05"

    public let driver: AndroidAutomationDriver
    public let registry: CustomMCPToolRegistry
    public let serverName: String
    public let serverVersion: String

    private let lock = NSLock()
    private var _isAgentPaused: Bool = false
    private var inFlightTasks: [UUID: Task<MCPToolResult, Never>] = [:]
    private var _onAgentActivity: (@Sendable (String?) -> Void)?
    private var _onSelfHealingNotice: (@Sendable (MCPSelfHealingEvent) -> Void)?
    private var _onToolsListChanged: (@Sendable () -> Void)?
    private var _executionConfiguration: MCPExecutionConfiguration?

    /// Optional callback invoked with a human-readable status label when an agent starts/finishes a tool call.
    public var onAgentActivity: (@Sendable (String?) -> Void)? {
        get { lock.withLock { _onAgentActivity } }
        set { lock.withLock { _onAgentActivity = newValue } }
    }

    /// Optional callback invoked whenever Tier 2 Vision OCR self-healing recovers a missing `resource-id`.
    public var onSelfHealingNotice: (@Sendable (MCPSelfHealingEvent) -> Void)? {
        get { lock.withLock { _onSelfHealingNotice } }
        set { lock.withLock { _onSelfHealingNotice = newValue } }
    }

    /// Optional callback invoked when the custom tool registry changes (wired automatically by `MCPHTTPServer`).
    public var onToolsListChanged: (@Sendable () -> Void)? {
        get { lock.withLock { _onToolsListChanged } }
        set { lock.withLock { _onToolsListChanged = newValue } }
    }

    /// Optional execution configuration override for macro delays, step caps, and self-healing defaults.
    public var executionConfiguration: MCPExecutionConfiguration? {
        get { lock.withLock { _executionConfiguration } }
        set { lock.withLock { _executionConfiguration = newValue } }
    }

    public init(
        driver: AndroidAutomationDriver = StandaloneADBAutomationDriver(),
        registry: CustomMCPToolRegistry = .shared,
        executionConfiguration: MCPExecutionConfiguration? = nil,
        serverName: String = "AndroidMCPKit",
        serverVersion: String = "1.0.0"
    ) {
        self.driver = driver
        self.registry = registry
        self._executionConfiguration = executionConfiguration
        self.serverName = serverName
        self.serverVersion = serverVersion

        _ = registry.loadAllTools()
        registry.onToolsChanged = { [weak self] in
            self?.onToolsListChanged?()
        }
    }

    /// Kill-switch: pausing immediately cancels all in-flight tool tasks and blocks new calls.
    public var isAgentPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isAgentPaused }
        set {
            lock.lock()
            _isAgentPaused = newValue
            let tasksToAbort = newValue ? Array(inFlightTasks.values) : []
            if newValue {
                inFlightTasks.removeAll()
            }
            let activityCallback = _onAgentActivity
            lock.unlock()

            if newValue {
                for task in tasksToAbort {
                    task.cancel()
                }
                activityCallback?(nil)
            }
        }
    }

    /// Processes a raw JSON-RPC 2.0 request line and returns encoded JSON response bytes (or `nil` for notifications).
    public func handleRawRequestData(_ data: Data) async -> Data? {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let request: MCPJSONRPCRequest
        do {
            request = try decoder.decode(MCPJSONRPCRequest.self, from: data)
        } catch {
            let errResp = MCPJSONRPCResponse(
                id: .null,
                error: MCPJSONRPCError(code: -32700, message: "Parse error: \(error.localizedDescription)")
            )
            return try? encoder.encode(errResp)
        }

        // Notifications have no `id` and require no response
        guard let requestId = request.id else {
            return nil
        }

        let response = await dispatch(request: request, id: requestId)
        return try? encoder.encode(response)
    }

    private func dispatch(request: MCPJSONRPCRequest, id: MCPJSONValue) async -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            let result: MCPJSONValue = .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(true)])
                ]),
                "serverInfo": .object([
                    "name": .string(serverName),
                    "version": .string(serverVersion)
                ])
            ])
            return MCPJSONRPCResponse(id: id, result: result)

        case "ping":
            return MCPJSONRPCResponse(id: id, result: .object([:]))

        case "tools/list":
            let builtIn = AndroidMCPTools.allDefinitions
            let custom = registry.enabledMCPDefinitions(reload: true)
            let tools = (builtIn + custom).map { $0.toJSONValue() }
            return MCPJSONRPCResponse(id: id, result: .object(["tools": .array(tools)]))

        case "tools/call":
            if isAgentPaused {
                return MCPJSONRPCResponse(
                    id: id,
                    result: MCPToolResult.text(
                        "Agent access is currently paused by the user.",
                        isError: true
                    ).toJSONValue()
                )
            }
            guard let params = request.params, let toolName = params["name"]?.stringValue else {
                return MCPJSONRPCResponse(
                    id: id,
                    error: MCPJSONRPCError(code: -32602, message: "Missing tool 'name' in params")
                )
            }
            let args = params["arguments"]?.objectValue ?? [:]
            onAgentActivity?(Self.activityLabel(for: toolName, args: args))

            let currentDriver = driver
            let currentRegistry = registry
            let currentConfig = executionConfiguration
            let healingCallback = onSelfHealingNotice

            let taskId = UUID()
            let execTask = Task<MCPToolResult, Never> {
                if let customSchema = currentRegistry.enabledTool(named: toolName) {
                    return await CustomMCPToolExecutor.execute(
                        schema: customSchema,
                        arguments: args,
                        driver: currentDriver,
                        executionConfiguration: currentConfig,
                        onSelfHealingNotice: healingCallback
                    )
                }
                return await AndroidMCPTools.execute(
                    name: toolName,
                    arguments: args,
                    driver: currentDriver
                )
            }
            let registered = lock.withLock { () -> Bool in
                if _isAgentPaused {
                    return false
                }
                inFlightTasks[taskId] = execTask
                return true
            }
            if !registered {
                execTask.cancel()
                onAgentActivity?(nil)
                return MCPJSONRPCResponse(
                    id: id,
                    result: MCPToolResult.text(
                        "Agent access is currently paused by the user.",
                        isError: true
                    ).toJSONValue()
                )
            }

            let result = await execTask.value
            let aborted = lock.withLock { () -> Bool in
                inFlightTasks.removeValue(forKey: taskId)
                return _isAgentPaused || execTask.isCancelled
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.onAgentActivity?(nil)
            }
            if aborted {
                return MCPJSONRPCResponse(
                    id: id,
                    result: MCPToolResult.text(
                        "Tool execution aborted: Agent access was paused/revoked by the user.",
                        isError: true
                    ).toJSONValue()
                )
            }
            return MCPJSONRPCResponse(id: id, result: result.toJSONValue())

        default:
            return MCPJSONRPCResponse(
                id: id,
                error: MCPJSONRPCError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    private static func activityLabel(for toolName: String, args: [String: MCPJSONValue]) -> String {
        switch toolName {
        case "android_tap_element":
            if let text = args["text"]?.stringValue {
                return "AI Agent: Tapping '\(text)'..."
            }
            if let x = args["x"]?.intValue, let y = args["y"]?.intValue {
                return "AI Agent: Tapping (\(x), \(y))..."
            }
            return "AI Agent: Tapping element..."
        case "android_type_text":
            return "AI Agent: Typing text..."
        case "android_swipe":
            return "AI Agent: Swiping \(args["direction"]?.stringValue ?? "screen")..."
        case "android_screenshot":
            return "AI Agent: Capturing screenshot..."
        case "android_get_ui_tree":
            return "AI Agent: Inspecting UI tree..."
        case "android_launch_app":
            return "AI Agent: Launching \(args["app"]?.stringValue ?? "app")..."
        case "android_get_notifications":
            return "AI Agent: Reading notifications..."
        default:
            return "AI Agent: \(toolName)"
        }
    }
}
