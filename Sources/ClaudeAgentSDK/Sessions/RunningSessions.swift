import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A Claude Code process that has a session open, from the record it keeps in
/// `<config>/sessions/<pid>.json` while it runs.
///
/// The record is the CLI's own and undocumented (checked against 2.1.289–2.1.310):
/// fields this type does not know are ignored, and a missing one is nil.
public struct RunningSession: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// Waiting for a prompt.
        case idle
        /// Working on a turn.
        case busy
        case other(String)

        init(_ text: String?) {
            switch text {
            case "idle": self = .idle
            case "busy": self = .busy
            default: self = .other(text ?? "")
            }
        }
    }

    public var pid: Int32
    /// The session the process is in now; it changes on `/clear` or `/resume`.
    public var sessionId: String
    public var cwd: String
    /// The session's name in the CLI (`/rename`, or one it derived).
    public var name: String?
    public var status: Status
    /// `interactive` for a terminal session.
    public var kind: String?
    /// `cli`, or what started the process.
    public var entrypoint: String?
    /// The CLI's version.
    public var version: String?
    public var startedAt: Date?
    public var updatedAt: Date?
    /// Set while the session takes Remote Control (claude.ai/code, the mobile app).
    public var remoteControlSessionId: String?

    /// A value made by hand, for previews and tests; ``runningSessions(configDirectory:)`` reads real ones.
    public init(
        pid: Int32, sessionId: String, cwd: String, name: String? = nil, status: Status = .idle, kind: String? = "interactive",
        entrypoint: String? = "cli", version: String? = nil, startedAt: Date? = nil, updatedAt: Date? = nil,
        remoteControlSessionId: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.status = status
        self.kind = kind
        self.entrypoint = entrypoint
        self.version = version
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.remoteControlSessionId = remoteControlSessionId
    }

    init?(record: JSONValue) {
        guard let pid = record["pid"]?.int, let sessionId = record["sessionId"]?.string, let cwd = record["cwd"]?.string
        else { return nil }
        self.pid = Int32(pid)
        self.sessionId = sessionId
        self.cwd = cwd
        name = record["name"]?.string
        status = Status(record["status"]?.string)
        kind = record["kind"]?.string
        entrypoint = record["entrypoint"]?.string
        version = record["version"]?.string
        startedAt = record["startedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        updatedAt = record["updatedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        remoteControlSessionId = record["bridgeSessionId"]?.string
    }
}

enum RunningSessionFiles {
    static func directory(_ configDirectory: String?) -> URL {
        SessionFiles.configDirectory(configDirectory).appendingPathComponent("sessions")
    }

    /// The process start the record names (`procStart`, as `ps -o lstart`
    /// prints it: "Sun Oct  4 09:52:56 2026"), read in `timeZone`. The CLI
    /// writes it in UTC (2.1.310).
    static func parseStart(_ text: String, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let single = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: single)
    }

    /// When the process `pid` started (any user's); nil when there is no such process.
    static func processStart(_ pid: Int32) -> Date? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }

    /// Whether the record's process still runs: its pid is alive and, when the
    /// record says when it started, started then (a pid is reused once its
    /// process exits, and a crashed CLI leaves its record behind).
    static func isAlive(_ record: JSONValue) -> Bool {
        guard let pid = record["pid"]?.int, let started = processStart(Int32(pid)) else { return false }
        guard let text = record["procStart"]?.string else { return true }
        // UTC as the CLI writes it, or local time as `ps` prints it.
        let named = [parseStart(text), parseStart(text, timeZone: .current)].compactMap { $0 }
        return named.isEmpty || named.contains { abs(started.timeIntervalSince($0)) < 2 }
    }
}

/// The Claude Code processes running now, each with the session it has open,
/// newest first.
///
/// A session open in one process should not be resumed in another until it
/// closes: both would append to its transcript. See ``requireSessionClosed(_:configDirectory:)``.
public func runningSessions(configDirectory: String? = nil) -> [RunningSession] {
    let folder = RunningSessionFiles.directory(configDirectory)
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { file -> RunningSession? in
        guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
              let record = try? JSONValue.parse(data), RunningSessionFiles.isAlive(record)
        else { return nil }
        return RunningSession(record: record)
    }
    .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
}

/// The process that has `sessionId` open, if one does.
public func runningSession(for sessionId: String, configDirectory: String? = nil) -> RunningSession? {
    runningSessions(configDirectory: configDirectory).first { $0.sessionId == sessionId }
}

/// A session is open in another Claude Code process.
public struct SessionInUseError: ClaudeSDKError {
    public let session: RunningSession
    public var message: String {
        "Session \(session.sessionId) is open in Claude Code (pid \(session.pid)\(session.name.map { ", \"\($0)\"" } ?? "")): close it there, or fork it"
    }
}

/// Throws ``SessionInUseError`` when a running Claude Code process has the session open.
public func requireSessionClosed(_ sessionId: String, configDirectory: String? = nil) throws {
    if let session = runningSession(for: sessionId, configDirectory: configDirectory) { throw SessionInUseError(session: session) }
}
