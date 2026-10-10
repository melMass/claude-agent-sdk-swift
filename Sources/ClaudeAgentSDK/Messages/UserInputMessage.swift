import Foundation

/// A user message written to the CLI: a prompt, in streaming-input mode or
/// through ``ClaudeSDKClient/query(_:sessionId:)``.
public struct UserInputMessage: Sendable, Hashable {
    /// The frame as it is written.
    public var json: JSONValue

    /// A frame given as is. It needs at least `type: "user"` and `message`;
    /// `session_id` is filled in when missing.
    public init(json: JSONValue) { self.json = json }

    /// A prompt of plain text.
    public init(_ text: String, sessionId: String? = nil, uuid: String? = nil) {
        self.init(content: .string(text), sessionId: sessionId, uuid: uuid)
    }

    /// A prompt of Messages API content blocks, e.g. text and an image:
    ///
    /// ```swift
    /// UserInputMessage(content: [
    ///     ["type": "text", "text": "What is in this picture?"],
    ///     ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(base64)]],
    /// ])
    /// ```
    public init(content: JSONValue, sessionId: String? = nil, uuid: String? = nil, parentToolUseId: String? = nil) {
        var frame: [String: JSONValue] = [
            "type": "user", "message": ["role": "user", "content": content],
            "parent_tool_use_id": JSONValue(parentToolUseId),
        ]
        frame.set("session_id", sessionId.map(JSONValue.string))
        frame.set("uuid", uuid.map(JSONValue.string))
        json = .object(frame)
    }

    /// The frame with `session_id` set when it had none, and `client_composed`
    /// set when prompts are delivered verbatim.
    func frame(sessionId: String, verbatim: Bool) -> JSONValue {
        var frame = json
        if frame["session_id"] == nil { frame["session_id"] = .string(sessionId) }
        if verbatim { frame["client_composed"] = true }
        return frame
    }
}

extension UserInputMessage: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}
