import Foundation

/// The CLI's answer to `initialize`: its commands, models, agents, account
/// and output styles. Typed views read the common fields; ``raw`` has all.
public struct InitializationResult: Sendable {
    public let raw: JSONValue

    public var commands: [SlashCommand] { raw["commands"]?.array?.map(SlashCommand.init(json:)) ?? [] }
    /// The account's models; the `default` entry repeats one of the others.
    public var models: [ModelInfo] { raw["models"]?.array?.compactMap(ModelInfo.init(json:)) ?? [] }
    public var agents: [AgentInfo] { raw["agents"]?.array?.compactMap(AgentInfo.init(json:)) ?? [] }
    public var account: AccountInfo { AccountInfo(json: raw["account"] ?? [:]) }
    public var outputStyle: String? { raw["output_style"]?.string }
    public var availableOutputStyles: [String] { raw["available_output_styles"]?.array?.compactMap(\.string) ?? [] }
    public var claudeCodeVersion: String? { raw["claude_code_version"]?.string }
}

/// A slash command or skill the session offers.
public struct SlashCommand: Sendable, Hashable {
    public var name: String
    public var description: String
    public var argumentHint: String
    public var raw: JSONValue

    init(json: JSONValue) {
        name = json["name"]?.string ?? ""
        description = json["description"]?.string ?? ""
        argumentHint = json["argumentHint"]?.string ?? ""
        raw = json
    }
}

/// A model the account can use.
public struct ModelInfo: Sendable, Hashable {
    /// What ``ClaudeAgentOptions/model`` and `setModel` take: an alias or a full id.
    public var value: String
    /// The model id the value stands for today.
    public var resolvedModel: String?
    public var displayName: String
    public var description: String
    public var supportedEffortLevels: [String]
    public var raw: JSONValue

    init?(json: JSONValue) {
        guard let value = json["value"]?.string else { return nil }
        self.value = value
        resolvedModel = json["resolvedModel"]?.string
        displayName = json["displayName"]?.string ?? value
        description = json["description"]?.string ?? ""
        supportedEffortLevels = json["supportedEffortLevels"]?.array?.compactMap(\.string) ?? []
        raw = json
    }
}

/// A subagent the session can start.
public struct AgentInfo: Sendable, Hashable {
    public var name: String
    public var description: String
    public var model: String?

    init?(json: JSONValue) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        description = json["description"]?.string ?? ""
        model = json["model"]?.string
    }
}

/// The logged-in account.
public struct AccountInfo: Sendable, Hashable {
    public var email: String?
    public var organization: String?
    public var subscriptionType: String?
    public var tokenSource: String?
    public var apiKeySource: String?
    public var apiProvider: String?
    public var raw: JSONValue

    init(json: JSONValue) {
        email = json["email"]?.string
        organization = json["organization"]?.string
        subscriptionType = json["subscriptionType"]?.string
        tokenSource = json["tokenSource"]?.string
        apiKeySource = json["apiKeySource"]?.string
        apiProvider = json["apiProvider"]?.string
        raw = json
    }
}

/// One MCP server's connection state.
public struct McpServerStatus: Sendable {
    public var name: String
    /// `connected`, `pending`, `failed`, `needs-auth` or `disabled`.
    public var status: String
    /// The server's own name and version, when connected.
    public var serverInfo: (name: String, version: String)?
    public var error: String?
    /// `project`, `user`, `local`, `claudeai`, `managed`, …
    public var scope: String?
    public var tools: [String]
    public var raw: JSONValue

    init(json: JSONValue) {
        name = json["name"]?.string ?? ""
        status = json["status"]?.string ?? ""
        if let info = json["serverInfo"], let name = info["name"]?.string {
            serverInfo = (name, info["version"]?.string ?? "")
        }
        error = json["error"]?.string
        scope = json["scope"]?.string
        tools = json["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        raw = json
    }
}

/// What the context window holds, by category (the `/context` command's data).
public struct ContextUsage: Sendable {
    public struct Category: Sendable, Hashable {
        public var name: String
        public var tokens: Int
        public var color: String
        public var isDeferred: Bool
    }

    public let raw: JSONValue

    public var categories: [Category] {
        raw["categories"]?.array?.map {
            Category(name: $0["name"]?.string ?? "", tokens: $0["tokens"]?.int ?? 0, color: $0["color"]?.string ?? "",
                     isDeferred: $0["isDeferred"]?.bool ?? false)
        } ?? []
    }
    public var totalTokens: Int { raw["totalTokens"]?.int ?? 0 }
    public var maxTokens: Int { raw["maxTokens"]?.int ?? 0 }
    public var rawMaxTokens: Int { raw["rawMaxTokens"]?.int ?? 0 }
    /// 0…100.
    public var percentage: Double { raw["percentage"]?.double ?? 0 }
    public var model: String { raw["model"]?.string ?? "" }
    public var isAutoCompactEnabled: Bool { raw["isAutoCompactEnabled"]?.bool ?? false }
}

/// What rewinding files did, or would do with `dryRun`.
public struct RewindFilesResult: Sendable, Hashable {
    public var canRewind: Bool
    public var error: String?
    public var filesChanged: [String]
    public var insertions: Int?
    public var deletions: Int?
    public var raw: JSONValue

    init(json: JSONValue) {
        canRewind = json["canRewind"]?.bool ?? (json["error"] == nil)
        error = json["error"]?.string
        filesChanged = json["filesChanged"]?.array?.compactMap(\.string) ?? []
        insertions = json["insertions"]?.int
        deletions = json["deletions"]?.int
        raw = json
    }
}

/// What an interrupt left: queued prompts that will still run unless cancelled.
public struct InterruptReceipt: Sendable, Hashable {
    /// Uuids of queued user messages that survive the interrupt.
    public var stillQueued: [String]
    /// Uuids cancelled by the interrupt (when it asked to cancel queued prompts).
    public var cancelled: [String]
}

/// What replacing the dynamic MCP servers did.
public struct McpSetServersResult: Sendable, Hashable {
    public var added: [String]
    public var removed: [String]
    /// Connection errors by server name.
    public var errors: [String: String]

    init(json: JSONValue) {
        added = json["added"]?.array?.compactMap(\.string) ?? []
        removed = json["removed"]?.array?.compactMap(\.string) ?? []
        errors = (json["errors"]?.object ?? [:]).compactMapValues(\.string)
    }
}

/// A file read through the session (`readFile`).
public struct ReadFileResult: Sendable, Hashable {
    /// The contents: text, or base64 when ``encoding`` is `base64`.
    public var contents: String
    public var absolutePath: String
    public var truncated: Bool
    public var encoding: String?

    init(json: JSONValue) {
        contents = json["contents"]?.string ?? ""
        absolutePath = json["absPath"]?.string ?? ""
        truncated = json["truncated"]?.bool ?? false
        encoding = json["encoding"]?.string
    }
}
