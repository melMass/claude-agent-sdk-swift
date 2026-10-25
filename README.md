# Claude Agent SDK for Swift

A Swift port of Anthropic's Claude Agent SDK
([Python](https://github.com/anthropics/claude-agent-sdk-python) ·
[TypeScript](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)).
It drives the Claude Code CLI over its stream-JSON control protocol, so agents
built with it get Claude Code's whole loop (tools, permissions, hooks, MCP,
subagents, sessions) and its login, with Swift types and `async`/`await`.

- Swift 6 language mode, strict concurrency, no dependencies beyond Foundation.
- macOS 13+. Linux should build (Foundation `Process`), untested so far.
- Names follow the official SDKs, so their docs carry over: `query()`,
  `ClaudeSDKClient`, `ClaudeAgentOptions`, `tool()`, `createSdkMcpServer()`,
  `listSessions()`, …

## Requirements

Claude Code installed and signed in:

```sh
npm install -g @anthropic-ai/claude-code   # or the native installer
claude                                      # sign in once
```

The SDK finds `claude` on `PATH` and in the usual install locations (npm,
`~/.local/bin`, `~/.claude/local`, Homebrew, mise's Node). An app launched from
the Finder or Xcode gets launchd's `PATH`, so set `options.cliPath` if yours
lives elsewhere.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/melmass/claude-agent-sdk-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyAgent", dependencies: [.product(name: "ClaudeAgentSDK", package: "claude-agent-sdk-swift")]),
]
```

## Quick start

### One-shot `query`

```swift
import ClaudeAgentSDK

var options = ClaudeAgentOptions()
options.model = "haiku"
options.systemPrompt = "You are a concise assistant."

for try await message in query(prompt: "What is 2 + 2?", options: options) {
    switch message {
    case let .assistant(reply): print(reply.text)
    case let .result(result): print("cost: $\(result.totalCostUsd ?? 0)")
    default: break
    }
}
```

`query` returns a `Query`: an `AsyncSequence` of `Message`s that also carries
the control requests (`interrupt()`, `setModel(_:)`, `setPermissionMode(_:)`,
`mcpServerStatus()`, `getContextUsage()`, `rewindFiles(…)`, …). For
streaming input, pass an `AsyncSequence` of `UserInputMessage` as the prompt.

### Multi-turn `ClaudeSDKClient`

```swift
let client = ClaudeSDKClient(options: options)
try await client.connect()

try await client.query("Remember the number 7341.")
for try await message in try client.receiveResponse() { … }   // up to and including the result

try await client.query("Which number was it?")
for try await message in try client.receiveResponse() { … }

try await client.setModel("sonnet")
await client.disconnect()
```

`receiveMessages()` reads every message across turns; each new read picks up
where the last one stopped. `client.session` exposes the full `Query` control surface.

### Tools served in-process

```swift
struct Operands: Decodable, Sendable { let a: Double; let b: Double }

let add = tool("add", "Adds two numbers.", inputSchema: ["a": .number, "b": .number], as: Operands.self) { input in
    .text("\(input.a + input.b)")
}
let raw = tool("echo", "Echoes.", inputSchema: .jsonSchema(["type": "object", "properties": ["text": ["type": "string"]]])) { args in
    .text(args["text"]?.string ?? "")
}

options.mcpServers = ["calc": createSdkMcpServer(name: "calculator", tools: [add, raw])]
options.allowedTools = ["mcp__calc__add"]          // pre-approve; the model sees mcp__calc__add
```

Arguments are checked against the schema before the handler runs; a thrown
error, an unknown tool and invalid arguments all become error results the model
reads. The server's key (`calc`) is the name the model and the CLI use.

### Permissions

```swift
options.permissionMode = .default
options.canUseTool = { toolName, input, context in
    if toolName == "Bash", input["command"]?.string?.contains("rm") == true {
        return .deny(message: "Not here.")
    }
    return .allow(updatedInput: nil, updatedPermissions: context.suggestions)   // "always allow"
}
```

`canUseTool` is asked only for calls the rules would prompt for: anything in
`allowedTools`, allowed by the permission mode or by settings rules never
reaches it. A `PreToolUse` hook sees every call.

### Hooks

```swift
options.hooks = [
    .preToolUse: [HookMatcher(matcher: "Bash") { input, toolUseId, _ in
        guard input.toolInput?["command"]?.string?.contains("sudo") == true else { return .empty }
        return HookOutput(hookSpecificOutput: .preToolUse(permissionDecision: .deny, permissionDecisionReason: "No sudo"))
    }],
    .userPromptSubmit: [HookMatcher { _, _, _ in
        HookOutput(hookSpecificOutput: .userPromptSubmit(additionalContext: "Today is Friday."))
    }],
]
```

Every hook event Claude Code documents is available (`HookEvent.allCases`);
`HookInput` has typed accessors and the full payload as `raw`.

### Sessions on disk

```swift
let recent = listSessions(directory: "/path/to/project", limit: 20)
let messages = getSessionMessages(recent[0].sessionId)
try renameSession(recent[0].sessionId, title: "Refactor")
let fork = try forkSession(recent[0].sessionId, upToMessageId: messages[3].uuid)
options.resume = fork.sessionId
```

`getSessionMessages` reads a transcript from its end and stops at the last
compaction, so a session of hundreds of MB opens in a fraction of a second.
Each `SessionMessage` has typed `content` (`ContentBlock`s), `text`, `model`,
`timestamp`, `toolUseResult` and the whole `entry`.

### Taking turns with Claude Code

A session can move between a terminal and an app: one closes it, the other
resumes it. Only one process should have it open at a time; both would append
to its transcript.

```swift
// Claude Code processes running now, from <config>/sessions/<pid>.json.
for session in runningSessions() { print(session.pid, session.status, session.sessionId, session.cwd) }

// Resume in the app: sets `resume` and `cwd` (the CLI only resumes a session
// from its own directory); throws SessionInUseError while a terminal has it open.
try options.resume(id)            // or `fork: true` to continue in a copy

// Hand it back: "cd '/path/to/project' && claude --resume <id>"
let command = resumeCommand(id, cwd: info.cwd!)

// Another provider's conversation as a session Claude Code can resume.
let imported = try writeSession(messages, cwd: "/path/to/project", title: "From ChatGPT")

// Keep a browser current (FSEvents): transcripts written, processes started or ended.
for await change in sessionChanges() { … }
// Or follow one conversation; only appended lines are parsed.
for await messages in sessionMessageUpdates(id) { … }
```

The running-session records and the transcript format are Claude Code's own,
undocumented; unknown fields are ignored (checked against CLI 2.1.289–2.1.310).

### Examples

```sh
swift run quick-start    # a query, then a two-turn client
swift run tool-server    # in-process tools, a permission callback and a hook
```

## Defaults worth knowing

These match the Python SDK:

- `systemPrompt == nil` sends an **empty** system prompt. Use
  `.claudeCode` (or `.preset(append:)`) for Claude Code's own.
- `settingSources == nil` loads the user's, project's and local settings
  (CLAUDE.md, hooks, MCP servers, permissions). Pass `[]` to isolate the session,
  and `strictMcpConfig = true` to use only the MCP servers you give.
- `permissionMode == nil` leaves the choice to the CLI, which may be `auto`;
  set `.default` when every prompt should reach `canUseTool`.
- The child inherits this process's environment (minus `CLAUDECODE`). A program
  started from inside a Claude Code session inherits that session's
  `CLAUDE_*` variables too; set `stripsClaudeCodeEnvironment = true` to drop them.
  An inherited `ANTHROPIC_API_KEY` makes the CLI bill the key instead of the login.

## Errors

All errors conform to `ClaudeSDKError`: `CLINotFoundError`,
`CLIConnectionError`, `ProcessError` (exit code and stderr tail),
`ResultError` (the CLI's expected non-zero exit after an error result, with the
result's `subtype`, `errors`, `apiErrorStatus`, …), `CLIJSONDecodeError`,
`ControlRequestError` (refused or timed-out control request), `InvalidOptionsError`.

## Parity

Compared with the Python SDK 0.2.165 and the TypeScript SDK 0.3.296, against Claude Code 2.1.296.

| Area | Python | TypeScript | Swift |
|---|---|---|---|
| `query()` with a string prompt or streamed input | ✓ | ✓ | ✓ `query(prompt:options:)` |
| Long-lived client (`connect`, `query`, `receive_messages`, `receive_response`, `disconnect`) | ✓ | (via `Query`) | ✓ `ClaudeSDKClient` |
| `interrupt` (with receipt, `cancel_queued`) | ✓ | ✓ | ✓ |
| `set_permission_mode`, `set_model`, `set_max_thinking_tokens` | ✓ / ✓ / – | ✓ | ✓ |
| `rewind_files` (+ `dryRun`) | ✓ | ✓ | ✓ |
| MCP: `mcp_status`, reconnect, toggle, `setMcpServers`, `readMcpResource`, permission-mode override | partly | ✓ | ✓ |
| `get_context_usage`, `get_usage`, `stop_task`, `backgroundTasks`, `cancelAsyncMessage`, `readFile`, `seedReadState`, reload plugins/skills/output styles, `applyFlagSettings`, `updateSettings`, `getSettings` | partly | ✓ | ✓ |
| `initializationResult` / `get_server_info`, `supportedModels/Commands/Agents`, `accountInfo`, `reinitialize` | ✓ | ✓ | ✓ |
| `canUseTool` with updated input and permission updates | ✓ | ✓ | ✓ |
| Hooks over `hook_callback`, all events, matchers, timeouts, typed outputs | ✓ | ✓ | ✓ |
| In-process MCP servers (`tool`, `createSdkMcpServer`, schema validation, annotations, `maxResultSizeChars`, cancellation) | ✓ | ✓ | ✓ (schema as JSON Schema or a type map; `Decodable` inputs) |
| External MCP servers (stdio / SSE / HTTP / config file) | ✓ | ✓ | ✓ |
| Agents, `agent`, skills, plugins, sandbox, settings, managed settings | ✓ | ✓ | ✓ |
| Thinking, effort, structured output, betas, task budget, budget/turn limits, fallback model | ✓ | ✓ | ✓ |
| Resume / continue / fork / `sessionId` / `resumeSessionAt` / `resumeDropsTurn` / `persistSession` | ✓ | ✓ | ✓ |
| `onElicitation`, `onUserDialog` | – | ✓ | ✓ |
| Typed messages + raw JSON + unknown-frame fallback | ✓ (drops unknown) | ✓ | ✓ (`Message.unknown`) |
| Run-end handling (session state, background agents, ceiling) | ✓ | ✓ | ✓ |
| Error types (`CLINotFound`, `ProcessError`, `ResultError`, JSON decode) | ✓ | ✓ | ✓ |
| Session helpers: list, info, messages, subagents, rename, tag, delete, fork | ✓ | ✓ | ✓ |
| Running sessions, resume guard, `resumeCommand`, `writeSession`, change streams | – | – | ✓ |
| Custom transport | ✓ `Transport` | `spawnClaudeCodeProcess` | ✓ `Transport` |

Not supported, and why:

- **SessionStore** (mirroring transcripts to external storage, store-backed
  resume and listing, `import_session_to_store`, `InMemorySessionStore`):
  a subsystem of its own (batched mirroring, temporary config directories,
  copying credentials out of the Keychain for resume). Local transcripts are
  fully supported.
- **`prewarm()` / `startup()` / `WarmQuery`** (TypeScript): a process-pool
  optimisation, not protocol behaviour.
- **`resolveSettings()`** (TypeScript): reimplements the CLI's settings cascade locally.
- **`systemPrompt` as an array with a cache boundary** (TypeScript): sent through
  `initialize` rather than argv; use a string, `.custom` or `.preset`.
- **`toolConfig`, `pluginDelivery: 'initialize'`, per-server `sdkMcpServerConfigs`**
  (TypeScript): undocumented on the wire or tied to `--await-initialize`.
- **`user`** (Python, run the CLI as another OS user): Foundation's `Process` cannot.
- **The CLI version probe and `CanUseToolShadowedWarning`** (Python): advisory
  log output only.
- **`abortController`** (TypeScript): use `Query.close()` or cancel the reading task.

## Testing

```sh
swift test                         # unit and protocol tests against a scripted fake CLI
CLAUDE_LIVE=1 swift test --filter LiveTests   # a few short Haiku exchanges on your login
```

The protocol tests run the SDK against `FakeClaude`, a small executable in this
package that plays a scripted NDJSON conversation and checks every frame the
SDK writes.

## License

MIT
