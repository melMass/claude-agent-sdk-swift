import Foundation

/// The control protocol on top of a ``Transport``: routes the CLI's frames
/// (control requests, responses and cancellations to their handlers,
/// everything else to the message channel), sends the SDK's own control
/// requests, and decides when the CLI's input can close.
actor QueryEngine {
    /// Background task types whose completion runs a follow-up turn, so the
    /// CLI may still need its input after a turn's result. Shells and
    /// monitors are left out: they may never end.
    static let deferringTaskTypes: Set<String> = ["local_agent", "local_workflow"]
    static let defaultRunEndCeilingMs = 600_000
    static let defaultControlTimeout: Duration = .seconds(60)

    let transport: Transport
    let options: ClaudeAgentOptions
    nonisolated let channel = MessageChannel()
    /// Resolved with the CLI's answer to `initialize`.
    nonisolated let initialization = Promise<JSONValue>()

    private var pending: [String: Promise<JSONValue>] = [:]
    private var requestCounter = 0
    private var hookCallbacks: [String: HookCallback] = [:]
    private var bridges: [String: SdkMcpBridge]
    private var handlers: [String: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var closed = false
    private var started = false

    // When the run is over (the CLI's input may close).
    private var runEnded = false
    private var runFinal = false
    private var runEndWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultReceived = false
    private var sessionState: String?
    private var turnInProgress = false
    private var inflightTasks: Set<String> = []
    private var ceilingTask: Task<Void, Never>?
    private var ceilingGeneration = 0
    private let runEndCeilingMs: Int
    /// The last frame when it is an error result: a non-zero exit after it is
    /// the expected end of a failed run, reported as a ``ResultError``.
    private var lastErrorResult: JSONValue?

    init(transport: Transport, options: ClaudeAgentOptions) {
        self.transport = transport
        self.options = options
        var bridges: [String: SdkMcpBridge] = [:]
        for (key, config) in options.mcpServers {
            if case let .sdk(server) = config { bridges[key] = SdkMcpBridge(key: key, server: server) }
        }
        self.bridges = bridges
        let raw = options.env["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"]
            ?? ProcessInfo.processInfo.environment["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"]
        runEndCeilingMs = raw.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } ?? Self.defaultRunEndCeilingMs
    }

    /// The `initialize` timeout: `CLAUDE_CODE_STREAM_CLOSE_TIMEOUT` (ms), at least 60 s.
    static var initializeTimeout: Duration {
        let milliseconds = ProcessInfo.processInfo.environment["CLAUDE_CODE_STREAM_CLOSE_TIMEOUT"].flatMap(Int.init) ?? 60_000
        return .milliseconds(max(milliseconds, 60_000))
    }

    private var hasBidirectionalNeeds: Bool { options.hasBidirectionalNeeds || !bridges.isEmpty }

    // MARK: Lifecycle

    /// Connects the transport and starts reading its frames.
    func start() async throws {
        guard !started else { return }
        started = true
        try await transport.connect()
        let frames = transport.readMessages()
        readTask = Task { [weak self] in
            do {
                for try await frame in frames {
                    guard let self else { return }
                    await self.route(frame)
                }
                await self?.readerEnded(error: nil)
            } catch {
                await self?.readerEnded(error: error)
            }
        }
    }

    /// Sends `initialize` (hooks, agents and the other session-level fields)
    /// and waits for the CLI's answer.
    @discardableResult
    func initialize() async throws -> JSONValue {
        var fields = options.initializeFields()
        fields["hooks"] = registerHooks()
        do {
            let response = try await request("initialize", fields, timeout: Self.initializeTimeout)
            initialization.succeed(response)
            return response
        } catch {
            initialization.fail(error)
            throw error
        }
    }

    /// Fails the session before it got going: readers see `error`.
    func failStartup(_ error: Error) async {
        initialization.fail(error)
        channel.finish(throwing: error)
        await close()
    }

    /// Assigns callback ids (`hook_0`, `hook_1`, … across all events) and
    /// returns the `hooks` field of `initialize`, or null when there are none.
    private func registerHooks() -> JSONValue {
        hookCallbacks = [:]
        var config: [String: JSONValue] = [:]
        var next = 0
        for (event, matchers) in options.hooks.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !matchers.isEmpty {
            config[event.rawValue] = .array(matchers.map { matcher in
                var ids: [JSONValue] = []
                for hook in matcher.hooks {
                    let id = "hook_\(next)"
                    next += 1
                    hookCallbacks[id] = hook
                    ids.append(.string(id))
                }
                var entry: [String: JSONValue] = ["matcher": JSONValue(matcher.matcher), "hookCallbackIds": .array(ids)]
                entry.set("timeout", matcher.timeout.map { $0.rounded() == $0 ? .int(Int($0)) : .double($0) })
                return .object(entry)
            })
        }
        return config.isEmpty ? .null : .object(config)
    }

    /// Stops everything: running handlers, in-process MCP servers, the CLI.
    /// Messages already read stay readable.
    func close() async {
        guard !closed else { return }
        closed = true
        runFinal = true
        endRun()
        clearCeiling()
        inputTask?.cancel()
        for handler in handlers.values { handler.cancel() }
        handlers = [:]
        for bridge in bridges.values { await bridge.close() }
        await transport.close()
        let error = CLIConnectionError("The session was closed")
        for promise in pending.values { promise.fail(error) }
        pending = [:]
        initialization.fail(error)
        channel.finish()
    }

    // MARK: Writing

    private func write(_ frame: JSONValue) async throws {
        try await transport.write(frame.jsonString + "\n")
    }

    /// Writes a user message.
    func send(_ message: UserInputMessage, sessionId: String) async throws {
        try await write(message.frame(sessionId: sessionId, verbatim: options.verbatimPrompts))
    }

    /// Writes a one-shot prompt, then closes the input once the run is over.
    func sendPromptAndFinish(_ message: UserInputMessage) async throws {
        try await send(message, sessionId: "")
        inputTask = Task { [weak self] in await self?.waitForRunEndAndCloseInput() }
    }

    /// Writes each message of `messages` as it comes, then closes the input
    /// once the last prompt's run is over.
    nonisolated func streamInput<S: AsyncSequence & Sendable>(_ messages: S, sessionId: String) async
    where S.Element == UserInputMessage {
        var written = 0
        do {
            for try await message in messages {
                guard await !isClosed else { break }
                await preparePrompt()
                try await send(message, sessionId: sessionId)
                written += 1
            }
        } catch {
            // A failing prompt sequence still ends the input, or the CLI would wait forever.
        }
        if written > 0 {
            await waitForRunEndAndCloseInput()
        } else {
            await finishInput()
        }
    }

    /// Starts reading `messages` into the CLI in the background.
    func startStreamingInput<S: AsyncSequence & Sendable>(_ messages: S, sessionId: String) where S.Element == UserInputMessage {
        inputTask = Task { [weak self] in await self?.streamInput(messages, sessionId: sessionId) }
    }

    private var isClosed: Bool { closed }

    /// A prompt is about to be written: it owes a run of its own.
    private func preparePrompt() {
        reopenRun()
        resultReceived = false
        clearCeiling()
    }

    private func finishInput() async {
        runFinal = true
        clearCeiling()
        await transport.endInput()
    }

    /// Waits until the run is over (when the CLI may still send requests that
    /// need answers), then closes the CLI's input.
    func waitForRunEndAndCloseInput() async {
        if hasBidirectionalNeeds, !runEnded {
            await withCheckedContinuation { runEndWaiters.append($0) }
        }
        await finishInput()
    }

    // MARK: Control requests

    /// Sends a control request and waits for its response body.
    func request(_ subtype: String, _ fields: [String: JSONValue] = [:], timeout: Duration = defaultControlTimeout)
        async throws -> JSONValue
    {
        guard !closed else { throw CLIConnectionError("The session is closed") }
        requestCounter += 1
        let id = "req_\(requestCounter)_\(Self.randomHex())"
        var body = fields
        body["subtype"] = .string(subtype)
        let promise = Promise<JSONValue>()
        pending[id] = promise
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPending(id, ControlRequestError(
                subtype: subtype, message: "Control request timeout: \(subtype)", timedOut: true))
        }
        defer { deadline.cancel() }
        do {
            try await write(["type": "control_request", "request_id": .string(id), "request": .object(body)])
        } catch {
            pending[id] = nil
            throw error
        }
        do {
            return try await promise.value
        } catch let error as ControlRequestError where error.subtype.isEmpty {
            throw ControlRequestError(subtype: subtype, message: error.message)
        }
    }

    private func failPending(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.fail(error)
    }

    private static func randomHex() -> String {
        (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Registers in-process servers added mid-session.
    func addBridges(_ servers: [String: SdkMcpServer]) {
        for (key, server) in servers where bridges[key] == nil {
            bridges[key] = SdkMcpBridge(key: key, server: server)
        }
    }

    /// Removes in-process servers no longer configured.
    func removeBridges(except keys: Set<String>) async {
        for (key, bridge) in bridges where !keys.contains(key) {
            bridges[key] = nil
            await bridge.close()
        }
    }

    // MARK: Reading

    private func route(_ frame: JSONValue) async {
        guard !closed else { return }
        let type = frame["type"]?.string
        switch type {
        case "control_response":
            guard let response = frame["response"], let id = response["request_id"]?.string,
                  let promise = pending.removeValue(forKey: id)
            else { return }
            if response["subtype"]?.string == "error" {
                let message = response["error"]?.string ?? "Unknown error"
                promise.fail(ControlRequestError(subtype: "", message: message))
            } else {
                promise.succeed(response["response"]?.object.map(JSONValue.object) ?? [:])
            }
            return
        case "control_request":
            guard let id = frame["request_id"]?.string, let request = frame["request"] else { return }
            handlers[id] = Task { [weak self] in await self?.handleControlRequest(id: id, request: request) }
            return
        case "control_cancel_request":
            if let id = frame["request_id"]?.string { handlers.removeValue(forKey: id)?.cancel() }
            return
        case "transcript_mirror":
            return
        default:
            break
        }

        if type == "system" {
            let hadTasks = !inflightTasks.isEmpty
            trackTaskLifecycle(frame)
            if hadTasks, inflightTasks.isEmpty { rearmCeilingBetweenTurns() }
            if frame["subtype"]?.string == "session_state_changed" {
                onSessionState(frame["state"]?.string)
                // Asked for by this SDK (CLAUDE_CODE_SDK_READS_SESSION_STATE), not by the caller.
                if frame["sdk_host_only"]?.bool == true { return }
            }
        }

        if type == "result" {
            resultReceived = true
            turnInProgress = false
            if sessionState == nil || sessionState == "idle" || !hasBidirectionalNeeds {
                maybeEndRun()
            } else if sessionState != "requires_action" {
                armCeiling()
            }
            lastErrorResult = frame["is_error"]?.bool == true ? frame : nil
        } else if !(type == "system" && frame["subtype"]?.string == "session_state_changed") {
            lastErrorResult = nil
            if type == "assistant" || type == "stream_event", frame["parent_tool_use_id"]?.nonNull == nil {
                turnInProgress = true
                reopenRun()
                clearCeiling()
            }
        }
        channel.push(Message(json: frame))
    }

    private func readerEnded(error: Error?) async {
        var failure = error
        if let processError = error as? ProcessError, let result = lastErrorResult {
            failure = ResultError(result: result, exitCode: processError.exitCode)
        }
        let pendingError = failure ?? CLIConnectionError("Claude Code exited before answering")
        for promise in pending.values { promise.fail(pendingError) }
        pending = [:]
        initialization.fail(pendingError)
        runFinal = true
        endRun()
        if let failure { channel.finish(throwing: failure) } else { channel.finish() }
        await close()
    }

    // MARK: Requests from the CLI

    private func handleControlRequest(id: String, request: JSONValue) async {
        let outcome: Result<JSONValue?, Error>
        do {
            outcome = .success(try await answer(request, id: id))
        } catch {
            outcome = .failure(error)
        }
        // A request the CLI cancelled gets no response.
        guard !Task.isCancelled, handlers.removeValue(forKey: id) != nil else { return }
        let response: JSONValue
        switch outcome {
        case let .success(body?):
            response = ["subtype": "success", "request_id": .string(id), "response": body]
        case .success(nil):
            return
        case let .failure(error):
            response = ["subtype": "error", "request_id": .string(id), "error": .string(errorText(error))]
        }
        try? await write(["type": "control_response", "response": response])
    }

    /// The response body for a request from the CLI; nil sends no response.
    private func answer(_ request: JSONValue, id: String) async throws -> JSONValue? {
        let subtype = request["subtype"]?.string ?? ""
        switch subtype {
        case "can_use_tool":
            guard let canUseTool = options.canUseTool else { throw HandlerError("canUseTool callback is not provided") }
            let input = request["input"] ?? [:]
            let context = ToolPermissionContext(request: request, requestId: id)
            let result = try await canUseTool(request["tool_name"]?.string ?? "", input, context)
            return result.json(originalInput: input)

        case "hook_callback":
            let callbackId = request["callback_id"]?.string ?? ""
            guard let hook = hookCallbacks[callbackId] else {
                throw HandlerError("No hook callback found for ID: \(callbackId)")
            }
            let output = try await hook(HookInput(raw: request["input"] ?? [:]), request["tool_use_id"]?.string,
                                        HookContext(requestId: id))
            return output.json

        case "mcp_message":
            guard let serverName = request["server_name"]?.string, let message = request["message"]?.nonNull else {
                throw HandlerError("Missing server_name or message for MCP request")
            }
            guard let bridge = bridges[serverName] else {
                return ["mcp_response": SdkMcpBridge.error(id: message["id"], code: -32601, message: "Server '\(serverName)' not found")]
            }
            // A notification gets no JSON-RPC reply, but its control request still wants an answer.
            let response = await bridge.handle(message) ?? ["jsonrpc": "2.0", "result": [:]]
            return ["mcp_response": response]

        case "elicitation":
            guard let onElicitation = options.onElicitation else { return ["action": "decline"] }
            return try await onElicitation(ElicitationRequest(request: request, requestId: id)).json

        case "request_user_dialog":
            // Without a renderer the dialog stays unanswered: another client, or the CLI's deadline, settles it.
            guard let onUserDialog = options.onUserDialog else { return nil }
            return try await onUserDialog(UserDialogRequest(request: request, requestId: id)).json

        default:
            throw HandlerError("Unsupported control request subtype: \(subtype)")
        }
    }

    // MARK: Run end

    /// Background agents in flight, from the task lifecycle frames.
    private func trackTaskLifecycle(_ frame: JSONValue) {
        guard let taskId = frame["task_id"]?.string, !taskId.isEmpty else { return }
        switch frame["subtype"]?.string {
        case "task_started":
            if let type = frame["task_type"]?.string, Self.deferringTaskTypes.contains(type) { inflightTasks.insert(taskId) }
        case "task_notification":
            inflightTasks.remove(taskId)
        case "task_updated":
            if let status = frame["patch"]?["status"]?.string, TaskEvent.terminalStatuses.contains(status) {
                inflightTasks.remove(taskId)
            }
        default:
            break
        }
    }

    private func onSessionState(_ state: String?) {
        sessionState = state
        if state == "idle" {
            if resultReceived { maybeEndRun() }
            return
        }
        // Work taken up after the run ended (a finished background task woke the session).
        reopenRun()
        if state == "requires_action" {
            clearCeiling()
        } else {
            rearmCeilingBetweenTurns()
        }
    }

    private func maybeEndRun() {
        guard inflightTasks.isEmpty else { return }
        endRun()
    }

    private func endRun() {
        clearCeiling()
        runEnded = true
        let waiters = runEndWaiters
        runEndWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func reopenRun() {
        if runEnded, !runFinal { runEnded = false }
    }

    /// Ends the run anyway if no new turn starts within the ceiling after a
    /// result: work that never finishes would otherwise hold the input open.
    private func armCeiling() {
        clearCeiling()
        guard runEndCeilingMs > 0, !runEnded, !runFinal, !closed, !turnInProgress, hasBidirectionalNeeds else { return }
        let generation = ceilingGeneration
        let milliseconds = min(runEndCeilingMs, Int(Int32.max))
        ceilingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            await self?.ceilingReached(generation)
        }
    }

    private func rearmCeilingBetweenTurns() {
        if resultReceived, let state = sessionState, state != "idle", state != "requires_action" { armCeiling() }
    }

    private func ceilingReached(_ generation: Int) {
        guard generation == ceilingGeneration else { return }
        ceilingTask = nil
        guard inflightTasks.isEmpty else { return }
        endRun()
    }

    private func clearCeiling() {
        ceilingGeneration += 1
        ceilingTask?.cancel()
        ceilingTask = nil
    }
}

/// Why a request from the CLI could not be answered; its text is the error response.
private struct HandlerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
