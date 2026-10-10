import Foundation

/// One in-process MCP server's side of the conversation with Claude Code:
/// answers the JSON-RPC messages the CLI wraps in `mcp_message` control
/// requests, and cancels a running tool call when the CLI abandons it.
actor SdkMcpBridge {
    /// The MCP protocol version answered when the client names none.
    static let defaultProtocolVersion = "2025-06-18"
    /// How long `close()` waits for cancelled tool calls to finish.
    static let shutdownGrace: Duration = .seconds(5)

    let key: String
    let server: SdkMcpServer
    private let schemas: [String: JSONValue]
    /// Tool calls running, by their JSON-RPC id (as JSON text, so `1` and `"1"` differ).
    private var inFlight: [String: Task<JSONValue, Never>] = [:]
    private var closed = false

    init(key: String, server: SdkMcpServer) {
        self.key = key
        self.server = server
        schemas = Dictionary(server.tools.map { ($0.name, $0.inputSchema.json) }, uniquingKeysWith: { first, _ in first })
    }

    /// The JSON-RPC response to `message`, or nil for a notification or a
    /// response, which get none.
    func handle(_ message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.string else { return nil }
        let id = message["id"]
        let params = message["params"] ?? [:]
        guard let id, !id.isNull else {
            if method == "notifications/cancelled", let requestId = params["requestId"] {
                inFlight[requestId.jsonString]?.cancel()
            }
            return nil
        }
        if closed { return Self.error(id: id, code: -32603, message: "Server '\(key)' is closed") }

        switch method {
        case "initialize":
            return Self.success(id: id, [
                "protocolVersion": params["protocolVersion"] ?? .string(Self.defaultProtocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(server.name), "version": .string(server.version)],
            ])
        case "ping":
            return Self.success(id: id, [:])
        case "tools/list":
            return Self.success(id: id, ["tools": .array(server.tools.map(\.listing))])
        case "tools/call":
            let callKey = id.jsonString
            if inFlight[callKey] != nil {
                return Self.error(id: id, code: -32603, message: "Request id \(callKey) is already in flight")
            }
            let task = Task { [server, schemas, key] in
                await Self.call(params: params, server: server, schemas: schemas, key: key).json
            }
            inFlight[callKey] = task
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            inFlight[callKey] = nil
            if task.isCancelled { return Self.error(id: id, code: -32800, message: "Request cancelled") }
            return Self.success(id: id, result)
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Cancels running tool calls and waits briefly for them to finish.
    func close() async {
        closed = true
        let tasks = Array(inFlight.values)
        tasks.forEach { $0.cancel() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in tasks { _ = await task.value } }
            group.addTask { try? await Task.sleep(for: Self.shutdownGrace) }
            await group.next()
            group.cancelAll()
        }
        inFlight = [:]
    }

    /// Runs one tool call. Unknown tools, invalid arguments and thrown errors
    /// are all results the model reads, never protocol errors.
    private static func call(params: JSONValue, server: SdkMcpServer, schemas: [String: JSONValue], key: String) async
        -> ToolResult
    {
        let name = params["name"]?.string ?? ""
        guard let tool = server.tools.first(where: { $0.name == name }), let schema = schemas[name] else {
            return .error("Tool '\(name)' not found")
        }
        let arguments = params["arguments"]?.nonNull ?? [:]
        if let violation = JSONSchemaValidator.firstError(arguments, schema: schema) {
            return .error("Input validation error: \(violation)")
        }
        let meta = params["_meta"]
        let context = ToolCallContext(serverName: key, toolUseId: meta?["claudecode/toolUseId"]?.string, meta: meta)
        do {
            return try await tool.handler(arguments, context)
        } catch {
            return .error(errorText(error))
        }
    }

    static func success(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue?, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .int(code), "message": .string(message)]]
    }
}
