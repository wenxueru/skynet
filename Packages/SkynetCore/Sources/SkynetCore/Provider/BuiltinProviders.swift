import Foundation

// MARK: - Built-in provider descriptors

extension AgentProviderDescriptor {
    /// The built-in Codex provider. Resolves to the `codex` executable on
    /// the backend's PATH.
    public static let codex = AgentProviderDescriptor(
        id: ProviderID.codex,
        kind: .codex,
        displayName: "Codex",
        notes: "The Codex CLI. Launches the `codex` executable found on the backend's PATH."
    )

    /// The built-in Claude Code provider. Resolves to the `claude`
    /// executable on the backend's PATH.
    public static let claudeCode = AgentProviderDescriptor(
        id: ProviderID.claudeCode,
        kind: .claudeCode,
        displayName: "Claude Code",
        notes: "The Claude Code CLI. Launches the `claude` executable found on the backend's PATH."
    )

    /// All providers SkynetCore ships knowledge of.
    public static let builtIns: [AgentProviderDescriptor] = [.codex, .claudeCode]
}

// MARK: - Effective catalog (built-ins + user configuration)

/// Merges built-in providers with the user's configured ones.
///
/// Merge rules:
/// - A user configuration whose id matches a built-in *replaces* it. This is
///   how users point the built-in "codex"/"claude-code" entries at custom
///   executables or model lineups without losing the built-in defaults.
/// - A user configuration with a fresh id is appended (this is the only way
///   Claude-Code-compatible wrappers come into existence — nothing in
///   SkynetCore hardcodes any specific wrapper).
/// - Every resulting provider must validate; invalid entries throw.
public struct ProviderCatalog: Sendable {
    public private(set) var providers: [AgentProviderDescriptor]

    public init(providers: [AgentProviderDescriptor]) {
        self.providers = providers
    }

    /// The effective catalog: `builtIns` overridden/extended by
    /// `userConfigured`.
    ///
    /// - Throws: `SkynetError.invalidProviderConfiguration` when a user
    ///   configuration is invalid, and when two user configurations share an
    ///   id.
    public static func effective(userConfigured: [AgentProviderDescriptor]) throws
        -> ProviderCatalog
    {
        var byID: [ProviderID: AgentProviderDescriptor] = [:]
        var order: [ProviderID] = []
        for provider in AgentProviderDescriptor.builtIns {
            byID[provider.id] = provider
            order.append(provider.id)
        }
        for provider in userConfigured {
            try provider.validate()
            let overridesBuiltin = AgentProviderDescriptor.builtIns
                .contains { $0.id == provider.id }
            if byID[provider.id] != nil, !overridesBuiltin {
                throw SkynetError.invalidProviderConfiguration(
                    detail: "Two user-configured providers share the id \"\(provider.id)\"."
                )
            }
            if byID[provider.id] == nil {
                order.append(provider.id)
            }
            byID[provider.id] = provider
        }
        return ProviderCatalog(providers: order.compactMap { byID[$0] })
    }

    public func provider(with id: ProviderID) -> AgentProviderDescriptor? {
        providers.first { $0.id == id }
    }

    public subscript(id: ProviderID) -> AgentProviderDescriptor? {
        provider(with: id)
    }
}
