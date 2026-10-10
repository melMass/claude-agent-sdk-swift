import Foundation
import Testing
@testable import ClaudeAgentSDK

@Suite struct JSONValueTests {
    @Test func keepsIntegersDoublesAndBooleansApart() throws {
        let value = try JSONValue.parse(#"{"i":1,"d":1.5,"b":true,"n":null,"s":"x","a":[1,"y"],"big":12345678901234}"#)
        #expect(value["i"] == .int(1))
        #expect(value["d"] == .double(1.5))
        #expect(value["b"] == .bool(true))
        #expect(value["n"] == .null)
        #expect(value["a"]?[1] == "y")
        #expect(value["big"]?.int == 12_345_678_901_234)
        #expect(try JSONValue.parse(value.jsonString) == value)
    }

    @Test func encodesCompactSortedAndUnescapedSlashes() {
        let value: JSONValue = ["b": 1, "a": ["url": "https://x/y", "text": "line\nbreak \u{2028}"]]
        #expect(value.jsonString == #"{"a":{"text":"line\nbreak \#u{2028}","url":"https://x/y"},"b":1}"#)
    }

    @Test func decodesIntoCodableTypes() throws {
        struct Point: Decodable, Equatable { let x: Int; let y: Double }
        let json: JSONValue = ["x": 1, "y": 2.5]
        let point: Point = try json.decode()
        #expect(point == Point(x: 1, y: 2.5))
    }
}

@Suite struct NDJSONTests {
    @Test func splitsOnlyOnNewlinesAcrossChunks() throws {
        var splitter = NDJSONSplitter()
        // A read may end inside a JSON string; U+2028 inside one is not a line break.
        #expect(try splitter.append(Data(#"{"type":"assistant","text":"a \#u{2028} b"#.utf8)).isEmpty)
        let frames = try splitter.append(Data("\"}\n{\"type\":\"result\"}\n{\"partial\":".utf8))
        #expect(frames.map { $0["type"] } == ["assistant", "result"])
        #expect(frames.first?["text"] == "a \u{2028} b")
        #expect(splitter.finish() == nil)
    }

    @Test func skipsNoiseAndParsesATrailingLine() throws {
        var splitter = NDJSONSplitter()
        let frames = try splitter.append(Data("[SandboxDebug] starting\n\n   {\"type\":\"x\"}\n{\"type\":\"tail\"}".utf8))
        #expect(frames == [["type": "x"]])
        #expect(splitter.finish() == ["type": "tail"])
    }

    @Test func aCorruptObjectLineIsAnError() {
        var splitter = NDJSONSplitter()
        #expect(throws: CLIJSONDecodeError.self) { try splitter.append(Data("{not json\n".utf8)) }
    }

    @Test func enforcesAMaximumLineSize() {
        var splitter = NDJSONSplitter(maxBufferSize: 16)
        #expect(throws: CLIJSONDecodeError.self) { try splitter.append(Data(#"{"long":"0123456789abcdef"#.utf8)) }
    }
}

@Suite struct MessageParsingTests {
    @Test func assistantWithEveryBlockType() throws {
        let message = Message(json: [
            "type": "assistant", "session_id": "s", "uuid": "u", "parent_tool_use_id": nil, "error": nil,
            "message": [
                "id": "msg_1", "model": "claude-haiku-4-5", "stop_reason": "tool_use", "usage": ["input_tokens": 3],
                "content": [
                    ["type": "thinking", "thinking": "hmm", "signature": "sig"],
                    ["type": "text", "text": "Hello"],
                    ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "/x"]],
                    ["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": ["query": "q"]],
                    ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": []],
                    ["type": "redacted_thinking", "data": "xyz"],
                ],
            ],
        ])
        let assistant = try #require(message.assistantMessage)
        #expect(assistant.model == "claude-haiku-4-5")
        #expect(assistant.messageId == "msg_1")
        #expect(assistant.stopReason == "tool_use")
        #expect(assistant.parentToolUseId == nil)
        #expect(assistant.text == "Hello")
        #expect(assistant.content[0] == .thinking(ThinkingBlock(thinking: "hmm", signature: "sig")))
        #expect(assistant.content[2] == .toolUse(ToolUseBlock(id: "toolu_1", name: "Read", input: ["file_path": "/x"])))
        #expect(assistant.content[3] == .serverToolUse(ServerToolUseBlock(id: "srv_1", name: "web_search", input: ["query": "q"])))
        #expect(assistant.content[4] == .serverToolResult(ServerToolResultBlock(type: "web_search_tool_result", toolUseId: "srv_1", content: [])))
        #expect(assistant.content[5] == .other(["type": "redacted_thinking", "data": "xyz"]))
        #expect(message.sessionId == "s")
    }

    @Test func userToolResultAndStringContent() throws {
        let toolResult = Message(json: [
            "type": "user", "uuid": "u1", "parent_tool_use_id": "toolu_parent",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1",
                                                      "content": [["type": "text", "text": "a"], ["type": "text", "text": "b"]], "is_error": false]]],
            "tool_use_result": ["filePath": "/p"],
        ])
        guard case let .user(user) = toolResult, case let .blocks(blocks) = user.content,
              case let .toolResult(block) = blocks.first
        else { Issue.record("not a tool result"); return }
        #expect(block.text == "a\nb")
        #expect(block.isError == false)
        #expect(user.parentToolUseId == "toolu_parent")
        #expect(user.toolUseResult == ["filePath": "/p"])

        let replay = Message(json: ["type": "user", "isReplay": true, "message": ["role": "user", "content": "Hi"]])
        guard case let .user(text) = replay else { Issue.record("not a user message"); return }
        #expect(text.content == .text("Hi"))
        #expect(text.isReplay)
    }

    @Test func systemInitAndTaskAndHookViews() throws {
        guard case let .system(system) = Message(json: try #require(Steps.systemInit["send"])) else {
            Issue.record("not a system message"); return
        }
        let initData = try #require(system.initData)
        #expect(initData.model == "claude-haiku-4-5")
        #expect(initData.tools == ["Read", "mcp__calc__add"])
        #expect(initData.mcpServers == [SystemInit.McpServer(name: "calc", status: "connected", source: "sdk")])
        #expect(initData.capabilities == ["interrupt_receipt_v1"])
        #expect(initData.permissionMode == .default)

        guard case let .system(updated) = Message(json: [
            "type": "system", "subtype": "task_updated", "task_id": "t1", "patch": ["status": "killed"],
        ]) else { return }
        #expect(updated.task?.isTerminal == true)
        #expect(updated.task?.status == "killed")

        guard case let .system(hook) = Message(json: [
            "type": "system", "subtype": "hook_response", "hook_event": "PreToolUse", "output": "ok", "exit_code": 0,
        ]) else { return }
        #expect(hook.hookEvent?.hookEventName == "PreToolUse")
        #expect(hook.hookEvent?.exitCode == 0)
    }

    @Test func resultWithUsageAndDeferredTool() throws {
        let result = try #require(Message(json: [
            "type": "result", "subtype": "success", "duration_ms": 3000, "duration_api_ms": 2000, "is_error": false,
            "num_turns": 1, "session_id": "s", "stop_reason": "end_turn", "total_cost_usd": 0.0106,
            "result": "Hello", "structured_output": ["a": 1], "terminal_reason": "completed",
            "modelUsage": ["claude-haiku-4-5": ["inputTokens": 3, "outputTokens": 24, "costUSD": 0.0106, "contextWindow": 200000]],
            "deferred_tool_use": ["id": "t", "name": "Bash", "input": ["command": "ls"]], "permission_denials": [],
        ]).resultMessage)
        #expect(result.durationMs == 3000)
        #expect(result.totalCostUsd == 0.0106)
        #expect(result.structuredOutput == ["a": 1])
        #expect(result.modelUsage["claude-haiku-4-5"]?.outputTokens == 24)
        #expect(result.deferredToolUse == DeferredToolUse(id: "t", name: "Bash", input: ["command": "ls"]))
        #expect(result.terminalReason == "completed")
    }

    /// A frame as CLI 2.1.296 sends it on a Max plan (recorded by MTBClaude's live tests).
    @Test func rateLimitEventReadsEveryWindowShortestFirst() throws {
        let frame = try JSONValue.parse(#"""
            {"type":"rate_limit_event","uuid":"u","session_id":"s","rate_limit_info":{"status":"allowed","resetsAt":1791654000,
             "rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,
             "unifiedWindows":{"seven_day":{"utilization":0.12,"resetsAt":1792087200},"five_hour":{"utilization":0.04,"resetsAt":1791654000}}}}
            """#)
        guard case let .rateLimitEvent(event) = Message(json: frame) else { Issue.record("not a rate limit event"); return }
        #expect(event.info.status == "allowed")
        #expect(event.info.windows.map(\.name) == ["five_hour", "seven_day"])
        #expect(event.info.window("five_hour")?.utilization == 0.04)
        #expect(event.info.window("seven_day")?.resetsAt == Date(timeIntervalSince1970: 1_792_087_200))
        #expect(event.info.isUsingOverage == false)
    }

    @Test func anOlderRateLimitFrameGivesItsOneWindow() {
        let info = RateLimitInfo(json: ["status": "allowed_warning", "rateLimitType": "seven_day_opus", "utilization": 0.85])
        #expect(info.windows == [RateLimitInfo.Window(name: "seven_day_opus", utilization: 0.85, resetsAt: nil)])
    }

    @Test func unknownAndMalformedFramesAreKept() {
        let unknown: JSONValue = ["type": "brand_new_frame", "x": 1]
        guard case let .unknown(raw) = Message(json: unknown) else { Issue.record("not unknown"); return }
        #expect(raw == unknown)
        let malformed: JSONValue = ["type": "assistant", "message": "not an object"]
        guard case .unknown = Message(json: malformed) else { Issue.record("malformed frame not kept as unknown"); return }
    }

    @Test func streamEventTextDelta() {
        guard case let .streamEvent(event) = Message(json: [
            "type": "stream_event", "uuid": "u", "session_id": "s",
            "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hel"]],
        ]) else { Issue.record("not a stream event"); return }
        #expect(event.textDelta == "Hel")
    }

    @Test func errorResultTextPrefersErrorsThenResult() {
        let api = ResultError(result: ["subtype": "success", "is_error": true, "errors": [], "result": "API Error: 529 overloaded",
                                       "api_error_status": 529], exitCode: 1)
        #expect(api.message == "Claude Code returned an error result: API Error: 529 overloaded")
        #expect(api.apiErrorStatus == 529)
        let turns = ResultError(result: ["subtype": "error_max_turns", "errors": [" Reached max turns ", ""]], exitCode: 1)
        #expect(turns.errors == ["Reached max turns"])
        #expect(turns.message.hasSuffix("Reached max turns"))
        #expect(ResultError(result: ["subtype": "error_during_execution"], exitCode: 1).message.hasSuffix("error_during_execution"))
    }
}

@Suite struct CallbackWireTests {
    @Test func permissionResultsOnTheWire() {
        #expect(PermissionResult.allow.json(originalInput: ["a": 1]) == ["behavior": "allow", "updatedInput": ["a": 1]])
        let rule = PermissionUpdate.addRules([PermissionRuleValue(toolName: "Bash", ruleContent: "ls")], behavior: .allow,
                                             destination: .localSettings)
        #expect(PermissionResult.allow(updatedInput: ["a": 2], updatedPermissions: [rule]).json(originalInput: ["a": 1]) == [
            "behavior": "allow", "updatedInput": ["a": 2],
            "updatedPermissions": [["type": "addRules", "destination": "localSettings", "behavior": "allow",
                                    "rules": [["toolName": "Bash", "ruleContent": "ls"]]]],
        ])
        #expect(PermissionResult.deny(message: "no").json(originalInput: [:]) == ["behavior": "deny", "message": "no"])
        #expect(PermissionResult.deny(message: "no", interrupt: true).json(originalInput: [:])["interrupt"] == true)
        #expect(PermissionUpdate(json: rule.json) == rule)
        #expect(PermissionUpdate.setMode(.acceptEdits).json == ["type": "setMode", "mode": "acceptEdits", "destination": "session"])
    }

    @Test func hookOutputsOnTheWire() {
        #expect(HookOutput.empty.json == [:])
        #expect(HookOutput(shouldContinue: false, stopReason: "stop").json == ["continue": false, "stopReason": "stop"])
        #expect(HookOutput.async(timeout: 500).json == ["async": true, "asyncTimeout": 500])
        let deny = HookOutput(hookSpecificOutput: .preToolUse(permissionDecision: .deny, permissionDecisionReason: "nope"))
        #expect(deny.json == ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                      "permissionDecisionReason": "nope"]])
        let context = HookOutput(hookSpecificOutput: .userPromptSubmit(additionalContext: "ctx"))
        #expect(context.json["hookSpecificOutput"] == ["hookEventName": "UserPromptSubmit", "additionalContext": "ctx"])
    }

    @Test func hookInputAccessors() {
        let input = HookInput(raw: [
            "hook_event_name": "PreToolUse", "session_id": "s", "transcript_path": "/t", "cwd": "/c",
            "permission_mode": "default", "tool_name": "Write", "tool_input": ["file_path": "/x"], "tool_use_id": "toolu_1",
            "agent_id": "a1", "effort": ["level": "high"],
        ])
        #expect(input.hookEventName == .preToolUse)
        #expect(input.toolName == "Write")
        #expect(input.toolInput == ["file_path": "/x"])
        #expect(input.agentId == "a1")
        #expect(input.effortLevel == "high")
    }
}
