import Foundation

/// One rule in the permission policy.
///
/// The first matching rule wins; if none matches, the policy's default
/// effect applies. Tool patterns are globs over the tool *name* (e.g.
/// `Bash`, `mcp__github__*`); argument patterns are globs over the tool's
/// primary argument (the command for `Bash`, the file path for
/// `Read`/`Edit`/`Write`, the URL for `WebFetch`).
public struct PermissionRule: Codable, Hashable, Sendable {
    public enum Effect: String, Codable, Sendable, CaseIterable {
        case allow
        case deny
        /// Surface the ask to a human (via `PermissionResponder` where the
        /// provider supports it).
        case ask
    }

    public var effect: Effect
    /// Glob over the tool name, e.g. `Bash`, `Read`, `mcp__*`.
    public var toolPattern: String
    /// Optional glob over the tool's primary argument, e.g. `git *` for
    /// `Bash`. When `nil`, the rule matches the tool regardless of
    /// arguments.
    public var argumentPattern: String?
    public var note: String?

    public init(
        effect: Effect,
        toolPattern: String,
        argumentPattern: String? = nil,
        note: String? = nil
    ) {
        self.effect = effect
        self.toolPattern = toolPattern
        self.argumentPattern = argumentPattern
        self.note = note
    }

    /// Matches a tool invocation. A rule without an argument pattern never
    /// consults the argument at all.
    public func matches(toolName: String, primaryArgument: String?) -> Bool {
        guard Glob.matches(toolPattern, value: toolName) else { return false }
        guard let argumentPattern else { return true }
        guard let primaryArgument else { return false }
        return Glob.matches(argumentPattern, value: primaryArgument)
    }
}

/// The verdict a policy hands down for one invocation.
public enum PermissionDecision: String, Sendable, Hashable {
    case allow
    case deny
    case ask
}

/// An ordered rule list plus a default effect — the whole permission story.
///
/// The policy is applied *before* launch: the adapters translate it into
/// provider flags (Claude Code `--allowedTools`/`--disallowedTools`/
/// `--permission-mode`, Codex sandbox/reviewer flags), so an `allow` or
/// `deny` verdict never depends on a human being present. Per-tool rules
/// are a Claude-family capability; Codex only understands the coarse
/// default effect, which its adapter maps onto sandbox modes.
public struct PermissionPolicy: Codable, Hashable, Sendable {
    public var rules: [PermissionRule]
    public var defaultEffect: PermissionRule.Effect

    public init(rules: [PermissionRule] = [], defaultEffect: PermissionRule.Effect = .ask) {
        self.rules = rules
        self.defaultEffect = defaultEffect
    }

    /// Shorthand for "ask about everything" — the safe default for a new
    /// install.
    public static let askEverything = PermissionPolicy(rules: [], defaultEffect: .ask)

    /// First-match-wins evaluation.
    public func evaluate(toolName: String, primaryArgument: String? = nil) -> PermissionDecision {
        for rule in rules where rule.matches(
            toolName: toolName,
            primaryArgument: primaryArgument
        ) {
            return PermissionDecision(rule.effect)
        }
        return PermissionDecision(defaultEffect)
    }

    /// Convenience overload for evaluating a `ToolCall`.
    public func evaluate(call: ToolCall) -> PermissionDecision {
        evaluate(toolName: call.name, primaryArgument: Self.primaryArgument(of: call))
    }

    /// The single most relevant argument of a tool call, used for argument
    /// pattern matching. Unknown tools have none — patterns fall back to
    /// tool-name-only matching.
    public static func primaryArgument(of call: ToolCall) -> String? {
        switch call.name {
        case "Bash", "bash":
            return call.input["command"]?.stringValue
        case "Read", "Write", "Edit", "NotebookEdit":
            return call.input["file_path"]?.stringValue
        case "WebFetch", "WebSearch":
            return call.input["url"]?.stringValue
        default:
            return call.input["command"]?.stringValue
                ?? call.input["file_path"]?.stringValue
                ?? call.input["path"]?.stringValue
                ?? call.input["url"]?.stringValue
        }
    }

    /// The rules as Claude-Code-style permission patterns
    /// (`Tool` or `Tool(arg-pattern)`), for adapters that pass them to the
    /// CLI verbatim.
    public func patternStrings(effect: PermissionRule.Effect) -> [String] {
        rules.filter { $0.effect == effect }.map { rule in
            guard let argumentPattern = rule.argumentPattern else {
                return rule.toolPattern
            }
            return "\(rule.toolPattern)(\(argumentPattern))"
        }
    }
}

extension PermissionDecision {
    /// Converts a rule effect into the coarse decision vocabulary.
    init(_ effect: PermissionRule.Effect) {
        switch effect {
        case .allow: self = .allow
        case .deny: self = .deny
        case .ask: self = .ask
        }
    }
}
