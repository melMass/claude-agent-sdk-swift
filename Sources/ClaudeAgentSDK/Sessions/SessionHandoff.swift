import Foundation

/// The project folder holding the transcripts of sessions run in `directory`
/// (its real path, so `/var/…` files under `/private/var/…`). It may not exist yet.
public func sessionProjectDirectory(for directory: String, configDirectory: String? = nil) -> URL {
    let canonical = SessionFiles.canonicalize(directory)
    return SessionFiles.findProjectDirectory(for: canonical, configDirectory: configDirectory)
        ?? SessionFiles.projectsDirectory(configDirectory).appendingPathComponent(SessionFiles.sanitize(canonical))
}

extension ClaudeAgentOptions {
    /// Continues a saved session: sets ``resume``, and ``cwd`` to the directory
    /// the session ran in, since the CLI looks for a session to resume only
    /// among its working directory's (and its worktrees').
    ///
    /// - Parameter fork: Continues in a new session, leaving the original as it
    ///   was; a session open in another process can only be forked.
    /// - Throws: ``SessionNotFoundError`` when there is no transcript,
    ///   ``SessionInUseError`` when a running Claude Code has it open and `fork` is false.
    public mutating func resume(_ sessionId: String, fork: Bool = false, configDirectory: String? = nil) throws {
        guard let info = getSessionInfo(sessionId, configDirectory: configDirectory) else {
            throw SessionNotFoundError(message: "Session \(sessionId) not found")
        }
        if !fork { try requireSessionClosed(sessionId, configDirectory: configDirectory) }
        resume = sessionId
        forkSession = fork
        if let directory = info.cwd { cwd = directory }
    }
}

/// A shell command that opens the session in an interactive Claude Code:
/// `cd '<cwd>' && claude --resume <id>`.
///
/// - Parameters:
///   - cwd: The directory the session ran in (``SDKSessionInfo/cwd``).
///   - executable: The `claude` to run.
///   - fork: Adds `--fork-session`, continuing in a new session.
public func resumeCommand(_ sessionId: String, cwd: String, executable: String = "claude", fork: Bool = false) -> String {
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let claude = executable.allSatisfy { $0.isLetter || $0.isNumber || "/-_.".contains($0) } ? executable : quote(executable)
    return "cd \(quote(cwd)) && \(claude) --resume \(sessionId)" + (fork ? " --fork-session" : "")
}

/// Writes a conversation as a new saved session of a `claude` running in
/// `cwd`, so resuming it (``ClaudeAgentOptions/resume(_:fork:configDirectory:)``,
/// or `claude --resume` in a terminal) goes on from there. Returns its id.
///
/// The transcript format is the CLI's own and undocumented; the entries carry
/// the fields a resume reads (checked against CLI 2.1.296–2.1.310).
///
/// - Parameters:
///   - messages: Messages API messages (`role`, `content`), oldest first,
///     opening on the user's side. An assistant `tool_use` needs its
///     `tool_result` first in the next user message.
///   - title: The session's title in the CLI's list.
///   - entrypoint: What the transcript says started the session.
public func writeSession(
    _ messages: [JSONValue], cwd: String, title: String? = nil, entrypoint: String = "sdk-swift",
    configDirectory: String? = nil
) throws -> String {
    guard messages.first?["role"] == "user" else { throw InvalidOptionsError("A session opens with a user message") }
    let sessionId = UUID().uuidString.lowercased()
    let directory = SessionFiles.canonicalize(cwd)
    let folder = sessionProjectDirectory(for: directory, configDirectory: configDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = formatter.string(from: Date())
    var parent: JSONValue = .null
    var lines: [String] = []
    for (index, message) in messages.enumerated() {
        let role = message["role"]?.string == "assistant" ? "assistant" : "user"
        let uuid = UUID().uuidString.lowercased()
        var entry: [String: JSONValue] = [
            "parentUuid": parent, "isSidechain": false, "type": .string(role), "uuid": .string(uuid),
            "timestamp": .string(now), "userType": "external", "entrypoint": .string(entrypoint),
            "cwd": .string(directory), "sessionId": .string(sessionId),
        ]
        if role == "assistant" {
            entry["message"] = [
                "id": .string("msg_imported_\(index)"), "type": "message", "role": "assistant",
                "model": message["model"] ?? "imported", "content": message["content"] ?? [],
                "stop_reason": "end_turn", "stop_sequence": .null, "usage": ["input_tokens": 0, "output_tokens": 0],
            ]
        } else {
            entry["message"] = ["role": "user", "content": message["content"] ?? ""]
        }
        lines.append(JSONValue.object(entry).jsonString)
        parent = .string(uuid)
    }
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        lines.append(JSONValue.orderedObject(["type": "custom-title", "customTitle": .string(title), "sessionId": .string(sessionId)]))
    }
    let file = folder.appendingPathComponent("\(sessionId).jsonl")
    guard FileManager.default.createFile(
        atPath: file.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: 0o600])
    else { throw CLIConnectionError("Could not write \(file.path)") }
    return sessionId
}
