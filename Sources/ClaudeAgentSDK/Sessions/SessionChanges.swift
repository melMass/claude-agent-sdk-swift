import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// A change to a saved transcript or to the running Claude Code processes.
public enum SessionChange: Sendable, Hashable {
    /// A session's transcript, or one of its subagents', was written, created or removed.
    case transcript(sessionId: String)
    /// A Claude Code process started or ended, or its record changed (status,
    /// the session it has open): ``runningSessions(configDirectory:)`` again.
    case running
}

/// Changes to saved and running sessions as they happen, coalesced over `latency`.
///
/// Ends when the consuming task is cancelled. Uses FSEvents on macOS; elsewhere
/// the stream finishes at once.
///
/// - Parameters:
///   - latency: Seconds FSEvents gathers changes for before reporting them.
public func sessionChanges(configDirectory: String? = nil, latency: TimeInterval = 0.2) -> AsyncStream<SessionChange> {
    let projects = SessionFiles.canonicalize(SessionFiles.projectsDirectory(configDirectory).path)
    let running = SessionFiles.canonicalize(RunningSessionFiles.directory(configDirectory).path)
    return AsyncStream { continuation in
        #if canImport(CoreServices)
        let watcher = FileWatcher(paths: [projects, running], latency: latency) { paths in
            var changes: [SessionChange] = []
            for path in paths {
                guard let change = SessionChangeMapping.change(for: path, projects: projects, running: running),
                      !changes.contains(change)
                else { continue }
                changes.append(change)
            }
            changes.forEach { continuation.yield($0) }
        }
        continuation.onTermination = { _ in watcher.stop() }
        #else
        continuation.finish()
        #endif
    }
}

/// A session's conversation each time its transcript changes, the current one
/// first: what ``getSessionMessages(_:directory:limit:offset:configDirectory:)``
/// returns, read incrementally (only lines appended since the last read are
/// parsed). Empty while the session has no transcript.
public func sessionMessageUpdates(
    _ sessionId: String, directory: String? = nil, configDirectory: String? = nil, latency: TimeInterval = 0.2
) -> AsyncStream<[SessionMessage]> {
    AsyncStream { continuation in
        let task = Task {
            let reader = TranscriptReader()
            func read() {
                let file = SessionFiles.findSessionFile(sessionId, directory: directory, configDirectory: configDirectory)?.file
                if let messages = reader.update(file) { continuation.yield(messages) }
            }
            let changes = sessionChanges(configDirectory: configDirectory, latency: latency)
            read()
            for await change in changes where change == .transcript(sessionId: sessionId) { read() }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

enum SessionChangeMapping {
    /// What a changed path stands for: a transcript (`<projects>/<folder>/<id>.jsonl`,
    /// or anything under `<folder>/<id>/`, its subagents) or a running-session
    /// record (`<running>/<pid>.json`). Both folders are real paths, as FSEvents reports.
    static func change(for path: String, projects: String, running: String) -> SessionChange? {
        if path.hasPrefix(running + "/") { return path.hasSuffix(".json") ? .running : nil }
        guard path.hasPrefix(projects + "/") else { return nil }
        let parts = path.dropFirst(projects.count + 1).split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let name = String(parts[1])
        let id = parts.count == 2 && name.hasSuffix(".jsonl") ? String(name.dropLast(".jsonl".count)) : name
        return SessionFiles.isUUID(id) ? .transcript(sessionId: id) : nil
    }
}

/// Reads a transcript as it grows: keeps the entries read so far and parses
/// only complete lines appended since; starts over when the file is replaced
/// (another inode) or shrinks.
final class TranscriptReader {
    private var file: URL?
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var entries: [JSONValue] = []
    private var last: [SessionMessage]?

    /// The conversation when it differs from the last one returned, else nil.
    func update(_ url: URL?) -> [SessionMessage]? {
        guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            reset(nil)
            return emit([])
        }
        let node = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if url != file || node != inode || size < offset {
            reset(url)
            inode = node
        }
        if size > offset, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let first = offset == 0
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            offset += UInt64(data.count)
            pending.append(data)
            if let end = pending.lastIndex(of: UInt8(ascii: "\n")) {
                let complete = Data(pending[pending.startIndex...end])
                pending = Data(pending[pending.index(after: end)...])
                // Appended entries chain onto the tail, which holds everything after the leaf.
                entries += first ? SessionFiles.tailEntries(complete) : SessionFiles.transcriptEntries(complete)
            }
        }
        let chain = SessionFiles.conversationChain(entries)
        return emit(chain.filter(SessionFiles.isVisible).map { sessionMessage($0) })
    }

    private func reset(_ url: URL?) {
        file = url
        inode = nil
        offset = 0
        pending = Data()
        entries = []
    }

    private func emit(_ messages: [SessionMessage]) -> [SessionMessage]? {
        if let last, last.map(\.uuid) == messages.map(\.uuid), last.last?.entry == messages.last?.entry { return nil }
        last = messages
        return messages
    }
}

#if canImport(CoreServices)
/// An FSEvents stream over some folders, reporting the paths of changed files.
/// Folders that do not exist yet are watched from when they appear.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ClaudeAgentSDK.FileWatcher")
    private let handler: @Sendable ([String]) -> Void

    init(paths: [String], latency: TimeInterval, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            watcher.handler((0..<count).compactMap { array[$0] as? String })
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    /// Stops the stream; after it returns the handler is not called again.
    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
#endif
