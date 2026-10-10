import Foundation

/// Every error this SDK throws conforms to this protocol, so one `catch let
/// error as ClaudeSDKError` covers them all. Mirrors the Python SDK's
/// `ClaudeSDKError` base class.
public protocol ClaudeSDKError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// A one-line description of what went wrong.
    var message: String { get }
}

extension ClaudeSDKError {
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Claude Code could not be reached: the process is not running, its input
/// is closed, or the SDK was used before `connect()`.
public struct CLIConnectionError: ClaudeSDKError {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The `claude` executable was not found. Install Claude Code
/// (`npm install -g @anthropic-ai/claude-code`, or the native installer) or
/// set ``ClaudeAgentOptions/cliPath``.
public struct CLINotFoundError: ClaudeSDKError {
    public let message: String
    /// The path that was tried, when one was given.
    public let cliPath: String?

    public init(_ message: String = "Claude Code not found", cliPath: String? = nil) {
        self.message = cliPath.map { "\(message): \($0)" } ?? message
        self.cliPath = cliPath
    }
}

/// The CLI process failed: it exited non-zero or could not be started.
public struct ProcessError: ClaudeSDKError {
    public let message: String
    public let exitCode: Int32?
    /// The last lines the process wrote to stderr, when any were captured.
    public let stderr: String?

    public init(_ message: String, exitCode: Int32? = nil, stderr: String? = nil) {
        var text = message
        if let exitCode { text += " (exit code: \(exitCode))" }
        if let stderr, !stderr.isEmpty { text += "\nError output: \(stderr)" }
        self.message = text
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// The CLI exited after reporting a terminal error result.
///
/// Claude Code ends a failed run by emitting a `result` message with
/// `is_error: true` (delivered to you as a ``ResultMessage``) and then exiting
/// non-zero. This error replaces the bare "exit code 1" ``ProcessError`` for
/// that case and carries the result's payload, so callers can branch on why
/// the run failed.
public struct ResultError: ClaudeSDKError {
    public let message: String
    /// The result subtype: `error_max_turns`, `error_during_execution`, … or
    /// `success` when the loop completed but the last turn was an API error.
    public let subtype: String?
    /// Error strings the CLI reported (may be empty).
    public let errors: [String]
    /// The result text; for API failures this holds the "API Error: …" prose.
    public let result: String?
    /// HTTP status of the failing API call, when there was one.
    public let apiErrorStatus: Int?
    /// Why the run ended (e.g. `api_error`, `max_turns`), when reported.
    public let terminalReason: String?
    public let sessionId: String?
    public let exitCode: Int32?
    /// The raw `result` frame.
    public let data: JSONValue

    init(result data: JSONValue, exitCode: Int32?) {
        self.data = data
        subtype = data["subtype"]?.string
        errors = Self.normalizedErrors(data["errors"])
        result = data["result"]?.string
        apiErrorStatus = data["api_error_status"]?.int
        terminalReason = data["terminal_reason"]?.string
        sessionId = data["session_id"]?.string
        self.exitCode = exitCode
        message = "Claude Code returned an error result: \(Self.text(for: data))"
    }

    /// The `errors` field as clean strings: a bare string is accepted, blank
    /// and non-string entries are dropped.
    static func normalizedErrors(_ raw: JSONValue?) -> [String] {
        let items: [JSONValue]
        switch raw {
        case let .string(text)?: items = [.string(text)]
        case let .array(array)?: items = array
        default: return []
        }
        return items.compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The most informative text of an error result: `errors`, then `result`,
    /// then a non-success subtype, then the HTTP status.
    static func text(for data: JSONValue) -> String {
        let errors = normalizedErrors(data["errors"])
        if !errors.isEmpty { return errors.joined(separator: "; ") }
        if let result = data["result"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            return result
        }
        if let subtype = data["subtype"]?.string, !subtype.isEmpty, subtype != "success" { return subtype }
        if let status = data["api_error_status"]?.int { return "API error (HTTP \(status))" }
        return "unknown error"
    }
}

/// A line of the CLI's output that looked like JSON could not be decoded.
public struct CLIJSONDecodeError: ClaudeSDKError {
    public let message: String
    /// The offending line.
    public let line: String
    public let underlying: String

    public init(line: String, underlying: Error) {
        self.line = line
        self.underlying = String(describing: underlying)
        message = "Failed to decode JSON: \(line.prefix(100))..."
    }
}

/// A message from the CLI could not be read as the type it claims to be.
public struct MessageParseError: ClaudeSDKError {
    public let message: String
    public let data: JSONValue?

    public init(_ message: String, data: JSONValue? = nil) {
        self.message = message
        self.data = data
    }
}

/// The CLI answered a control request with an error, or did not answer in time.
public struct ControlRequestError: ClaudeSDKError {
    public let message: String
    /// The control request's subtype, e.g. `set_model`.
    public let subtype: String
    /// Whether the request timed out rather than being refused.
    public let timedOut: Bool

    init(subtype: String, message: String, timedOut: Bool = false) {
        self.subtype = subtype
        self.message = message
        self.timedOut = timedOut
    }
}

/// Options that cannot be used together, or a value the SDK refuses before
/// starting the CLI.
public struct InvalidOptionsError: ClaudeSDKError {
    public let message: String
    public init(_ message: String) { self.message = message }
}
