import Foundation

/// Everything that configures a session: how the `claude` process is started,
/// what the model may do, and the callbacks that answer the CLI.
///
/// Mirrors the Python SDK's `ClaudeAgentOptions` and the TypeScript SDK's
/// `Options`, with Swift names. Defaults match the Python SDK: in particular
/// a nil ``systemPrompt`` sends an empty system prompt (use
/// ``SystemPrompt/claudeCode`` for Claude Code's own), and a nil
/// ``settingSources`` loads all of the user's settings files.
public struct ClaudeAgentOptions: Sendable {
    // MARK: Tools and permissions

    /// The built-in tools offered: a list, or Claude Code's default set. Nil
    /// leaves the CLI's default. To approve tools without asking, use ``allowedTools``.
    public var tools: ToolsOption?
    /// Tools that run without asking (permission rules such as `Read`,
    /// `Bash(git status:*)` or `mcp__calc__add`). This approves; it neither offers nor hides a tool.
    public var allowedTools: [String] = []
    /// Tools removed from the model's context.
    public var disallowedTools: [String] = []
    /// The session's permission mode. Nil leaves the CLI's choice (which may be `auto`).
    public var permissionMode: PermissionMode?
    /// Required alongside ``PermissionMode/bypassPermissions`` by newer CLIs.
    public var allowDangerouslySkipPermissions = false
    /// An MCP tool that answers permission prompts. Not combinable with ``canUseTool``.
    public var permissionPromptToolName: String?
    /// Who answers permission prompts: `host` (the default) or `none`, which
    /// denies anything that would prompt.
    public var permissionPrompts: String?
    /// Decides tool calls the permission rules would prompt for. Not called
    /// for calls already allowed by ``allowedTools``, the permission mode or
    /// settings rules; a PreToolUse hook sees every call.
    public var canUseTool: CanUseTool?
    /// Hooks by event; each event's matchers run concurrently.
    public var hooks: [HookEvent: [HookMatcher]] = [:]
    /// Maps a tool name the model may emit to another tool (`["Bash": "mcp__workspace__bash"]`).
    public var toolAliases: [String: String] = [:]

    // MARK: Prompt and model

    /// The system prompt. Nil sends an empty one; ``SystemPrompt/claudeCode`` keeps Claude Code's.
    public var systemPrompt: SystemPrompt?
    /// `opus`, `sonnet`, `haiku`, or a full model id. Nil is the CLI's default.
    public var model: String?
    /// Model(s) to fall back to when the primary is unavailable (comma-separated).
    public var fallbackModel: String?
    /// Beta features, e.g. `context-1m-2025-08-07`.
    public var betas: [String] = []
    public var thinking: ThinkingConfig?
    /// Deprecated: use ``thinking``.
    public var maxThinkingTokens: Int?
    public var effort: EffortLevel?
    /// Makes the final result's `structured_output` conform to a JSON Schema.
    public var outputFormat: OutputFormat?
    /// Runs the main thread as this agent (from ``agents`` or settings).
    public var agent: String?
    /// Subagents the model can start with the Agent tool, by name.
    public var agents: [String: AgentDefinition] = [:]
    /// Custom plan-mode workflow instructions.
    public var planModeInstructions: String?

    // MARK: Limits

    public var maxTurns: Int?
    /// Stops the run with an `error_max_budget_usd` result past this cost.
    public var maxBudgetUsd: Double?
    /// An API-side token budget the model paces itself against.
    public var taskBudget: Int?

    // MARK: Sessions

    /// Continues the most recent conversation in ``cwd``.
    public var continueConversation = false
    /// A session id to resume.
    public var resume: String?
    /// The new session's id (a UUID).
    public var sessionId: String?
    /// With ``resume``: continues in a new session instead of the original.
    public var forkSession = false
    /// With ``resume``: loads the conversation only up to this message uuid.
    public var resumeSessionAt: String?
    /// With ``resumeSessionAt``: the prompt uuid of the turn the resume
    /// discards; the CLI refuses the resume if anything else would be lost.
    public var resumeDropsTurn: String?
    /// False keeps the session off disk: it cannot be resumed afterwards.
    public var persistSession = true
    /// A title for a new session.
    public var title: String?
    /// Backs up files before edits so ``Query/rewindFiles(userMessageId:dryRun:)`` can restore them.
    public var enableFileCheckpointing = false

    // MARK: MCP

    /// MCP servers by key; the model sees their tools as `mcp__<key>__<tool>`.
    public var mcpServers: [String: McpServerConfig] = [:]
    /// An MCP config file path or JSON string, passed to `--mcp-config` as
    /// given when ``mcpServers`` is empty.
    public var mcpConfig: String?
    /// Uses only the MCP servers given here, ignoring `.mcp.json`, settings and plugins.
    public var strictMcpConfig = false
    /// Answers MCP elicitation requests; without it they are declined.
    public var onElicitation: OnElicitation?

    // MARK: Environment

    /// The session's working directory. Nil is this process's.
    public var cwd: String?
    /// More directories the session may access.
    public var addDirs: [String] = []
    /// The `claude` executable; nil looks for it (see ``ClaudeCLI/locate(environment:)``).
    public var cliPath: String?
    /// Variables set in the CLI's environment, over the inherited ones.
    public var env: [String: String] = [:]
    /// Drops inherited `CLAUDE*` and `ANTHROPIC_*` variables (except
    /// `CLAUDE_CONFIG_DIR`) before ``env`` is applied. A process started from
    /// inside a Claude Code session inherits that session's variables, which
    /// reach past the flags (its plugins, an API key instead of the login).
    public var stripsClaudeCodeEnvironment = false
    /// Settings files to load. Nil loads all (the CLI's default); `[]` loads none.
    public var settingSources: [SettingSource]?
    /// Extra settings layered over the files.
    public var settings: SettingsValue?
    /// Policy-tier settings from the host application.
    public var managedSettings: JSONValue?
    /// The trusted checkout ``cwd`` is a worktree of.
    public var projectConfigRoot: String?
    /// Bash sandboxing; merged into ``settings`` as its `sandbox` key.
    public var sandbox: SandboxSettings?
    public var plugins: [SdkPluginConfig] = []
    /// Skills for the main session; also allows the Skill tool and, when
    /// ``settingSources`` is nil, loads user and project settings so skills are found.
    public var skills: SkillsOption?
    /// Flags passed to the CLI as `--key value` (`--key` for nil values).
    public var extraArgs: [String: String?] = [:]

    // MARK: Output

    /// Streams partial output as ``Message/streamEvent(_:)`` messages.
    public var includePartialMessages = false
    /// Emits hook lifecycle events as system messages.
    public var includeHookEvents = false
    /// Forwards subagents' text and thinking, not only their tool calls.
    public var forwardSubagentText = false
    /// Delivers prompts as written: no `@path` expansion, no slash commands.
    public var verbatimPrompts = false
    /// Emits a predicted next prompt after each turn.
    public var promptSuggestions = false
    /// Periodic progress summaries for running subagents.
    public var agentProgressSummaries = false
    /// Declares a per-task stop control, so an interrupt spares background tasks.
    public var perTaskStopAffordance = false
    /// Renders `request_user_dialog` dialogs; only kinds in ``supportedDialogKinds`` are sent.
    public var onUserDialog: OnUserDialog?
    public var supportedDialogKinds: [String] = []
    /// Called with each line the CLI writes to stderr.
    public var stderr: (@Sendable (String) -> Void)?
    /// Enables the CLI's debug logging.
    public var debug = false
    /// Writes the CLI's debug log to this file.
    public var debugFile: String?
    /// The longest stdout line accepted, in bytes; nil is unlimited.
    public var maxBufferSize: Int?

    public init() {}
}
