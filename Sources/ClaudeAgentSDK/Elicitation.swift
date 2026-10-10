import Foundation

/// An MCP server asking the user for input (a form, or a URL to visit), which
/// no hook handled first.
public struct ElicitationRequest: Sendable {
    /// The MCP server that asked.
    public var serverName: String
    public var message: String
    /// `form` or `url`.
    public var mode: String?
    public var url: String?
    public var elicitationId: String?
    /// The JSON Schema of the form's fields.
    public var requestedSchema: JSONValue?
    public var title: String?
    public var displayName: String?
    public var description: String?
    /// The control request's id.
    public var requestId: String
    /// The whole request as the CLI sent it.
    public var raw: JSONValue

    init(request: JSONValue, requestId: String) {
        serverName = request["mcp_server_name"]?.string ?? ""
        message = request["message"]?.string ?? ""
        mode = request["mode"]?.string
        url = request["url"]?.string
        elicitationId = request["elicitation_id"]?.string
        requestedSchema = request["requested_schema"]
        title = request["title"]?.string
        displayName = request["display_name"]?.string
        description = request["description"]?.string
        self.requestId = requestId
        raw = request
    }
}

/// The user's answer to an elicitation.
public enum ElicitationResult: Sendable, Hashable {
    /// Accepted, with the form's values when it was a form.
    case accept(content: JSONValue? = nil)
    case decline
    case cancel

    var json: JSONValue {
        switch self {
        case let .accept(content):
            var object: [String: JSONValue] = ["action": "accept"]
            object.set("content", content)
            return .object(object)
        case .decline: return ["action": "decline"]
        case .cancel: return ["action": "cancel"]
        }
    }
}

/// Answers MCP elicitation requests. Without one, every elicitation is declined.
public typealias OnElicitation = @Sendable (_ request: ElicitationRequest) async throws -> ElicitationResult

/// A blocking dialog the CLI asks the host to render (`request_user_dialog`).
public struct UserDialogRequest: Sendable {
    /// Which dialog: only kinds listed in ``ClaudeAgentOptions/supportedDialogKinds`` are sent.
    public var dialogKind: String
    /// The dialog's data; its shape depends on `dialogKind`.
    public var payload: JSONValue
    public var toolUseId: String?
    public var requestId: String

    init(request: JSONValue, requestId: String) {
        dialogKind = request["dialog_kind"]?.string ?? ""
        payload = request["payload"] ?? [:]
        toolUseId = request["tool_use_id"]?.string
        self.requestId = requestId
    }
}

/// The host's answer to a dialog.
public enum UserDialogResult: Sendable, Hashable {
    /// The dialog completed with this result.
    case completed(JSONValue)
    /// The user dismissed it; the CLI applies the dialog's default. Also the
    /// required answer for a kind the host does not know.
    case cancelled

    var json: JSONValue {
        switch self {
        case let .completed(result): return ["behavior": "completed", "result": result]
        case .cancelled: return ["behavior": "cancelled"]
        }
    }
}

/// Renders dialogs the CLI asks for. Without one, dialogs get no answer and
/// the CLI's deadline settles them.
public typealias OnUserDialog = @Sendable (_ request: UserDialogRequest) async throws -> UserDialogResult
