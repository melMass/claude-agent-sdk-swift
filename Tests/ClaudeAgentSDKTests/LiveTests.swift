import Foundation
import Testing
@testable import ClaudeAgentSDK

/// Against the installed `claude` and its login: `CLAUDE_LIVE=1 swift test --filter LiveTests`.
/// Each test is a short exchange on Haiku and deletes the sessions it made.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_LIVE"] != nil), .serialized, .timeLimit(.minutes(3)))
struct LiveTests {
    /// Isolated from the user's setup: no settings files, no MCP servers but
    /// the ones given, no built-in tools, and none of a parent Claude Code's variables.
    static var options: ClaudeAgentOptions {
        var options = ClaudeAgentOptions()
        options.model = "haiku"
        options.systemPrompt = "You are a terse assistant. Use tools when asked."
        options.cwd = FileManager.default.temporaryDirectory.path
        options.settingSources = []
        options.strictMcpConfig = true
        options.tools = .list([])
        options.stripsClaudeCodeEnvironment = true
        return options
    }

    /// Deletes the sessions a test made when it ends.
    final class Sessions: @unchecked Sendable {
        private let ids = Locked<Set<String>>([])
        func add(_ messages: [Message]) { ids.withLock { $0.formUnion(messages.compactMap(\.sessionId).filter(SessionFiles.isUUID)) } }
        deinit { for id in ids.withLock({ $0 }) { try? deleteSession(id) } }
    }
    let sessions = Sessions()

    @Test func queryStreamsAnAnswer() async throws {
        var options = Self.options
        options.includePartialMessages = true
        let messages = try await collect(query(prompt: "Reply with exactly: blue whale", options: options))
        sessions.add(messages)
        let deltas = messages.compactMap { if case let .streamEvent(event) = $0 { event.textDelta } else { nil } }.joined()
        let text = messages.compactMap(\.assistantMessage).map(\.text).joined()
        let result = try #require(messages.last?.resultMessage)
        let initData = messages.compactMap { if case let .system(system) = $0 { system.initData } else { nil } }.first
        #expect(text.lowercased().contains("blue whale"))
        #expect(deltas == text)
        #expect(result.subtype == "success" && !result.isError)
        #expect(initData?.model.contains("haiku") == true)
        #expect(initData?.tools == [])
    }

    @Test func clientRemembersAcrossTurns() async throws {
        let client = ClaudeSDKClient(options: Self.options)
        try await client.connect()
        let info = try await client.getServerInfo()
        #expect(info.models.contains { $0.value == "haiku" })
        #expect(try await client.getMcpStatus().isEmpty)

        try await client.query("Remember the number 7341. Reply OK.")
        let first = try await collect(client.receiveResponse())
        try await client.query("Which number did I ask you to remember? Digits only.")
        let second = try await collect(client.receiveResponse())
        sessions.add(first + second)
        #expect(second.compactMap(\.assistantMessage).map(\.text).joined().contains("7341"))
        #expect(first.last?.resultMessage?.sessionId == second.last?.resultMessage?.sessionId)
        await client.disconnect()
    }

    /// An in-process tool that is not pre-approved: the PreToolUse hook sees the
    /// call, the permission callback approves it, the tool runs here.
    @Test func inProcessToolWithPermissionCallbackAndHook() async throws {
        let ran = Locked<[String?]>([])
        let asked = Locked<[String]>([])
        let hooked = Locked<[String]>([])
        let secret = tool("secret_word", "Returns today's secret word.", inputSchema: [:]) { _, context in
            ran.withLock { $0.append(context.toolUseId) }
            return .text("zeppelin")
        }
        var options = Self.options
        options.permissionMode = .default
        options.mcpServers = ["vault": createSdkMcpServer(name: "vault", tools: [secret])]
        options.canUseTool = { name, _, context in
            asked.withLock { $0.append(name) }
            #expect(context.toolUseId != nil)
            return .allow
        }
        options.hooks = [.preToolUse: [HookMatcher(matcher: "mcp__vault__secret_word") { input, _, _ in
            hooked.withLock { $0.append(input.toolName ?? "") }
            return .empty
        }]]
        let messages = try await collect(query(prompt: "Call the secret_word tool and tell me the word.", options: options))
        sessions.add(messages)
        let answer = messages.compactMap(\.assistantMessage).map(\.text).joined()
        #expect(hooked.withLock { $0 } == ["mcp__vault__secret_word"])
        #expect(asked.withLock { $0 } == ["mcp__vault__secret_word"])
        #expect(ran.withLock { $0.count } == 1)
        #expect(ran.withLock { $0.first ?? nil }?.hasPrefix("toolu_") == true)
        #expect(answer.lowercased().contains("zeppelin"))
    }

    @Test func userPromptSubmitHookAddsContext() async throws {
        var options = Self.options
        options.hooks = [.userPromptSubmit: [HookMatcher { input, _, _ in
            #expect(input.prompt?.contains("password") == true)
            return HookOutput(hookSpecificOutput: .userPromptSubmit(additionalContext: "The secret password is swordfish."))
        }]]
        let messages = try await collect(query(prompt: "What is the secret password? One word.", options: options))
        sessions.add(messages)
        #expect(messages.compactMap(\.assistantMessage).map(\.text).joined().lowercased().contains("swordfish"))
    }
}
