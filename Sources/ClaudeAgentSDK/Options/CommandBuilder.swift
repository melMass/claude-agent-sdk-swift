import Foundation

extension ClaudeAgentOptions {
    /// Rejects option combinations the CLI cannot honour, before anything starts.
    func validate() throws {
        if canUseTool != nil, permissionPromptToolName != nil {
            throw InvalidOptionsError(
                "canUseTool callback cannot be used with permissionPromptToolName. Please use one or the other.")
        }
        if let fallbackModel, let model, fallbackModel == model {
            throw InvalidOptionsError(
                "Fallback model cannot be the same as the main model. Please specify a different model for fallbackModel option.")
        }
        if case let .only(names)? = skills {
            for name in names { try Self.validateSkillName(name) }
        }
        if !supportedDialogKinds.isEmpty, onUserDialog == nil {
            throw InvalidOptionsError("supportedDialogKinds requires an onUserDialog callback.")
        }
    }

    /// A skill name must ride safely inside a `Skill(name)` rule, which the CLI
    /// splits on commas and spaces outside parentheses.
    static func validateSkillName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InvalidOptionsError("Skill names must be non-empty strings") }
        guard trimmed == name else {
            throw InvalidOptionsError("Invalid skill name '\(name)': surrounding whitespace never matches a skill.")
        }
        let delimiters = CharacterSet(charactersIn: ",()*").union(.whitespacesAndNewlines)
        if name.unicodeScalars.contains(where: delimiters.contains) {
            throw InvalidOptionsError("Invalid skill name '\(name)': names cannot contain commas, spaces, parentheses or wildcards.")
        }
    }

    /// ``allowedTools`` plus the rules ``skills`` needs, and the setting
    /// sources it implies.
    var effectiveToolsAndSources: (allowedTools: [String], settingSources: [SettingSource]?) {
        var allowed = allowedTools
        var sources = settingSources
        guard let skills else { return (allowed, sources) }
        switch skills {
        case .all:
            if !allowed.contains("Skill") { allowed.append("Skill") }
        case let .only(names):
            for name in names where !allowed.contains("Skill(\(name))") { allowed.append("Skill(\(name))") }
        }
        if sources == nil { sources = [.user, .project] }
        return (allowed, sources)
    }

    /// The `--settings` value: the settings as given, or, with ``sandbox``,
    /// one JSON object holding both.
    func settingsArgument() -> String? {
        guard let sandbox else {
            switch settings {
            case let .path(path)?: return path
            case let .inline(value)?: return value.jsonString
            case nil: return nil
            }
        }
        var object: [String: JSONValue] = [:]
        switch settings {
        case let .inline(value)?:
            object = value.object ?? [:]
        case let .path(path)?:
            let text = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("{"), text.hasSuffix("}"), let parsed = try? JSONValue.parse(text) {
                object = parsed.object ?? [:]
            } else if let data = FileManager.default.contents(atPath: text), let parsed = try? JSONValue.parse(data) {
                object = parsed.object ?? [:]
            }
        case nil:
            break
        }
        object["sandbox"] = sandbox.json
        return JSONValue.object(object).jsonString
    }

    /// The `--mcp-config` value, when there are servers.
    func mcpConfigArgument() -> String? {
        if !mcpServers.isEmpty {
            return JSONValue.object(["mcpServers": .object(mcpServers.mapValues(\.cliJSON))]).jsonString
        }
        return mcpConfig
    }

    /// The CLI's arguments after the executable, in the Python SDK's order,
    /// with `--input-format stream-json` last. With ``canUseTool`` set,
    /// permission prompts come back over the control protocol (`stdio`).
    func cliArguments() -> [String] {
        var arguments = ["--output-format", "stream-json", "--verbose"]

        switch systemPrompt {
        case nil: arguments += ["--system-prompt", ""]
        case let .text(text)?: arguments += ["--system-prompt", text]
        case let .file(path)?: arguments += ["--system-prompt-file", path]
        case let .custom(prompt, _)?: arguments += ["--system-prompt", prompt]
        case let .preset(append, _, _)?: if let append { arguments += ["--append-system-prompt", append] }
        }

        switch tools {
        case let .list(names)?: arguments += ["--tools", names.joined(separator: ",")]
        case .claudeCode?: arguments += ["--tools", "default"]
        case nil: break
        }

        let (allowed, sources) = effectiveToolsAndSources
        if !allowed.isEmpty { arguments += ["--allowedTools", allowed.joined(separator: ",")] }
        if let maxTurns, maxTurns != 0 { arguments += ["--max-turns", String(maxTurns)] }
        if let maxBudgetUsd { arguments += ["--max-budget-usd", Self.number(maxBudgetUsd)] }
        if !disallowedTools.isEmpty { arguments += ["--disallowedTools", disallowedTools.joined(separator: ",")] }
        if let taskBudget { arguments += ["--task-budget", String(taskBudget)] }
        if let model { arguments += ["--model", model] }
        if let fallbackModel { arguments += ["--fallback-model", fallbackModel] }
        if !betas.isEmpty { arguments += ["--betas", betas.joined(separator: ",")] }
        if canUseTool != nil {
            arguments += ["--permission-prompt-tool", "stdio"]
        } else if let permissionPromptToolName {
            arguments += ["--permission-prompt-tool", permissionPromptToolName]
        }
        if let permissionMode { arguments += ["--permission-mode", permissionMode.rawValue] }
        if continueConversation { arguments.append("--continue") }
        // The `=` form binds the value to its flag: the CLI declares these with
        // an optional value, so a dash-leading value would otherwise parse as a flag.
        if let resume { arguments.append("--resume=\(resume)") }
        if let sessionId { arguments.append("--session-id=\(sessionId)") }
        if let settings = settingsArgument() { arguments += ["--settings", settings] }
        for directory in addDirs { arguments += ["--add-dir", directory] }
        if let mcpConfig = mcpConfigArgument() { arguments += ["--mcp-config", mcpConfig] }
        if includePartialMessages { arguments.append("--include-partial-messages") }
        if includeHookEvents { arguments.append("--include-hook-events") }
        if strictMcpConfig { arguments.append("--strict-mcp-config") }
        if forkSession { arguments.append("--fork-session") }
        if let resumeSessionAt { arguments.append("--resume-session-at=\(resumeSessionAt)") }
        if let resumeDropsTurn { arguments.append("--resume-drops-turn=\(resumeDropsTurn)") }
        if let sources { arguments.append("--setting-sources=\(sources.map(\.rawValue).joined(separator: ","))") }
        for plugin in plugins {
            arguments += [plugin.skipMcpDiscovery ? "--plugin-dir-no-mcp" : "--plugin-dir", plugin.path]
        }
        for (flag, value) in extraArgs.sorted(by: { $0.key < $1.key }) {
            if let value {
                // A dash-leading value in two tokens would parse as a separate flag.
                if value.hasPrefix("-") { arguments.append("--\(flag)=\(value)") } else { arguments += ["--\(flag)", value] }
            } else {
                arguments.append("--\(flag)")
            }
        }

        if let thinking {
            switch thinking {
            case let .adaptive(display):
                arguments += ["--thinking", "adaptive"]
                if let display { arguments += ["--thinking-display", display.rawValue] }
            case let .enabled(budget, display):
                arguments += ["--max-thinking-tokens", String(budget)]
                if let display { arguments += ["--thinking-display", display.rawValue] }
            case .disabled:
                arguments += ["--thinking", "disabled"]
            }
        } else if let maxThinkingTokens {
            arguments += ["--max-thinking-tokens", String(maxThinkingTokens)]
        }
        if let effort { arguments += ["--effort", effort.rawValue] }
        if case let .jsonSchema(schema)? = outputFormat { arguments += ["--json-schema", schema.jsonString] }

        // Options the TypeScript SDK has and the Python SDK lacks.
        if let agent { arguments += ["--agent", agent] }
        if allowDangerouslySkipPermissions { arguments.append("--allow-dangerously-skip-permissions") }
        if let permissionPrompts { arguments += ["--permission-prompts", permissionPrompts] }
        if !persistSession { arguments.append("--no-session-persistence") }
        if let debugFile { arguments += ["--debug-file", debugFile] } else if debug { arguments.append("--debug") }
        if let projectConfigRoot { arguments += ["--project-config-root", projectConfigRoot] }
        if let managedSettings { arguments += ["--managed-settings", managedSettings.jsonString] }

        arguments += ["--input-format", "stream-json"]
        return arguments
    }

    /// The CLI's environment: `base` without `CLAUDECODE` (so the child does
    /// not think it runs inside Claude Code), then the SDK's markers, then ``env``.
    func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base.filter { $0.key != "CLAUDECODE" }
        if stripsClaudeCodeEnvironment {
            environment = environment.filter { key, _ in
                key == "CLAUDE_CONFIG_DIR" || !(key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC_"))
            }
        }
        environment["CLAUDE_CODE_ENTRYPOINT"] = "sdk-swift"
        environment.merge(env) { _, given in given }
        environment["CLAUDE_AGENT_SDK_VERSION"] = claudeAgentSDKVersion
        // Session-state frames tell the SDK when a run is over (see QueryEngine);
        // they are marked `sdk_host_only` and hidden from callers.
        if !environment.keys.contains(where: { $0.uppercased() == "CLAUDE_CODE_SDK_READS_SESSION_STATE" }) {
            environment["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1"
        }
        if enableFileCheckpointing { environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true" }
        if let cwd { environment["PWD"] = cwd }
        return environment
    }

    /// The fields of the `initialize` control request other than hooks.
    func initializeFields() -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if !agents.isEmpty { fields["agents"] = .object(agents.mapValues(\.json)) }
        switch systemPrompt {
        case let .preset(_, excludeDynamicSections, snapshot)?:
            fields.set("excludeDynamicSections", excludeDynamicSections.map(JSONValue.bool))
            fields.set("systemPromptSnapshot", snapshot.map(JSONValue.bool))
        case let .custom(_, snapshot)?:
            fields.set("systemPromptSnapshot", snapshot.map(JSONValue.bool))
        default:
            break
        }
        // `all` and no option are the same on the wire: no filter.
        if case let .only(names)? = skills { fields["skills"] = JSONValue(names) }
        if forwardSubagentText { fields["forwardSubagentText"] = true }
        fields.set("title", title.map(JSONValue.string))
        fields.set("planModeInstructions", planModeInstructions.map(JSONValue.string))
        if !toolAliases.isEmpty { fields["toolAliases"] = .object(toolAliases.mapValues(JSONValue.string)) }
        if promptSuggestions { fields["promptSuggestions"] = true }
        if agentProgressSummaries { fields["agentProgressSummaries"] = true }
        if perTaskStopAffordance { fields["perTaskStopAffordance"] = true }
        if !supportedDialogKinds.isEmpty { fields["supportedDialogKinds"] = JSONValue(supportedDialogKinds) }
        return fields
    }

    /// Whether the CLI may send requests that need an answer, so its input
    /// must stay open until the run is over.
    var hasBidirectionalNeeds: Bool {
        canUseTool != nil || !hooks.isEmpty || onElicitation != nil || onUserDialog != nil
            || mcpServers.values.contains { if case .sdk = $0 { true } else { false } }
    }

    /// A number as the CLI reads it: no trailing `.0` for whole values.
    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
