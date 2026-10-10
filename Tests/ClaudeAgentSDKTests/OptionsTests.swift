import Foundation
import Testing
@testable import ClaudeAgentSDK

private func value(after flag: String, in arguments: [String]) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
}

@Suite struct ArgumentTests {
    @Test func defaultsMatchThePythonSDK() {
        let arguments = ClaudeAgentOptions().cliArguments()
        #expect(arguments.prefix(3) == ["--output-format", "stream-json", "--verbose"])
        #expect(arguments.suffix(2) == ["--input-format", "stream-json"])
        // No system prompt given means an empty one, not Claude Code's.
        #expect(value(after: "--system-prompt", in: arguments) == "")
        #expect(!arguments.contains("--tools"))
        #expect(!arguments.contains { $0.hasPrefix("--setting-sources") })
        #expect(!arguments.contains("--permission-prompt-tool"))
        #expect(!arguments.contains("--print") && !arguments.contains("-p"))
    }

    @Test func systemPromptForms() {
        func arguments(_ prompt: SystemPrompt) -> [String] {
            var options = ClaudeAgentOptions()
            options.systemPrompt = prompt
            return options.cliArguments()
        }
        #expect(value(after: "--system-prompt", in: arguments("Be terse.")) == "Be terse.")
        #expect(value(after: "--system-prompt", in: arguments(.custom(prompt: "Custom"))) == "Custom")
        #expect(value(after: "--system-prompt-file", in: arguments(.file(path: "/p.md"))) == "/p.md")
        let preset = arguments(.claudeCode)
        #expect(!preset.contains("--system-prompt") && !preset.contains("--append-system-prompt"))
        #expect(value(after: "--append-system-prompt", in: arguments(.preset(append: "Extra."))) == "Extra.")
    }

    @Test func sdkServersGoInTheMCPConfigAndDashValuesUseTheEqualsForm() throws {
        var options = ClaudeAgentOptions()
        options.mcpServers = [
            "music": createSdkMcpServer(name: "music-server"),
            "files": .stdio(command: "npx", args: ["server"]),
            "remote": .http(url: "https://example.com/mcp", headers: ["X": "1"]),
        ]
        options.resume = "-abc"
        options.sessionId = "-def"
        options.canUseTool = { _, _, _ in .allow }
        let arguments = options.cliArguments()
        let config = try JSONValue.parse(try #require(value(after: "--mcp-config", in: arguments)))
        #expect(config["mcpServers"]?["music"] == ["type": "sdk", "name": "music-server"])
        #expect(config["mcpServers"]?["files"] == ["type": "stdio", "command": "npx", "args": ["server"]])
        #expect(config["mcpServers"]?["remote"] == ["type": "http", "url": "https://example.com/mcp", "headers": ["X": "1"]])
        #expect(arguments.contains("--resume=-abc"))
        #expect(arguments.contains("--session-id=-def"))
        #expect(value(after: "--permission-prompt-tool", in: arguments) == "stdio")
    }

    @Test func toolsListPresetAndEmpty() {
        var options = ClaudeAgentOptions()
        options.tools = .list([])
        #expect(value(after: "--tools", in: options.cliArguments()) == "")
        options.tools = .list(["Read", "Grep"])
        #expect(value(after: "--tools", in: options.cliArguments()) == "Read,Grep")
        options.tools = .claudeCode
        #expect(value(after: "--tools", in: options.cliArguments()) == "default")
    }

    @Test func skillsAllowTheSkillToolAndLoadSettings() throws {
        var options = ClaudeAgentOptions()
        options.allowedTools = ["Read"]
        options.skills = .all
        var arguments = options.cliArguments()
        #expect(value(after: "--allowedTools", in: arguments) == "Read,Skill")
        #expect(arguments.contains("--setting-sources=user,project"))

        options.skills = .only(["pdf", "docs:export"])
        options.settingSources = []
        arguments = options.cliArguments()
        #expect(value(after: "--allowedTools", in: arguments) == "Read,Skill(pdf),Skill(docs:export)")
        #expect(arguments.contains("--setting-sources="))
        #expect(options.initializeFields()["skills"] == ["pdf", "docs:export"])

        options.skills = .only(["bad name"])
        #expect(throws: InvalidOptionsError.self) { try options.validate() }
    }

    @Test func modelThinkingEffortAndOutputFormat() {
        var options = ClaudeAgentOptions()
        options.model = "haiku"
        options.fallbackModel = "sonnet"
        options.thinking = .enabled(budgetTokens: 2048, display: .summarized)
        options.effort = .low
        options.maxTurns = 3
        options.maxBudgetUsd = 0.5
        options.outputFormat = .jsonSchema(["type": "object", "properties": ["a": ["type": "string"]]])
        let arguments = options.cliArguments()
        #expect(value(after: "--model", in: arguments) == "haiku")
        #expect(value(after: "--fallback-model", in: arguments) == "sonnet")
        #expect(value(after: "--max-thinking-tokens", in: arguments) == "2048")
        #expect(value(after: "--thinking-display", in: arguments) == "summarized")
        #expect(value(after: "--effort", in: arguments) == "low")
        #expect(value(after: "--max-turns", in: arguments) == "3")
        #expect(value(after: "--max-budget-usd", in: arguments) == "0.5")
        #expect(value(after: "--json-schema", in: arguments) == #"{"properties":{"a":{"type":"string"}},"type":"object"}"#)

        options.thinking = .adaptive()
        #expect(value(after: "--thinking", in: options.cliArguments()) == "adaptive")
        options.thinking = .disabled
        #expect(value(after: "--thinking", in: options.cliArguments()) == "disabled")
    }

    @Test func extraArgsBindDashValuesWithEquals() {
        var options = ClaudeAgentOptions()
        options.extraArgs = ["replay-user-messages": nil, "foo": "-bar", "name": "value"]
        let arguments = options.cliArguments()
        #expect(arguments.contains("--replay-user-messages"))
        #expect(arguments.contains("--foo=-bar"))
        #expect(value(after: "--name", in: arguments) == "value")
    }

    @Test func sandboxMergesIntoInlineSettings() throws {
        var options = ClaudeAgentOptions()
        options.settings = .inline(["model": "haiku"])
        options.sandbox = SandboxSettings(enabled: true, excludedCommands: ["git"], network: SandboxNetworkConfig(allowLocalBinding: true))
        let settings = try JSONValue.parse(try #require(value(after: "--settings", in: options.cliArguments())))
        #expect(settings["model"] == "haiku")
        #expect(settings["sandbox"] == ["enabled": true, "excludedCommands": ["git"], "network": ["allowLocalBinding": true]])

        options.sandbox = nil
        options.settings = .path("/etc/settings.json")
        #expect(value(after: "--settings", in: options.cliArguments()) == "/etc/settings.json")
    }

    @Test func typeScriptOnlyFlags() {
        var options = ClaudeAgentOptions()
        options.agent = "reviewer"
        options.persistSession = false
        options.allowDangerouslySkipPermissions = true
        options.permissionMode = .bypassPermissions
        options.addDirs = ["/a", "/b"]
        options.plugins = [.local("/p"), SdkPluginConfig(path: "/q", skipMcpDiscovery: true)]
        options.continueConversation = true
        options.forkSession = true
        options.resumeSessionAt = "u-1"
        let arguments = options.cliArguments()
        #expect(value(after: "--agent", in: arguments) == "reviewer")
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--allow-dangerously-skip-permissions"))
        #expect(value(after: "--permission-mode", in: arguments) == "bypassPermissions")
        #expect(arguments.filter { $0 == "--add-dir" }.count == 2)
        #expect(value(after: "--plugin-dir", in: arguments) == "/p")
        #expect(value(after: "--plugin-dir-no-mcp", in: arguments) == "/q")
        #expect(arguments.contains("--continue") && arguments.contains("--fork-session"))
        #expect(arguments.contains("--resume-session-at=u-1"))
        #expect(arguments.last == "stream-json")
    }

    @Test func canUseToolAndAPromptToolAreExclusive() {
        var options = ClaudeAgentOptions()
        options.canUseTool = { _, _, _ in .allow }
        options.permissionPromptToolName = "mcp__perm__ask"
        #expect(throws: InvalidOptionsError.self) { try options.validate() }
    }
}

@Suite struct EnvironmentTests {
    @Test func childEnvironmentMarksTheSDKAndDropsCLAUDECODE() {
        var options = ClaudeAgentOptions()
        options.env = ["CUSTOM": "1", "CLAUDE_CODE_ENTRYPOINT": "my-app"]
        options.cwd = "/work"
        options.enableFileCheckpointing = true
        let environment = options.processEnvironment(base: ["CLAUDECODE": "1", "HOME": "/h", "ANTHROPIC_API_KEY": "k"])
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["HOME"] == "/h")
        // Inherited by default, as in the Python SDK.
        #expect(environment["ANTHROPIC_API_KEY"] == "k")
        #expect(environment["CUSTOM"] == "1")
        #expect(environment["CLAUDE_CODE_ENTRYPOINT"] == "my-app")
        #expect(environment["CLAUDE_AGENT_SDK_VERSION"] == claudeAgentSDKVersion)
        #expect(environment["CLAUDE_CODE_SDK_READS_SESSION_STATE"] == "1")
        #expect(environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "true")
        #expect(environment["PWD"] == "/work")
    }

    /// A process started from inside Claude Code inherits its variables, which
    /// reach past the flags (plugins, an API key instead of the login).
    @Test func strippingKeepsOnlyTheConfigDirectory() {
        var options = ClaudeAgentOptions()
        options.stripsClaudeCodeEnvironment = true
        let environment = options.processEnvironment(base: [
            "ANTHROPIC_API_KEY": "k", "CLAUDECODE": "1", "CLAUDE_CODE_PLUGIN_DIRS": "~/plugins", "CLAUDE_CODE_SESSION_ID": "s",
            "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h",
        ])
        #expect(environment.keys.sorted() == [
            "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SDK_READS_SESSION_STATE", "CLAUDE_CONFIG_DIR", "HOME",
        ])
    }

    @Test func aCallersSessionStateChoiceWins() {
        var options = ClaudeAgentOptions()
        options.env = ["claude_code_sdk_reads_session_state": "0"]
        let environment = options.processEnvironment(base: [:])
        #expect(environment["CLAUDE_CODE_SDK_READS_SESSION_STATE"] == nil)
        #expect(environment["claude_code_sdk_reads_session_state"] == "0")
    }
}

@Suite struct InitializeFieldTests {
    @Test func agentsPromptFlagsAndTypeScriptFields() {
        var options = ClaudeAgentOptions()
        options.agents = ["reviewer": AgentDefinition(description: "Reviews", prompt: "Review.", tools: ["Read"], model: "sonnet")]
        options.systemPrompt = .preset(append: "x", excludeDynamicSections: true, snapshot: false)
        options.forwardSubagentText = true
        options.title = "My session"
        options.toolAliases = ["Bash": "mcp__ws__bash"]
        let fields = options.initializeFields()
        #expect(fields["agents"] == ["reviewer": ["description": "Reviews", "prompt": "Review.", "tools": ["Read"], "model": "sonnet"]])
        #expect(fields["excludeDynamicSections"] == true)
        #expect(fields["systemPromptSnapshot"] == false)
        #expect(fields["forwardSubagentText"] == true)
        #expect(fields["title"] == "My session")
        #expect(fields["toolAliases"] == ["Bash": "mcp__ws__bash"])
        #expect(fields["skills"] == nil)
    }
}

@Suite struct CLILocateTests {
    @Test func findsOnPathAndSkipsMiseShims() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("locate-\(UUID().uuidString)")
        let shims = folder.appendingPathComponent("mise/shims")
        let bin = folder.appendingPathComponent("bin")
        for directory in [shims, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("claude")
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = ClaudeCLI.locate(environment: ["PATH": "\(shims.path):\(bin.path)", "HOME": folder.path])
        #expect(found == bin.appendingPathComponent("claude").path)
    }
}
