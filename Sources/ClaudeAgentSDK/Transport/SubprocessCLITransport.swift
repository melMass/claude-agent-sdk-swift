import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Runs the local `claude` CLI and talks to it over its stdin and stdout.
///
/// Stdout is read on a thread of its own and split into NDJSON frames;
/// stderr is read on another, each line passed to
/// ``ClaudeAgentOptions/stderr`` and the last ones kept for error messages.
public final class SubprocessCLITransport: Transport, @unchecked Sendable {
    /// How long the CLI gets after its input closes before it is stopped:
    /// it saves the session on the way out, and stopping it early loses the
    /// last message.
    static let gracefulExitTimeout: Duration = .seconds(5)
    private static let stderrTailLines = 40

    private struct State {
        var process: Process?
        var stdin: FileHandle?
        var stderrTail: [String] = []
        var closing = false
        var started = false
    }

    private let options: ClaudeAgentOptions
    private let state = Locked(State())
    private let writeLock = NSLock()
    /// Signalled when stderr reaches its end, so an exit error carries all of it.
    private let stderrDone = DispatchSemaphore(value: 0)
    private let frames: AsyncThrowingStream<JSONValue, Error>
    private let framesContinuation: AsyncThrowingStream<JSONValue, Error>.Continuation

    /// The arguments the process was started with (after the executable).
    public let arguments: [String]

    public init(options: ClaudeAgentOptions) {
        self.options = options
        arguments = options.cliArguments()
        (frames, framesContinuation) = AsyncThrowingStream.makeStream(of: JSONValue.self)
    }

    public func connect() async throws {
        guard !state.withLock({ $0.started }) else { return }
        let path: String
        if let given = options.cliPath {
            guard FileManager.default.isExecutableFile(atPath: given) else {
                throw CLINotFoundError("Claude Code not found at", cliPath: given)
            }
            path = given
        } else if let found = ClaudeCLI.locate() {
            path = found
        } else {
            throw CLINotFoundError(ClaudeCLI.notFoundMessage)
        }
        if let cwd = options.cwd {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIConnectionError("Working directory does not exist: \(cwd)")
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = options.processEnvironment()
        if let cwd = options.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        Self.ignoreBrokenPipe(on: stdin.fileHandleForWriting)

        do {
            try process.run()
        } catch {
            throw CLIConnectionError("Failed to start Claude Code at \(path): \(errorText(error))")
        }
        state.withLock {
            $0.process = process
            $0.stdin = stdin.fileHandleForWriting
            $0.started = true
        }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        startStderrReader(stderr.fileHandleForReading)
        startStdoutReader(stdout.fileHandleForReading, process: ProcessBox(process))
    }

    public func write(_ line: String) async throws {
        let handle: FileHandle? = state.withLock { state in
            guard let process = state.process, process.isRunning, !state.closing else { return nil }
            return state.stdin
        }
        guard let handle else {
            throw CLIConnectionError("Claude Code is not running or its input is closed")
        }
        do {
            try writeLock.withLock { try handle.write(contentsOf: Data(line.utf8)) }
        } catch {
            throw CLIConnectionError("Failed to write to Claude Code: \(errorText(error))")
        }
    }

    public func readMessages() -> AsyncThrowingStream<JSONValue, Error> { frames }

    public func endInput() async {
        let handle = state.withLock { state -> FileHandle? in
            defer { state.stdin = nil }
            return state.stdin
        }
        writeLock.withLock { try? handle?.close() }
    }

    public func close() async {
        state.withLock { $0.closing = true }
        await endInput()
        guard let process = state.withLock({ $0.process }) else {
            framesContinuation.finish()
            return
        }
        let box = ProcessBox(process)
        if await Self.waitForExit(box, within: Self.gracefulExitTimeout) { return }
        process.terminate()
        if await Self.waitForExit(box, within: .seconds(5)) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await Self.waitForExit(box, within: .seconds(5))
    }

    /// The last lines the CLI wrote to stderr.
    public var stderrTail: String { state.withLock { $0.stderrTail.joined(separator: "\n") } }

    // MARK: Readers

    private func startStdoutReader(_ handle: FileHandle, process: ProcessBox) {
        let continuation = framesContinuation
        let maxBufferSize = options.maxBufferSize
        let thread = Thread { [weak self] in
            var splitter = NDJSONSplitter(maxBufferSize: maxBufferSize)
            var failure: Error?
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                do {
                    for frame in try splitter.append(chunk) { continuation.yield(frame) }
                } catch {
                    failure = error
                    break
                }
            }
            if failure == nil, let tail = splitter.finish() { continuation.yield(tail) }
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            process.process.waitUntilExit()
            _ = self?.stderrDone.wait(timeout: .now() + 1)
            let status = process.process.terminationStatus
            let closing = self?.state.withLock { $0.closing } ?? true
            if status != 0, !closing {
                let reason = process.process.terminationReason == .uncaughtSignal ? "terminated by signal \(status)" : nil
                continuation.finish(throwing: ProcessError(
                    reason.map { "Command \($0)" } ?? "Command failed with exit code \(status)",
                    exitCode: status, stderr: self?.stderrTail))
            } else {
                continuation.finish()
            }
        }
        thread.name = "ClaudeAgentSDK.stdout"
        thread.start()
    }

    private func startStderrReader(_ handle: FileHandle) {
        let callback = options.stderr
        let thread = Thread { [weak self] in
            var buffer = Data()
            func emit(_ line: Data) {
                var text = String(decoding: line, as: UTF8.self)
                while let last = text.last, last.isWhitespace { text.removeLast() }
                guard !text.isEmpty else { return }
                self?.state.withLock { state in
                    state.stderrTail.append(text)
                    if state.stderrTail.count > Self.stderrTailLines { state.stderrTail.removeFirst() }
                }
                callback?(text)
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    emit(buffer[buffer.startIndex..<newline])
                    buffer = Data(buffer[buffer.index(after: newline)...])
                }
            }
            if !buffer.isEmpty { emit(buffer) }
            self?.stderrDone.signal()
        }
        thread.name = "ClaudeAgentSDK.stderr"
        thread.start()
    }

    // MARK: Helpers

    /// Polls until the process exits or `limit` passes; true when it exited.
    private static func waitForExit(_ box: ProcessBox, within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while box.process.isRunning {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Writing to a pipe whose reader has exited raises SIGPIPE, which would
    /// kill this process; the write should fail with EPIPE instead.
    private static func ignoreBrokenPipe(on handle: FileHandle) {
        #if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif
    }
}

/// `Process` is not `Sendable`; its methods used here are safe from any thread.
private struct ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
