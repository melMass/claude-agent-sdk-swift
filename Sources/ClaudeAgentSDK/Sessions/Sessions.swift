import Foundation

/// A saved session's metadata, read from the start and end of its transcript.
public struct SDKSessionInfo: Sendable, Hashable {
    public var sessionId: String
    /// A display title: the custom or generated title, the last prompt, a summary, or the first prompt.
    public var summary: String
    public var lastModified: Date
    public var fileSize: Int?
    /// The user-set or generated title.
    public var customTitle: String?
    public var firstPrompt: String?
    public var gitBranch: String?
    public var cwd: String?
    /// The user-set tag.
    public var tag: String?
    /// From the first entry's timestamp.
    public var createdAt: Date?

    /// A value made by hand, for previews and tests; ``listSessions(directory:limit:offset:includeWorktrees:configDirectory:)`` reads real ones.
    public init(
        sessionId: String, summary: String, lastModified: Date, fileSize: Int? = nil, customTitle: String? = nil,
        firstPrompt: String? = nil, gitBranch: String? = nil, cwd: String? = nil, tag: String? = nil, createdAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.summary = summary
        self.lastModified = lastModified
        self.fileSize = fileSize
        self.customTitle = customTitle
        self.firstPrompt = firstPrompt
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.tag = tag
        self.createdAt = createdAt
    }
}

/// A user or assistant message read from a saved transcript.
public struct SessionMessage: Sendable {
    /// `user` or `assistant`.
    public var type: String
    public var uuid: String
    public var sessionId: String
    /// The Messages API message (`role`, `content`, …).
    public var message: JSONValue
    /// For a subagent's messages: the Agent `tool_use` that started it.
    public var parentToolUseId: String?
    /// For a nested subagent's messages: the agent that started it.
    public var parentAgentId: String?
    /// The whole transcript entry, for fields not modeled here.
    public var entry: JSONValue

    /// The message's content: a plain-text prompt is one text block.
    public var content: [ContentBlock] {
        let content = message["content"]
        if let text = content?.string { return [.text(TextBlock(text: text))] }
        return (content?.array ?? []).map(ContentBlock.init(json:))
    }

    /// The text blocks, joined.
    public var text: String { content.compactMap(\.text).joined() }

    /// When the entry was written.
    public var timestamp: Date? { entry["timestamp"]?.string.flatMap(parseDate) }

    /// The model that wrote an assistant message.
    public var model: String? { message["model"]?.string }

    /// A tool's structured result, on the user message that carries it.
    public var toolUseResult: JSONValue? { entry["toolUseResult"]?.nonNull }

    /// True for the summary that stands in for a compacted conversation.
    public var isCompactSummary: Bool { entry["isCompactSummary"]?.bool ?? false }

    /// True for a user message that holds only tool results, not a prompt.
    public var isToolResult: Bool {
        type == "user" && !content.isEmpty && content.allSatisfy { if case .toolResult = $0 { true } else { false } }
    }
}

/// The new session made by ``forkSession(_:directory:upToMessageId:title:configDirectory:)``.
public struct ForkSessionResult: Sendable, Hashable {
    public var sessionId: String
}

private func parseDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
}

private func sessionInfo(id: String, lite: SessionFiles.Lite, projectPath: String?) -> SDKSessionInfo? {
    let firstLine = lite.head.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? lite.head
    if firstLine.contains("\"isSidechain\":true") || firstLine.contains("\"isSidechain\": true") { return nil }
    let customTitle = SessionFiles.lastStringField(lite.tail, "customTitle") ?? SessionFiles.lastStringField(lite.head, "customTitle")
        ?? SessionFiles.lastStringField(lite.tail, "aiTitle") ?? SessionFiles.lastStringField(lite.head, "aiTitle")
    let nonEmptyTitle = customTitle.flatMap { $0.isEmpty ? nil : $0 }
    let firstPrompt = SessionFiles.firstPrompt(fromHead: lite.head)
    let summary = nonEmptyTitle ?? SessionFiles.lastStringField(lite.tail, "lastPrompt")
        ?? SessionFiles.lastStringField(lite.tail, "summary") ?? (firstPrompt.isEmpty ? nil : firstPrompt)
    guard let summary, !summary.isEmpty else { return nil }
    let tagLine = lite.tail.split(separator: "\n").last { $0.hasPrefix("{\"type\":\"tag\"") }
    let tag = tagLine.flatMap { SessionFiles.lastStringField(String($0), "tag") }.flatMap { $0.isEmpty ? nil : $0 }
    return SDKSessionInfo(
        sessionId: id, summary: summary, lastModified: lite.modified, fileSize: lite.size, customTitle: nonEmptyTitle,
        firstPrompt: firstPrompt.isEmpty ? nil : firstPrompt,
        gitBranch: SessionFiles.lastStringField(lite.tail, "gitBranch") ?? SessionFiles.firstStringField(lite.head, "gitBranch"),
        cwd: SessionFiles.firstStringField(lite.head, "cwd") ?? projectPath, tag: tag,
        createdAt: SessionFiles.firstStringField(lite.head, "timestamp").flatMap(parseDate))
}

private func sessions(in project: URL, projectPath: String?) -> [SDKSessionInfo] {
    let files = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { file in
        guard file.pathExtension == "jsonl" else { return nil }
        let id = file.deletingPathExtension().lastPathComponent
        guard SessionFiles.isUUID(id), let lite = SessionFiles.readLite(file) else { return nil }
        return sessionInfo(id: id, lite: lite, projectPath: projectPath)
    }
}

/// Lists saved sessions, newest first.
///
/// - Parameters:
///   - directory: A project directory: its sessions and, with
///     `includeWorktrees`, those of its git worktrees. Nil lists every project's.
///   - limit: At most this many.
///   - offset: Skips this many first (for paging).
///   - configDirectory: Claude Code's config directory; nil is
///     `$CLAUDE_CONFIG_DIR` or `~/.claude`.
public func listSessions(
    directory: String? = nil, limit: Int? = nil, offset: Int = 0, includeWorktrees: Bool = true,
    configDirectory: String? = nil
) -> [SDKSessionInfo] {
    var all: [SDKSessionInfo] = []
    if let directory {
        let canonical = SessionFiles.canonicalize(directory)
        var projects: [(URL, String?)] = []
        if let own = SessionFiles.findProjectDirectory(for: canonical, configDirectory: configDirectory) { projects.append((own, canonical)) }
        if includeWorktrees {
            for worktree in SessionFiles.worktreePaths(canonical) where worktree != canonical {
                if let url = SessionFiles.findProjectDirectory(for: worktree, configDirectory: configDirectory),
                   !projects.contains(where: { $0.0 == url })
                {
                    projects.append((url, worktree))
                }
            }
        }
        for (url, path) in projects { all += sessions(in: url, projectPath: path) }
    } else {
        for project in SessionFiles.directories(in: SessionFiles.projectsDirectory(configDirectory)) {
            all += sessions(in: project, projectPath: nil)
        }
    }
    var newest: [String: SDKSessionInfo] = [:]
    for info in all where (newest[info.sessionId]?.lastModified ?? .distantPast) < info.lastModified {
        newest[info.sessionId] = info
    }
    let sorted = newest.values.sorted { $0.lastModified > $1.lastModified }
    return SessionFiles.page(sorted, limit: limit, offset: offset)
}

/// One session's metadata; nil when it is not found, is a sidechain, or has nothing to show.
public func getSessionInfo(_ sessionId: String, directory: String? = nil, configDirectory: String? = nil) -> SDKSessionInfo? {
    guard SessionFiles.isUUID(sessionId) else { return nil }
    for (project, path) in SessionFiles.candidateProjectDirectories(directory: directory, configDirectory: configDirectory) {
        if let lite = SessionFiles.readLite(project.appendingPathComponent("\(sessionId).jsonl")) {
            return sessionInfo(id: sessionId, lite: lite, projectPath: path)
        }
    }
    return nil
}

/// A session's conversation, oldest first: user and assistant messages along
/// the transcript's main chain. Empty when the session is not found.
public func getSessionMessages(
    _ sessionId: String, directory: String? = nil, limit: Int? = nil, offset: Int = 0, configDirectory: String? = nil
) -> [SessionMessage] {
    guard SessionFiles.isUUID(sessionId),
          let (file, _) = SessionFiles.findSessionFile(sessionId, directory: directory, configDirectory: configDirectory),
          let content = try? Data(contentsOf: file, options: .mappedIfSafe)
    else { return [] }
    let chain = SessionFiles.conversationChain(SessionFiles.tailEntries(content))
    let messages = chain.filter(SessionFiles.isVisible).map { sessionMessage($0) }
    return SessionFiles.page(messages, limit: limit, offset: offset)
}

func sessionMessage(_ entry: JSONValue, parentToolUseId: String? = nil, parentAgentId: String? = nil) -> SessionMessage {
    SessionMessage(
        type: entry["type"] == "user" ? "user" : "assistant", uuid: entry["uuid"]?.string ?? "",
        sessionId: entry["sessionId"]?.string ?? "", message: entry["message"] ?? .null,
        parentToolUseId: parentToolUseId, parentAgentId: parentAgentId, entry: entry)
}

/// `agent-<id>.jsonl` transcripts under a session's `subagents/` folder, nested folders included.
private func agentFiles(_ sessionId: String, directory: String?, configDirectory: String?) -> [(id: String, file: URL)] {
    guard let (file, _) = SessionFiles.findSessionFile(sessionId, directory: directory, configDirectory: configDirectory) else { return [] }
    let root = file.deletingPathExtension().appendingPathComponent("subagents")
    var results: [(String, URL)] = []
    func walk(_ url: URL) {
        let entries = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            let name = entry.lastPathComponent
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walk(entry)
            } else if name.hasPrefix("agent-"), name.hasSuffix(".jsonl") {
                results.append((String(name.dropFirst("agent-".count).dropLast(".jsonl".count)), entry))
            }
        }
    }
    walk(root)
    return results
}

/// The ids of a session's subagents.
public func listSubagents(_ sessionId: String, directory: String? = nil, configDirectory: String? = nil) -> [String] {
    guard SessionFiles.isUUID(sessionId) else { return [] }
    return agentFiles(sessionId, directory: directory, configDirectory: configDirectory).map(\.id)
}

/// A subagent's conversation, oldest first. Each message carries the Agent
/// `tool_use` that started the subagent, from its `.meta.json` sidecar.
public func getSubagentMessages(
    _ sessionId: String, agentId: String, directory: String? = nil, limit: Int? = nil, offset: Int = 0,
    configDirectory: String? = nil
) -> [SessionMessage] {
    guard SessionFiles.isUUID(sessionId), !agentId.isEmpty,
          let match = agentFiles(sessionId, directory: directory, configDirectory: configDirectory).first(where: { $0.id == agentId }),
          let content = try? Data(contentsOf: match.file, options: .mappedIfSafe)
    else { return [] }
    let metaURL = match.file.deletingLastPathComponent()
        .appendingPathComponent(String(match.file.lastPathComponent.dropLast(".jsonl".count)) + ".meta.json")
    let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONValue.parse($0) }
    let entries = SessionFiles.transcriptEntries(content)
    var byUUID: [String: JSONValue] = [:]
    for entry in entries { byUUID[entry["uuid"]?.string ?? ""] = entry }
    var chain: [JSONValue] = []
    var seen: Set<String> = []
    var current = entries.last { $0["type"] == "user" || $0["type"] == "assistant" }
    while let entry = current, let uuid = entry["uuid"]?.string, seen.insert(uuid).inserted {
        chain.append(entry)
        current = entry["parentUuid"]?.string.flatMap { byUUID[$0] }
    }
    let messages = chain.reversed().filter { $0["type"] == "user" || $0["type"] == "assistant" }.map {
        sessionMessage($0, parentToolUseId: meta?["toolUseId"]?.string, parentAgentId: meta?["parentAgentId"]?.string)
    }
    return SessionFiles.page(messages, limit: limit, offset: offset)
}
