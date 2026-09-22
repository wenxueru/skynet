import Foundation

/// How much reasoning a model is allowed to perform before answering.
///
/// The levels form one shared vocabulary across providers. Not every model
/// supports every level — a model's descriptor lists the levels it accepts,
/// and the adapters translate the shared level into the provider's own
/// spelling on the command line.
public enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Hashable {
    /// Think as little as the provider allows. Codex-only.
    case minimal
    case low
    case medium
    case high
    /// Between `high` and `max`. Claude models from Opus 4.7 onward.
    case xhigh
    case max

    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Maximum"
        }
    }
}

/// One selectable model exposed by a provider.
///
/// Descriptors are *snapshot data*, not live facts: SkynetCore ships a
/// conservative built-in snapshot per provider kind and users can replace it
/// wholesale by setting `AgentProviderDescriptor.models`. Never treat a
/// missing field as an error — decode leniently and let the UI degrade
/// gracefully.
public struct ModelDescriptor: Codable, Hashable, Sendable {
    public var id: ModelID
    public var displayName: String
    /// Loose grouping for UI sectioning ("opus", "sonnet", "gpt-5.1", …).
    public var family: String?
    /// Effort levels this model accepts, in ascending order.
    public var supportedEfforts: [ReasoningEffort]
    public var supportsVision: Bool
    public var contextWindowTokens: Int?
    public var maxOutputTokens: Int?
    public var notes: String?

    public init(
        id: ModelID,
        displayName: String,
        family: String? = nil,
        supportedEfforts: [ReasoningEffort] = [],
        supportsVision: Bool = false,
        contextWindowTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.supportedEfforts = supportedEfforts
        self.supportsVision = supportsVision
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
        self.notes = notes
    }

    /// The effort to offer when the user has not chosen one.
    public var defaultEffort: ReasoningEffort? {
        supportedEfforts.last
    }

    public func supports(_ effort: ReasoningEffort) -> Bool {
        supportedEfforts.contains(effort)
    }

    // MARK: - Codable (lenient decode; stable keys)

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case family
        case supportedEfforts
        case supportsVision
        case contextWindowTokens
        case maxOutputTokens
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ModelID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        family = try container.decodeIfPresent(String.self, forKey: .family)
        supportedEfforts =
            try container.decodeIfPresent([ReasoningEffort].self, forKey: .supportedEfforts) ?? []
        supportsVision =
            try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
        contextWindowTokens =
            try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
        maxOutputTokens =
            try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// The set of models a provider offers, plus which one to pick by default.
public struct ModelCatalog: Codable, Hashable, Sendable {
    public var models: [ModelDescriptor]
    /// The model selected when the user has not chosen one. `nil` means the
    /// first entry of `models` (or whatever the provider CLI defaults to).
    public var defaultModelID: ModelID?

    public init(models: [ModelDescriptor] = [], defaultModelID: ModelID? = nil) {
        self.models = models
        self.defaultModelID = defaultModelID
    }

    public func model(with id: ModelID) -> ModelDescriptor? {
        models.first { $0.id == id }
    }

    /// The model a new session should use: the explicit default if it is
    /// actually present, otherwise the first entry.
    public var resolvedDefaultModel: ModelDescriptor? {
        if let defaultModelID, let model = model(with: defaultModelID) {
            return model
        }
        return models.first
    }

    /// Upserts a descriptor, preserving order for updates and appending
    /// otherwise.
    public func replacingModel(_ descriptor: ModelDescriptor) -> ModelCatalog {
        var catalog = self
        if let index = catalog.models.firstIndex(where: { $0.id == descriptor.id }) {
            catalog.models[index] = descriptor
        } else {
            catalog.models.append(descriptor)
        }
        return catalog
    }

    // MARK: - Built-in snapshots

    /// The built-in model snapshot for a provider kind.
    ///
    /// These are deliberately conservative: they list stable, widely
    /// available model identifiers and can be replaced at any time by a
    /// provider's `models` override — SkynetCore never queries the network
    /// to refresh them.
    public static func builtInSnapshot(for kind: AgentProviderDescriptor.Kind) -> ModelCatalog {
        switch kind {
        case .codex:
            return codexSnapshot
        case .claudeCode, .claudeCodeCompatible:
            return claudeCodeSnapshot
        }
    }

    /// Claude models known to the Claude Code CLI.
    ///
    /// Snapshotted 2026-09; a user who needs newer (or older) model strings
    /// sets them on the provider descriptor instead of waiting for an app
    /// update.
    public static let claudeCodeSnapshot = ModelCatalog(
        models: [
            ModelDescriptor(
                id: ModelID("claude-fable-5"),
                displayName: "Claude Fable 5",
                family: "fable",
                supportedEfforts: [.low, .medium, .high, .xhigh, .max],
                supportsVision: true,
                contextWindowTokens: 1_000_000,
                maxOutputTokens: 128_000,
                notes: "Most capable; thinking is always on."
            ),
            ModelDescriptor(
                id: ModelID("claude-opus-4-8"),
                displayName: "Claude Opus 4.8",
                family: "opus",
                supportedEfforts: [.low, .medium, .high, .xhigh, .max],
                supportsVision: true,
                contextWindowTokens: 1_000_000,
                maxOutputTokens: 128_000
            ),
            ModelDescriptor(
                id: ModelID("claude-opus-4-7"),
                displayName: "Claude Opus 4.7",
                family: "opus",
                supportedEfforts: [.low, .medium, .high, .xhigh, .max],
                supportsVision: true,
                contextWindowTokens: 1_000_000,
                maxOutputTokens: 128_000
            ),
            ModelDescriptor(
                id: ModelID("claude-opus-4-6"),
                displayName: "Claude Opus 4.6",
                family: "opus",
                supportedEfforts: [.low, .medium, .high, .max],
                supportsVision: true,
                contextWindowTokens: 1_000_000,
                maxOutputTokens: 128_000
            ),
            ModelDescriptor(
                id: ModelID("claude-sonnet-5"),
                displayName: "Claude Sonnet 5",
                family: "sonnet",
                supportedEfforts: [.low, .medium, .high, .xhigh, .max],
                supportsVision: true,
                contextWindowTokens: 1_000_000,
                maxOutputTokens: 128_000
            ),
            ModelDescriptor(
                id: ModelID("claude-sonnet-4-6"),
                displayName: "Claude Sonnet 4.6",
                family: "sonnet",
                supportedEfforts: [.low, .medium, .high, .max],
                supportsVision: true,
                contextWindowTokens: 1_000_000,
                maxOutputTokens: 128_000
            ),
            ModelDescriptor(
                id: ModelID("claude-haiku-4-5"),
                displayName: "Claude Haiku 4.5",
                family: "haiku",
                supportedEfforts: [.low, .medium, .high],
                supportsVision: true,
                contextWindowTokens: 200_000,
                maxOutputTokens: 64_000,
                notes: "Fastest and cheapest."
            ),
        ],
        defaultModelID: ModelID("claude-opus-4-8")
    )

    /// Models known to the Codex CLI.
    ///
    /// Deliberately minimal — Codex model names churn quickly, so the
    /// snapshot sticks to stable identifiers and users can override the
    /// list on the provider descriptor.
    public static let codexSnapshot = ModelCatalog(
        models: [
            ModelDescriptor(
                id: ModelID("gpt-5.1-codex"),
                displayName: "GPT-5.1 Codex",
                family: "gpt-5.1",
                supportedEfforts: [.minimal, .low, .medium, .high],
                supportsVision: true,
                contextWindowTokens: 400_000,
                maxOutputTokens: 128_000,
                notes: "Default Codex coding model."
            ),
            ModelDescriptor(
                id: ModelID("gpt-5.1"),
                displayName: "GPT-5.1",
                family: "gpt-5.1",
                supportedEfforts: [.minimal, .low, .medium, .high],
                supportsVision: true,
                contextWindowTokens: 400_000,
                maxOutputTokens: 128_000
            ),
            ModelDescriptor(
                id: ModelID("gpt-5-codex"),
                displayName: "GPT-5 Codex",
                family: "gpt-5",
                supportedEfforts: [.minimal, .low, .medium, .high],
                supportsVision: true,
                contextWindowTokens: 400_000,
                maxOutputTokens: 128_000
            ),
            ModelDescriptor(
                id: ModelID("gpt-5"),
                displayName: "GPT-5",
                family: "gpt-5",
                supportedEfforts: [.minimal, .low, .medium, .high],
                supportsVision: true,
                contextWindowTokens: 400_000,
                maxOutputTokens: 128_000
            ),
        ],
        defaultModelID: ModelID("gpt-5.1-codex")
    )
}
