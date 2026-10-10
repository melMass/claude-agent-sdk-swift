import Foundation

/// How tool calls are approved for a session.
public struct PermissionMode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    /// Standard behavior: dangerous operations go to ``ClaudeAgentOptions/canUseTool``.
    public static let `default`: PermissionMode = "default"
    /// File edits are accepted without asking.
    public static let acceptEdits: PermissionMode = "acceptEdits"
    /// Planning only: no tool that changes anything runs.
    public static let plan: PermissionMode = "plan"
    /// Every permission check is skipped (except explicit deny rules).
    public static let bypassPermissions: PermissionMode = "bypassPermissions"
    /// Nothing prompts; anything not pre-approved is denied.
    public static let dontAsk: PermissionMode = "dontAsk"
    /// A model classifier approves or denies each call, asking when it cannot decide.
    public static let auto: PermissionMode = "auto"
}

/// What a permission rule does to matching tool calls.
public enum PermissionBehavior: String, Sendable, Hashable, Codable {
    case allow, deny, ask
}

/// Where a permission update is saved.
public enum PermissionUpdateDestination: String, Sendable, Hashable, Codable {
    case userSettings, projectSettings, localSettings, session, cliArg
}

/// A permission rule: a tool name and, optionally, a specifier such as a
/// command pattern (`Bash` + `git status`).
public struct PermissionRuleValue: Sendable, Hashable {
    public var toolName: String
    public var ruleContent: String?

    public init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }
}

/// A change to the session's permission rules, as the CLI suggests it in a
/// permission request or as a callback returns it to apply.
public struct PermissionUpdate: Sendable, Hashable {
    /// The kind of update.
    public enum Kind: String, Sendable, Hashable {
        case addRules, replaceRules, removeRules, setMode, addDirectories, removeDirectories
    }

    public var type: Kind
    public var rules: [PermissionRuleValue]?
    public var behavior: PermissionBehavior?
    public var mode: PermissionMode?
    public var directories: [String]?
    public var destination: PermissionUpdateDestination?

    public init(
        type: Kind, rules: [PermissionRuleValue]? = nil, behavior: PermissionBehavior? = nil,
        mode: PermissionMode? = nil, directories: [String]? = nil, destination: PermissionUpdateDestination? = nil
    ) {
        self.type = type
        self.rules = rules
        self.behavior = behavior
        self.mode = mode
        self.directories = directories
        self.destination = destination
    }

    /// Adds rules with `behavior` at `destination`.
    public static func addRules(
        _ rules: [PermissionRuleValue], behavior: PermissionBehavior, destination: PermissionUpdateDestination = .session
    ) -> PermissionUpdate {
        PermissionUpdate(type: .addRules, rules: rules, behavior: behavior, destination: destination)
    }

    /// Switches the permission mode.
    public static func setMode(_ mode: PermissionMode, destination: PermissionUpdateDestination = .session) -> PermissionUpdate {
        PermissionUpdate(type: .setMode, mode: mode, destination: destination)
    }

    /// Grants access to more directories.
    public static func addDirectories(_ directories: [String], destination: PermissionUpdateDestination = .session) -> PermissionUpdate {
        PermissionUpdate(type: .addDirectories, directories: directories, destination: destination)
    }

    /// The wire form: only the fields that belong to this kind of update.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string(type.rawValue)]
        object.set("destination", destination.map { .string($0.rawValue) })
        switch type {
        case .addRules, .replaceRules, .removeRules:
            object.set("rules", rules.map { rules in
                .array(rules.map { ["toolName": .string($0.toolName), "ruleContent": JSONValue($0.ruleContent)] })
            })
            object.set("behavior", behavior.map { .string($0.rawValue) })
        case .setMode:
            object.set("mode", mode.map { .string($0.rawValue) })
        case .addDirectories, .removeDirectories:
            object.set("directories", directories.map(JSONValue.init))
        }
        return .object(object)
    }

    /// Reads the wire form; nil when `type` is missing or unknown.
    public init?(json: JSONValue) {
        guard let kind = json["type"]?.string.flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(
            type: kind,
            rules: json["rules"]?.array?.compactMap { rule in
                rule["toolName"]?.string.map { PermissionRuleValue(toolName: $0, ruleContent: rule["ruleContent"]?.string) }
            },
            behavior: json["behavior"]?.string.flatMap(PermissionBehavior.init(rawValue:)),
            mode: json["mode"]?.string.map(PermissionMode.init(rawValue:)),
            directories: json["directories"]?.array?.compactMap(\.string),
            destination: json["destination"]?.string.flatMap(PermissionUpdateDestination.init(rawValue:))
        )
    }
}

/// What the CLI says about a tool call it asks permission for.
public struct ToolPermissionContext: Sendable {
    /// Rule changes that would stop the CLI asking again, e.g. for an
    /// "always allow" button; return them as `updatedPermissions` to apply.
    public var suggestions: [PermissionUpdate]
    /// The `tool_use` block's id; always present on current CLIs.
    public var toolUseId: String?
    /// Set when the call comes from inside a subagent.
    public var agentId: String?
    /// The path that triggered the request, e.g. a command reaching outside the allowed directories.
    public var blockedPath: String?
    /// Why the request was raised, e.g. a PreToolUse hook's `ask` reason.
    public var decisionReason: String?
    /// The full prompt sentence, e.g. "Claude wants to read foo.txt".
    public var title: String?
    /// A short noun phrase for the action, e.g. "Read file".
    public var displayName: String?
    /// A subtitle for the permission UI.
    public var description: String?
    /// For `mcp__*` tools: the server's name and where it was configured (`sdk` for in-process servers).
    public var mcpServer: (name: String, source: String)?
    /// The control request's id.
    public var requestId: String
    /// The whole request as the CLI sent it.
    public var raw: JSONValue

    init(request: JSONValue, requestId: String) {
        suggestions = request["permission_suggestions"]?.array?.compactMap(PermissionUpdate.init(json:)) ?? []
        toolUseId = request["tool_use_id"]?.string
        agentId = request["agent_id"]?.string
        blockedPath = request["blocked_path"]?.string
        decisionReason = request["decision_reason"]?.string
        title = request["title"]?.string
        displayName = request["display_name"]?.string
        description = request["description"]?.string
        if let server = request["mcp_server"], let name = server["name"]?.string {
            mcpServer = (name, server["source"]?.string ?? "")
        }
        self.requestId = requestId
        raw = request
    }
}

/// The answer to a permission request.
public enum PermissionResult: Sendable, Hashable {
    /// Runs the tool, with `updatedInput` in place of the model's input when
    /// given, and applies `updatedPermissions` when given.
    case allow(updatedInput: JSONValue? = nil, updatedPermissions: [PermissionUpdate]? = nil)
    /// Refuses the call; the model reads `message`. `interrupt` also ends the turn.
    case deny(message: String = "", interrupt: Bool = false)

    /// Allows the call unchanged.
    public static var allow: PermissionResult { .allow() }

    func json(originalInput: JSONValue) -> JSONValue {
        switch self {
        case let .allow(updatedInput, updatedPermissions):
            var object: [String: JSONValue] = ["behavior": "allow", "updatedInput": updatedInput ?? originalInput]
            object.set("updatedPermissions", updatedPermissions.map { .array($0.map(\.json)) })
            return .object(object)
        case let .deny(message, interrupt):
            var object: [String: JSONValue] = ["behavior": "deny", "message": .string(message)]
            if interrupt { object["interrupt"] = true }
            return .object(object)
        }
    }
}

/// Decides whether a tool call may run: called with the tool's name, its
/// input and the CLI's context whenever the permission rules would prompt.
public typealias CanUseTool = @Sendable (_ toolName: String, _ input: JSONValue, _ context: ToolPermissionContext) async throws
    -> PermissionResult
