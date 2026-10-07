import SkynetCore

enum ProviderModelDiscovery {
    struct Catalog: Sendable {
        var models: [ModelDescriptor] = []
        var defaultEfforts: [ModelID: ReasoningEffort] = [:]
        var error: String?
    }

    static func models(for provider: AgentProviderDescriptor?, backend: any ExecutionBackend,
                       workingDirectory: String?) async -> Catalog {
        guard let provider else { return Catalog() }
        if let configured = provider.models { return Catalog(models: configured) }
        switch provider.kind {
        case .codex:
            do {
                let catalog = try await CodexModelDiscovery.load(provider: provider, backend: backend,
                                                                  workingDirectory: workingDirectory)
                return Catalog(models: catalog.models, defaultEfforts: catalog.defaultEfforts)
            } catch {
                return Catalog(error: "Model discovery failed: \(error.localizedDescription)")
            }
        case .claudeCode:
            return Catalog(models: ModelCatalog.claudeCodeSnapshot.models)
        case .claudeCodeCompatible:
            return Catalog()
        }
    }
}

