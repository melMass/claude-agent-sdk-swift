import Foundation

/// Where Claude Code keeps session transcripts: one JSONL file per session
/// under `<config>/projects/<the session's directory, sanitized>/`.
enum SessionFiles {
    /// Bytes read from each end of a transcript for its metadata.
    static let liteReadSize = 65_536
    static let maxSanitizedLength = 200

    static func configDirectory(_ override: String?) -> URL {
        if let override { return URL(fileURLWithPath: override) }
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env.precomposedStringWithCanonicalMapping)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    static func projectsDirectory(_ configDirectory: String?) -> URL {
        self.configDirectory(configDirectory).appendingPathComponent("projects")
    }

    static func isUUID(_ text: String) -> Bool {
        text.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    /// A 32-bit string hash in base 36, as the CLI names long project directories.
    static func simpleHash(_ text: String) -> String {
        var hash: Int32 = 0
        for unit in text.utf16 { hash = (hash &<< 5) &- hash &+ Int32(unit) }
        return String(abs(Int64(hash)), radix: 36)
    }

    /// A directory path as a project folder name: every UTF-16 unit but ASCII
    /// letters and digits becomes `-` (as the CLI's JavaScript does); long
    /// names are cut and suffixed with a hash.
    static func sanitize(_ path: String) -> String {
        let sanitized = String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(Unicode.Scalar(UInt8(unit)))
            default: "-"
            }
        })
        guard sanitized.count > maxSanitizedLength else { return sanitized }
        return "\(sanitized.prefix(maxSanitizedLength))-\(simpleHash(path))"
    }

    /// The real path, NFC-normalized (sessions are filed under `/private/var/…`, not `/var/…`).
    static func canonicalize(_ path: String) -> String {
        let resolved = realpath(path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
        return resolved.precomposedStringWithCanonicalMapping
    }

    static func directories(in url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// The project folder for a directory, tolerating a different hash suffix on long paths.
    static func findProjectDirectory(for path: String, configDirectory: String?) -> URL? {
        let projects = projectsDirectory(configDirectory)
        let sanitized = sanitize(path)
        let exact = projects.appendingPathComponent(sanitized)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: exact.path, isDirectory: &isDirectory), isDirectory.boolValue { return exact }
        guard sanitized.count > maxSanitizedLength else { return nil }
        let prefix = String(sanitized.prefix(maxSanitizedLength)) + "-"
        return directories(in: projects).first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// The worktree paths of the git repository holding `path`; empty outside one.
    static func worktreePaths(_ path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "worktree", "list", "--porcelain"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)).precomposedStringWithCanonicalMapping : nil
        }
    }

    /// The project folders to look in for `directory` (itself, then its
    /// worktrees), or every project folder when `directory` is nil.
    static func candidateProjectDirectories(directory: String?, configDirectory: String?) -> [(url: URL, projectPath: String?)] {
        guard let directory else {
            return directories(in: projectsDirectory(configDirectory)).map { ($0, nil) }
        }
        let canonical = canonicalize(directory)
        var result: [(URL, String?)] = []
        if let own = findProjectDirectory(for: canonical, configDirectory: configDirectory) { result.append((own, canonical)) }
        for worktree in worktreePaths(canonical) where worktree != canonical {
            if let url = findProjectDirectory(for: worktree, configDirectory: configDirectory),
               !result.contains(where: { $0.0 == url })
            {
                result.append((url, worktree))
            }
        }
        return result
    }

    /// The transcript of `sessionId` (non-empty), and its project folder.
    static func findSessionFile(_ sessionId: String, directory: String?, configDirectory: String?) -> (file: URL, project: URL)? {
        for (project, _) in candidateProjectDirectories(directory: directory, configDirectory: configDirectory) {
            let file = project.appendingPathComponent("\(sessionId).jsonl")
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 0 {
                return (file, project)
            }
        }
        return nil
    }

    // MARK: Reading without parsing

    struct Lite {
        var modified: Date
        var size: Int
        var head: String
        var tail: String
    }

    /// The file's first and last 64 KiB, size and modification time; nil when empty or unreadable.
    static func readLite(_ url: URL) -> Lite? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0
        else { return nil }
        let modified = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        guard let headData = try? handle.read(upToCount: liteReadSize), !headData.isEmpty else { return nil }
        let head = String(decoding: headData, as: UTF8.self)
        var tail = head
        if size > liteReadSize {
            try? handle.seek(toOffset: UInt64(size - liteReadSize))
            tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        }
        return Lite(modified: modified, size: size, head: head, tail: tail)
    }

    /// The value of the first `"key":"…"` in `text`, read without parsing the line.
    static func firstStringField(_ text: String, _ key: String) -> String? {
        stringFields(text, key).first
    }

    /// The value of the last `"key":"…"` in `text`.
    static func lastStringField(_ text: String, _ key: String) -> String? {
        stringFields(text, key).last
    }

    /// Every `"key":"…"` value in `text`, in order, found by a byte search
    /// (`memmem`): a listing scans 128 KiB of every transcript for several keys.
    private static func stringFields(_ text: String, _ key: String) -> [String] {
        var text = text
        return text.withUTF8 { bytes -> [String] in
            guard let base = bytes.baseAddress else { return [] }
            var values: [(position: Int, value: String)] = []
            for pattern in ["\"\(key)\":\"", "\"\(key)\": \""] {
                let needle = Array(pattern.utf8)
                var start = 0
                while start < bytes.count,
                      let hit = memmem(base + start, bytes.count - start, needle, needle.count)
                {
                    let valueStart = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + needle.count
                    var index = valueStart
                    var escaped = false
                    while index < bytes.count {
                        let byte = bytes[index]
                        if escaped {
                            escaped = false
                        } else if byte == UInt8(ascii: "\\") {
                            escaped = true
                        } else if byte == UInt8(ascii: "\"") {
                            break
                        }
                        index += 1
                    }
                    guard index < bytes.count else { break }
                    let raw = String(decoding: UnsafeBufferPointer(rebasing: bytes[valueStart..<index]), as: UTF8.self)
                    values.append((valueStart - needle.count, unescape(raw)))
                    start = index + 1
                }
            }
            return values.sorted { $0.position < $1.position }.map(\.value)
        }
    }

    private static func unescape(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        return (try? JSONValue.parse("\"\(raw)\"").string) ?? raw
    }

    private static let skippedPromptPattern =
        #"^(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|\[Request interrupted by user[^\]]*\]|\s*<ide_opened_file>[\s\S]*</ide_opened_file>\s*$|\s*<ide_selection>[\s\S]*</ide_selection>\s*$)"#

    /// The first prompt a person typed: tool results, meta and compact
    /// summaries, slash commands and generated notices are skipped. Cut to 200 characters.
    static func firstPrompt(fromHead head: String) -> String {
        var commandFallback = ""
        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\""),
                  !line.contains("\"tool_result\""),
                  !(line.contains("\"isMeta\":true") || line.contains("\"isMeta\": true")),
                  !(line.contains("\"isCompactSummary\":true") || line.contains("\"isCompactSummary\": true")),
                  let entry = try? JSONValue.parse(String(line)), entry["type"] == "user",
                  let content = entry["message"]?["content"]
            else { continue }
            let texts = content.string.map { [$0] }
                ?? (content.array ?? []).compactMap { $0["type"] == "text" ? $0["text"]?.string : nil }
            for raw in texts {
                let text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if let range = text.range(of: "<command-name>(.*?)</command-name>", options: .regularExpression) {
                    if commandFallback.isEmpty {
                        commandFallback = String(text[range]).replacingOccurrences(of: "<command-name>", with: "")
                            .replacingOccurrences(of: "</command-name>", with: "")
                    }
                    continue
                }
                if text.range(of: skippedPromptPattern, options: .regularExpression) != nil { continue }
                if text.count > 200 {
                    var cut = String(text.prefix(200))
                    while let last = cut.last, last.isWhitespace { cut.removeLast() }
                    return cut + "\u{2026}"
                }
                return text
            }
        }
        return commandFallback
    }

    // MARK: Transcript entries

    static let chainEntryTypes: Set<String> = ["user", "assistant", "progress", "system", "attachment"]

    /// The entries of a transcript that belong to the message chain (they have a uuid).
    static func transcriptEntries(_ content: String) -> [JSONValue] {
        transcriptEntries(Data(content.utf8))
    }

    /// The chain entries of transcript bytes, split on newlines as bytes: a
    /// long transcript is hundreds of MB, too slow to split as a `String`.
    static func transcriptEntries(_ data: Data) -> [JSONValue] {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [JSONValue] in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var entries: [JSONValue] = []
            var start = 0
            while start < bytes.count {
                let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
                let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                start = end + 1
                guard !line.isEmpty, !isBookkeeping(line),
                      let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let entry = try? JSONValue(foundation: object), let type = entry["type"]?.string,
                      chainEntryTypes.contains(type), entry["uuid"]?.string != nil
                else { continue }
                entries.append(entry)
            }
            return entries
        }
    }

    private static let typePrefix = Array("{\"type\":\"".utf8)
    private static let chainEntryTypeBytes = chainEntryTypes.map { Array($0.utf8) + [UInt8(ascii: "\"")] }

    /// A line the CLI writes type-first (`{"type":"api-request",…}`) whose type
    /// is not a chain entry's, told apart without parsing it. Request dumps,
    /// titles and file-history snapshots make up about half of a long transcript;
    /// chain entries start with `{"parentUuid"`, so they always get parsed.
    static func isBookkeeping(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        guard line.starts(with: typePrefix) else { return false }
        let rest = line[typePrefix.count...]
        return !chainEntryTypeBytes.contains { rest.starts(with: $0) }
    }

    /// The conversation, root to leaf: from the latest main-chain leaf, walked
    /// back through `parentUuid`. Compaction back-pointers are not followed;
    /// the summary stands in for what it replaced.
    static func conversationChain(_ entries: [JSONValue]) -> [JSONValue] {
        guard !entries.isEmpty else { return [] }
        var byUUID: [String: JSONValue] = [:]
        var position: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let uuid = entry["uuid"]?.string ?? ""
            byUUID[uuid] = entry
            position[uuid] = index
        }
        let parents = Set(entries.compactMap { $0["parentUuid"]?.string })
        var leaves: [JSONValue] = []
        for terminal in entries where !parents.contains(terminal["uuid"]?.string ?? "") {
            var current: JSONValue? = terminal
            var seen: Set<String> = []
            while let entry = current, let uuid = entry["uuid"]?.string, seen.insert(uuid).inserted {
                if entry["type"] == "user" || entry["type"] == "assistant" {
                    leaves.append(entry)
                    break
                }
                current = entry["parentUuid"]?.string.flatMap { byUUID[$0] }
            }
        }
        guard !leaves.isEmpty else { return [] }
        let main = leaves.filter { $0["isSidechain"]?.bool != true && $0["teamName"]?.nonNull == nil && $0["isMeta"]?.bool != true }
        let pool = main.isEmpty ? leaves : main
        guard let leaf = pool.max(by: { (position[$0["uuid"]?.string ?? ""] ?? -1) < (position[$1["uuid"]?.string ?? ""] ?? -1) })
        else { return [] }
        var chain: [JSONValue] = []
        var seen: Set<String> = []
        var current: JSONValue? = leaf
        while let entry = current, let uuid = entry["uuid"]?.string, seen.insert(uuid).inserted {
            chain.append(entry)
            current = entry["parentUuid"]?.string.flatMap { byUUID[$0] }
        }
        return chain.reversed()
    }

    /// The chain entries of transcript bytes that ``conversationChain(_:)``
    /// needs, in file order, read from the end: the leaf is the last
    /// main-chain message, and lines are parsed backward only until its chain
    /// reaches a root, so the result also holds every entry after it. A
    /// compaction starts the chain over: a long session parses only what
    /// followed its last one. With no main-chain message, every entry.
    static func tailEntries(_ data: Data) -> [JSONValue] {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [JSONValue] in
            let bytes = buffer.bindMemory(to: UInt8.self)
            // Lines before `end` are still unread.
            var end = bytes.count
            var read: [JSONValue] = []
            var byUUID: [String: JSONValue] = [:]
            var leaf: JSONValue?
            /// Reads the line before `end`, keeping it when it is a chain entry
            /// (the first main-chain message so found is the leaf); false once
            /// the whole file is read.
            func readPrevious() -> Bool {
                guard end > 0 else { return false }
                let newline = bytes[..<end].lastIndex(of: 0x0A)
                let line = UnsafeBufferPointer(rebasing: bytes[(newline.map { $0 + 1 } ?? 0)..<end])
                end = newline ?? 0
                guard !line.isEmpty, !isBookkeeping(line),
                      let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let entry = try? JSONValue(foundation: object), let type = entry["type"]?.string,
                      chainEntryTypes.contains(type), let uuid = entry["uuid"]?.string
                else { return true }
                read.append(entry)
                byUUID[uuid] = entry
                if leaf == nil, type == "user" || type == "assistant", entry["isSidechain"]?.bool != true,
                   entry["teamName"]?.nonNull == nil, entry["isMeta"]?.bool != true
                {
                    leaf = entry
                }
                return true
            }
            while leaf == nil, readPrevious() {}
            // A parent is always written before its child: read back until it turns up.
            var seen: Set<String> = []
            var current = leaf
            while let entry = current, let uuid = entry["uuid"]?.string, seen.insert(uuid).inserted,
                  let parent = entry["parentUuid"]?.string
            {
                while byUUID[parent] == nil, readPrevious() {}
                current = byUUID[parent]
            }
            return read.reversed()
        }
    }

    static func isVisible(_ entry: JSONValue) -> Bool {
        guard entry["type"] == "user" || entry["type"] == "assistant" else { return false }
        return entry["isMeta"]?.bool != true && entry["isSidechain"]?.bool != true && entry["teamName"]?.nonNull == nil
    }

    static func page<T>(_ items: [T], limit: Int?, offset: Int) -> [T] {
        let start = min(max(offset, 0), items.count)
        let rest = items[start...]
        if let limit, limit > 0 { return Array(rest.prefix(limit)) }
        return Array(rest)
    }
}
