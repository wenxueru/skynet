import Foundation

/// An interactive permission ask from the agent, when the provider supports
/// pausing for a human decision (the permission policy's `ask` verdict).
public struct PermissionRequest: Hashable, Sendable, Identifiable {
    /// Provider-assigned identifier; echoed back in the response.
    public var id: String
    public var sessionID: SessionID
    public var toolName: String
    /// The tool's input, exactly as the provider expressed it.
    public var input: JSONValue
    /// One-line human summary the UI can show without understanding the
    /// tool.
    public var summary: String

    public init(
        id: String,
        sessionID: SessionID,
        toolName: String,
        input: JSONValue = .null,
        summary: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.toolName = toolName
        self.input = input
        self.summary = summary
    }

    /// The primary argument the policy (and the human) should look at.
    public var primaryArgument: String? {
        let call = ToolCall(id: ToolCallID("request"), name: toolName, input: input)
        return PermissionPolicy.primaryArgument(of: call)
    }
}

/// A human (or policy-cached) answer to a `PermissionRequest`.
public struct PermissionResponse: Hashable, Sendable {
    public enum Decision: String, Sendable, Hashable {
        case allow
        case deny
        /// Allow, and remember for the rest of the session.
        case allowAlways
    }

    public var requestID: String
    public var decision: Decision
    /// Optionally rewritten tool input (an edited command). `nil` leaves
    /// the input untouched.
    public var updatedInput: JSONValue?
    public var reason: String?

    public init(
        requestID: String,
        decision: Decision,
        updatedInput: JSONValue? = nil,
        reason: String? = nil
    ) {
        self.requestID = requestID
        self.decision = decision
        self.updatedInput = updatedInput
        self.reason = reason
    }
}

/// Answers interactive permission asks. Implemented by the app's UI layer
/// (and by scripted doubles in tests). One responder serves one session.
public protocol PermissionResponder: Sendable {
    /// Answer a permission request. Called once per request; the session
    /// awaits the answer before replying to the agent.
    func decide(_ request: PermissionRequest) async -> PermissionResponse
}
