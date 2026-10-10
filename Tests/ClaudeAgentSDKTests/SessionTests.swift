import Foundation
import Testing
@testable import ClaudeAgentSDK

/// A Claude Code config directory in a temporary folder, with transcripts written by hand.
struct SessionFixture {
    let config: URL
    let projectPath = "/Users/someone/app"

    init() throws {
        config = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    var project: URL { config.appendingPathComponent("projects").appendingPathComponent(SessionFiles.sanitize(projectPath)) }

    /// Writes a transcript; each line starts with its `"type"`, as the CLI writes them.
    func write(_ id: String, _ entries: [JSONValue], modified: Date? = nil) throws {
        let file = project.appendingPathComponent("\(id).jsonl")
        let lines = entries.map { entry in
            var rest = entry
            rest["type"] = nil
            let body = rest.jsonString.dropFirst()
            return "{\"type\":\(entry["type"]?.jsonString ?? "null")" + (body == "}" ? "}" : "," + body)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
    }

    func remove() { try? FileManager.default.removeItem(at: config) }
}

private func entry(_ type: String, _ uuid: String, parent: String?, _ content: JSONValue, session: String, extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string(type), "uuid": .string(uuid), "parentUuid": JSONValue(parent), "sessionId": .string(session),
        "timestamp": "2026-10-01T10:00:00.000Z", "cwd": "/Users/someone/app", "gitBranch": "main",
        "message": ["role": .string(type), "content": content],
    ]
    for (key, value) in extra { object[key] = value }
    return .object(object)
}

@Suite struct SessionTests {
    static let a = "11111111-1111-4111-8111-111111111111"
    static let b = "22222222-2222-4222-8222-222222222222"

    @Test func projectFolderIsThePathWithDashes() {
        #expect(SessionFiles.sanitize("/Users/me/.dot") == "-Users-me--dot")
        #expect(SessionFiles.sanitize("/Users/me/Library/Application Support/MTBAgentUI/Claude")
            == "-Users-me-Library-Application-Support-MTBAgentUI-Claude")
        let long = "/" + String(repeating: "x", count: 250)
        let name = SessionFiles.sanitize(long)
        #expect(name.hasPrefix("-" + String(repeating: "x", count: 199) + "-"))
        #expect(name.count > 200)
    }

    @Test func listsSessionsNewestFirstWithTitlesAndTags() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.write(Self.a, [
            entry("user", "u1", parent: nil, "<command-name>/clear</command-name>", session: Self.a),
            entry("user", "u2", parent: "u1", "Plan the trip to Lisbon", session: Self.a),
            entry("assistant", "u3", parent: "u2", [["type": "text", "text": "Sure."]], session: Self.a),
        ], modified: Date(timeIntervalSince1970: 1000))
        try fixture.write(Self.b, [
            entry("user", "v1", parent: nil, "Fix the build", session: Self.b),
            ["type": "custom-title", "customTitle": "Build fix", "sessionId": .string(Self.b)],
            ["type": "tag", "tag": "work", "sessionId": .string(Self.b)],
        ], modified: Date(timeIntervalSince1970: 2000))
        try Data("{}\n".utf8).write(to: fixture.project.appendingPathComponent("not-a-uuid.jsonl"))

        let sessions = listSessions(configDirectory: fixture.config.path)
        #expect(sessions.map(\.sessionId) == [Self.b, Self.a])
        #expect(sessions[0].summary == "Build fix")
        #expect(sessions[0].customTitle == "Build fix")
        #expect(sessions[0].tag == "work")
        #expect(sessions[1].summary == "Plan the trip to Lisbon")
        #expect(sessions[1].firstPrompt == "Plan the trip to Lisbon")
        #expect(sessions[1].gitBranch == "main")
        #expect(sessions[1].createdAt != nil)
        #expect(listSessions(limit: 1, offset: 1, configDirectory: fixture.config.path).map(\.sessionId) == [Self.a])
        #expect(getSessionInfo(Self.b, configDirectory: fixture.config.path)?.tag == "work")
        #expect(getSessionInfo("not-a-uuid", configDirectory: fixture.config.path) == nil)
    }

    @Test func readsTheMainChainOfAConversation() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.write(Self.a, [
            entry("user", "u1", parent: nil, "Hello", session: Self.a),
            entry("assistant", "u2", parent: "u1", [["type": "text", "text": "Hi"]], session: Self.a),
            entry("assistant", "branch", parent: "u1", [["type": "text", "text": "Other reply"]], session: Self.a),
            entry("user", "m1", parent: "u2", "meta", session: Self.a, extra: ["isMeta": true]),
            entry("user", "u3", parent: "m1", "Again", session: Self.a),
            entry("assistant", "u4", parent: "u3", [["type": "text", "text": "Done"]], session: Self.a),
            entry("user", "s1", parent: nil, "side", session: Self.a, extra: ["isSidechain": true]),
        ])
        let messages = getSessionMessages(Self.a, configDirectory: fixture.config.path)
        #expect(messages.map(\.uuid) == ["u1", "u2", "u3", "u4"])
        #expect(messages.map(\.type) == ["user", "assistant", "user", "assistant"])
        #expect(getSessionMessages(Self.a, limit: 2, offset: 1, configDirectory: fixture.config.path).map(\.uuid) == ["u2", "u3"])
    }

    @Test func renamesTagsForksAndDeletes() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let config = fixture.config.path
        try fixture.write(Self.a, [
            entry("user", "u1", parent: nil, "First", session: Self.a),
            entry("assistant", "u2", parent: "u1", [["type": "text", "text": "One"]], session: Self.a),
            entry("user", "u3", parent: "u2", "Second", session: Self.a),
            entry("assistant", "u4", parent: "u3", [["type": "text", "text": "Two"]], session: Self.a),
        ])
        try renameSession(Self.a, title: "  Renamed  ", configDirectory: config)
        try tagSession(Self.a, tag: "ke\u{200B}ep", configDirectory: config)
        var info = try #require(getSessionInfo(Self.a, configDirectory: config))
        #expect(info.customTitle == "Renamed")
        #expect(info.tag == "keep")
        try tagSession(Self.a, tag: nil, configDirectory: config)
        info = try #require(getSessionInfo(Self.a, configDirectory: config))
        #expect(info.tag == nil)
        #expect(throws: InvalidOptionsError.self) { try renameSession(Self.a, title: " ", configDirectory: config) }
        #expect(throws: SessionNotFoundError.self) { try renameSession(Self.b, title: "x", configDirectory: config) }

        let fork = try forkSession(Self.a, upToMessageId: nil, configDirectory: config)
        let forked = getSessionMessages(fork.sessionId, configDirectory: config)
        #expect(forked.count == 4)
        #expect(Set(forked.map(\.uuid)).isDisjoint(with: ["u1", "u2", "u3", "u4"]))
        #expect(forked.allSatisfy { $0.sessionId == fork.sessionId })
        #expect(getSessionInfo(fork.sessionId, configDirectory: config)?.customTitle == "Renamed (fork)")

        try FileManager.default.createDirectory(at: fixture.project.appendingPathComponent("\(Self.a)/subagents"), withIntermediateDirectories: true)
        try deleteSession(Self.a, configDirectory: config)
        #expect(getSessionInfo(Self.a, configDirectory: config) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(Self.a).path))
        #expect(getSessionInfo(fork.sessionId, configDirectory: config) != nil)
    }

    @Test func forkingUpToAMessageCutsTheCopy() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let messageId = "33333333-3333-4333-8333-333333333333"
        try fixture.write(Self.a, [
            entry("user", "11111111-0000-4000-8000-000000000001", parent: nil, "First", session: Self.a),
            entry("assistant", messageId, parent: "11111111-0000-4000-8000-000000000001", [["type": "text", "text": "One"]], session: Self.a),
            entry("user", "11111111-0000-4000-8000-000000000003", parent: messageId, "Second", session: Self.a),
        ])
        let fork = try forkSession(Self.a, upToMessageId: messageId, title: "Branch", configDirectory: fixture.config.path)
        #expect(getSessionMessages(fork.sessionId, configDirectory: fixture.config.path).map(\.type) == ["user", "assistant"])
        #expect(getSessionInfo(fork.sessionId, configDirectory: fixture.config.path)?.summary == "Branch")
    }

    @Test func readsSubagentTranscripts() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.write(Self.a, [entry("user", "u1", parent: nil, "Delegate", session: Self.a)])
        let subagents = fixture.project.appendingPathComponent("\(Self.a)/subagents/workflows/run1")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let transcript = [
            entry("user", "a1", parent: nil, "Task", session: Self.a, extra: ["isSidechain": true]),
            entry("assistant", "a2", parent: "a1", [["type": "text", "text": "Result"]], session: Self.a, extra: ["isSidechain": true]),
        ]
        try Data((transcript.map(\.jsonString).joined(separator: "\n") + "\n").utf8).write(to: subagents.appendingPathComponent("agent-abc.jsonl"))
        try JSONValue.object(["toolUseId": "toolu_agent"]).data().write(to: subagents.appendingPathComponent("agent-abc.meta.json"))

        #expect(listSubagents(Self.a, configDirectory: fixture.config.path) == ["abc"])
        let messages = getSubagentMessages(Self.a, agentId: "abc", configDirectory: fixture.config.path)
        #expect(messages.map(\.uuid) == ["a1", "a2"])
        #expect(messages.allSatisfy { $0.parentToolUseId == "toolu_agent" })
    }

    @Test func unicodeSanitizingStripsInvisibleCharacters() {
        #expect(sanitizeUnicode("a\u{200B}b\u{202E}c\u{FEFF}") == "abc")
        #expect(sanitizeUnicode("ｆｕｌｌ") == "full")
    }
}
