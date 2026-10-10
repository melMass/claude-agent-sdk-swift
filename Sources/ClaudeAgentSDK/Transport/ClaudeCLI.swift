import Foundation

/// Finding the `claude` executable.
public enum ClaudeCLI {
    /// The first `claude` found: on `PATH`, then where the installers put it
    /// (npm's global prefix, `/usr/local/bin`, the native installer's
    /// `~/.local/bin` and `~/.claude/local`, Homebrew, mise's Node).
    ///
    /// An app launched from the Finder or Xcode gets launchd's `PATH`, not the
    /// shell's, so the fixed locations matter. mise's shims are skipped: they
    /// need mise's own environment to resolve, the binaries behind them don't.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        var candidates: [String] = []
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(directory)/claude")
        }
        candidates += [
            "\(home)/.npm-global/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/node_modules/.bin/claude",
            "\(home)/.yarn/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.local/share/mise/installs/node/lts/bin/claude",
        ]
        return candidates.first { path in
            !path.contains("/mise/shims/") && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static let notFoundMessage = """
        Claude Code not found. Install with:
          npm install -g @anthropic-ai/claude-code
        or the native installer (https://claude.com/claude-code), then sign in by running `claude` once.
        If it is already installed somewhere else, set ClaudeAgentOptions.cliPath.
        """
}

/// Splits the CLI's stdout into NDJSON frames.
///
/// Lines split on `\n` only: a read can end inside a JSON string, and a
/// U+2028 inside a string is not a line break. Lines that are not JSON
/// objects (the CLI's debug noise, e.g. `[SandboxDebug] …`) are skipped.
struct NDJSONSplitter {
    private var buffer = Data()
    let maxBufferSize: Int?

    init(maxBufferSize: Int? = nil) { self.maxBufferSize = maxBufferSize }

    /// The frames completed by `chunk`.
    mutating func append(_ chunk: Data) throws -> [JSONValue] {
        buffer.append(chunk)
        var frames: [JSONValue] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if let frame = try Self.parse(buffer[start..<newline], strict: true) { frames.append(frame) }
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        if let maxBufferSize, buffer.count > maxBufferSize {
            let size = buffer.count
            buffer = Data()
            throw CLIJSONDecodeError(
                line: "JSON message exceeded maximum buffer size of \(maxBufferSize) bytes",
                underlying: MessageParseError("Buffer size \(size) exceeds limit \(maxBufferSize)"))
        }
        return frames
    }

    /// The trailing partial line, if it parses; a corrupt tail is dropped.
    mutating func finish() -> JSONValue? {
        defer { buffer = Data() }
        return (try? Self.parse(buffer, strict: false)) ?? nil
    }

    private static func parse(_ line: Data, strict: Bool) throws -> JSONValue? {
        guard let first = line.firstIndex(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0D) }),
              line[first] == UInt8(ascii: "{")
        else { return nil }
        do {
            return try JSONValue.parse(line)
        } catch {
            if strict { throw CLIJSONDecodeError(line: String(decoding: line, as: UTF8.self), underlying: error) }
            return nil
        }
    }
}
