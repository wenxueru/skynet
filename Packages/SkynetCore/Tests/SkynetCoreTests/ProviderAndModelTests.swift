import Foundation
import SkynetCore
import Testing

@Suite("Permission policy")
struct PermissionPolicyTests {
    let read = PermissionRule(effect: .allow, toolPattern: "Read")
    let gitCommands = PermissionRule(
        effect: .allow,
        toolPattern: "Bash",
        argumentPattern: "git *"
    )
    let denyRm = PermissionRule(
        effect: .deny,
        toolPattern: "Bash",
        argumentPattern: "rm *"
    )
    let denyAllBash = PermissionRule(effect: .deny, toolPattern: "Bash")

    @Test func firstMatchWins() {
        let policy = PermissionPolicy(
            rules: [denyRm, gitCommands],
            defaultEffect: .ask
        )
        #expect(policy.evaluate(toolName: "Bash", primaryArgument: "git status") == .allow)
        #expect(policy.evaluate(toolName: "Bash", primaryArgument: "rm -rf /") == .deny)
        // The allow rule requires a git-prefixed argument; a bare "git"
        // matches neither and falls through to the default.
        #expect(policy.evaluate(toolName: "Bash", primaryArgument: "git") == .ask)
    }

    @Test func ruleWithoutArgumentPatternIgnoresTheArgument() {
        let policy = PermissionPolicy(rules: [denyAllBash], defaultEffect: .allow)
        #expect(policy.evaluate(toolName: "Bash", primaryArgument: "anything") == .deny)
        #expect(policy.evaluate(toolName: "Read") == .allow)
    }

    @Test func argumentPatternRequiresAnArgument() {
        let policy = PermissionPolicy(rules: [gitCommands], defaultEffect: .deny)
        #expect(policy.evaluate(toolName: "Bash", primaryArgument: nil) == .deny)
        #expect(policy.evaluate(toolName: "Bash", primaryArgument: "git push") == .allow)
    }

    @Test func defaultEffectAppliesWhenNothingMatches() {
        let askAll = PermissionPolicy.askEverything
        #expect(askAll.evaluate(toolName: "Bash") == .ask)
        #expect(askAll.evaluate(toolName: "Read") == .ask)

        let allowAll = PermissionPolicy(rules: [], defaultEffect: .allow)
        #expect(allowAll.evaluate(toolName: "Bash") == .allow)
    }

    @Test func evaluatesToolCallsThroughPrimaryArgument() {
        let policy = PermissionPolicy(rules: [read], defaultEffect: .deny)
        let readCall = ToolCall(
            id: ToolCallID("t1"),
            name: "Read",
            input: ["file_path": "/etc/passwd"]
        )
        let writeCall = ToolCall(
            id: ToolCallID("t2"),
            name: "Write",
            input: ["file_path": "/tmp/x"]
        )
        #expect(policy.evaluate(call: readCall) == .allow)
        #expect(policy.evaluate(call: writeCall) == .deny)
    }

    @Test func primaryArgumentExtractsKnownToolFields() {
        #expect(
            PermissionPolicy.primaryArgument(
                of: ToolCall(id: ToolCallID("a"), name: "Bash", input: ["command": "ls"])
            ) == "ls"
        )
        #expect(
            PermissionPolicy.primaryArgument(
                of: ToolCall(id: ToolCallID("b"), name: "Edit", input: ["file_path": "/a/b.swift"])
            ) == "/a/b.swift"
        )
        #expect(
            PermissionPolicy.primaryArgument(
                of: ToolCall(id: ToolCallID("c"), name: "WebFetch", input: ["url": "https://x.y"])
            ) == "https://x.y"
        )
        #expect(
            PermissionPolicy.primaryArgument(
                of: ToolCall(id: ToolCallID("d"), name: "Custom", input: ["path": "/p"])
            ) == "/p"
        )
        #expect(
            PermissionPolicy.primaryArgument(
                of: ToolCall(id: ToolCallID("e"), name: "Custom", input: .null)
            ) == nil
        )
    }

    @Test func patternStringsComposeToolAndArgumentPatterns() {
        let policy = PermissionPolicy(rules: [read, gitCommands, denyRm])
        #expect(policy.patternStrings(effect: .allow) == ["Read", "Bash(git *)"])
        #expect(policy.patternStrings(effect: .deny) == ["Bash(rm *)"])
        #expect(policy.patternStrings(effect: .ask).isEmpty)
    }

    @Test func decodesFromJSONLeniently() throws {
        let json = """
        {"rules":[{"effect":"allow","toolPattern":"Read"},{"effect":"deny","toolPattern":"Bash","argumentPattern":"rm *"}],"defaultEffect":"deny"}
        """
        let policy = try JSONDecoder().decode(PermissionPolicy.self, from: Data(json.utf8))
        #expect(policy.rules.count == 2)
        #expect(policy.defaultEffect == .deny)
        #expect(policy.evaluate(toolName: "Bash", primaryArgument: "rm x") == .deny)
    }
}

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test func claudeSnapshotListsCurrentModels() {
        let catalog = ModelCatalog.claudeCodeSnapshot
        let ids = catalog.models.map(\.id.rawValue)
        #expect(ids == ["fable", "opus", "sonnet", "haiku"])
        #expect(catalog.resolvedDefaultModel == nil)
    }

    @Test func codexSnapshotIsConservative() {
        let catalog = ModelCatalog.codexSnapshot
        let ids = catalog.models.map(\.id.rawValue)
        #expect(ids.isEmpty)
        #expect(catalog.resolvedDefaultModel == nil)
    }

    @Test func effortsAreOrderedAscending() {
        for catalog in [ModelCatalog.claudeCodeSnapshot, ModelCatalog.codexSnapshot] {
            for model in catalog.models {
                let ranks = model.supportedEfforts.map { ReasoningEffort.allCases.firstIndex(of: $0)! }
                #expect(ranks == ranks.sorted(), "efforts of \(model.id) must ascend")
            }
        }
    }

    @Test func builtInSnapshotDispatchesByKind() {
        #expect(ModelCatalog.builtInSnapshot(for: .codex) == ModelCatalog.codexSnapshot)
        #expect(ModelCatalog.builtInSnapshot(for: .claudeCode) == ModelCatalog.claudeCodeSnapshot)
        #expect(
            ModelCatalog.builtInSnapshot(for: .claudeCodeCompatible)
                == ModelCatalog()
        )
    }

    @Test func descriptorDecodesWithDefaults() throws {
        let json = #"{"id":"custom-model","displayName":"Custom"}"#
        let model = try JSONDecoder().decode(
            ModelDescriptor.self,
            from: Data(json.utf8)
        )
        #expect(model.supportedEfforts.isEmpty)
        #expect(!model.supportsVision)
        #expect(model.contextWindowTokens == nil)
    }

    @Test func replacingModelUpserts() {
        var catalog = ModelCatalog.codexSnapshot
        let tweaked = ModelDescriptor(
            id: ModelID("gpt-5.1"),
            displayName: "GPT-5.1 (tweaked)",
            supportedEfforts: [.low]
        )
        catalog = catalog.replacingModel(tweaked)
        #expect(catalog.models.count == 1)
        #expect(catalog.model(with: ModelID("gpt-5.1"))?.displayName == "GPT-5.1 (tweaked)")

        catalog = catalog.replacingModel(
            ModelDescriptor(id: ModelID("brand-new"), displayName: "Brand new")
        )
        #expect(catalog.models.count == 2)
        #expect(catalog.model(with: ModelID("brand-new")) != nil)
    }

    @Test func missingDefaultDefersToProvider() {
        let catalog = ModelCatalog(
            models: [ModelDescriptor(id: ModelID("only"), displayName: "Only")],
            defaultModelID: ModelID("missing")
        )
        #expect(catalog.resolvedDefaultModel == nil)
    }
}
