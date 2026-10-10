import Foundation

/// The channel to a Claude Code process: NDJSON frames written to it and read
/// from it. ``SubprocessCLITransport`` runs the local `claude`; another
/// implementation can reach a CLI elsewhere (a container, a VM, a remote host).
///
/// The SDK calls ``connect()`` once, then ``readMessages()`` once, and writes
/// frames while reading.
public protocol Transport: AnyObject, Sendable {
    /// Starts the process or opens the connection.
    func connect() async throws
    /// Writes one frame: a JSON object followed by a newline.
    func write(_ line: String) async throws
    /// The frames the CLI writes, ending when its output ends; throws when the
    /// process fails (e.g. ``ProcessError`` for a non-zero exit).
    func readMessages() -> AsyncThrowingStream<JSONValue, Error>
    /// Closes the CLI's input; it finishes its work and exits.
    func endInput() async
    /// Stops the CLI and releases everything.
    func close() async
}
