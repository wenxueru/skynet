import Foundation

/// Queries the executable/account used for execution, never another CLI's cache.
public enum CodexModelDiscovery {
    public struct Catalog: Sendable {
        public var models: [ModelDescriptor] = []
        public var defaultEfforts: [ModelID: ReasoningEffort] = [:]
        public var defaultModelID: ModelID?
    }

    public static func load(provider: AgentProviderDescriptor, backend: any ExecutionBackend,
                            workingDirectory: String? = nil,
                            timeout: Duration = .seconds(15)) async throws -> Catalog {
        var catalog = Catalog()
        var cursor: String?
        var cursors: Set<String> = []
        var ids: Set<ModelID> = []
        repeat {
            try Task.checkCancellation()
            let page = try await CodexAppServerRPC.perform(
                request: CodexAppServerBridge.modelListRequest(cursor: cursor),
                operation: "list models", contextID: "catalog", backend: backend,
                executable: provider.executable ?? "codex", environment: provider.environment,
                timeout: timeout, defaultArguments: provider.defaultArguments,
                workingDirectory: workingDirectory)
            guard let entries = page["data"]?.arrayValue else {
                throw SkynetError.executionFailed(reason: "Codex model list returned no data")
            }
            for entry in entries {
                guard entry["hidden"]?.boolValue != true,
                      let model = entry["model"]?.stringValue ?? entry["id"]?.stringValue,
                      !model.isEmpty else { continue }
                let id = ModelID(model)
                guard ids.insert(id).inserted else { continue }
                catalog.models.append(ModelDescriptor(
                    id: id, displayName: entry["displayName"]?.stringValue ?? model,
                    supportedEfforts: (entry["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
                        $0["reasoningEffort"]?.stringValue.flatMap(ReasoningEffort.init(rawValue:))
                    },
                    supportsVision: entry["inputModalities"]?.arrayValue.map {
                        $0.contains(.string("image"))
                    } ?? true,
                    contextWindowTokens: entry["contextWindow"]?.intValue))
                if let effort = entry["defaultReasoningEffort"]?.stringValue.flatMap(ReasoningEffort.init(rawValue:)) {
                    catalog.defaultEfforts[id] = effort
                }
                if entry["isDefault"]?.boolValue == true { catalog.defaultModelID = id }
            }
            cursor = page["nextCursor"]?.stringValue
            if let cursor, !cursors.insert(cursor).inserted || cursors.count > 100 {
                throw SkynetError.executionFailed(reason: "Codex model list returned invalid pagination")
            }
        } while cursor != nil
        return catalog
    }
}
