import Foundation

/// The JSON type of a tool parameter, for the shorthand schema form.
public enum JSONSchemaType: String, Sendable, Hashable {
    case string, integer, number, boolean, array, object
}

/// A tool's input schema: a full JSON Schema, or the shorthand of parameter
/// names and types (every parameter required), as the Python SDK's
/// `{"name": str}` form.
public enum ToolInputSchema: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    /// A full JSON Schema object, sent as given.
    case jsonSchema(JSONValue)
    /// Parameter names and their types; all of them are required.
    case properties([String: JSONSchemaType])

    public init(dictionaryLiteral elements: (String, JSONSchemaType)...) {
        self = .properties(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    /// The JSON Schema sent to the CLI.
    public var json: JSONValue {
        switch self {
        case let .jsonSchema(schema):
            return schema
        case let .properties(properties):
            return [
                "type": "object",
                "properties": .object(properties.mapValues { ["type": .string($0.rawValue)] }),
                "required": JSONValue(properties.keys.sorted()),
            ]
        }
    }
}

/// MCP tool annotations: hints about a tool's behavior, plus Claude Code's
/// `maxResultSizeChars` (the size up to which a result stays inline rather
/// than being saved to a file and previewed), which travels in the tool's `_meta`.
public struct ToolAnnotations: Sendable, Hashable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?
    public var maxResultSizeChars: Int?

    public init(
        title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil, maxResultSizeChars: Int? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
        self.maxResultSizeChars = maxResultSizeChars
    }

    /// The MCP `annotations` object; nil when no hint is set.
    var json: JSONValue? {
        var object: [String: JSONValue] = [:]
        object.set("title", title.map(JSONValue.string))
        object.set("readOnlyHint", readOnlyHint.map(JSONValue.bool))
        object.set("destructiveHint", destructiveHint.map(JSONValue.bool))
        object.set("idempotentHint", idempotentHint.map(JSONValue.bool))
        object.set("openWorldHint", openWorldHint.map(JSONValue.bool))
        return object.isEmpty ? nil : .object(object)
    }
}

/// One piece of a tool's result.
public enum ToolContent: Sendable, Hashable {
    case text(String)
    /// Base64-encoded image data and its MIME type.
    case image(data: String, mimeType: String)
    /// A link to a resource; sent to the model as text ("name\nuri\ndescription").
    case resourceLink(name: String?, uri: String?, description: String?)
    /// An embedded text resource; sent as its text.
    case resource(text: String)

    /// The MCP content block the CLI receives.
    var json: JSONValue {
        switch self {
        case let .text(text):
            return ["type": "text", "text": .string(text)]
        case let .image(data, mimeType):
            return ["type": "image", "data": .string(data), "mimeType": .string(mimeType)]
        case let .resourceLink(name, uri, description):
            let parts = [name, uri, description].compactMap { $0 }.filter { !$0.isEmpty }
            return ["type": "text", "text": .string(parts.isEmpty ? "Resource link" : parts.joined(separator: "\n"))]
        case let .resource(text):
            return ["type": "text", "text": .string(text)]
        }
    }
}

/// What a tool returns: content for the model and whether it is an error.
public struct ToolResult: Sendable, Hashable {
    public var content: [ToolContent]
    public var isError: Bool

    public init(content: [ToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// A text result.
    public static func text(_ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(content: [.text(text)], isError: isError)
    }

    /// An error result the model reads as text.
    public static func error(_ text: String) -> ToolResult {
        ToolResult(content: [.text(text)], isError: true)
    }

    /// The MCP `CallToolResult`.
    var json: JSONValue {
        ["content": .array(content.map(\.json)), "isError": .bool(isError)]
    }
}

extension ToolResult: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

/// What the CLI says about a tool call besides its arguments.
public struct ToolCallContext: Sendable {
    /// The key the server is registered under in ``ClaudeAgentOptions/mcpServers``.
    public let serverName: String
    /// The model's `tool_use` id, when the CLI sends it in the call's `_meta`.
    public let toolUseId: String?
    /// The call's `_meta` object.
    public let meta: JSONValue?
}

/// A tool served in-process to Claude Code by an ``SdkMcpServer``.
public struct SdkMcpTool: Sendable {
    public typealias Handler = @Sendable (_ arguments: JSONValue, _ context: ToolCallContext) async throws -> ToolResult

    public let name: String
    public let description: String
    public let inputSchema: ToolInputSchema
    public let annotations: ToolAnnotations?
    public let handler: Handler

    public init(
        name: String, description: String, inputSchema: ToolInputSchema, annotations: ToolAnnotations? = nil,
        handler: @escaping Handler
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.handler = handler
    }

    /// The entry `tools/list` returns for this tool.
    var listing: JSONValue {
        var entry: [String: JSONValue] = [
            "name": .string(name), "description": .string(description), "inputSchema": inputSchema.json,
        ]
        entry.set("annotations", annotations?.json)
        entry.set("_meta", annotations?.maxResultSizeChars.map { ["anthropic/maxResultSizeChars": .int($0)] })
        return .object(entry)
    }
}

/// Defines a tool for an in-process MCP server. The handler receives the
/// call's arguments, already checked against `inputSchema`; a thrown error
/// becomes an error result the model reads.
///
/// ```swift
/// let add = tool("add", "Adds two numbers", inputSchema: ["a": .number, "b": .number]) { args in
///     .text("\((args["a"]?.double ?? 0) + (args["b"]?.double ?? 0))")
/// }
/// ```
public func tool(
    _ name: String, _ description: String, inputSchema: ToolInputSchema, annotations: ToolAnnotations? = nil,
    handler: @escaping @Sendable (_ arguments: JSONValue) async throws -> ToolResult
) -> SdkMcpTool {
    SdkMcpTool(name: name, description: description, inputSchema: inputSchema, annotations: annotations) { arguments, _ in
        try await handler(arguments)
    }
}

/// Defines a tool whose handler also receives the call's context (the
/// model's `tool_use` id and the call's `_meta`).
public func tool(
    _ name: String, _ description: String, inputSchema: ToolInputSchema, annotations: ToolAnnotations? = nil,
    handler: @escaping SdkMcpTool.Handler
) -> SdkMcpTool {
    SdkMcpTool(name: name, description: description, inputSchema: inputSchema, annotations: annotations, handler: handler)
}

/// Defines a tool whose arguments are decoded into a `Decodable` type.
///
/// ```swift
/// struct Greeting: Decodable { let name: String }
/// let greet = tool("greet", "Greets someone", inputSchema: ["name": .string], as: Greeting.self) { input in
///     .text("Hello, \(input.name)!")
/// }
/// ```
public func tool<Input: Decodable & Sendable>(
    _ name: String, _ description: String, inputSchema: ToolInputSchema, annotations: ToolAnnotations? = nil,
    as type: Input.Type, handler: @escaping @Sendable (_ input: Input) async throws -> ToolResult
) -> SdkMcpTool {
    SdkMcpTool(name: name, description: description, inputSchema: inputSchema, annotations: annotations) { arguments, _ in
        let input: Input = try arguments.decode()
        return try await handler(input)
    }
}

/// An MCP server that lives in this process: Claude Code reaches it through
/// `mcp_message` control requests over the same pipes, so there is no server
/// process. The model sees its tools as `mcp__<key>__<tool>`, where `<key>`
/// is the server's key in ``ClaudeAgentOptions/mcpServers``.
public struct SdkMcpServer: Sendable {
    public let name: String
    public let version: String
    public let tools: [SdkMcpTool]

    public init(name: String, version: String = "1.0.0", tools: [SdkMcpTool] = []) {
        self.name = name
        self.version = version
        self.tools = tools
    }
}

/// Creates an in-process MCP server config for ``ClaudeAgentOptions/mcpServers``.
///
/// ```swift
/// let calculator = createSdkMcpServer(name: "calculator", tools: [add])
/// var options = ClaudeAgentOptions()
/// options.mcpServers = ["calc": calculator]
/// options.allowedTools = ["mcp__calc__add"]
/// ```
public func createSdkMcpServer(name: String, version: String = "1.0.0", tools: [SdkMcpTool] = []) -> McpServerConfig {
    .sdk(SdkMcpServer(name: name, version: version, tools: tools))
}
