import Foundation

/// A message from the session: everything the CLI writes to its output other
/// than control traffic. Each case keeps the frame as ``raw``; frame types
/// this SDK does not know arrive as ``unknown(_:)`` rather than failing.
public enum Message: Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case system(SystemMessage)
    /// The end of a turn, with its cost, usage and final text.
    case result(ResultMessage)
    /// A raw Messages API streaming event (with ``ClaudeAgentOptions/includePartialMessages``).
    case streamEvent(StreamEvent)
    /// The plan's usage limits changed (claude.ai logins).
    case rateLimitEvent(RateLimitEvent)
    /// The conversation was replaced (e.g. after `/clear`); later messages carry a new session id.
    case conversationReset(ConversationResetMessage)
    /// A frame type this SDK does not model, as sent.
    case unknown(JSONValue)

    /// Reads a frame. Never fails: a frame that does not fit its type becomes ``unknown(_:)``.
    public init(json: JSONValue) {
        switch json["type"]?.string {
        case "user":
            self = UserMessage(json: json).map(Message.user) ?? .unknown(json)
        case "assistant":
            self = AssistantMessage(json: json).map(Message.assistant) ?? .unknown(json)
        case "system":
            self = .system(SystemMessage(json: json))
        case "result":
            self = .result(ResultMessage(json: json))
        case "stream_event":
            self = .streamEvent(StreamEvent(json: json))
        case "rate_limit_event":
            self = .rateLimitEvent(RateLimitEvent(json: json))
        case "conversation_reset":
            self = .conversationReset(ConversationResetMessage(json: json))
        default:
            self = .unknown(json)
        }
    }

    /// The frame as the CLI sent it.
    public var raw: JSONValue {
        switch self {
        case let .user(message): message.raw
        case let .assistant(message): message.raw
        case let .system(message): message.raw
        case let .result(message): message.raw
        case let .streamEvent(message): message.raw
        case let .rateLimitEvent(message): message.raw
        case let .conversationReset(message): message.raw
        case let .unknown(raw): raw
        }
    }

    /// The frame's `type`.
    public var type: String { raw["type"]?.string ?? "" }

    /// The session the frame belongs to, when it says.
    public var sessionId: String? { raw["session_id"]?.string }
}

/// What a user message holds: plain text or content blocks.
public enum UserContent: Sendable, Hashable {
    case text(String)
    case blocks([ContentBlock])
}

/// A user-role message: a tool result, a replayed prompt, or a subagent's prompt.
public struct UserMessage: Sendable {
    public var content: UserContent
    /// Usable with ``Query/rewindFiles(userMessageId:dryRun:)``.
    public var uuid: String?
    /// Set on a subagent's messages: the Agent `tool_use` that started it.
    public var parentToolUseId: String?
    /// The tool's structured result, for tool-result messages.
    public var toolUseResult: JSONValue?
    /// Where the message came from (`{"kind": "human" | "task-notification" | …}`); nil when unattributed.
    public var origin: JSONValue?
    /// True when this is the CLI echoing a prompt it took (`--replay-user-messages`).
    public var isReplay: Bool
    public var sessionId: String?
    public var raw: JSONValue

    init?(json: JSONValue) {
        guard let message = json["message"], let content = message["content"] else { return nil }
        if let text = content.string {
            self.content = .text(text)
        } else if let blocks = content.array {
            self.content = .blocks(blocks.map(ContentBlock.init(json:)))
        } else {
            return nil
        }
        uuid = json["uuid"]?.string
        parentToolUseId = json["parent_tool_use_id"]?.string
        toolUseResult = json["tool_use_result"]?.nonNull
        origin = json["origin"]?.nonNull
        isReplay = json["isReplay"]?.bool ?? false
        sessionId = json["session_id"]?.string
        raw = json
    }
}

/// A message from the model.
public struct AssistantMessage: Sendable {
    public var content: [ContentBlock]
    public var model: String
    /// Set on a subagent's messages: the Agent `tool_use` that started it.
    public var parentToolUseId: String?
    /// `authentication_failed`, `billing_error`, `rate_limit`, `invalid_request`, `server_error` or `unknown`.
    public var error: String?
    public var usage: JSONValue?
    /// The API message id; one API message may arrive as several frames.
    public var messageId: String?
    public var stopReason: String?
    public var sessionId: String?
    public var uuid: String?
    public var raw: JSONValue

    init?(json: JSONValue) {
        guard let message = json["message"], let blocks = message["content"]?.array else { return nil }
        content = blocks.map(ContentBlock.init(json:))
        model = message["model"]?.string ?? ""
        parentToolUseId = json["parent_tool_use_id"]?.string
        error = json["error"]?.string
        usage = message["usage"]?.nonNull
        messageId = message["id"]?.string
        stopReason = message["stop_reason"]?.string
        sessionId = json["session_id"]?.string
        uuid = json["uuid"]?.string
        raw = json
    }

    /// The message's text blocks, joined.
    public var text: String { content.compactMap(\.text).joined() }
}

/// A system message: session metadata (`init`), task and hook lifecycle,
/// and other notices. ``subtype`` says which; typed views read the common ones.
public struct SystemMessage: Sendable {
    public var subtype: String
    /// The whole frame.
    public var data: JSONValue
    public var raw: JSONValue { data }
    public var sessionId: String? { data["session_id"]?.string }
    public var uuid: String? { data["uuid"]?.string }

    init(json: JSONValue) {
        subtype = json["subtype"]?.string ?? ""
        data = json
    }

    /// The session metadata of an `init` message.
    public var initData: SystemInit? { subtype == "init" ? SystemInit(data: data) : nil }

    /// A `task_started`, `task_progress`, `task_notification` or `task_updated` message.
    public var task: TaskEvent? {
        ["task_started", "task_progress", "task_notification", "task_updated"].contains(subtype) ? TaskEvent(data: data) : nil
    }

    /// A `hook_started`, `hook_progress` or `hook_response` message (with ``ClaudeAgentOptions/includeHookEvents``).
    public var hookEvent: HookEventMessage? {
        ["hook_started", "hook_progress", "hook_response"].contains(subtype) ? HookEventMessage(data: data) : nil
    }

    /// The session's state for a `session_state_changed` message: `running`, `idle` or `requires_action`.
    public var sessionState: String? { subtype == "session_state_changed" ? data["state"]?.string : nil }
}

/// The session metadata the CLI sends at the start of each turn.
public struct SystemInit: Sendable {
    public struct McpServer: Sendable, Hashable {
        public var name: String
        public var status: String
        /// `sdk`, `plugin`, or a config scope such as `user`.
        public var source: String?
    }

    public let data: JSONValue

    public var model: String { data["model"]?.string ?? "" }
    public var cwd: String { data["cwd"]?.string ?? "" }
    /// Every tool the model is offered, as the CLI names them.
    public var tools: [String] { data["tools"]?.array?.compactMap(\.string) ?? [] }
    public var mcpServers: [McpServer] {
        data["mcp_servers"]?.array?.compactMap { entry in
            entry["name"]?.string.map { McpServer(name: $0, status: entry["status"]?.string ?? "", source: entry["source"]?.string) }
        } ?? []
    }
    public var permissionMode: PermissionMode? { data["permissionMode"]?.string.map(PermissionMode.init(rawValue:)) }
    public var slashCommands: [String] { data["slash_commands"]?.array?.compactMap(\.string) ?? [] }
    public var skills: [String] { data["skills"]?.array?.compactMap(\.string) ?? [] }
    public var agents: [String] { data["agents"]?.array?.compactMap(\.string) ?? [] }
    /// `ANTHROPIC_API_KEY`, `apiKeyHelper`, `/login managed key`, or `none` (a claude.ai login).
    public var apiKeySource: String? { data["apiKeySource"]?.string }
    public var claudeCodeVersion: String? { data["claude_code_version"]?.string }
    public var outputStyle: String? { data["output_style"]?.string }
    /// Protocol capabilities for feature detection, e.g. `interrupt_receipt_v1`.
    public var capabilities: [String] { data["capabilities"]?.array?.compactMap(\.string) ?? [] }
    public var plugins: [JSONValue] { data["plugins"]?.array ?? [] }
    public var fastModeState: String? { data["fast_mode_state"]?.string }
}

/// A background task's lifecycle message.
public struct TaskEvent: Sendable {
    /// Statuses that mean the task is over, from either `task_notification` or `task_updated`.
    public static let terminalStatuses: Set<String> = ["completed", "failed", "stopped", "killed"]

    public let data: JSONValue

    public var subtype: String { data["subtype"]?.string ?? "" }
    public var taskId: String { data["task_id"]?.string ?? "" }
    public var description: String? { data["description"]?.string }
    public var toolUseId: String? { data["tool_use_id"]?.string }
    /// `local_agent`, `local_workflow`, `local_bash`, … (task_started).
    public var taskType: String? { data["task_type"]?.string }
    /// The status: a notification's own, or a `task_updated` patch's.
    public var status: String? { data["status"]?.string ?? data["patch"]?["status"]?.string }
    public var summary: String? { data["summary"]?.string }
    public var outputFile: String? { data["output_file"]?.string }
    /// `total_tokens`, `tool_uses`, `duration_ms`.
    public var usage: JSONValue? { data["usage"] }
    public var lastToolName: String? { data["last_tool_name"]?.string }
    /// The changed fields of a `task_updated` message.
    public var patch: JSONValue? { data["patch"] }
    /// Whether the task has finished.
    public var isTerminal: Bool { status.map(Self.terminalStatuses.contains) ?? false }
}

/// A hook lifecycle event in the message stream.
public struct HookEventMessage: Sendable {
    public let data: JSONValue
    /// `hook_started`, `hook_progress` or `hook_response`.
    public var subtype: String { data["subtype"]?.string ?? "" }
    public var hookEventName: String {
        data["hook_event"]?.string ?? data["hook_name"]?.string ?? data["hook_event_name"]?.string ?? ""
    }
    public var output: String? { data["output"]?.string }
    public var exitCode: Int? { data["exit_code"]?.int }
    public var outcome: String? { data["outcome"]?.string }
}

/// A tool use a PreToolUse hook deferred: the run stopped so the host can decide.
public struct DeferredToolUse: Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue
}

/// Per-model token usage and cost.
public struct ModelUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int
    public var webSearchRequests: Int
    public var costUSD: Double
    public var contextWindow: Int
    public var maxOutputTokens: Int
    public var raw: JSONValue

    init(json: JSONValue) {
        inputTokens = json["inputTokens"]?.int ?? 0
        outputTokens = json["outputTokens"]?.int ?? 0
        cacheReadInputTokens = json["cacheReadInputTokens"]?.int ?? 0
        cacheCreationInputTokens = json["cacheCreationInputTokens"]?.int ?? 0
        webSearchRequests = json["webSearchRequests"]?.int ?? 0
        costUSD = json["costUSD"]?.double ?? 0
        contextWindow = json["contextWindow"]?.int ?? 0
        maxOutputTokens = json["maxOutputTokens"]?.int ?? 0
        raw = json
    }
}

/// The end of a turn.
public struct ResultMessage: Sendable {
    /// `success`, `error_max_turns`, `error_during_execution`, `error_max_budget_usd`, …
    public var subtype: String
    public var durationMs: Int
    public var durationApiMs: Int
    public var isError: Bool
    public var numTurns: Int
    public var sessionId: String
    public var stopReason: String?
    /// The session's running cost (notional on a subscription login).
    public var totalCostUsd: Double?
    public var usage: JSONValue?
    /// The final text.
    public var result: String?
    /// The result conforming to ``ClaudeAgentOptions/outputFormat``.
    public var structuredOutput: JSONValue?
    public var modelUsage: [String: ModelUsage]
    public var permissionDenials: [JSONValue]
    public var deferredToolUse: DeferredToolUse?
    public var errors: [String]
    /// HTTP status of the failing API call, when ``isError`` comes from one.
    public var apiErrorStatus: Int?
    public var uuid: String?
    /// Why the loop ended: `completed`, `max_turns`, `aborted_streaming`, `aborted_tools`, …
    public var terminalReason: String?
    /// The origin of the message that started the turn; nil or `human` for your own prompts.
    public var origin: JSONValue?
    public var raw: JSONValue

    init(json: JSONValue) {
        subtype = json["subtype"]?.string ?? ""
        durationMs = json["duration_ms"]?.int ?? 0
        durationApiMs = json["duration_api_ms"]?.int ?? 0
        isError = json["is_error"]?.bool ?? false
        numTurns = json["num_turns"]?.int ?? 0
        sessionId = json["session_id"]?.string ?? ""
        stopReason = json["stop_reason"]?.string
        totalCostUsd = json["total_cost_usd"]?.double
        usage = json["usage"]?.nonNull
        result = json["result"]?.string
        structuredOutput = json["structured_output"]?.nonNull
        modelUsage = (json["modelUsage"]?.object ?? [:]).mapValues(ModelUsage.init(json:))
        permissionDenials = json["permission_denials"]?.array ?? []
        if let deferred = json["deferred_tool_use"], let id = deferred["id"]?.string {
            deferredToolUse = DeferredToolUse(id: id, name: deferred["name"]?.string ?? "", input: deferred["input"] ?? [:])
        }
        errors = ResultError.normalizedErrors(json["errors"])
        apiErrorStatus = json["api_error_status"]?.int
        uuid = json["uuid"]?.string
        terminalReason = json["terminal_reason"]?.string
        origin = json["origin"]?.nonNull
        raw = json
    }
}

/// A raw Messages API streaming event.
public struct StreamEvent: Sendable {
    public var uuid: String
    public var sessionId: String
    /// `message_start`, `content_block_delta`, … as the API sends it.
    public var event: JSONValue
    public var parentToolUseId: String?
    public var raw: JSONValue

    init(json: JSONValue) {
        uuid = json["uuid"]?.string ?? ""
        sessionId = json["session_id"]?.string ?? ""
        event = json["event"] ?? .null
        parentToolUseId = json["parent_tool_use_id"]?.string
        raw = json
    }

    /// The text of a `text_delta`, when this event is one.
    public var textDelta: String? {
        guard event["type"] == "content_block_delta", event["delta"]?["type"] == "text_delta" else { return nil }
        return event["delta"]?["text"]?.string
    }
}

/// The plan's rate-limit state.
public struct RateLimitInfo: Sendable {
    /// One usage window.
    public struct Window: Sendable, Hashable {
        /// `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, …
        public var name: String
        /// 0…1, when reported.
        public var utilization: Double?
        public var resetsAt: Date?
    }

    /// `allowed`, `allowed_warning` or `rejected`.
    public var status: String
    public var resetsAt: Date?
    public var rateLimitType: String?
    public var utilization: Double?
    public var overageStatus: String?
    public var overageResetsAt: Date?
    public var overageDisabledReason: String?
    public var isUsingOverage: Bool?
    /// Every window, shortest first: from `unifiedWindows` when the CLI sends
    /// it, else the one window the frame names.
    public var windows: [Window]
    public var raw: JSONValue

    init(json: JSONValue) {
        let date = { (value: JSONValue?) in value?.double.map { Date(timeIntervalSince1970: $0) } }
        status = json["status"]?.string ?? ""
        resetsAt = date(json["resetsAt"])
        rateLimitType = json["rateLimitType"]?.string
        utilization = json["utilization"]?.double
        overageStatus = json["overageStatus"]?.string
        overageResetsAt = date(json["overageResetsAt"])
        overageDisabledReason = json["overageDisabledReason"]?.string
        isUsingOverage = json["isUsingOverage"]?.bool
        var windows: [Window] = []
        if let unified = json["unifiedWindows"]?.object {
            windows = unified.map { Window(name: $0.key, utilization: $0.value["utilization"]?.double, resetsAt: date($0.value["resetsAt"])) }
        } else if let name = rateLimitType {
            windows = [Window(name: name, utilization: utilization, resetsAt: resetsAt)]
        }
        let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "overage"]
        windows.sort { (order.firstIndex(of: $0.name) ?? order.count, $0.name) < (order.firstIndex(of: $1.name) ?? order.count, $1.name) }
        self.windows = windows
        raw = json
    }

    /// The window named `name`.
    public func window(_ name: String) -> Window? { windows.first { $0.name == name } }
}

/// The plan's rate-limit state changed.
public struct RateLimitEvent: Sendable {
    public var info: RateLimitInfo
    public var uuid: String
    public var sessionId: String
    public var raw: JSONValue

    init(json: JSONValue) {
        info = RateLimitInfo(json: json["rate_limit_info"] ?? [:])
        uuid = json["uuid"]?.string ?? ""
        sessionId = json["session_id"]?.string ?? ""
        raw = json
    }
}

/// The conversation was replaced without ending the connection; running
/// totals such as cost restart from zero.
public struct ConversationResetMessage: Sendable {
    /// An id for the fresh conversation (not the next session id).
    public var newConversationId: String
    public var uuid: String
    /// The session that was reset.
    public var sessionId: String
    public var raw: JSONValue

    init(json: JSONValue) {
        newConversationId = json["new_conversation_id"]?.string ?? ""
        uuid = json["uuid"]?.string ?? ""
        sessionId = json["session_id"]?.string ?? ""
        raw = json
    }
}
