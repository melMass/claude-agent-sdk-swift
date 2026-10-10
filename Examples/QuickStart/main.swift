// A one-shot query, then a two-turn conversation with ClaudeSDKClient.
//
//   swift run quick-start
//
// Needs Claude Code installed and signed in (`claude` once in a terminal).

import ClaudeAgentSDK
import Foundation

var options = ClaudeAgentOptions()
options.model = "haiku"
options.systemPrompt = "You are a concise assistant."
options.maxTurns = 1

print("— query —")
for try await message in query(prompt: "What is 2 + 2? Answer in one short sentence.", options: options) {
    switch message {
    case let .assistant(reply):
        print("Claude:", reply.text)
    case let .result(result):
        print("(\(result.numTurns) turn, \(result.durationMs) ms, $\(result.totalCostUsd ?? 0))")
    default:
        break
    }
}

print("— client —")
let client = ClaudeSDKClient(options: options)
try await client.connect()
for prompt in ["Name a city in Portugal.", "What is it known for? One sentence."] {
    print("You:", prompt)
    try await client.query(prompt)
    for try await message in try client.receiveResponse() {
        if case let .assistant(reply) = message, !reply.text.isEmpty { print("Claude:", reply.text) }
    }
}
await client.disconnect()
