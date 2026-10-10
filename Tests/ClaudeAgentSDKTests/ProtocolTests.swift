import Foundation
import Testing
@testable import ClaudeAgentSDK

/// The SDK against the scripted `FakeClaude`: what it writes, in what order,
/// and how it answers the CLI's requests.
@Suite(.timeLimit(.minutes(1))) struct ProtocolTests {
    @Test func oneShotQueryStreamsMessagesAndClosesInput() async throws {
        let fake = try FakeCLI(Steps.initialize(["subtype": "initialize", "hooks": nil]) + [
            Steps.expectUser("Hi"),
            ["stdout": "[SandboxDebug] noise that is not JSON\n"],
            Steps.systemInit,
            Steps.sessionState("running"),
            Steps.assistant("Hello!"),
            ["send": ["type": "brand_new_frame", "x": 1]],
            Steps.result("Hello!"),
            // Nothing needs answers, so the input closes after the prompt.
            ["expectEOF": true],
        ]) { $0.model = "haiku" }
        let messages = try await collect(query(prompt: "Hi", options: fake.options))
        #expect(messages.map(\.type) == ["system", "assistant", "brand_new_frame", "result"])
        #expect(messages[1].assistantMessage?.text == "Hello!")
        #expect(messages.last?.resultMessage?.result == "Hello!")
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 2 }
        #expect(record["failure"] == .null)
        #expect(record["args"]?.array?.contains("haiku") == true)
        #expect(record["env"]?["CLAUDE_CODE_ENTRYPOINT"] == "sdk-swift")
    }

    @Test func canUseToolAnswersAllowAndDeny() async throws {
        let fake = try FakeCLI(Steps.initialize() + [
            Steps.expectUser("Run it"),
            Steps.sessionState("running"),
            ["send": ["type": "control_request", "request_id": "perm_1", "request": [
                "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"], "tool_use_id": "toolu_1",
                "title": "Claude wants to run ls", "permission_suggestions": [
                    ["type": "addRules", "destination": "localSettings", "behavior": "allow", "rules": [["toolName": "Bash", "ruleContent": "ls"]]],
                ],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "perm_1", "response": [
                "behavior": "allow", "updatedInput": ["command": "ls -la"],
                "updatedPermissions": [["type": "addRules", "destination": "localSettings", "behavior": "allow",
                                        "rules": [["toolName": "Bash", "ruleContent": "ls"]]]],
            ]]]],
            ["send": ["type": "control_request", "request_id": "perm_2", "request": [
                "subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": "/etc/x"], "tool_use_id": "toolu_2",
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "perm_2", "response": [
                "behavior": "deny", "message": "No writes", "interrupt": true,
            ]]]],
            Steps.result(),
            // The callback may still be needed until the CLI reports the run idle.
            ["sleep": 200],
            Steps.sessionState("idle"),
            ["expectEOF": true],
        ]) { options in
            options.canUseTool = { tool, input, context in
                if tool == "Bash" {
                    #expect(context.title == "Claude wants to run ls")
                    #expect(context.toolUseId == "toolu_1")
                    return .allow(updatedInput: ["command": "ls -la"], updatedPermissions: context.suggestions)
                }
                return .deny(message: "No writes", interrupt: true)
            }
        }
        let messages = try await collect(query(prompt: "Run it", options: fake.options))
        // The session-state frames are the SDK's own and are not shown.
        #expect(messages.map(\.type) == ["result"])
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 4 }
        #expect(record["failure"] == .null)
        #expect(record["args"]?.array?.contains("--permission-prompt-tool") == true)
    }

    @Test func hookCallbacksAreRegisteredAndAnswered() async throws {
        let fake = try FakeCLI(Steps.initialize(["subtype": "initialize", "hooks": [
            "PreToolUse": [["matcher": "Bash", "hookCallbackIds": ["hook_0", "hook_1"], "timeout": 30]],
            "UserPromptSubmit": [["matcher": nil, "hookCallbackIds": ["hook_2"]]],
        ]]) + [
            Steps.expectUser("Go"),
            Steps.sessionState("running"),
            ["send": ["type": "control_request", "request_id": "hook-1", "request": [
                "subtype": "hook_callback", "callback_id": "hook_0", "tool_use_id": "toolu_1",
                "input": ["hook_event_name": "PreToolUse", "session_id": "s-1", "transcript_path": "/t", "cwd": "/c",
                          "tool_name": "Bash", "tool_input": ["command": "rm -rf /"], "tool_use_id": "toolu_1"],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "hook-1", "response": [
                "hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "dangerous"],
            ]]]],
            ["send": ["type": "control_request", "request_id": "hook-2", "request": [
                "subtype": "hook_callback", "callback_id": "hook_2", "tool_use_id": nil,
                "input": ["hook_event_name": "UserPromptSubmit", "session_id": "s-1", "transcript_path": "/t", "cwd": "/c", "prompt": "Go"],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "hook-2", "response": [
                "continue": true, "hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": "It is Tuesday."],
            ]]]],
            ["send": ["type": "control_request", "request_id": "hook-3", "request": ["subtype": "hook_callback", "callback_id": "hook_99", "input": [:]]]],
            ["expect": ["type": "control_response", "response": ["subtype": "error", "request_id": "hook-3",
                                                                  "error": "No hook callback found for ID: hook_99"]]],
            Steps.result(),
            Steps.sessionState("idle"),
            ["expectEOF": true],
        ]) { options in
            options.hooks = [
                .preToolUse: [HookMatcher(matcher: "Bash", timeout: 30, hooks: [
                    { input, toolUseId, _ in
                        #expect(input.toolName == "Bash")
                        #expect(toolUseId == "toolu_1")
                        return HookOutput(hookSpecificOutput: .preToolUse(permissionDecision: .deny, permissionDecisionReason: "dangerous"))
                    },
                    { _, _, _ in .empty },
                ])],
                .userPromptSubmit: [HookMatcher { input, _, _ in
                    #expect(input.prompt == "Go")
                    return HookOutput(shouldContinue: true, hookSpecificOutput: .userPromptSubmit(additionalContext: "It is Tuesday."))
                }],
            ]
        }
        _ = try await collect(query(prompt: "Go", options: fake.options))
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 5 }
        #expect(record["failure"] == .null)
    }

    @Test func inProcessMCPServerAnswersOverTheControlChannel() async throws {
        let echo = tool("echo", "Echoes.", inputSchema: ["text": .string]) { args in .text(args["text"]?.string ?? "") }
        let fake = try FakeCLI([
            // The CLI may talk to the server before it answers initialize.
            ["expect": ["type": "control_request", "request_id": "$init", "request": ["subtype": "initialize"]]],
            ["send": ["type": "control_request", "request_id": "mcp_init_1", "request": [
                "subtype": "mcp_message", "server_name": "tools",
                "message": ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "mcp_init_1", "response": [
                "mcp_response": ["jsonrpc": "2.0", "id": 0, "result": ["protocolVersion": "2025-06-18", "serverInfo": ["name": "echo-server", "version": "1.0.0"]]],
            ]]]],
            ["send": ["type": "control_request", "request_id": "mcp_2", "request": [
                "subtype": "mcp_message", "server_name": "tools", "message": ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "mcp_2",
                                                                  "response": ["mcp_response": ["jsonrpc": "2.0", "result": [:]]]]]],
            ["send": ["type": "control_response", "response": ["subtype": "success", "request_id": "$init", "response": [:]]]],
            Steps.expectUser("Echo"),
            ["send": ["type": "control_request", "request_id": "mcp_3", "request": [
                "subtype": "mcp_message", "server_name": "tools",
                "message": ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi"]]],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "mcp_3", "response": [
                "mcp_response": ["jsonrpc": "2.0", "id": 2, "result": ["content": [["type": "text", "text": "hi"]], "isError": false]],
            ]]]],
            ["send": ["type": "control_request", "request_id": "mcp_4", "request": [
                "subtype": "mcp_message", "server_name": "nope", "message": ["jsonrpc": "2.0", "id": 3, "method": "tools/list"],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "mcp_4", "response": [
                "mcp_response": ["jsonrpc": "2.0", "id": 3, "error": ["code": -32601, "message": "Server 'nope' not found"]],
            ]]]],
            ["send": ["type": "control_request", "request_id": "x_1", "request": ["subtype": "something_new"]]],
            ["expect": ["type": "control_response", "response": ["subtype": "error", "request_id": "x_1",
                                                                  "error": "Unsupported control request subtype: something_new"]]],
            ["send": ["type": "control_request", "request_id": "el_1", "request": ["subtype": "elicitation", "mcp_server_name": "x", "message": "?"]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "el_1", "response": ["action": "decline"]]]],
            Steps.result(),
            Steps.sessionState("idle"),
            ["expectEOF": true],
        ]) { options in
            options.mcpServers = ["tools": createSdkMcpServer(name: "echo-server", tools: [echo])]
        }
        _ = try await collect(query(prompt: "Echo", options: fake.options))
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 8 }
        #expect(record["failure"] == .null)
        let config = try JSONValue.parse(try #require(record["args"]?.array?.compactMap(\.string).first { $0.hasPrefix("{\"mcpServers\"") }))
        #expect(config == ["mcpServers": ["tools": ["type": "sdk", "name": "echo-server"]]])
    }

    /// Elicitations go to `onElicitation` and dialogs to `onUserDialog`, each
    /// request answered in its own task: a slow dialog does not hold up the elicitation.
    @Test func elicitationsAndDialogsAndVerbatimPrompts() async throws {
        let fake = try FakeCLI(Steps.initialize(["subtype": "initialize", "supportedDialogKinds": ["refusal_fallback_prompt"]]) + [
            ["expect": ["type": "user", "client_composed": true, "message": ["content": "@/etc/passwd"]]],
            ["send": ["type": "control_request", "request_id": "dlg_1", "request": [
                "subtype": "request_user_dialog", "dialog_kind": "refusal_fallback_prompt", "payload": ["x": 1],
            ]]],
            ["send": ["type": "control_request", "request_id": "el_1", "request": [
                "subtype": "elicitation", "mcp_server_name": "github", "message": "Your name?", "mode": "form",
                "requested_schema": ["type": "object", "properties": ["name": ["type": "string"]]],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "el_1", "response": [
                "action": "accept", "content": ["name": "Ada"],
            ]]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "dlg_1", "response": [
                "behavior": "cancelled",
            ]]]],
            Steps.result(),
            Steps.sessionState("idle"),
            ["expectEOF": true],
        ]) { options in
            options.verbatimPrompts = true
            options.supportedDialogKinds = ["refusal_fallback_prompt"]
            options.onUserDialog = { request in
                #expect(request.payload == ["x": 1])
                try await Task.sleep(for: .milliseconds(300))
                return .cancelled
            }
            options.onElicitation = { request in
                #expect(request.serverName == "github")
                #expect(request.mode == "form")
                return .accept(content: ["name": "Ada"])
            }
        }
        _ = try await collect(query(prompt: "@/etc/passwd", options: fake.options))
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 4 }
        #expect(record["failure"] == .null)
    }

    /// A request the CLI withdraws gets no response: the next frame the SDK
    /// writes answers the request that followed it.
    @Test func cancelledRequestsGetNoResponse() async throws {
        let fake = try FakeCLI(Steps.initialize() + [
            Steps.expectUser("Wait"),
            ["send": ["type": "control_request", "request_id": "perm_slow", "request": [
                "subtype": "can_use_tool", "tool_name": "Slow", "input": [:], "tool_use_id": "toolu_1",
            ]]],
            ["sleep": 100],
            ["send": ["type": "control_cancel_request", "request_id": "perm_slow"]],
            ["send": ["type": "control_request", "request_id": "perm_fast", "request": [
                "subtype": "can_use_tool", "tool_name": "Fast", "input": [:], "tool_use_id": "toolu_2",
            ]]],
            ["expect": ["type": "control_response", "response": ["request_id": "perm_fast", "response": ["behavior": "allow"]]]],
            Steps.result(),
            Steps.sessionState("idle"),
            ["expectEOF": true],
        ]) { options in
            options.canUseTool = { tool, _, _ in
                if tool == "Slow" { try await Task.sleep(for: .seconds(20)) }
                return .allow
            }
        }
        _ = try await collect(query(prompt: "Wait", options: fake.options))
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 3 }
        #expect(record["failure"] == .null)
    }

    /// With callbacks the input stays open past a result while the CLI still
    /// works (a background agent's follow-up turn), and closes at `idle`.
    @Test func inputStaysOpenUntilTheRunIsIdle() async throws {
        let fake = try FakeCLI(Steps.initialize() + [
            Steps.expectUser("Start"),
            ["send": ["type": "system", "subtype": "task_started", "task_id": "t1", "task_type": "local_agent",
                      "description": "agent", "uuid": "u", "session_id": "s-1"]],
            Steps.result("first"),
            ["sleep": 300],
            ["send": ["type": "system", "subtype": "task_notification", "task_id": "t1", "status": "completed",
                      "output_file": "/o", "summary": "done", "uuid": "u2", "session_id": "s-1"]],
            ["send": ["type": "control_request", "request_id": "hook-late", "request": [
                "subtype": "hook_callback", "callback_id": "hook_0", "tool_use_id": nil, "input": ["hook_event_name": "Stop"],
            ]]],
            ["expect": ["type": "control_response", "response": ["subtype": "success", "request_id": "hook-late"]]],
            Steps.assistant("follow-up"),
            Steps.result("second"),
            ["expectEOF": true],
        ]) { options in
            options.hooks = [.stop: [HookMatcher { _, _, _ in .empty }]]
        }
        let messages = try await collect(query(prompt: "Start", options: fake.options))
        #expect(messages.compactMap(\.resultMessage).map(\.result) == ["first", "second"])
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 3 }
        #expect(record["failure"] == .null)
    }

    @Test func streamingInputWritesEachPromptThenCloses() async throws {
        let fake = try FakeCLI(Steps.initialize() + [
            Steps.expectUser("one"),
            Steps.result("1"),
            ["expect": ["type": "user", "session_id": "", "uuid": "u-two", "message": ["content": [["type": "text", "text": "two"]]]]],
            Steps.result("2"),
            ["expectEOF": true],
        ])
        let (prompts, continuation) = AsyncStream.makeStream(of: UserInputMessage.self)
        let session = query(prompt: prompts, options: fake.options)
        var results: [String] = []
        continuation.yield("one")
        for try await message in session {
            guard let result = message.resultMessage else { continue }
            results.append(result.result ?? "")
            if results.count == 1 {
                continuation.yield(UserInputMessage(content: [["type": "text", "text": "two"]], uuid: "u-two"))
                continuation.finish()
            }
        }
        #expect(results == ["1", "2"])
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 3 }
        #expect(record["failure"] == .null)
    }

    @Test func clientRunsTurnsAndControlRequests() async throws {
        let fake = try FakeCLI(Steps.initialize(response: [
            "commands": [["name": "compact", "description": "Compacts", "argumentHint": ""]],
            "models": [["value": "haiku", "resolvedModel": "claude-haiku-4-5", "displayName": "Haiku", "description": "Fast"]],
            "account": ["email": "me@example.com"], "output_style": "default", "available_output_styles": ["default"],
        ]) + [
            Steps.expectUser("first", sessionId: "default"),
            Steps.assistant("one"),
            Steps.result("one"),
            ["expect": ["type": "control_request", "request_id": "$m", "request": ["subtype": "set_model", "model": "sonnet"]]],
            ["send": ["type": "control_response", "response": ["subtype": "success", "request_id": "$m", "response": [:]]]],
            ["expect": ["type": "control_request", "request_id": "$p", "request": ["subtype": "set_permission_mode", "mode": "acceptEdits"]]],
            ["send": ["type": "control_response", "response": ["subtype": "success", "request_id": "$p", "response": [:]]]],
            ["expect": ["type": "control_request", "request_id": "$s", "request": ["subtype": "mcp_status"]]],
            ["send": ["type": "control_response", "response": ["subtype": "success", "request_id": "$s", "response": [
                "mcpServers": [["name": "calc", "status": "connected", "serverInfo": ["name": "calc", "version": "1.0.0"], "tools": [["name": "add"]]]],
            ]]]],
            Steps.expectUser("second", sessionId: "default"),
            Steps.assistant("two"),
            ["expect": ["type": "control_request", "request_id": "$i", "request": ["subtype": "interrupt"]]],
            ["send": ["type": "control_response", "response": ["subtype": "success", "request_id": "$i", "response": ["still_queued": []]]]],
            ["send": ["type": "result", "subtype": "error_during_execution", "duration_ms": 1, "duration_api_ms": 1, "is_error": false,
                      "num_turns": 1, "session_id": "s-1", "terminal_reason": "aborted_streaming"]],
            ["expect": ["type": "control_request", "request_id": "$bad", "request": ["subtype": "set_model"]]],
            ["send": ["type": "control_response", "response": ["subtype": "error", "request_id": "$bad", "error": "Unknown model"]]],
            ["expectEOF": true],
        ])
        let client = ClaudeSDKClient(options: fake.options)
        try await client.connect()
        let info = try await client.getServerInfo()
        #expect(info.models.first?.resolvedModel == "claude-haiku-4-5")
        #expect(info.commands.map(\.name) == ["compact"])
        #expect(info.account.email == "me@example.com")

        try await client.query("first")
        let first = try await collect(client.receiveResponse())
        #expect(first.compactMap(\.assistantMessage).map(\.text) == ["one"])
        #expect(first.last?.resultMessage?.result == "one")

        try await client.setModel("sonnet")
        try await client.setPermissionMode(.acceptEdits)
        let status = try await client.getMcpStatus()
        #expect(status.first?.status == "connected")
        #expect(status.first?.tools == ["add"])

        try await client.query("second")
        var second: [Message] = []
        for try await message in try client.receiveResponse() {
            second.append(message)
            if message.assistantMessage != nil {
                let receipt = try await client.interrupt()
                #expect(receipt == InterruptReceipt(stillQueued: [], cancelled: []))
            }
        }
        #expect(second.last?.resultMessage?.terminalReason == "aborted_streaming")

        await #expect(throws: ControlRequestError.self) { try await client.setModel("nonsense") }
        await client.disconnect()
        let record = try await fake.waitForRecord { $0["failure"] != nil || $0["stdin"]?.array?.count == 8 }
        #expect(record["failure"] == .null)
    }
}

@Suite(.timeLimit(.minutes(1))) struct FailureTests {
    /// The CLI exits 1 after an error result on purpose; that is a ResultError
    /// carrying the result, after the result itself was delivered.
    @Test func anErrorResultThenExitIsAResultError() async throws {
        let fake = try FakeCLI(Steps.initialize() + [
            Steps.expectUser("Hi"),
            ["send": ["type": "result", "subtype": "success", "is_error": true, "duration_ms": 1, "duration_api_ms": 1,
                      "num_turns": 1, "session_id": "s-1", "result": "API Error: 529 overloaded", "errors": [], "api_error_status": 529]],
            ["exit": 1],
        ])
        var results: [ResultMessage] = []
        do {
            for try await message in query(prompt: "Hi", options: fake.options) {
                if let result = message.resultMessage { results.append(result) }
            }
            Issue.record("no error thrown")
        } catch let error as ResultError {
            #expect(error.apiErrorStatus == 529)
            #expect(error.result == "API Error: 529 overloaded")
            #expect(error.exitCode == 1)
        }
        #expect(results.count == 1)
    }

    @Test func aCrashIsAProcessErrorWithStderr() async throws {
        let fake = try FakeCLI(Steps.initialize() + [
            Steps.expectUser("Hi"),
            ["stderr": "Error: something broke"],
            ["exit": 2],
        ])
        do {
            _ = try await collect(query(prompt: "Hi", options: fake.options))
            Issue.record("no error thrown")
        } catch let error as ProcessError {
            #expect(error.exitCode == 2)
            #expect(error.stderr?.contains("something broke") == true)
        }
    }

    @Test func aRefusedStartFailsInitialization() async throws {
        let fake = try FakeCLI([
            ["expect": ["type": "control_request", "request": ["subtype": "initialize"]]],
            ["send": ["type": "result", "subtype": "error_during_execution", "is_error": true, "duration_ms": 0, "duration_api_ms": 0,
                      "num_turns": 0, "session_id": "s", "errors": ["No conversation found with session ID: abc"]]],
            ["exit": 1],
        ])
        let client = ClaudeSDKClient(options: fake.options)
        do {
            try await client.connect()
            Issue.record("connected")
        } catch let error as ResultError {
            #expect(error.errors == ["No conversation found with session ID: abc"])
        }
    }

    @Test func aMissingCLIIsCLINotFound() async throws {
        var options = ClaudeAgentOptions()
        options.cliPath = "/nonexistent/claude"
        await #expect(throws: CLINotFoundError.self) { _ = try await collect(query(prompt: "Hi", options: options)) }
        let client = ClaudeSDKClient(options: options)
        await #expect(throws: CLINotFoundError.self) { try await client.connect() }
    }

    @Test func usingAClientBeforeConnectingIsAConnectionError() async {
        let client = ClaudeSDKClient()
        await #expect(throws: CLIConnectionError.self) { try await client.query("Hi") }
        #expect(throws: CLIConnectionError.self) { _ = try client.receiveMessages() }
    }

    @Test func invalidOptionsFailBeforeStarting() async {
        var options = ClaudeAgentOptions()
        options.cliPath = FakeCLI.executable
        options.canUseTool = { _, _, _ in .allow }
        options.permissionPromptToolName = "mcp__x__y"
        await #expect(throws: InvalidOptionsError.self) { _ = try await collect(query(prompt: "Hi", options: options)) }
    }
}
