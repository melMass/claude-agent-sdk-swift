import Foundation
import Testing
@testable import ClaudeAgentSDK

/// Runs the SDK against the `FakeClaude` executable, which plays a scripted
/// conversation and records what the SDK wrote (see Sources/FakeClaude/main.swift).
struct FakeCLI {
    let scenario: URL
    let record: URL
    var options: ClaudeAgentOptions

    /// The `FakeClaude` executable the test target depends on, next to the test bundle.
    static let executable: String = {
        if let path = ProcessInfo.processInfo.environment["FAKE_CLAUDE_PATH"] { return path }
        var directories = [Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()]
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            directories.append(bundle.bundleURL.deletingLastPathComponent())
        }
        directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        for directory in directories {
            let candidate = directory.appendingPathComponent("FakeClaude").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "FakeClaude-not-found"
    }()

    init(_ steps: [JSONValue], configure: (inout ClaudeAgentOptions) -> Void = { _ in }) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scenario = folder.appendingPathComponent("scenario.json")
        record = folder.appendingPathComponent("record.json")
        try JSONValue.array(steps).data().write(to: scenario)
        var options = ClaudeAgentOptions()
        options.cliPath = Self.executable
        options.env = ["FAKE_CLAUDE_SCENARIO": scenario.path, "FAKE_CLAUDE_RECORD": record.path]
        configure(&options)
        self.options = options
    }

    /// What the fake CLI recorded: `args`, `env`, `cwd`, `stdin` (the frames the SDK wrote), `failure`.
    func recorded() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: record))
    }

    /// Waits for the fake CLI to write its final record (it exits after its input closes).
    func waitForRecord(timeout: Duration = .seconds(10), until done: (JSONValue) -> Bool) async throws -> JSONValue {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let value = try? recorded(), done(value) { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try recorded()
    }
}

/// A class of the test bundle, to find the bundle (and the executables built beside it).
private final class BundleMarker {}

/// Steps shared by most scenarios.
enum Steps {
    /// Answers `initialize` (whose request must match `request`) with `response`.
    static func initialize(_ request: JSONValue = ["subtype": "initialize"], response: JSONValue = [:]) -> [JSONValue] {
        [
            ["expect": ["type": "control_request", "request_id": "$init", "request": request]],
            ["send": ["type": "control_response", "response": ["subtype": "success", "request_id": "$init", "response": response]]],
        ]
    }

    static func expectUser(_ content: JSONValue, sessionId: String = "") -> JSONValue {
        ["expect": ["type": "user", "session_id": .string(sessionId), "message": ["role": "user", "content": content]]]
    }

    static let systemInit: JSONValue = ["send": [
        "type": "system", "subtype": "init", "session_id": "s-1", "uuid": "u-0", "model": "claude-haiku-4-5",
        "cwd": "/tmp", "tools": ["Read", "mcp__calc__add"], "permissionMode": "default", "apiKeySource": "none",
        "mcp_servers": [["name": "calc", "status": "connected", "source": "sdk"]], "slash_commands": [], "skills": [],
        "plugins": [], "output_style": "default", "claude_code_version": "2.1.296", "capabilities": ["interrupt_receipt_v1"],
    ]]

    static func assistant(_ text: String, id: String = "msg_1") -> JSONValue {
        ["send": [
            "type": "assistant", "session_id": "s-1", "uuid": "u-a", "parent_tool_use_id": nil,
            "message": ["id": .string(id), "role": "assistant", "model": "claude-haiku-4-5",
                        "content": [["type": "text", "text": .string(text)]], "stop_reason": "end_turn"],
        ]]
    }

    static func result(_ text: String = "done", isError: Bool = false, subtype: String = "success") -> JSONValue {
        ["send": [
            "type": "result", "subtype": .string(subtype), "duration_ms": 10, "duration_api_ms": 8, "is_error": .bool(isError),
            "num_turns": 1, "session_id": "s-1", "result": .string(text), "total_cost_usd": 0.001,
            "usage": ["input_tokens": 3, "output_tokens": 4], "uuid": "u-r",
        ]]
    }

    static func sessionState(_ state: String) -> JSONValue {
        ["send": ["type": "system", "subtype": "session_state_changed", "state": .string(state), "sdk_host_only": true,
                  "session_id": "s-1", "uuid": "u-s"]]
    }
}

/// Reads a query's messages until it ends.
func collect(_ query: Query) async throws -> [Message] {
    var messages: [Message] = []
    for try await message in query { messages.append(message) }
    return messages
}

/// Reads a stream's messages until it ends.
func collect(_ stream: MessageStream) async throws -> [Message] {
    var messages: [Message] = []
    for try await message in stream { messages.append(message) }
    return messages
}

extension Message {
    var resultMessage: ResultMessage? { if case let .result(result) = self { result } else { nil } }
    var assistantMessage: AssistantMessage? { if case let .assistant(message) = self { message } else { nil } }
}
