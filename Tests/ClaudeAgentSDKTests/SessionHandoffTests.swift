import Foundation
import Testing
@testable import ClaudeAgentSDK

private let a = "11111111-1111-4111-8111-111111111111"

private func entry(_ type: String, _ uuid: String, parent: String?, _ content: JSONValue, extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string(type), "uuid": .string(uuid), "parentUuid": JSONValue(parent), "sessionId": .string(a),
        "timestamp": "2026-10-01T10:00:00.000Z", "cwd": "/Users/someone/app",
        "message": ["role": .string(type), "content": content],
    ]
    for (key, value) in extra { object[key] = value }
    return .object(object)
}

extension SessionFixture {
    /// Writes a running-session record as the CLI keeps it in `<config>/sessions/<pid>.json`.
    func writeRecord(pid: Int32, sessionId: String, procStart: String?, status: String = "idle") throws {
        let folder = config.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var record: [String: JSONValue] = [
            "pid": .int(Int(pid)), "sessionId": .string(sessionId), "cwd": .string(projectPath), "name": "app-1f",
            "status": .string(status), "kind": "interactive", "entrypoint": "cli", "version": "2.1.310",
            "startedAt": 1_792_399_766_389, "updatedAt": 1_792_609_399_843, "peerToken": "secret",
        ]
        if let procStart { record["procStart"] = .string(procStart) }
        try JSONValue.object(record).data().write(to: folder.appendingPathComponent("\(pid).json"))
    }

    func append(_ id: String, _ entries: [JSONValue]) throws {
        let handle = try FileHandle(forWritingTo: project.appendingPathComponent("\(id).jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(entries.map { $0.jsonString + "\n" }.joined().utf8))
    }
}

/// This process's start as the CLI writes `procStart`: `ps -o lstart`'s form, in UTC.
private func ownProcStart() throws -> String {
    let start = try #require(RunningSessionFiles.processStart(getpid()))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return formatter.string(from: start)
}

@Suite struct RunningSessionTests {
    @Test func readsLiveRecordsAndSkipsStaleOnes() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.writeRecord(pid: getpid(), sessionId: a, procStart: try ownProcStart(), status: "busy")
        // A record left by a process whose pid now belongs to another one.
        try fixture.writeRecord(pid: 1, sessionId: "22222222-2222-4222-8222-222222222222", procStart: "Mon Jan  1 00:00:00 2001")
        try fixture.writeRecord(pid: 999_999, sessionId: "33333333-3333-4333-8333-333333333333", procStart: nil)

        let running = runningSessions(configDirectory: fixture.config.path)
        #expect(running.map(\.sessionId) == [a])
        let session = try #require(running.first)
        #expect(session.pid == getpid())
        #expect(session.status == .busy)
        #expect(session.cwd == fixture.projectPath)
        #expect(session.name == "app-1f")
        #expect(session.startedAt == Date(timeIntervalSince1970: 1_792_399_766.389))
        #expect(runningSession(for: a, configDirectory: fixture.config.path)?.pid == getpid())
    }

    @Test func parsesThePaddedProcessStart() throws {
        let date = try #require(RunningSessionFiles.parseStart("Sun Oct  4 09:52:56 2026"))
        let parts = Calendar.current.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        #expect(parts.day == 4 && parts.hour == 9 && parts.second == 56)
    }

    @Test func resumingAnOpenSessionAsksForAFork() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.write(a, [entry("user", "u1", parent: nil, "Hello")])
        var options = ClaudeAgentOptions()
        try options.resume(a, configDirectory: fixture.config.path)
        #expect(options.resume == a)
        #expect(options.cwd == "/Users/someone/app")
        #expect(!options.forkSession)

        try fixture.writeRecord(pid: getpid(), sessionId: a, procStart: try ownProcStart())
        #expect(throws: SessionInUseError.self) { try requireSessionClosed(a, configDirectory: fixture.config.path) }
        var other = ClaudeAgentOptions()
        #expect(throws: SessionInUseError.self) { try other.resume(a, configDirectory: fixture.config.path) }
        try other.resume(a, fork: true, configDirectory: fixture.config.path)
        #expect(other.forkSession)
        #expect(throws: SessionNotFoundError.self) {
            try other.resume("44444444-4444-4444-8444-444444444444", configDirectory: fixture.config.path)
        }
    }
}

@Suite struct SessionHandoffTests {
    @Test func resumeCommandQuotesTheDirectory() {
        #expect(resumeCommand(a, cwd: "/Users/me/it's here") == "cd '/Users/me/it'\\''s here' && claude --resume \(a)")
        #expect(resumeCommand(a, cwd: "/x", executable: "/opt/my claude", fork: true)
            == "cd '/x' && '/opt/my claude' --resume \(a) --fork-session")
    }

    @Test func messagesAreTyped() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.write(a, [
            entry("user", "u1", parent: nil, "List the files"),
            entry("assistant", "u2", parent: "u1", [
                ["type": "text", "text": "Listing."],
                ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]],
            ], extra: ["message": ["role": "assistant", "model": "claude-fable-5-1", "content": [
                ["type": "text", "text": "Listing."],
                ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]],
            ]]]),
            entry("user", "u3", parent: "u2", [["type": "tool_result", "tool_use_id": "toolu_1", "content": "a.txt"]],
                  extra: ["toolUseResult": ["stdout": "a.txt"]]),
        ])
        let messages = getSessionMessages(a, configDirectory: fixture.config.path)
        #expect(messages.map(\.text) == ["List the files", "Listing.", ""])
        #expect(messages[1].model == "claude-fable-5-1")
        guard case let .toolUse(use) = messages[1].content.last else { Issue.record("no tool_use"); return }
        #expect(use.name == "Bash")
        #expect(!messages[0].isToolResult)
        #expect(messages[2].isToolResult)
        #expect(messages[2].toolUseResult?["stdout"] == "a.txt")
        #expect(messages[0].timestamp == ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
    }

    @Test func writtenSessionsReadBackUnderTheirDirectory() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let directory = FileManager.default.temporaryDirectory.path
        let id = try writeSession([
            ["role": "user", "content": "Plan the trip"],
            ["role": "assistant", "content": [["type": "text", "text": "Lisbon, then Porto."]]],
            ["role": "user", "content": [["type": "text", "text": "Book it"]]],
        ], cwd: directory, title: "Trip", configDirectory: fixture.config.path)

        let folder = sessionProjectDirectory(for: directory, configDirectory: fixture.config.path)
        // Sessions are filed under the real path: /var/folders is /private/var/folders.
        #expect(folder.lastPathComponent.hasPrefix("-private-var-"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).jsonl").path))
        let info = try #require(getSessionInfo(id, configDirectory: fixture.config.path))
        #expect(info.customTitle == "Trip")
        #expect(info.cwd == SessionFiles.canonicalize(directory))
        #expect(getSessionMessages(id, configDirectory: fixture.config.path).map(\.text) == ["Plan the trip", "Lisbon, then Porto.", "Book it"])
        #expect(throws: InvalidOptionsError.self) {
            try writeSession([["role": "assistant", "content": []]], cwd: directory, configDirectory: fixture.config.path)
        }
    }
}

@Suite struct SessionChangeTests {
    @Test func pathsMapToTheSessionTheyBelongTo() {
        let projects = "/c/projects", running = "/c/sessions"
        func change(_ path: String) -> SessionChange? { SessionChangeMapping.change(for: path, projects: projects, running: running) }
        #expect(change("/c/projects/-app/\(a).jsonl") == .transcript(sessionId: a))
        #expect(change("/c/projects/-app/\(a)/subagents/agent-x.jsonl") == .transcript(sessionId: a))
        #expect(change("/c/projects/-app/memory/notes.md") == nil)
        #expect(change("/c/projects/-app") == nil)
        #expect(change("/c/sessions/1787.json") == .running)
        #expect(change("/c/sessions/1787.abc.key") == nil)
        #expect(change("/c/other/file") == nil)
    }

    @Test func tailReadStopsAtTheLastCompaction() throws {
        let lines: [JSONValue] = [
            entry("user", "old1", parent: nil, "Before"),
            entry("assistant", "old2", parent: "old1", [["type": "text", "text": "Long ago"]]),
            ["type": "api-request", "sessionId": .string(a), "body": "…"],
            ["type": "system", "subtype": "compact_boundary", "uuid": "c1", "parentUuid": .null, "logicalParentUuid": "old2"],
            entry("user", "s1", parent: "c1", "Summary of before", extra: ["isCompactSummary": true]),
            entry("assistant", "n1", parent: "s1", [["type": "text", "text": "Next"]]),
            ["type": "progress", "uuid": "p1", "parentUuid": "n1"],
        ]
        let data = Data(lines.map { $0.jsonString + "\n" }.joined().utf8)
        let tail = SessionFiles.tailEntries(data)
        #expect(tail.compactMap { $0["uuid"]?.string } == ["c1", "s1", "n1", "p1"])
        let full = SessionFiles.conversationChain(SessionFiles.transcriptEntries(data))
        #expect(SessionFiles.conversationChain(tail).map(\.jsonString) == full.map(\.jsonString))
        #expect(SessionFiles.tailEntries(Data()).isEmpty)
    }

    /// `TRANSCRIPT_PARITY=1`: the tail read gives the same conversation as the
    /// full read for every transcript in `~/.claude/projects`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPT_PARITY"] == "1"))
    func tailReadMatchesTheFullReadOnRealTranscripts() throws {
        let projects = SessionFiles.projectsDirectory(nil)
        var checked = 0
        for project in SessionFiles.directories(in: projects) {
            for file in (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "jsonl" {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let full = SessionFiles.conversationChain(SessionFiles.transcriptEntries(data)).compactMap { $0["uuid"]?.string }
                let tail = SessionFiles.conversationChain(SessionFiles.tailEntries(data)).compactMap { $0["uuid"]?.string }
                #expect(tail == full, "\(project.lastPathComponent)/\(file.lastPathComponent)")
                checked += 1
            }
        }
        print("checked \(checked) transcripts")
    }

    @Test func readerParsesOnlyCompleteAppendedLines() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.write(a, [entry("user", "u1", parent: nil, "Hello")])
        let file = fixture.project.appendingPathComponent("\(a).jsonl")
        let reader = TranscriptReader()
        #expect(reader.update(file)?.map(\.uuid) == ["u1"])
        #expect(reader.update(file) == nil)

        // Half a line: nothing new until it ends.
        let line = entry("assistant", "u2", parent: "u1", [["type": "text", "text": "Hi"]]).jsonString + "\n"
        let half = line.index(line.startIndex, offsetBy: line.count / 2)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line[..<half].utf8))
        #expect(reader.update(file) == nil)
        try handle.write(contentsOf: Data(line[half...].utf8))
        try handle.close()
        #expect(reader.update(file)?.map(\.uuid) == ["u1", "u2"])

        // A rewrite starts over.
        try fixture.write(a, [entry("user", "n1", parent: nil, "New")])
        #expect(reader.update(file)?.map(\.uuid) == ["n1"])
        try FileManager.default.removeItem(at: file)
        #expect(reader.update(nil)?.isEmpty == true)
    }

    @Test func updatesFollowATranscriptAsItGrows() async throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.config.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try fixture.write(a, [entry("user", "u1", parent: nil, "Hello")])

        let seen = try await withThrowingTaskGroup(of: [[String]].self) { group in
            group.addTask {
                var seen: [[String]] = []
                for await messages in sessionMessageUpdates(a, configDirectory: fixture.config.path, latency: 0.05) {
                    seen.append(messages.map(\.uuid))
                    if seen.count == 2 { break }
                }
                return seen
            }
            group.addTask {
                // Long enough for the stream to start before the append.
                try await Task.sleep(for: .milliseconds(500))
                try fixture.append(a, [entry("assistant", "u2", parent: "u1", [["type": "text", "text": "Hi"]])])
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
        #expect(seen == [["u1"], ["u1", "u2"]])
    }

    @Test func changesReportRunningRecords() async throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.config.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let change = try await withThrowingTaskGroup(of: SessionChange?.self) { group in
            group.addTask {
                for await change in sessionChanges(configDirectory: fixture.config.path, latency: 0.05) { return change }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(500))
                try fixture.writeRecord(pid: getpid(), sessionId: a, procStart: nil)
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(change == .running)
    }
}
