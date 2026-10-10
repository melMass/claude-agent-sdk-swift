import Foundation

/// A session to change was not found, or its id is not a UUID.
public struct SessionNotFoundError: ClaudeSDKError {
    public let message: String
}

private func compact(_ value: JSONValue) -> String { value.jsonString }

private func nowStamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

/// Appends a line to an existing, non-empty transcript; false when there is none at `url`.
private func tryAppend(_ url: URL, _ line: String) throws -> Bool {
    guard let handle = try? FileHandle(forUpdating: url) else { return false }
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    guard end > 0 else { return false }
    try handle.write(contentsOf: Data(line.utf8))
    return true
}

private func appendToSession(_ sessionId: String, _ line: String, directory: String?, configDirectory: String?) throws {
    for (project, _) in SessionFiles.candidateProjectDirectories(directory: directory, configDirectory: configDirectory) {
        if try tryAppend(project.appendingPathComponent("\(sessionId).jsonl"), line) { return }
    }
    throw SessionNotFoundError(message: "Session \(sessionId) not found" + (directory.map { " in project directory for \($0)" } ?? ""))
}

private func requireUUID(_ sessionId: String) throws {
    guard SessionFiles.isUUID(sessionId) else { throw InvalidOptionsError("Invalid session_id: \(sessionId)") }
}

/// Renames a session by appending a custom-title entry; the latest title wins.
public func renameSession(_ sessionId: String, title: String, directory: String? = nil, configDirectory: String? = nil) throws {
    try requireUUID(sessionId)
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw InvalidOptionsError("title must be non-empty") }
    let entry = JSONValue.orderedObject(["type": "custom-title", "customTitle": .string(trimmed), "sessionId": .string(sessionId)])
    try appendToSession(sessionId, entry + "\n", directory: directory, configDirectory: configDirectory)
}

/// Tags a session (nil clears the tag) by appending a tag entry; the latest wins.
/// Invisible and directional Unicode is stripped from the tag.
public func tagSession(_ sessionId: String, tag: String?, directory: String? = nil, configDirectory: String? = nil) throws {
    try requireUUID(sessionId)
    var value = ""
    if let tag {
        value = sanitizeUnicode(tag).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw InvalidOptionsError("tag must be non-empty (use nil to clear)") }
    }
    let entry = JSONValue.orderedObject(["type": "tag", "tag": .string(value), "sessionId": .string(sessionId)])
    try appendToSession(sessionId, entry + "\n", directory: directory, configDirectory: configDirectory)
}

/// Deletes a session's transcript and its subagent transcripts. There is no undo;
/// for a soft delete, tag the session and filter on the tag instead.
public func deleteSession(_ sessionId: String, directory: String? = nil, configDirectory: String? = nil) throws {
    try requireUUID(sessionId)
    guard let (file, _) = SessionFiles.findSessionFile(sessionId, directory: directory, configDirectory: configDirectory) else {
        throw SessionNotFoundError(message: "Session \(sessionId) not found" + (directory.map { " in project directory for \($0)" } ?? ""))
    }
    try FileManager.default.removeItem(at: file)
    try? FileManager.default.removeItem(at: file.deletingPathExtension())
}

/// Copies a session into a new one with fresh message uuids, optionally only
/// up to a message, beside the original. The copy starts without undo history.
///
/// - Parameters:
///   - upToMessageId: The last message to copy; nil copies everything.
///   - title: The copy's title; nil derives one from the original plus " (fork)".
public func forkSession(
    _ sessionId: String, directory: String? = nil, upToMessageId: String? = nil, title: String? = nil,
    configDirectory: String? = nil
) throws -> ForkSessionResult {
    try requireUUID(sessionId)
    if let upToMessageId, !SessionFiles.isUUID(upToMessageId) {
        throw InvalidOptionsError("Invalid up_to_message_id: \(upToMessageId)")
    }
    guard let (file, project) = SessionFiles.findSessionFile(sessionId, directory: directory, configDirectory: configDirectory),
          let data = try? Data(contentsOf: file), !data.isEmpty
    else { throw SessionNotFoundError(message: "Session \(sessionId) not found") }
    let content = String(decoding: data, as: UTF8.self)

    var transcript: [JSONValue] = []
    var replacements: [JSONValue] = []
    let forkTypes: Set<String> = ["user", "assistant", "attachment", "system", "progress"]
    for line in content.split(separator: "\n") {
        guard let entry = try? JSONValue.parse(String(line)), let type = entry["type"]?.string else { continue }
        if forkTypes.contains(type), entry["uuid"]?.string != nil {
            transcript.append(entry)
        } else if type == "content-replacement", entry["sessionId"]?.string == sessionId, let list = entry["replacements"]?.array {
            replacements += list
        }
    }
    transcript = transcript.filter { $0["isSidechain"]?.bool != true }
    guard !transcript.isEmpty else { throw InvalidOptionsError("Session \(sessionId) has no messages to fork") }
    if let upToMessageId {
        guard let cutoff = transcript.firstIndex(where: { $0["uuid"]?.string == upToMessageId }) else {
            throw InvalidOptionsError("Message \(upToMessageId) not found in session \(sessionId)")
        }
        transcript = Array(transcript[...cutoff])
    }

    var mapping: [String: String] = [:]
    var byUUID: [String: JSONValue] = [:]
    for entry in transcript {
        let uuid = entry["uuid"]?.string ?? ""
        mapping[uuid] = UUID().uuidString.lowercased()
        byUUID[uuid] = entry
    }
    // Progress entries are links in the chain but not worth copying.
    let writable = transcript.filter { $0["type"] != "progress" }
    guard !writable.isEmpty else { throw InvalidOptionsError("Session \(sessionId) has no messages to fork") }

    let forkId = UUID().uuidString.lowercased()
    let now = nowStamp()
    var lines: [String] = []
    for (index, original) in writable.enumerated() {
        guard case var .object(forked) = original, let uuid = original["uuid"]?.string else { continue }
        var parent: String?
        var parentId = original["parentUuid"]?.string
        while let id = parentId, let entry = byUUID[id] {
            if entry["type"] != "progress" {
                parent = mapping[id]
                break
            }
            parentId = entry["parentUuid"]?.string
        }
        forked["uuid"] = .string(mapping[uuid] ?? uuid)
        forked["parentUuid"] = JSONValue(parent)
        if let logical = original["logicalParentUuid"]?.string {
            forked["logicalParentUuid"] = JSONValue(mapping[logical])
        } else {
            forked["logicalParentUuid"] = original["logicalParentUuid"] ?? .null
        }
        forked["sessionId"] = .string(forkId)
        // The newest timestamp marks the leaf when the fork is resumed.
        forked["timestamp"] = index == writable.count - 1 ? .string(now) : (original["timestamp"] ?? .string(now))
        forked["isSidechain"] = false
        forked["forkedFrom"] = ["sessionId": .string(sessionId), "messageUuid": .string(uuid)]
        for key in ["teamName", "agentName", "slug", "sourceToolAssistantUUID"] { forked[key] = nil }
        lines.append(compact(.object(forked)))
    }
    if !replacements.isEmpty {
        lines.append(JSONValue.orderedObject([
            "type": "content-replacement", "sessionId": .string(forkId), "replacements": .array(replacements),
            "uuid": .string(UUID().uuidString.lowercased()), "timestamp": .string(now),
        ]))
    }
    var forkTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if forkTitle.isEmpty {
        let head = String(decoding: data.prefix(SessionFiles.liteReadSize), as: UTF8.self)
        let tail = String(decoding: data.suffix(SessionFiles.liteReadSize), as: UTF8.self)
        let derived = SessionFiles.lastStringField(tail, "customTitle") ?? SessionFiles.lastStringField(head, "customTitle")
            ?? SessionFiles.lastStringField(tail, "aiTitle") ?? SessionFiles.lastStringField(head, "aiTitle")
            ?? SessionFiles.firstPrompt(fromHead: head)
        forkTitle = "\(derived.isEmpty ? "Forked session" : derived) (fork)"
    }
    lines.append(JSONValue.orderedObject([
        "type": "custom-title", "sessionId": .string(forkId), "customTitle": .string(forkTitle),
        "uuid": .string(UUID().uuidString.lowercased()), "timestamp": .string(now),
    ]))

    let forkURL = project.appendingPathComponent("\(forkId).jsonl")
    guard FileManager.default.createFile(
        atPath: forkURL.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: 0o600])
    else { throw CLIConnectionError("Could not write \(forkURL.path)") }
    return ForkSessionResult(sessionId: forkId)
}

/// Strips format, private-use and unassigned characters (zero-width spaces,
/// directional marks, …) after NFKC normalization, until nothing changes.
func sanitizeUnicode(_ value: String) -> String {
    var current = value
    for _ in 0..<10 {
        let previous = current
        current = current.precomposedStringWithCompatibilityMapping
        current = String(String.UnicodeScalarView(current.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .format, .privateUse, .unassigned: false
            default: true
            }
        }))
        if current == previous { break }
    }
    return current
}
