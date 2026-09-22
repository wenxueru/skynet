import Foundation

/// A provider describes *what* agent implementation Skynet drives: the Codex
/// CLI, the Claude Code CLI, or any Claude-Code-compatible wrapper the user
/// configures.
///
/// Providers are pure configuration values. They are safely persistable and
/// safely shareable between the macOS and iOS apps via the app group store.
/// *Where* a provider runs (locally, over SSH, or through a paired Mac relay)
/// is a separate concern owned by `ExecutionBackend`.
public struct AgentProviderDescriptor: Codable, Hashable, Sendable {
    /// The protocol family a provider speaks.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The Codex CLI.
        case codex
        /// The Claude Code CLI.
        case claudeCode = "claude-code"
        /// A user-configured wrapper that is wire-compatible with the Claude
        /// Code CLI (`--input-format stream-json --output-format
        /// stream-json`). SkynetCore ships no built-in instances of this
        /// kind; users name and configure their own.
        case claudeCodeCompatible = "claude-code-compatible"

        /// The executable name used when a descriptor does not specify one.
        public var defaultExecutableName: String {
            switch self {
            case .codex: return "codex"
            case .claudeCode, .claudeCodeCompatible: return "claude"
            }
        }

        public var displayName: String {
            switch self {
            case .codex: return "Codex"
            case .claudeCode: return "Claude Code"
            case .claudeCodeCompatible: return "Claude Code-compatible wrapper"
            }
        }
    }

    public var id: ProviderID
    public var kind: Kind
    /// Human-facing name shown in the UI. Never empty (validated).
    public var displayName: String
    /// The CLI to launch. `nil` means "resolve `kind.defaultExecutableName`
    /// on the backend's PATH". Never `nil` for `.claudeCodeCompatible`.
    public var executable: String?
    /// Extra arguments inserted before the adapter-generated arguments.
    public var defaultArguments: [String]
    /// Extra environment variables for the child process.
    public var environment: [String: String]
    /// Model to select when the user has not chosen one.
    public var defaultModelID: ModelID?
    /// When set, replaces the built-in model catalog snapshot for this
    /// provider (used by wrappers that expose a different model lineup).
    public var models: [ModelDescriptor]?
    /// Free-form user notes.
    public var notes: String?

    public init(
        id: ProviderID,
        kind: Kind,
        displayName: String,
        executable: String? = nil,
        defaultArguments: [String] = [],
        environment: [String: String] = [:],
        defaultModelID: ModelID? = nil,
        models: [ModelDescriptor]? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.executable = executable
        self.defaultArguments = defaultArguments
        self.environment = environment
        self.defaultModelID = defaultModelID
        self.models = models
        self.notes = notes
    }

    /// The executable this descriptor resolves to.
    public var resolvedExecutableName: String? {
        executable ?? kind.defaultExecutableName
    }

    /// The model catalog to use: the provider's override, or the built-in
    /// snapshot for its kind.
    public var resolvedModelCatalog: ModelCatalog {
        if let models, !models.isEmpty {
            return ModelCatalog(models: models, defaultModelID: defaultModelID)
        }
        var catalog = ModelCatalog.builtInSnapshot(for: kind)
        catalog.defaultModelID = defaultModelID ?? catalog.defaultModelID
        return catalog
    }

    // MARK: - Codable (stable keys)

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName
        case executable
        case defaultArguments
        case environment
        case defaultModelID
        case models
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        executable = try container.decodeIfPresent(String.self, forKey: .executable)
        defaultArguments =
            try container.decodeIfPresent([String].self, forKey: .defaultArguments) ?? []
        environment =
            try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        defaultModelID = try container.decodeIfPresent(ModelID.self, forKey: .defaultModelID)
        models = try container.decodeIfPresent([ModelDescriptor].self, forKey: .models)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

// MARK: - Validation

extension AgentProviderDescriptor {
    /// Validates a provider configuration, returning a human-readable
    /// problem description or `nil` when the configuration is sound.
    ///
    /// Rules:
    /// - Identifiers and display names must be non-empty.
    /// - The built-in identifiers (`codex`, `claude-code`) may only be used
    ///   with their matching kind.
    /// - `.claudeCodeCompatible` wrappers must declare their own executable;
    ///   they may not silently resolve to the stock `claude` binary.
    /// - Environment keys must be non-empty and must not contain `=`.
    public func validationProblem() -> String? {
        if id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Provider id must not be empty."
        }
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Provider display name must not be empty."
        }
        if id == .codex, kind != .codex {
            return "The provider id \"codex\" is reserved for the built-in Codex provider."
        }
        if id == .claudeCode, kind != .claudeCode {
            return "The provider id \"claude-code\" is reserved for the built-in Claude Code provider."
        }
        if kind == .claudeCodeCompatible {
            guard let executable, !executable.isEmpty else {
                return
                    "Claude-Code-compatible wrappers must declare the executable of the wrapper to launch."
            }
            if executable.hasPrefix("-") {
                return "The executable \(executable) looks like a command-line flag."
            }
        }
        if let executable, executable.hasPrefix("-") {
            return "The executable \(executable) looks like a command-line flag."
        }
        for (key, _) in environment where key.isEmpty || key.contains("=") {
            return "Environment variable name \"\(key)\" is invalid."
        }
        if let models, models.isEmpty {
            return "An explicit model list may not be empty; remove it to use the built-in catalog."
        }
        return nil
    }

    /// Throws `SkynetError.invalidProviderConfiguration` when invalid.
    public func validate() throws {
        if let problem = validationProblem() {
            throw SkynetError.invalidProviderConfiguration(detail: problem)
        }
    }
}
