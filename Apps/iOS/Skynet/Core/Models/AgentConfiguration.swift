import Foundation

/// The knobs a user can turn on a session: which model answers, how hard it
/// thinks, and how much freedom it gets over the machine.
public struct AgentConfiguration: Hashable, Codable, Sendable {
    public var model: AgentModel
    public var effort: ReasoningEffort
    public var permissions: PermissionMode

    public init(
        model: AgentModel,
        effort: ReasoningEffort = .standard,
        permissions: PermissionMode = .askForWrites
    ) {
        self.model = model
        self.effort = effort
        self.permissions = permissions
    }

    public static let standard = AgentConfiguration(
        model: AgentModel.balanced,
        effort: .standard,
        permissions: .askForWrites
    )
}

/// A model offered by the relay. The app treats models as opaque identifiers;
/// the paired Mac decides what actually runs.
public struct AgentModel: Hashable, Codable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    /// Short marketing-free description, e.g. "Fast replies, light reasoning".
    public let summary: String
    /// Whether the model honors reasoning-effort selection.
    public let supportsEffort: Bool

    public init(id: String, displayName: String, summary: String, supportsEffort: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.supportsEffort = supportsEffort
    }

    /// Generic catalog used when the relay has not reported one yet.
    public static let balanced = AgentModel(
        id: "balanced",
        displayName: "Balanced",
        summary: "Good default for everyday coding tasks"
    )
    public static let fast = AgentModel(
        id: "fast",
        displayName: "Fast",
        summary: "Prioritizes quick replies",
        supportsEffort: false
    )
    public static let deep = AgentModel(
        id: "deep",
        displayName: "Deep",
        summary: "Slower, more thorough reasoning"
    )

    public static let defaultCatalog: [AgentModel] = [.fast, .balanced, .deep]
}

/// How much reasoning effort the agent should spend before answering.
public enum ReasoningEffort: String, CaseIterable, Codable, Sendable, Identifiable {
    case minimal
    case standard
    case thorough
    case exhaustive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .standard: return "Standard"
        case .thorough: return "Thorough"
        case .exhaustive: return "Exhaustive"
        }
    }

    public var summary: String {
        switch self {
        case .minimal: return "Answer quickly with little deliberation"
        case .standard: return "Balanced thinking for most tasks"
        case .thorough: return "Weigh options before acting"
        case .exhaustive: return "Maximum deliberation for hard problems"
        }
    }
}

/// How much approval the agent needs before performing actions on the Mac.
public enum PermissionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Ask before every side-effecting action.
    case askForEverything
    /// Reads are auto-approved; writes and commands still ask.
    case askForWrites
    /// Everything is auto-approved. Opt-in, surfaced with extra warnings.
    case autonomous

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .askForEverything: return "Ask Always"
        case .askForWrites: return "Ask Before Changes"
        case .autonomous: return "Autonomous"
        }
    }

    public var summary: String {
        switch self {
        case .askForEverything: return "Confirm every read, write, and command"
        case .askForWrites: return "Files and commands ask; reads proceed"
        case .autonomous: return "Runs without asking. Use with care."
        }
    }

    /// The most permissive mode the UI should preselect without friction.
    public static let defaultMode: PermissionMode = .askForWrites
}

/// The kind of action a permission request covers.
public enum PermissionScope: String, Codable, Hashable, Sendable {
    case read
    case write
    case command
    case network
    case other
}

/// The user's answer to a permission request.
public enum PermissionDecision: String, Codable, Hashable, Sendable {
    case approvedOnce
    case approvedAlways
    case denied
}

/// Pure policy logic deciding whether a permission request can be answered
/// automatically under the active mode. Kept free of UI so it is trivially
/// testable; the relay remains the source of truth on the Mac side.
public enum PermissionEvaluator {
    /// Returns the automatic decision for a scope under a mode, or `nil` when
    /// the user must be asked.
    public static func automaticDecision(
        scope: PermissionScope,
        mode: PermissionMode
    ) -> PermissionDecision? {
        switch mode {
        case .askForEverything:
            return nil
        case .askForWrites:
            return scope == .read ? .approvedOnce : nil
        case .autonomous:
            return .approvedOnce
        }
    }

    /// Whether choosing "Always allow" should escalate the session's mode.
    public static func modeAfter(decision: PermissionDecision, current: PermissionMode) -> PermissionMode {
        guard case .approvedAlways = decision else { return current }
        switch current {
        case .askForEverything: return .askForWrites
        case .askForWrites, .autonomous: return .autonomous
        }
    }
}
