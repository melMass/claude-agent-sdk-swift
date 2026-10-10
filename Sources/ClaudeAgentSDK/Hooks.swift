import Foundation

/// A point in the agent loop where hooks run. An open set: the constants
/// below are the events Claude Code documents, and any other name is passed
/// through as given.
public struct HookEvent: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let preToolUse: HookEvent = "PreToolUse"
    public static let postToolUse: HookEvent = "PostToolUse"
    public static let postToolUseFailure: HookEvent = "PostToolUseFailure"
    public static let postToolBatch: HookEvent = "PostToolBatch"
    public static let notification: HookEvent = "Notification"
    public static let userPromptSubmit: HookEvent = "UserPromptSubmit"
    public static let userPromptExpansion: HookEvent = "UserPromptExpansion"
    public static let sessionStart: HookEvent = "SessionStart"
    public static let sessionEnd: HookEvent = "SessionEnd"
    public static let stop: HookEvent = "Stop"
    public static let stopFailure: HookEvent = "StopFailure"
    public static let subagentStart: HookEvent = "SubagentStart"
    public static let subagentStop: HookEvent = "SubagentStop"
    public static let preCompact: HookEvent = "PreCompact"
    public static let postCompact: HookEvent = "PostCompact"
    public static let preModelSwitch: HookEvent = "PreModelSwitch"
    public static let postModelSwitch: HookEvent = "PostModelSwitch"
    public static let permissionRequest: HookEvent = "PermissionRequest"
    public static let permissionDenied: HookEvent = "PermissionDenied"
    public static let setup: HookEvent = "Setup"
    public static let teammateIdle: HookEvent = "TeammateIdle"
    public static let taskCreated: HookEvent = "TaskCreated"
    public static let taskCompleted: HookEvent = "TaskCompleted"
    public static let elicitation: HookEvent = "Elicitation"
    public static let elicitationResult: HookEvent = "ElicitationResult"
    public static let configChange: HookEvent = "ConfigChange"
    public static let worktreeCreate: HookEvent = "WorktreeCreate"
    public static let worktreeRemove: HookEvent = "WorktreeRemove"
    public static let instructionsLoaded: HookEvent = "InstructionsLoaded"
    public static let cwdChanged: HookEvent = "CwdChanged"
    public static let fileChanged: HookEvent = "FileChanged"
    public static let directoryAdded: HookEvent = "DirectoryAdded"
    public static let messageDisplay: HookEvent = "MessageDisplay"

    /// Every event Claude Code documents, in its lifecycle order.
    public static let allCases: [HookEvent] = [
        .preToolUse, .postToolUse, .postToolUseFailure, .postToolBatch, .notification, .userPromptSubmit,
        .userPromptExpansion, .sessionStart, .sessionEnd, .stop, .stopFailure, .subagentStart, .subagentStop,
        .preCompact, .postCompact, .preModelSwitch, .postModelSwitch, .permissionRequest, .permissionDenied,
        .setup, .teammateIdle, .taskCreated, .taskCompleted, .elicitation, .elicitationResult, .configChange,
        .worktreeCreate, .worktreeRemove, .instructionsLoaded, .cwdChanged, .fileChanged, .directoryAdded,
        .messageDisplay,
    ]
}

/// What a hook receives: the fields every event carries, typed accessors for
/// the event-specific ones, and the whole payload as ``raw``.
public struct HookInput: Sendable {
    /// The whole input as the CLI sent it.
    public let raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    public var hookEventName: HookEvent { HookEvent(rawValue: raw["hook_event_name"]?.string ?? "") }
    public var sessionId: String { raw["session_id"]?.string ?? "" }
    public var transcriptPath: String { raw["transcript_path"]?.string ?? "" }
    public var cwd: String { raw["cwd"]?.string ?? "" }
    public var permissionMode: PermissionMode? { raw["permission_mode"]?.string.map(PermissionMode.init(rawValue:)) }
    /// The id of the user prompt being processed; absent until the first input.
    public var promptId: String? { raw["prompt_id"]?.string }
    /// The effort level in effect for the turn, when the model supports effort.
    public var effortLevel: String? { raw["effort"]?["level"]?.string }
    /// Set when the hook fires inside a subagent (tool hooks, SubagentStart/Stop).
    public var agentId: String? { raw["agent_id"]?.string }
    public var agentType: String? { raw["agent_type"]?.string }

    // Tool lifecycle (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest)
    public var toolName: String? { raw["tool_name"]?.string }
    public var toolInput: JSONValue? { raw["tool_input"] }
    public var toolUseId: String? { raw["tool_use_id"]?.string }
    /// PostToolUse: what the tool returned.
    public var toolResponse: JSONValue? { raw["tool_response"] }
    /// PostToolUseFailure: the error text.
    public var error: String? { raw["error"]?.string }
    public var isInterrupt: Bool? { raw["is_interrupt"]?.bool }
    /// Tool execution time, excluding permission prompts and hooks.
    public var durationMs: Int? { raw["duration_ms"]?.int }
    /// PermissionRequest: the CLI's suggested rule updates.
    public var permissionSuggestions: [PermissionUpdate] {
        raw["permission_suggestions"]?.array?.compactMap(PermissionUpdate.init(json:)) ?? []
    }

    // UserPromptSubmit
    public var prompt: String? { raw["prompt"]?.string }

    // Stop, SubagentStop
    public var stopHookActive: Bool? { raw["stop_hook_active"]?.bool }
    public var lastAssistantMessage: String? { raw["last_assistant_message"]?.string }
    public var agentTranscriptPath: String? { raw["agent_transcript_path"]?.string }

    // PreCompact
    /// `manual` or `auto`.
    public var trigger: String? { raw["trigger"]?.string }
    public var customInstructions: String? { raw["custom_instructions"]?.string }

    // Notification
    public var message: String? { raw["message"]?.string }
    public var title: String? { raw["title"]?.string }
    public var notificationType: String? { raw["notification_type"]?.string }

    // SessionStart / SessionEnd
    /// SessionStart: `startup`, `resume`, `clear` or `compact`.
    public var source: String? { raw["source"]?.string }
    /// SessionEnd: why the session ended.
    public var reason: String? { raw["reason"]?.string }
}

/// Per-call context for a hook.
public struct HookContext: Sendable {
    /// The control request's id.
    public let requestId: String
}

/// The decision a PreToolUse hook makes about a tool call.
public enum HookPermissionDecision: String, Sendable, Hashable {
    case allow, deny, ask, `defer`
}

/// Event-specific hook output (`hookSpecificOutput` on the wire).
public enum HookSpecificOutput: Sendable, Hashable {
    /// Decides a tool call, optionally rewriting its input or adding context.
    case preToolUse(
        permissionDecision: HookPermissionDecision? = nil, permissionDecisionReason: String? = nil,
        updatedInput: JSONValue? = nil, additionalContext: String? = nil)
    /// Adds context after a tool ran, or replaces its output before the model sees it.
    case postToolUse(additionalContext: String? = nil, updatedToolOutput: JSONValue? = nil, updatedMCPToolOutput: JSONValue? = nil)
    case postToolUseFailure(additionalContext: String? = nil)
    /// Adds context to the prompt, or sets the session title.
    case userPromptSubmit(additionalContext: String? = nil, sessionTitle: String? = nil, suppressOriginalPrompt: Bool? = nil)
    case sessionStart(additionalContext: String? = nil, initialUserMessage: String? = nil, sessionTitle: String? = nil)
    case notification(additionalContext: String? = nil)
    case subagentStart(additionalContext: String? = nil)
    /// Answers a permission request: `decision` is the CLI's permission decision object.
    case permissionRequest(decision: JSONValue)
    case stop(additionalContext: String? = nil)
    case subagentStop(additionalContext: String? = nil)
    case postToolBatch(additionalContext: String? = nil)
    /// Any other event's output, given as the whole `hookSpecificOutput` object.
    case custom(JSONValue)

    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        func event(_ name: String) { object["hookEventName"] = .string(name) }
        switch self {
        case let .preToolUse(decision, reason, updatedInput, additionalContext):
            event("PreToolUse")
            object.set("permissionDecision", decision.map { .string($0.rawValue) })
            object.set("permissionDecisionReason", reason.map(JSONValue.string))
            object.set("updatedInput", updatedInput)
            object.set("additionalContext", additionalContext.map(JSONValue.string))
        case let .postToolUse(additionalContext, updatedToolOutput, updatedMCPToolOutput):
            event("PostToolUse")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
            object.set("updatedToolOutput", updatedToolOutput)
            object.set("updatedMCPToolOutput", updatedMCPToolOutput)
        case let .postToolUseFailure(additionalContext):
            event("PostToolUseFailure")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
        case let .userPromptSubmit(additionalContext, sessionTitle, suppressOriginalPrompt):
            event("UserPromptSubmit")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
            object.set("sessionTitle", sessionTitle.map(JSONValue.string))
            object.set("suppressOriginalPrompt", suppressOriginalPrompt.map(JSONValue.bool))
        case let .sessionStart(additionalContext, initialUserMessage, sessionTitle):
            event("SessionStart")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
            object.set("initialUserMessage", initialUserMessage.map(JSONValue.string))
            object.set("sessionTitle", sessionTitle.map(JSONValue.string))
        case let .notification(additionalContext):
            event("Notification")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
        case let .subagentStart(additionalContext):
            event("SubagentStart")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
        case let .permissionRequest(decision):
            event("PermissionRequest")
            object["decision"] = decision
        case let .stop(additionalContext):
            event("Stop")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
        case let .subagentStop(additionalContext):
            event("SubagentStop")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
        case let .postToolBatch(additionalContext):
            event("PostToolBatch")
            object.set("additionalContext", additionalContext.map(JSONValue.string))
        case let .custom(value):
            return value
        }
        return .object(object)
    }
}

/// What a hook answers. Every field is optional; the empty output lets
/// things proceed unchanged. Mirrors the CLI's hook JSON output
/// (`continue`, `suppressOutput`, `stopReason`, `decision`, `systemMessage`,
/// `reason`, `hookSpecificOutput`, or `async` for a deferred hook).
public struct HookOutput: Sendable, Hashable {
    /// Whether Claude goes on after the hook (`continue`); false stops it.
    public var shouldContinue: Bool?
    /// Hides the hook's output from the transcript.
    public var suppressOutput: Bool?
    /// Shown when `shouldContinue` is false.
    public var stopReason: String?
    /// `block` to block the action (for events other than PreToolUse).
    public var decision: String?
    /// A warning shown to the user.
    public var systemMessage: String?
    /// Feedback for Claude about the decision.
    public var reason: String?
    public var hookSpecificOutput: HookSpecificOutput?
    /// Defers the hook: the CLI goes on without waiting for it.
    public var isAsync: Bool
    /// With `isAsync`: how long the deferred hook may take, in milliseconds.
    public var asyncTimeout: Int?
    /// Extra top-level fields, passed through as given.
    public var extra: [String: JSONValue]

    public init(
        shouldContinue: Bool? = nil, suppressOutput: Bool? = nil, stopReason: String? = nil, decision: String? = nil,
        systemMessage: String? = nil, reason: String? = nil, hookSpecificOutput: HookSpecificOutput? = nil,
        isAsync: Bool = false, asyncTimeout: Int? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.shouldContinue = shouldContinue
        self.suppressOutput = suppressOutput
        self.stopReason = stopReason
        self.decision = decision
        self.systemMessage = systemMessage
        self.reason = reason
        self.hookSpecificOutput = hookSpecificOutput
        self.isAsync = isAsync
        self.asyncTimeout = asyncTimeout
        self.extra = extra
    }

    /// No opinion: things proceed as they would without the hook.
    public static let empty = HookOutput()

    /// A deferred hook: the CLI does not wait for it.
    public static func async(timeout milliseconds: Int? = nil) -> HookOutput {
        HookOutput(isAsync: true, asyncTimeout: milliseconds)
    }

    /// The wire form.
    public var json: JSONValue {
        var object = extra
        if isAsync {
            object["async"] = true
            object.set("asyncTimeout", asyncTimeout.map(JSONValue.int))
        }
        object.set("continue", shouldContinue.map(JSONValue.bool))
        object.set("suppressOutput", suppressOutput.map(JSONValue.bool))
        object.set("stopReason", stopReason.map(JSONValue.string))
        object.set("decision", decision.map(JSONValue.string))
        object.set("systemMessage", systemMessage.map(JSONValue.string))
        object.set("reason", reason.map(JSONValue.string))
        object.set("hookSpecificOutput", hookSpecificOutput?.json)
        return .object(object)
    }
}

/// A hook: called with the event's input, the tool use id when the event
/// concerns a tool call, and per-call context.
public typealias HookCallback = @Sendable (_ input: HookInput, _ toolUseId: String?, _ context: HookContext) async throws
    -> HookOutput

/// Hooks for one event, filtered by a matcher.
public struct HookMatcher: Sendable {
    /// Which calls the hooks see, in Claude Code's hook matcher syntax: for
    /// tool events a tool name or `|`-separated names (`"Write|Edit"`); nil matches all.
    public var matcher: String?
    public var hooks: [HookCallback]
    /// Time limit for each hook of this matcher, in seconds (the CLI's default is 60).
    public var timeout: TimeInterval?

    public init(matcher: String? = nil, timeout: TimeInterval? = nil, hooks: [HookCallback]) {
        self.matcher = matcher
        self.hooks = hooks
        self.timeout = timeout
    }

    public init(matcher: String? = nil, timeout: TimeInterval? = nil, _ hook: @escaping HookCallback) {
        self.init(matcher: matcher, timeout: timeout, hooks: [hook])
    }
}
