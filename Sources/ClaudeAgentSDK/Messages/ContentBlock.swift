import Foundation

/// A block of a message's content, as the Messages API defines it.
public enum ContentBlock: Sendable, Hashable {
    case text(TextBlock)
    case thinking(ThinkingBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    /// A tool the API runs itself (`web_search`, `web_fetch`, `code_execution`, `advisor`, …).
    case serverToolUse(ServerToolUseBlock)
    /// The result of a server-side tool (`web_search_tool_result`, `advisor_tool_result`, …).
    case serverToolResult(ServerToolResultBlock)
    /// Any other block (images, documents, redacted thinking, newer types), as sent.
    case other(JSONValue)

    init(json: JSONValue) {
        let type = json["type"]?.string ?? ""
        switch type {
        case "text":
            self = .text(TextBlock(text: json["text"]?.string ?? ""))
        case "thinking":
            self = .thinking(ThinkingBlock(thinking: json["thinking"]?.string ?? "", signature: json["signature"]?.string ?? ""))
        case "tool_use":
            self = .toolUse(ToolUseBlock(id: json["id"]?.string ?? "", name: json["name"]?.string ?? "", input: json["input"] ?? [:]))
        case "tool_result":
            self = .toolResult(ToolResultBlock(
                toolUseId: json["tool_use_id"]?.string ?? "", content: json["content"]?.nonNull, isError: json["is_error"]?.bool))
        case "server_tool_use":
            self = .serverToolUse(ServerToolUseBlock(
                id: json["id"]?.string ?? "", name: json["name"]?.string ?? "", input: json["input"] ?? [:]))
        case let type where type.hasSuffix("_tool_result") && json["tool_use_id"]?.string != nil:
            self = .serverToolResult(ServerToolResultBlock(
                type: type, toolUseId: json["tool_use_id"]?.string ?? "", content: json["content"] ?? .null))
        default:
            self = .other(json)
        }
    }

    /// The block's text when it is a text block.
    public var text: String? {
        if case let .text(block) = self { return block.text }
        return nil
    }
}

public struct TextBlock: Sendable, Hashable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ThinkingBlock: Sendable, Hashable {
    /// The thinking text; empty unless the session asked for summarized thinking.
    public var thinking: String
    public var signature: String
    public init(thinking: String, signature: String) {
        self.thinking = thinking
        self.signature = signature
    }
}

public struct ToolUseBlock: Sendable, Hashable {
    public var id: String
    /// The tool's name: a built-in (`Read`) or `mcp__<server>__<tool>`.
    public var name: String
    public var input: JSONValue
    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResultBlock: Sendable, Hashable {
    public var toolUseId: String
    /// A string, a list of content blocks, or nil.
    public var content: JSONValue?
    public var isError: Bool?
    public init(toolUseId: String, content: JSONValue? = nil, isError: Bool? = nil) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }

    /// The result's text: the string content, or its text blocks joined by newlines.
    public var text: String? {
        if let string = content?.string { return string }
        guard let blocks = content?.array else { return nil }
        return blocks.compactMap { $0["type"] == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }
}

public struct ServerToolUseBlock: Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ServerToolResultBlock: Sendable, Hashable {
    /// The block type, e.g. `web_search_tool_result`.
    public var type: String
    public var toolUseId: String
    public var content: JSONValue
    public init(type: String, toolUseId: String, content: JSONValue) {
        self.type = type
        self.toolUseId = toolUseId
        self.content = content
    }
}
