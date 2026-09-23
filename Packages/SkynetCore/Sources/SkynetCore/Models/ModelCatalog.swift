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
    case ultra

    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Maximum"
        case .ultra: return "Ultra"
        }
    }
}

/// One selectable model exposed by a provider.
///
/// Descriptors are suggestions, not live availability facts. The macOS app
/// reads Codex availability from its local CLI cache; providers can replace
/// the suggestions by setting `AgentProviderDescriptor.models`. Never treat a
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
    /// Explicit suggested default. `nil` leaves model selection to the CLI.
    public var defaultModelID: ModelID?

    public init(models: [ModelDescriptor] = [], defaultModelID: ModelID? = nil) {
        self.models = models
        self.defaultModelID = defaultModelID
    }

    public func model(with id: ModelID) -> ModelDescriptor? {
        models.first { $0.id == id }
    }

    /// The explicitly configured default, if present in this catalog.
    public var resolvedDefaultModel: ModelDescriptor? {
        if let defaultModelID, let model = model(with: defaultModelID) {
            return model
        }
        return nil
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

    /// Stable built-in suggestions; versioned availability is discovered by
    /// the app or supplied through a provider override.
    public static func builtInSnapshot(for kind: AgentProviderDescriptor.Kind) -> ModelCatalog {
        switch kind {
        case .codex:
            return codexSnapshot
        case .claudeCode:
            return claudeCodeSnapshot
        case .claudeCodeCompatible:
            return ModelCatalog()
        }
    }

    /// CLI aliases remain stable while versioned model IDs change frequently.
    /// An unset model lets Claude Code choose its own default.
    public static let claudeCodeSnapshot = ModelCatalog(models: [
        ModelDescriptor(id: ModelID("fable"), displayName: "Fable", supportedEfforts: [.low, .medium, .high, .xhigh, .max]),
        ModelDescriptor(id: ModelID("opus"), displayName: "Opus", supportedEfforts: [.low, .medium, .high, .xhigh, .max]),
        ModelDescriptor(id: ModelID("sonnet"), displayName: "Sonnet", supportedEfforts: [.low, .medium, .high, .xhigh, .max]),
        ModelDescriptor(id: ModelID("haiku"), displayName: "Haiku"),
    ])

    /// Codex availability is account- and machine-specific; the macOS app
    /// reads the installed CLI's cache instead of publishing guessed IDs.
    public static let codexSnapshot = ModelCatalog()
}
