import Foundation

/// The system prompt a session runs with.
public enum SystemPrompt: Sendable, Hashable, ExpressibleByStringLiteral {
    /// A prompt of your own, replacing Claude Code's.
    case text(String)
    /// Claude Code's own prompt, optionally with text appended.
    ///
    /// - Parameters:
    ///   - append: Added after Claude Code's prompt.
    ///   - excludeDynamicSections: Moves per-user sections (working directory,
    ///     memory, git status) out of the system prompt into the first user
    ///     message, so the prompt stays cacheable across users.
    ///   - snapshot: Whether the session records the prompt on its first
    ///     request and reuses it verbatim afterwards (the CLI's default is true).
    case preset(append: String? = nil, excludeDynamicSections: Bool? = nil, snapshot: Bool? = nil)
    /// A prompt of your own, in the form that can also set `snapshot`.
    case custom(prompt: String, snapshot: Bool? = nil)
    /// A prompt read from a file.
    case file(path: String)

    public init(stringLiteral value: String) { self = .text(value) }

    /// Claude Code's own prompt, unchanged.
    public static var claudeCode: SystemPrompt { .preset() }
}

/// The built-in tools a session offers.
public enum ToolsOption: Sendable, Hashable {
    /// Exactly these built-in tools (`Bash`, `Read`, …); an empty list offers none.
    case list([String])
    /// Claude Code's default tool set.
    case claudeCode
}

/// Which settings files the CLI loads.
public enum SettingSource: String, Sendable, Hashable {
    /// `~/.claude/settings.json`
    case user
    /// `.claude/settings.json` and the project's `CLAUDE.md`.
    case project
    /// `.claude/settings.local.json`
    case local
}

/// How much effort Claude puts into a response.
public struct EffortLevel: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let low: EffortLevel = "low"
    public static let medium: EffortLevel = "medium"
    public static let high: EffortLevel = "high"
    public static let xhigh: EffortLevel = "xhigh"
    public static let max: EffortLevel = "max"
}

/// Whether thinking text comes back summarized or is left out.
public enum ThinkingDisplay: String, Sendable, Hashable {
    case summarized, omitted
}

/// Claude's extended thinking.
public enum ThinkingConfig: Sendable, Hashable {
    /// Claude decides when and how much to think.
    case adaptive(display: ThinkingDisplay? = nil)
    /// A fixed thinking budget in tokens (older models).
    case enabled(budgetTokens: Int, display: ThinkingDisplay? = nil)
    /// No extended thinking.
    case disabled
}

/// A structured-output format for the final result.
public enum OutputFormat: Sendable, Hashable {
    /// The result's `structured_output` conforms to this JSON Schema.
    case jsonSchema(JSONValue)
}

/// Which skills the main session may use.
public enum SkillsOption: Sendable, Hashable {
    /// Every discovered skill.
    case all
    /// Only these skills, by exact name (`pdf`, or `plugin:skill`).
    case only([String])
}

/// Extra settings layered over the settings files (the CLI's `--settings`).
public enum SettingsValue: Sendable, Hashable {
    /// A settings JSON file.
    case path(String)
    /// Settings given inline.
    case inline(JSONValue)
}

/// A plugin to load.
public struct SdkPluginConfig: Sendable, Hashable {
    /// A local plugin directory.
    public var path: String
    /// Loads the plugin without the MCP servers it declares.
    public var skipMcpDiscovery: Bool

    public init(path: String, skipMcpDiscovery: Bool = false) {
        self.path = path
        self.skipMcpDiscovery = skipMcpDiscovery
    }

    /// A local plugin directory.
    public static func local(_ path: String) -> SdkPluginConfig { SdkPluginConfig(path: path) }
}

/// An MCP server the session can use.
public enum McpServerConfig: Sendable {
    /// A server run as a child process speaking MCP over stdio.
    case stdio(command: String, args: [String] = [], env: [String: String] = [:])
    /// A remote server over server-sent events.
    case sse(url: String, headers: [String: String] = [:])
    /// A remote server over streamable HTTP.
    case http(url: String, headers: [String: String] = [:])
    /// A server living in this process (see ``createSdkMcpServer(name:version:tools:)``).
    case sdk(SdkMcpServer)
    /// Any other server configuration, passed to the CLI as given.
    case json(JSONValue)

    /// The entry under `mcpServers` in the CLI's `--mcp-config`.
    var cliJSON: JSONValue {
        switch self {
        case let .stdio(command, args, env):
            var object: [String: JSONValue] = ["type": "stdio", "command": .string(command)]
            if !args.isEmpty { object["args"] = JSONValue(args) }
            if !env.isEmpty { object["env"] = .object(env.mapValues(JSONValue.string)) }
            return .object(object)
        case let .sse(url, headers):
            var object: [String: JSONValue] = ["type": "sse", "url": .string(url)]
            if !headers.isEmpty { object["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(object)
        case let .http(url, headers):
            var object: [String: JSONValue] = ["type": "http", "url": .string(url)]
            if !headers.isEmpty { object["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(object)
        case let .sdk(server):
            return ["type": "sdk", "name": .string(server.name)]
        case let .json(value):
            return value
        }
    }
}

/// A subagent the model can start with the Agent tool.
public struct AgentDefinition: Sendable, Hashable {
    /// When the model should use this agent.
    public var description: String
    /// The agent's system prompt.
    public var prompt: String
    /// Tools the agent may use; nil inherits the main session's.
    public var tools: [String]?
    public var disallowedTools: [String]?
    /// `sonnet`, `opus`, `haiku`, `inherit`, or a full model id.
    public var model: String?
    public var skills: [String]?
    /// `user`, `project` or `local`.
    public var memory: String?
    /// Server names, or inline `{name: config}` objects.
    public var mcpServers: [JSONValue]?
    public var initialPrompt: String?
    public var maxTurns: Int?
    public var background: Bool?
    /// An effort level name or a number.
    public var effort: JSONValue?
    public var permissionMode: PermissionMode?
    /// Other fields, passed through as given.
    public var extra: [String: JSONValue]

    public init(
        description: String, prompt: String, tools: [String]? = nil, disallowedTools: [String]? = nil,
        model: String? = nil, skills: [String]? = nil, memory: String? = nil, mcpServers: [JSONValue]? = nil,
        initialPrompt: String? = nil, maxTurns: Int? = nil, background: Bool? = nil, effort: JSONValue? = nil,
        permissionMode: PermissionMode? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.description = description
        self.prompt = prompt
        self.tools = tools
        self.disallowedTools = disallowedTools
        self.model = model
        self.skills = skills
        self.memory = memory
        self.mcpServers = mcpServers
        self.initialPrompt = initialPrompt
        self.maxTurns = maxTurns
        self.background = background
        self.effort = effort
        self.permissionMode = permissionMode
        self.extra = extra
    }

    /// The definition as the `initialize` request carries it, unset fields left out.
    var json: JSONValue {
        var object = extra
        object["description"] = .string(description)
        object["prompt"] = .string(prompt)
        object.set("tools", tools.map(JSONValue.init))
        object.set("disallowedTools", disallowedTools.map(JSONValue.init))
        object.set("model", model.map(JSONValue.string))
        object.set("skills", skills.map(JSONValue.init))
        object.set("memory", memory.map(JSONValue.string))
        object.set("mcpServers", mcpServers.map(JSONValue.array))
        object.set("initialPrompt", initialPrompt.map(JSONValue.string))
        object.set("maxTurns", maxTurns.map(JSONValue.int))
        object.set("background", background.map(JSONValue.bool))
        object.set("effort", effort)
        object.set("permissionMode", permissionMode.map { .string($0.rawValue) })
        return .object(object)
    }
}

/// Network isolation for sandboxed commands.
public struct SandboxNetworkConfig: Sendable, Hashable {
    public var allowedDomains: [String]?
    public var deniedDomains: [String]?
    public var allowManagedDomainsOnly: Bool?
    public var allowUnixSockets: [String]?
    public var allowAllUnixSockets: Bool?
    public var allowLocalBinding: Bool?
    public var allowMachLookup: [String]?
    public var httpProxyPort: Int?
    public var socksProxyPort: Int?

    public init(
        allowedDomains: [String]? = nil, deniedDomains: [String]? = nil, allowManagedDomainsOnly: Bool? = nil,
        allowUnixSockets: [String]? = nil, allowAllUnixSockets: Bool? = nil, allowLocalBinding: Bool? = nil,
        allowMachLookup: [String]? = nil, httpProxyPort: Int? = nil, socksProxyPort: Int? = nil
    ) {
        self.allowedDomains = allowedDomains
        self.deniedDomains = deniedDomains
        self.allowManagedDomainsOnly = allowManagedDomainsOnly
        self.allowUnixSockets = allowUnixSockets
        self.allowAllUnixSockets = allowAllUnixSockets
        self.allowLocalBinding = allowLocalBinding
        self.allowMachLookup = allowMachLookup
        self.httpProxyPort = httpProxyPort
        self.socksProxyPort = socksProxyPort
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        object.set("allowedDomains", allowedDomains.map(JSONValue.init))
        object.set("deniedDomains", deniedDomains.map(JSONValue.init))
        object.set("allowManagedDomainsOnly", allowManagedDomainsOnly.map(JSONValue.bool))
        object.set("allowUnixSockets", allowUnixSockets.map(JSONValue.init))
        object.set("allowAllUnixSockets", allowAllUnixSockets.map(JSONValue.bool))
        object.set("allowLocalBinding", allowLocalBinding.map(JSONValue.bool))
        object.set("allowMachLookup", allowMachLookup.map(JSONValue.init))
        object.set("httpProxyPort", httpProxyPort.map(JSONValue.int))
        object.set("socksProxyPort", socksProxyPort.map(JSONValue.int))
        return .object(object)
    }
}

/// How Claude Code sandboxes bash commands (filesystem and network
/// isolation). Tool-level file and network restrictions come from permission
/// rules instead (Read/Edit/WebFetch rules).
public struct SandboxSettings: Sendable, Hashable {
    public var enabled: Bool?
    /// Auto-approves bash commands that run sandboxed.
    public var autoAllowBashIfSandboxed: Bool?
    /// Commands that run outside the sandbox, e.g. `["git", "docker"]`.
    public var excludedCommands: [String]?
    /// Lets a command opt out of the sandbox with `dangerouslyDisableSandbox`.
    public var allowUnsandboxedCommands: Bool?
    public var network: SandboxNetworkConfig?
    /// Violations to ignore: `file` paths and `network` hosts.
    public var ignoreViolations: (file: [String]?, network: [String]?)?
    /// A weaker sandbox for unprivileged Docker environments (Linux).
    public var enableWeakerNestedSandbox: Bool?
    /// Other sandbox settings, passed through as given.
    public var extra: [String: JSONValue]

    public init(
        enabled: Bool? = nil, autoAllowBashIfSandboxed: Bool? = nil, excludedCommands: [String]? = nil,
        allowUnsandboxedCommands: Bool? = nil, network: SandboxNetworkConfig? = nil,
        ignoreViolations: (file: [String]?, network: [String]?)? = nil, enableWeakerNestedSandbox: Bool? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.enabled = enabled
        self.autoAllowBashIfSandboxed = autoAllowBashIfSandboxed
        self.excludedCommands = excludedCommands
        self.allowUnsandboxedCommands = allowUnsandboxedCommands
        self.network = network
        self.ignoreViolations = ignoreViolations
        self.enableWeakerNestedSandbox = enableWeakerNestedSandbox
        self.extra = extra
    }

    public static func == (lhs: SandboxSettings, rhs: SandboxSettings) -> Bool { lhs.json == rhs.json }
    public func hash(into hasher: inout Hasher) { hasher.combine(json) }

    /// The `sandbox` settings object.
    public var json: JSONValue {
        var object = extra
        object.set("enabled", enabled.map(JSONValue.bool))
        object.set("autoAllowBashIfSandboxed", autoAllowBashIfSandboxed.map(JSONValue.bool))
        object.set("excludedCommands", excludedCommands.map(JSONValue.init))
        object.set("allowUnsandboxedCommands", allowUnsandboxedCommands.map(JSONValue.bool))
        object.set("network", network?.json)
        if let ignoreViolations {
            var ignore: [String: JSONValue] = [:]
            ignore.set("file", ignoreViolations.file.map(JSONValue.init))
            ignore.set("network", ignoreViolations.network.map(JSONValue.init))
            object["ignoreViolations"] = .object(ignore)
        }
        object.set("enableWeakerNestedSandbox", enableWeakerNestedSandbox.map(JSONValue.bool))
        return .object(object)
    }
}
