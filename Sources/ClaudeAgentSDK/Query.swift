import Foundation

/// A running session: an `AsyncSequence` of its ``Message``s, plus the
/// control requests the CLI accepts while it runs (interrupt, switch model or
/// permission mode, MCP status, …). Mirrors the TypeScript SDK's `Query`.
///
/// The CLI starts as soon as the query is created. Releasing the query (or
/// calling ``close()``) stops it.
public final class Query: AsyncSequence, Sendable {
    public typealias Element = Message

    let engine: QueryEngine

    init(engine: QueryEngine) {
        self.engine = engine
    }

    deinit {
        let engine = engine
        Task { await engine.close() }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        // Keeps the query alive while it is iterated.
        let owner: Query
        var messages: MessageStream.AsyncIterator

        public mutating func next() async throws -> Message? { try await messages.next() }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(owner: self, messages: MessageStream(channel: engine.channel, stopsAtResult: false).makeAsyncIterator())
    }

    /// The messages, read from where the last reader stopped.
    public var messages: MessageStream { MessageStream(channel: engine.channel, stopsAtResult: false) }

    /// Stops the CLI and everything serving it. Messages already received stay readable.
    public func close() async {
        await engine.close()
    }

    private func request(_ subtype: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        _ = try await engine.initialization.value
        return try await engine.request(subtype, fields)
    }

    // MARK: Turn control

    /// Interrupts the turn in progress; it still ends with a `result` whose
    /// `terminalReason` is `aborted_streaming` or `aborted_tools`.
    ///
    /// - Parameter cancelQueued: Also cancels prompts queued behind the turn.
    /// - Returns: The CLI's receipt of queued prompts that survive, on CLIs
    ///   that advertise `interrupt_receipt_v1`; nil on older ones.
    @discardableResult
    public func interrupt(cancelQueued: Bool = false) async throws -> InterruptReceipt? {
        let response = try await request("interrupt", cancelQueued ? ["cancel_queued": true] : [:])
        guard let stillQueued = response["still_queued"]?.array else { return nil }
        return InterruptReceipt(
            stillQueued: stillQueued.compactMap(\.string), cancelled: response["cancelled"]?.array?.compactMap(\.string) ?? [])
    }

    /// Writes more user messages into the session, as they come.
    public func streamInput<S: AsyncSequence & Sendable>(_ messages: S) async where S.Element == UserInputMessage {
        await engine.streamInput(messages, sessionId: "")
    }

    /// Stops a background task; a `task_updated` (and maybe `task_notification`)
    /// message with a terminal status follows.
    public func stopTask(_ taskId: String) async throws {
        _ = try await request("stop_task", ["task_id": .string(taskId)])
    }

    /// Moves foreground tasks (Bash commands, subagents) to the background:
    /// one, by its `tool_use` id, or all.
    ///
    /// - Returns: False only when `toolUseId` matched no foreground task.
    @discardableResult
    public func backgroundTasks(toolUseId: String? = nil) async throws -> Bool {
        var fields: [String: JSONValue] = [:]
        fields.set("tool_use_id", toolUseId.map(JSONValue.string))
        return try await request("background_tasks", fields)["backgrounded"]?.bool ?? true
    }

    /// Drops a queued user message by its uuid; false when it already ran.
    @discardableResult
    public func cancelAsyncMessage(uuid: String) async throws -> Bool {
        try await request("cancel_async_message", ["message_uuid": .string(uuid)])["cancelled"]?.bool ?? false
    }

    // MARK: Session settings

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        _ = try await request("set_permission_mode", ["mode": .string(mode.rawValue)])
    }

    /// Switches the model for the next turns; nil returns to the default.
    public func setModel(_ model: String?) async throws {
        _ = try await request("set_model", ["model": JSONValue(model)])
    }

    /// Sets the thinking budget (nil restores the session default) and, when
    /// given, how thinking is displayed for the rest of the session.
    public func setMaxThinkingTokens(_ tokens: Int?, display: ThinkingDisplay? = nil) async throws {
        var fields: [String: JSONValue] = ["max_thinking_tokens": tokens.map(JSONValue.int) ?? .null]
        fields.set("thinking_display", display.map { .string($0.rawValue) })
        _ = try await request("set_max_thinking_tokens", fields)
    }

    /// Merges settings into the session's flag-settings layer; a null value clears a key.
    public func applyFlagSettings(_ settings: JSONValue) async throws {
        _ = try await request("apply_flag_settings", ["settings": settings])
    }

    /// Writes allowed keys into a settings file through the CLI's own writer
    /// (`localSettings`: `outputStyle`; `userSettings`: `effortLevel`).
    public func updateSettings(source: String, settings: JSONValue) async throws {
        _ = try await request("update_settings", ["source": .string(source), "settings": settings])
    }

    /// The effective merged settings and each source's own.
    public func getSettings() async throws -> JSONValue {
        try await request("get_settings")
    }

    // MARK: Session information

    /// The CLI's answer to `initialize`.
    public func initializationResult() async throws -> InitializationResult {
        InitializationResult(raw: try await engine.initialization.value)
    }

    /// Sends `initialize` again, e.g. to re-register hooks, and returns the fresh answer.
    public func reinitialize() async throws -> InitializationResult {
        _ = try await engine.initialization.value
        return InitializationResult(raw: try await engine.initialize())
    }

    public func supportedCommands() async throws -> [SlashCommand] { try await initializationResult().commands }
    public func supportedModels() async throws -> [ModelInfo] { try await initializationResult().models }
    public func supportedAgents() async throws -> [AgentInfo] { try await initializationResult().agents }
    public func accountInfo() async throws -> AccountInfo { try await initializationResult().account }

    /// What the context window holds, by category.
    ///
    /// - Parameter detail: `full` counts each category with the token-count
    ///   API; `summary` estimates from the last response. Nil is `full`.
    public func getContextUsage(detail: String? = nil) async throws -> ContextUsage {
        var fields: [String: JSONValue] = [:]
        fields.set("detail", detail.map(JSONValue.string))
        return ContextUsage(raw: try await request("get_context_usage", fields))
    }

    /// The `/usage` data: session cost and the plan's rate-limit windows.
    /// Experimental in the CLI: the shape may change.
    public func getUsage(skipBehaviors: Bool = false) async throws -> JSONValue {
        try await request("get_usage", skipBehaviors ? ["skip_behaviors": true] : [:])
    }

    /// Reads a file through the session, under the Read tool's permission rules;
    /// nil when refused or missing.
    public func readFile(_ path: String, maxBytes: Int? = nil, base64: Bool = false) async throws -> ReadFileResult? {
        var fields: [String: JSONValue] = ["path": .string(path)]
        fields.set("max_bytes", maxBytes.map(JSONValue.int))
        if base64 { fields["encoding"] = "base64" }
        do {
            return ReadFileResult(json: try await request("read_file", fields))
        } catch is ControlRequestError {
            return nil
        }
    }

    // MARK: Files

    /// Restores tracked files to their state at a user message (needs
    /// ``ClaudeAgentOptions/enableFileCheckpointing``; message uuids come from
    /// replayed user messages, `--replay-user-messages`).
    @discardableResult
    public func rewindFiles(userMessageId: String, dryRun: Bool = false) async throws -> RewindFilesResult {
        var fields: [String: JSONValue] = ["user_message_id": .string(userMessageId)]
        if dryRun { fields["dry_run"] = true }
        return RewindFilesResult(json: try await request("rewind_files", fields))
    }

    /// Tells the CLI a file was read at `mtime` (ms), so an Edit is not refused
    /// after the Read left the context.
    public func seedReadState(path: String, mtime: Int) async throws {
        _ = try await request("seed_read_state", ["path": .string(path), "mtime": .int(mtime)])
    }

    // MARK: Reloading

    /// Reloads plugins; returns the refreshed commands, agents, plugins and MCP status.
    public func reloadPlugins(holdOnCacheImpact: Bool = false) async throws -> JSONValue {
        try await request("reload_plugins", holdOnCacheImpact ? ["hold_on_cache_impact": true] : [:])
    }

    public func reloadSkills() async throws -> [SlashCommand] {
        try await request("reload_skills")["skills"]?.array?.map(SlashCommand.init(json:)) ?? []
    }

    public func reloadOutputStyles() async throws -> [String] {
        try await request("reload_output_styles")["available_output_styles"]?.array?.compactMap(\.string) ?? []
    }

    // MARK: MCP

    /// Every configured MCP server's connection state.
    public func mcpServerStatus() async throws -> [McpServerStatus] {
        try await request("mcp_status")["mcpServers"]?.array?.map(McpServerStatus.init(json:)) ?? []
    }

    public func reconnectMcpServer(_ serverName: String) async throws {
        _ = try await request("mcp_reconnect", ["serverName": .string(serverName)])
    }

    public func toggleMcpServer(_ serverName: String, enabled: Bool) async throws {
        _ = try await request("mcp_toggle", ["serverName": .string(serverName), "enabled": .bool(enabled)])
    }

    /// Reads a `ui://` resource from an MCP server the CLI connected itself.
    public func readMcpResource(serverName: String, uri: String) async throws -> JSONValue {
        try await request("mcp_read_resource", ["serverName": .string(serverName), "uri": .string(uri)])
    }

    /// Replaces the session's dynamically added MCP servers. In-process
    /// servers are served from this process like those given at start.
    @discardableResult
    public func setMcpServers(_ servers: [String: McpServerConfig]) async throws -> McpSetServersResult {
        var sdkServers: [String: SdkMcpServer] = [:]
        for (key, config) in servers { if case let .sdk(server) = config { sdkServers[key] = server } }
        await engine.addBridges(sdkServers)
        let result = McpSetServersResult(json: try await request("mcp_set_servers", ["servers": .object(servers.mapValues(\.cliJSON))]))
        let initial = Set(engine.options.mcpServers.keys)
        await engine.removeBridges(except: initial.union(sdkServers.keys))
        return result
    }

    /// Pins (or clears, with nil) a per-server permission-mode override:
    /// `default` or `auto`, applied only where the session would auto-allow.
    ///
    /// - Returns: A warning when no known server has that name.
    @discardableResult
    public func setMcpPermissionModeOverride(serverName: String, mode: PermissionMode?) async throws -> String? {
        let response = try await request("set_mcp_permission_mode_override", [
            "serverName": .string(serverName), "mode": mode.map { .string($0.rawValue) } ?? .null,
        ])
        return response["warning"]?.string
    }
}

// MARK: - Starting a query

/// Runs a prompt and returns its messages as they come; the session ends
/// after the run (one or more turns) is over.
///
/// ```swift
/// for try await message in query(prompt: "What is 2 + 2?") {
///     if case let .assistant(reply) = message { print(reply.text) }
/// }
/// ```
///
/// - Parameter transport: A transport to use instead of starting the local `claude`.
public func query(prompt: String, options: ClaudeAgentOptions = ClaudeAgentOptions(), transport: Transport? = nil) -> Query {
    startQuery(options: options, transport: transport) { engine in
        try await engine.sendPromptAndFinish(UserInputMessage(prompt))
    }
}

/// Runs a session fed by a sequence of user messages (streaming-input mode):
/// each is written as it comes, and the session ends once the last one's run is over.
public func query<S: AsyncSequence & Sendable>(
    prompt messages: S, options: ClaudeAgentOptions = ClaudeAgentOptions(), transport: Transport? = nil
) -> Query where S.Element == UserInputMessage {
    startQuery(options: options, transport: transport) { engine in
        await engine.startStreamingInput(messages, sessionId: "")
    }
}

func startQuery(
    options: ClaudeAgentOptions, transport: Transport?, afterInitialize: @escaping @Sendable (QueryEngine) async throws -> Void
) -> Query {
    let engine = QueryEngine(transport: transport ?? SubprocessCLITransport(options: options), options: options)
    let query = Query(engine: engine)
    Task {
        do {
            try options.validate()
            try await engine.start()
            try await engine.initialize()
            try await afterInitialize(engine)
        } catch {
            await engine.failStartup(error)
        }
    }
    return query
}
