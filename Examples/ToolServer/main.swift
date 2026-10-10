// Tools served from this process (an in-process MCP server), a permission
// callback that decides each call, and a hook that logs tool use.
//
//   swift run tool-server
//
// Needs Claude Code installed and signed in (`claude` once in a terminal).

import ClaudeAgentSDK
import Foundation

struct Operands: Decodable, Sendable {
    let a: Double
    let b: Double
}

let add = tool("add", "Adds two numbers.", inputSchema: ["a": .number, "b": .number], as: Operands.self) { input in
    .text("\(input.a + input.b)")
}
let divide = tool("divide", "Divides a by b.", inputSchema: ["a": .number, "b": .number], as: Operands.self) { input in
    input.b == 0 ? .error("Division by zero") : .text("\(input.a / input.b)")
}

var options = ClaudeAgentOptions()
options.model = "haiku"
options.systemPrompt = "You are a calculator. Use the calculator tools for arithmetic."
options.tools = .list([])
options.mcpServers = ["calc": createSdkMcpServer(name: "calculator", version: "1.0.0", tools: [add, divide])]
// `add` runs without asking; `divide` goes through canUseTool.
options.allowedTools = ["mcp__calc__add"]
options.permissionMode = .default
options.canUseTool = { toolName, input, _ in
    print("  [permission] \(toolName) \(input)")
    return .allow
}
options.hooks = [
    .preToolUse: [HookMatcher(matcher: "mcp__calc__.*") { input, _, _ in
        print("  [hook] about to run \(input.toolName ?? "?")")
        return .empty
    }],
]

for try await message in query(prompt: "What is (12 + 30) / 7? Use the tools step by step.", options: options) {
    switch message {
    case let .assistant(reply):
        for block in reply.content {
            switch block {
            case let .text(text): print("Claude:", text.text)
            case let .toolUse(use): print("  [tool] \(use.name) \(use.input)")
            default: break
            }
        }
    case let .result(result):
        print("Done: \(result.result ?? "") ($\(result.totalCostUsd ?? 0))")
    default:
        break
    }
}
