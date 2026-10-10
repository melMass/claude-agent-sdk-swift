// A stand-in for the `claude` CLI that plays a scripted NDJSON conversation.
//
// The script is a JSON array of steps in the file named by FAKE_CLAUDE_SCENARIO:
//   {"send": <frame>}          writes a frame to stdout; "$name" strings are replaced by captured values
//   {"expect": <pattern>}      reads the next stdin line and checks it against <pattern>:
//                              objects match as subsets, "*" matches anything, "$name" captures the value,
//                              "<absent>" requires the key to be missing
//   {"stdout": "text"}         writes raw text (no newline added)
//   {"stderr": "text"}         writes a line to stderr
//   {"sleep": ms}
//   {"expectEOF": true}        reads until stdin closes; any line read fails the script
//   {"exit": code}             exits now
// After the last step it waits for stdin to close, then exits 0, as the CLI does.
//
// FAKE_CLAUDE_RECORD names a file that receives {"args", "env", "cwd", "stdin", "failure"} as JSON.
// A failed expectation exits with status 3 and its reason on stderr.

import ClaudeAgentSDK
import Foundation

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["-v"] || arguments == ["--version"] {
    print("2.1.296 (Claude Code)")
    exit(0)
}

var received: [JSONValue] = []
var failure: String?

@MainActor func record() {
    guard let path = environment["FAKE_CLAUDE_RECORD"] else { return }
    let document: JSONValue = [
        "args": JSONValue(arguments),
        "env": .object(environment.mapValues(JSONValue.string)),
        "cwd": .string(FileManager.default.currentDirectoryPath),
        "stdin": .array(received),
        "failure": JSONValue(failure),
    ]
    try? document.data().write(to: URL(fileURLWithPath: path))
}

@MainActor func fail(_ reason: String) -> Never {
    failure = reason
    record()
    FileHandle.standardError.write(Data("fake-claude: \(reason)\n".utf8))
    exit(3)
}

func writeOut(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

var captured: [String: JSONValue] = [:]

@MainActor func matches(_ pattern: JSONValue, _ actual: JSONValue?) -> Bool {
    if case let .string(text) = pattern {
        if text == "*" { return actual != nil }
        if text == "<absent>" { return actual == nil }
        if text.hasPrefix("$"), text.count > 1 {
            guard let actual else { return false }
            captured[String(text.dropFirst())] = actual
            return true
        }
    }
    guard let actual else { return false }
    switch pattern {
    case let .object(expected):
        guard case .object = actual else { return false }
        return expected.allSatisfy { key, value in matches(value, actual[key]) }
    case let .array(expected):
        guard case let .array(items) = actual, items.count == expected.count else { return false }
        return zip(expected, items).allSatisfy { matches($0, $1) }
    case .int, .double:
        return pattern.double == actual.double
    default:
        return pattern == actual
    }
}

@MainActor func substitute(_ template: JSONValue) -> JSONValue {
    switch template {
    case let .string(text) where text.hasPrefix("$") && text.count > 1:
        return captured[String(text.dropFirst())] ?? template
    case let .object(object):
        return .object(object.mapValues(substitute))
    case let .array(items):
        return .array(items.map(substitute))
    default:
        return template
    }
}

@MainActor func readFrame() -> JSONValue? {
    while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard let frame = try? JSONValue.parse(line) else { fail("stdin line is not JSON: \(line)") }
        received.append(frame)
        record()
        return frame
    }
    return nil
}

record()
guard let scriptPath = environment["FAKE_CLAUDE_SCENARIO"],
      let scriptData = FileManager.default.contents(atPath: scriptPath),
      let steps = (try? JSONValue.parse(scriptData))?.array
else { fail("FAKE_CLAUDE_SCENARIO is missing or not a JSON array") }

for (index, step) in steps.enumerated() {
    if let frame = step["send"] {
        writeOut(substitute(frame).jsonString + "\n")
    } else if let pattern = step["expect"] {
        guard let frame = readFrame() else { fail("step \(index): stdin closed, expected \(pattern.jsonString)") }
        if !matches(pattern, frame) { fail("step \(index): expected \(pattern.jsonString), got \(frame.jsonString)") }
    } else if let text = step["stdout"]?.string {
        writeOut(text)
    } else if let text = step["stderr"]?.string {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else if let milliseconds = step["sleep"]?.int {
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
    } else if step["expectEOF"] != nil {
        if let frame = readFrame() { fail("step \(index): expected stdin to close, got \(frame.jsonString)") }
    } else if let code = step["exit"]?.int {
        record()
        exit(Int32(code))
    } else {
        fail("step \(index) is not understood: \(step.jsonString)")
    }
}
while readFrame() != nil {}
record()
exit(0)
