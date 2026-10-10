import Foundation

/// A long-lived, multi-turn conversation with Claude Code: connect once, then
/// send prompts and read replies turn by turn, with the control requests
/// (interrupt, permission mode, model, MCP) available in between. Mirrors the
/// Python SDK's `ClaudeSDKClient`.
///
/// ```swift
/// let client = ClaudeSDKClient(options: options)
/// try await client.connect()
/// try await client.query("What's the capital of France?")
/// for try await message in client.receiveResponse() {
///     if case let .assistant(reply) = message { print(reply.text) }
/// }
/// try await client.query("And of Spain?")
/// for try await message in client.receiveResponse() { … }
/// await client.disconnect()
/// ```
public final class ClaudeSDKClient: Sendable {
    public let options: ClaudeAgentOptions
    private let customTransport: Transport?
    private let state = Locked<Query?>(nil)

    /// - Parameter transport: A transport to use instead of starting the local `claude`.
    public init(options: ClaudeAgentOptions = ClaudeAgentOptions(), transport: Transport? = nil) {
        self.options = options
        customTransport = transport
    }

    /// The running session, which also carries every control request (see ``Query``).
    public var session: Query {
        get throws {
            guard let query = state.withLock({ $0 }) else { throw CLIConnectionError("Not connected. Call connect() first.") }
            return query
        }
    }

    /// Starts the CLI and waits for it to be ready, optionally sending a first prompt.
    public func connect(prompt: String? = nil) async throws {
        try await connect { engine in
            if let prompt { try await engine.send(UserInputMessage(prompt), sessionId: "default") }
        }
    }

    /// Starts the CLI fed by a sequence of user messages; its input closes
    /// once the last message's run is over.
    public func connect<S: AsyncSequence & Sendable>(messages: S) async throws where S.Element == UserInputMessage {
        try await connect { engine in await engine.startStreamingInput(messages, sessionId: "default") }
    }

    private func connect(afterInitialize: @escaping @Sendable (QueryEngine) async throws -> Void) async throws {
        if state.withLock({ $0 }) != nil { await disconnect() }
        try options.validate()
        let engine = QueryEngine(transport: customTransport ?? SubprocessCLITransport(options: options), options: options)
        let query = Query(engine: engine)
        state.withLock { $0 = query }
        do {
            try await engine.start()
            try await engine.initialize()
            try await afterInitialize(engine)
        } catch {
            await disconnect()
            throw error
        }
    }

    /// Sends a prompt. Read the reply with ``receiveResponse()``.
    ///
    /// - Parameter sessionId: A routing label on the message; the session itself
    ///   is chosen with ``ClaudeAgentOptions/resume`` or ``ClaudeAgentOptions/sessionId``.
    public func query(_ prompt: String, sessionId: String = "default") async throws {
        try await query(UserInputMessage(prompt), sessionId: sessionId)
    }

    /// Sends a user message, e.g. one with image blocks.
    public func query(_ message: UserInputMessage, sessionId: String = "default") async throws {
        try await session.engine.send(message, sessionId: sessionId)
    }

    /// Sends each message of a sequence as it comes.
    public func query<S: AsyncSequence & Sendable>(messages: S, sessionId: String = "default") async throws
    where S.Element == UserInputMessage {
        let engine = try session.engine
        for try await message in messages { try await engine.send(message, sessionId: sessionId) }
    }

    /// Every message from now on, across turns, until the session ends.
    public func receiveMessages() throws -> MessageStream {
        MessageStream(channel: try session.engine.channel, stopsAtResult: false)
    }

    /// The messages of the current turn, up to and including its ``ResultMessage``.
    public func receiveResponse() throws -> MessageStream {
        MessageStream(channel: try session.engine.channel, stopsAtResult: true)
    }

    /// Interrupts the turn in progress; it still ends with a `result`.
    @discardableResult
    public func interrupt(cancelQueued: Bool = false) async throws -> InterruptReceipt? {
        try await session.interrupt(cancelQueued: cancelQueued)
    }

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        try await session.setPermissionMode(mode)
    }

    /// Switches the model for the next turns; nil returns to the default.
    public func setModel(_ model: String? = nil) async throws {
        try await session.setModel(model)
    }

    /// Restores tracked files to their state at a user message.
    @discardableResult
    public func rewindFiles(userMessageId: String, dryRun: Bool = false) async throws -> RewindFilesResult {
        try await session.rewindFiles(userMessageId: userMessageId, dryRun: dryRun)
    }

    public func reconnectMcpServer(_ serverName: String) async throws {
        try await session.reconnectMcpServer(serverName)
    }

    public func toggleMcpServer(_ serverName: String, enabled: Bool) async throws {
        try await session.toggleMcpServer(serverName, enabled: enabled)
    }

    public func stopTask(_ taskId: String) async throws {
        try await session.stopTask(taskId)
    }

    /// Every configured MCP server's connection state.
    public func getMcpStatus() async throws -> [McpServerStatus] {
        try await session.mcpServerStatus()
    }

    public func getContextUsage() async throws -> ContextUsage {
        try await session.getContextUsage()
    }

    /// The CLI's answer to `initialize` (commands, models, account, output styles).
    public func getServerInfo() async throws -> InitializationResult {
        try await session.initializationResult()
    }

    /// Ends the session: closes the CLI's input, gives it a few seconds to
    /// save the session, then stops it.
    public func disconnect() async {
        let query = state.withLock { state -> Query? in
            defer { state = nil }
            return state
        }
        await query?.close()
    }
}
