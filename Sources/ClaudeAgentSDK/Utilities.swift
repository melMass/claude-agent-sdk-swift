import Foundation

/// A value guarded by a lock, for state shared with callbacks that run on
/// arbitrary threads (process termination, pipe readers).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// The text an error shows a reader: a `LocalizedError`'s description, else
/// the error's own description (not Foundation's generic "operation couldn't
/// be completed" sentence).
func errorText(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
    return String(describing: error)
}

/// The SDK's version, sent to the CLI as `CLAUDE_AGENT_SDK_VERSION`.
public let claudeAgentSDKVersion = "0.1.0"
