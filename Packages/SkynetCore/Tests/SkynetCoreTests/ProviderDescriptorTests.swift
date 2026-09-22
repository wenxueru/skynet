import Foundation
import SkynetCore
import Testing

@Suite("Agent provider descriptors")
struct AgentProviderDescriptorTests {
    @Test func builtInsAreValid() throws {
        for provider in AgentProviderDescriptor.builtIns {
            #expect(provider.validationProblem() == nil)
            try provider.validate()
        }
        #expect(AgentProviderDescriptor.builtIns.map(\.id) == [.codex, .claudeCode])
    }

    @Test func builtInDefaultExecutables() {
        #expect(AgentProviderDescriptor.codex.resolvedExecutableName == "codex")
        #expect(AgentProviderDescriptor.claudeCode.resolvedExecutableName == "claude")
    }

    @Test func validationRejectsEmptyIdentifiers() {
        let emptyID = AgentProviderDescriptor(
            id: ProviderID("  "),
            kind: .codex,
            displayName: "Codex"
        )
        #expect(emptyID.validationProblem()?.contains("id") == true)

        let emptyName = AgentProviderDescriptor(
            id: ProviderID("x"),
            kind: .codex,
            displayName: ""
        )
        #expect(emptyName.validationProblem()?.contains("display name") == true)
    }

    @Test func validationGuardsReservedIdentifiers() {
        let codexImpostor = AgentProviderDescriptor(
            id: .codex,
            kind: .claudeCode,
            displayName: "Not Codex"
        )
        #expect(codexImpostor.validationProblem()?.contains("reserved") == true)

        let claudeImpostor = AgentProviderDescriptor(
            id: .claudeCode,
            kind: .claudeCodeCompatible,
            displayName: "Not Claude Code"
        )
        #expect(claudeImpostor.validationProblem()?.contains("reserved") == true)
    }

    @Test func claudeCompatibleWrappersNeedAnExecutable() {
        let noExecutable = AgentProviderDescriptor(
            id: ProviderID("my-wrapper"),
            kind: .claudeCodeCompatible,
            displayName: "My Wrapper"
        )
        #expect(
            noExecutable.validationProblem()?.contains("executable") == true
        )

        let flagExecutable = AgentProviderDescriptor(
            id: ProviderID("my-wrapper"),
            kind: .claudeCodeCompatible,
            displayName: "My Wrapper",
            executable: "--pretend"
        )
        #expect(flagExecutable.validationProblem()?.contains("flag") == true)

        let good = AgentProviderDescriptor(
            id: ProviderID("my-wrapper"),
            kind: .claudeCodeCompatible,
            displayName: "My Wrapper",
            executable: "/opt/tools/my-claude"
        )
        #expect(good.validationProblem() == nil)
    }

    @Test func validationRejectsBrokenEnvironmentKeys() {
        let bad = AgentProviderDescriptor(
            id: ProviderID("p"),
            kind: .codex,
            displayName: "P",
            environment: ["": "x"]
        )
        #expect(bad.validationProblem()?.contains("Environment") == true)

        let alsoBad = AgentProviderDescriptor(
            id: ProviderID("p"),
            kind: .codex,
            displayName: "P",
            environment: ["A=B": "x"]
        )
        #expect(alsoBad.validationProblem()?.contains("Environment") == true)
    }

    @Test func explicitModelListMayNotBeEmpty() {
        let emptyModels = AgentProviderDescriptor(
            id: ProviderID("p"),
            kind: .codex,
            displayName: "P",
            models: []
        )
        #expect(emptyModels.validationProblem()?.contains("model list") == true)
    }

    @Test func decodesLeniently() throws {
        // Old files (or hand-edited ones) may omit newer keys entirely.
        let json = """
        {"id":"codex","kind":"codex","displayName":"Codex"}
        """
        let provider = try JSONDecoder().decode(
            AgentProviderDescriptor.self,
            from: Data(json.utf8)
        )
        #expect(provider.defaultArguments.isEmpty)
        #expect(provider.environment.isEmpty)
        #expect(provider.models == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        let original = AgentProviderDescriptor(
            id: ProviderID("my-wrapper"),
            kind: .claudeCodeCompatible,
            displayName: "My Wrapper",
            executable: "/opt/wrapper",
            defaultArguments: ["--verbose"],
            environment: ["WRAPPER_ENV": "1"],
            defaultModelID: ModelID("claude-sonnet-5"),
            models: [ModelDescriptor(id: ModelID("m1"), displayName: "M1")],
            notes: "internal wrapper"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentProviderDescriptor.self, from: data)
        #expect(decoded == original)
    }

    @Test func resolvedModelCatalogPrefersExplicitModels() {
        let wrapper = AgentProviderDescriptor(
            id: ProviderID("w"),
            kind: .claudeCodeCompatible,
            displayName: "W",
            executable: "/opt/w",
            defaultModelID: ModelID("only-one"),
            models: [ModelDescriptor(id: ModelID("only-one"), displayName: "Only One")]
        )
        let catalog = wrapper.resolvedModelCatalog
        #expect(catalog.models.map(\.id.rawValue) == ["only-one"])
        #expect(catalog.defaultModelID == ModelID("only-one"))

        let plain = AgentProviderDescriptor.claudeCode
        #expect(plain.resolvedModelCatalog == ModelCatalog.claudeCodeSnapshot)

        let defaultOverride = AgentProviderDescriptor(
            id: ProviderID("codex"),
            kind: .codex,
            displayName: "Codex",
            defaultModelID: ModelID("gpt-5")
        )
        #expect(
            defaultOverride.resolvedModelCatalog.defaultModelID == ModelID("gpt-5")
        )
    }
}

@Suite("Provider catalog merge")
struct ProviderCatalogTests {
    @Test func builtInsOnlyWhenNothingConfigured() throws {
        let catalog = try ProviderCatalog.effective(userConfigured: [])
        #expect(catalog.providers.map(\.id) == [.codex, .claudeCode])
        #expect(catalog.provider(with: .codex)?.kind == .codex)
    }

    @Test func userConfigurationOverridesBuiltInWithSameID() throws {
        let customCodex = AgentProviderDescriptor(
            id: .codex,
            kind: .codex,
            displayName: "Codex (custom build)",
            executable: "/opt/codex/codex"
        )
        let catalog = try ProviderCatalog.effective(userConfigured: [customCodex])
        #expect(catalog.providers.count == 2)
        #expect(catalog.provider(with: .codex)?.executable == "/opt/codex/codex")
    }

    @Test func userConfigurationAppendsNewProviders() throws {
        let wrapper = AgentProviderDescriptor(
            id: ProviderID("team-wrapper"),
            kind: .claudeCodeCompatible,
            displayName: "Team Wrapper",
            executable: "/opt/team/agent"
        )
        let catalog = try ProviderCatalog.effective(userConfigured: [wrapper])
        #expect(catalog.providers.map(\.id) == [.codex, .claudeCode, ProviderID("team-wrapper")])
    }

    @Test func invalidUserConfigurationThrows() {
        let broken = AgentProviderDescriptor(
            id: ProviderID("broken"),
            kind: .claudeCodeCompatible,
            displayName: "No executable"
        )
        #expect(throws: SkynetError.self) {
            _ = try ProviderCatalog.effective(userConfigured: [broken])
        }
    }

    @Test func duplicateUserIDsThrow() {
        let first = AgentProviderDescriptor(
            id: ProviderID("dupe"),
            kind: .claudeCodeCompatible,
            displayName: "One",
            executable: "/bin/one"
        )
        let second = AgentProviderDescriptor(
            id: ProviderID("dupe"),
            kind: .claudeCodeCompatible,
            displayName: "Two",
            executable: "/bin/two"
        )
        #expect(throws: SkynetError.self) {
            _ = try ProviderCatalog.effective(userConfigured: [first, second])
        }
    }

    @Test func overridingTheSameBuiltInTwiceIsAllowed() throws {
        // Later configuration wins, like a settings file being re-applied.
        let a = AgentProviderDescriptor(
            id: .codex, kind: .codex, displayName: "A", executable: "/a"
        )
        let b = AgentProviderDescriptor(
            id: .codex, kind: .codex, displayName: "B", executable: "/b"
        )
        let catalog = try ProviderCatalog.effective(userConfigured: [a, b])
        #expect(catalog.provider(with: .codex)?.displayName == "B")
    }

    @Test func noHardcodedWrapperBrands() throws {
        // The whole point of claudeCodeCompatible: wrappers come from
        // configuration only, and the built-ins must never smuggle in a
        // specific product's name.
        let catalog = try ProviderCatalog.effective(userConfigured: [])
        for provider in catalog.providers {
            let text = provider.displayName + (provider.notes ?? "")
            #expect(!text.lowercased().contains("codewiz"))
            #expect(!text.lowercased().contains("hiwork"))
        }
    }
}
