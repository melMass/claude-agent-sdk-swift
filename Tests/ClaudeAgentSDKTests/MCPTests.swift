import Foundation
import Testing
@testable import ClaudeAgentSDK

private struct Nope: Error, CustomStringConvertible { var description: String { "nope" } }

@Suite struct SdkMcpBridgeTests {
    static func bridge() -> SdkMcpBridge {
        let add = tool("add", "Adds.", inputSchema: ["a": .number, "b": .number],
                       annotations: ToolAnnotations(readOnlyHint: true, maxResultSizeChars: 500_000)) { args in
            .text(String(Int((args["a"]?.double ?? 0) + (args["b"]?.double ?? 0))))
        }
        let fail = tool("fail", "Fails.", inputSchema: .jsonSchema(["type": "object", "properties": [:]])) { _ in throw Nope() }
        let whoami = tool("whoami", "Reports the call.", inputSchema: [:]) { _, context in
            .text("\(context.serverName) \(context.toolUseId ?? "-")")
        }
        let link = tool("link", "A link.", inputSchema: [:]) { _ in
            ToolResult(content: [.resourceLink(name: "doc", uri: "file:///doc", description: nil), .image(data: "AAAA", mimeType: "image/png")])
        }
        let slow = tool("slow", "Waits.", inputSchema: [:]) { _ in
            try await Task.sleep(for: .seconds(30))
            return "late"
        }
        struct Greeting: Decodable, Sendable { let name: String }
        let greet = tool("greet", "Greets.", inputSchema: ["name": .string], as: Greeting.self) { input in .text("Hello, \(input.name)!") }
        return SdkMcpBridge(key: "math", server: SdkMcpServer(name: "math-server", version: "3.2.1",
                                                               tools: [add, fail, whoami, link, slow, greet]))
    }

    static func call(_ bridge: SdkMcpBridge, _ id: Int, _ name: String, _ arguments: JSONValue = [:], meta: JSONValue? = nil) async -> JSONValue? {
        var params: [String: JSONValue] = ["name": .string(name), "arguments": arguments]
        params.set("_meta", meta)
        return await bridge.handle(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": .object(params)])
    }

    @Test func initializeEchoesTheProtocolVersion() async {
        let reply = await Self.bridge().handle(["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                                 "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]])
        #expect(reply?["id"] == 0)
        #expect(reply?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply?["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply?["result"]?["serverInfo"] == ["name": "math-server", "version": "3.2.1"])
    }

    @Test func listsToolsWithSchemasAnnotationsAndMeta() async throws {
        let list = await Self.bridge().handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        let tools = try #require(list?["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == ["add", "fail", "whoami", "link", "slow", "greet"])
        #expect(tools[0]["inputSchema"] == ["type": "object", "properties": ["a": ["type": "number"], "b": ["type": "number"]],
                                            "required": ["a", "b"]])
        #expect(tools[0]["annotations"] == ["readOnlyHint": true])
        #expect(tools[0]["_meta"] == ["anthropic/maxResultSizeChars": 500_000])
        #expect(tools[1]["annotations"] == nil)
    }

    @Test func callsToolsAndMapsContent() async {
        let bridge = Self.bridge()
        #expect(await Self.call(bridge, 2, "add", ["a": 2, "b": 3])?["result"] == ["content": [["type": "text", "text": "5"]], "isError": false])
        #expect(await Self.call(bridge, 3, "greet", ["name": "Alice"])?["result"]?["content"]?[0]?["text"] == "Hello, Alice!")
        let who = await Self.call(bridge, 4, "whoami", meta: ["claudecode/toolUseId": "toolu_9"])
        #expect(who?["result"]?["content"]?[0]?["text"] == "math toolu_9")
        let link = await Self.call(bridge, 5, "link")
        #expect(link?["result"]?["content"] == [["type": "text", "text": "doc\nfile:///doc"],
                                                ["type": "image", "data": "AAAA", "mimeType": "image/png"]])
    }

    @Test func toolFailuresAreResultsTheModelReads() async {
        let bridge = Self.bridge()
        let failed = await Self.call(bridge, 6, "fail")
        #expect(failed?["result"]?["isError"] == true)
        #expect(failed?["result"]?["content"]?[0]?["text"] == "nope")
        let unknown = await Self.call(bridge, 7, "zzz")
        #expect(unknown?["result"] == ["content": [["type": "text", "text": "Tool 'zzz' not found"]], "isError": true])
        let invalid = await Self.call(bridge, 8, "add", ["a": "two", "b": 3])
        #expect(invalid?["result"]?["isError"] == true)
        #expect(invalid?["result"]?["content"]?[0]?["text"]?.string?.hasPrefix("Input validation error:") == true)
        let missing = await Self.call(bridge, 9, "add", ["a": 1])
        #expect(missing?["result"]?["content"]?[0]?["text"] == "Input validation error: 'b' is a required property")
    }

    @Test func notificationsGetNoReplyAndUnknownMethodsAnError() async {
        let bridge = Self.bridge()
        #expect(await bridge.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        #expect(await bridge.handle(["jsonrpc": "2.0", "id": 10, "method": "ping"])?["result"] == [:])
        let unknown = await bridge.handle(["jsonrpc": "2.0", "id": 11, "method": "resources/list"])
        #expect(unknown?["error"]?["code"] == -32601)
        #expect(unknown?["id"] == 11)
    }

    @Test func aCancelledCallAnswersRequestCancelled() async {
        let bridge = Self.bridge()
        async let reply = Self.call(bridge, 12, "slow")
        try? await Task.sleep(for: .milliseconds(100))
        // The same id again while the first is running is refused.
        let duplicate = await Self.call(bridge, 12, "add", ["a": 1, "b": 1])
        #expect(duplicate?["error"]?["code"] == -32603)
        _ = await bridge.handle(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 12, "reason": "x"]])
        let answer = await reply
        #expect(answer?["error"]?["code"] == -32800)
    }
}

@Suite struct SchemaValidatorTests {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "minLength": 1],
            "count": ["type": "integer", "minimum": 0],
            "mode": ["enum": ["fast", "slow"]],
            "tags": ["type": "array", "items": ["type": "string"]],
            "either": ["anyOf": [["type": "string"], ["type": "null"]]],
        ],
        "required": ["name"],
        "additionalProperties": false,
    ]

    func check(_ value: JSONValue) -> String? { JSONSchemaValidator.firstError(value, schema: schema) }

    @Test func acceptsConformingValues() {
        #expect(check(["name": "x", "count": 2, "mode": "fast", "tags": ["a"], "either": nil]) == nil)
        #expect(check(["name": "x", "count": 2.0]) == nil)
    }

    @Test func reportsTheFirstViolation() {
        #expect(check([:]) == "'name' is a required property")
        #expect(check(["name": 1]) == "1 is not of type 'string' (at 'name')")
        #expect(check(["name": "x", "count": 1.5]) == "1.5 is not of type 'integer' (at 'count')")
        #expect(check(["name": "x", "count": -1])?.hasPrefix("-1 is less than the minimum") == true)
        #expect(check(["name": "x", "mode": "medium"])?.hasPrefix("'medium' is not one of") == true)
        #expect(check(["name": "x", "tags": ["a", 2]]) == "2 is not of type 'string' (at 'tags[1]')")
        #expect(check(["name": "x", "extra": 1]) == "Additional properties are not allowed ('extra' was unexpected)")
        #expect(check(["name": "x", "either": 3])?.contains("any of the given schemas") == true)
    }
}
