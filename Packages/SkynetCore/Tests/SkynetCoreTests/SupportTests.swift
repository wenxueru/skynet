import Foundation
import SkynetCore
import Testing

@Suite("Glob")
struct GlobTests {
    @Test func exactMatch() {
        #expect(Glob.matches("Bash", value: "Bash"))
        #expect(!Glob.matches("Bash", value: "bash"))
        #expect(!Glob.matches("Bash", value: "Bash2"))
    }

    @Test func starMatchesAnyRunIncludingNone() {
        #expect(Glob.matches("mcp__*", value: "mcp__github"))
        #expect(Glob.matches("mcp__*", value: "mcp__a__b"))
        #expect(!Glob.matches("mcp__*", value: "mcp_"))
        #expect(Glob.matches("Web*", value: "WebFetch"))
    }

    @Test func questionMarkMatchesExactlyOne() {
        #expect(Glob.matches("Read?", value: "Read1"))
        #expect(!Glob.matches("Read?", value: "Read"))
        #expect(!Glob.matches("Read?", value: "Read12"))
    }

    @Test func patternsWithBothWildcards() {
        #expect(Glob.matches("git *", value: "git push --force"))
        #expect(Glob.matches("git *", value: "git "))
        #expect(!Glob.matches("git *", value: "git"))
        #expect(Glob.matches("*://*.example.com/*", value: "https://api.example.com/v1"))
    }

    @Test func starBacktrackingRecovers() {
        // A naive greedy matcher without backtracking fails this case.
        #expect(Glob.matches("*ab", value: "aab"))
        #expect(Glob.matches("a*bc", value: "abbc"))
        #expect(Glob.matches("*a*b*c*", value: "xxaxxbxxcxx"))
    }

    @Test func emptyValuesAndPatterns() {
        #expect(Glob.matches("*", value: ""))
        #expect(Glob.matches("", value: ""))
        #expect(!Glob.matches("", value: "a"))
        #expect(Glob.matches("**", value: "anything at all"))
    }

    @Test func exactDetection() {
        #expect(Glob.isExact("Bash"))
        #expect(!Glob.isExact("Bash*"))
        #expect(!Glob.isExact("Ba?h"))
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTripsArbitraryJSON() throws {
        let original: JSONValue = [
            "string": "text",
            "number": 42,
            "double": 3.5,
            "bool": true,
            "null": nil,
            "array": [1, "two", false],
            "nested": ["deep": ["empty": []]],
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test func preservesNumericPrecision() throws {
        // Doubles beyond Int64 would lose precision if coerced.
        let text = "{\"big\": 9007199254740993}"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value["big"]?.stringValue == nil)
        let reencoded = try JSONEncoder().encode(value)
        let text2 = String(decoding: reencoded, as: UTF8.self)
        #expect(text2.contains("9007199254740993"))
    }

    @Test func accessors() {
        let value: JSONValue = [
            "name": "skynet",
            "count": 3,
            "ratio": 0.5,
            "on": true,
            "list": ["a", "b"],
        ]
        #expect(value["name"]?.stringValue == "skynet")
        #expect(value["count"]?.intValue == 3)
        #expect(value["ratio"]?.doubleValue == 0.5)
        #expect(value["on"]?.boolValue == true)
        #expect(value["list"]?[1]?.stringValue == "b")
        #expect(value["list"]?[5] == nil)
        #expect(value["missing"] == nil)
    }

    @Test func wrapsAndDecodesCodables() throws {
        let message = Message(
            origin: .agent,
            content: [.text("hello"), .thinking(text: "hmm", signature: "sig")]
        )
        let wrapped = try JSONValue.wrap(message)
        #expect(wrapped["origin"]?.stringValue == "agent")
        let unwrapped = try wrapped.decode(Message.self)
        #expect(unwrapped.content.count == 2)
        #expect(unwrapped.content.first?.text == "hello")
    }

    @Test func literalConveniences() {
        let value: JSONValue = ["command": "ls", "args": ["-l"], "force": true]
        #expect(value["args"]?.arrayValue?.count == 1)
        #expect(value["force"]?.boolValue == true)
    }
}

@Suite("Identifiers")
struct IdentifierTests {
    @Test func typedWrappersDoNotConfuse() {
        let provider = ProviderID("codex")
        let model = ModelID("codex")
        // Same raw string, different types — this is the point.
        #expect(provider.rawValue == model.rawValue)
        #expect(provider == .codex)
    }

    @Test func uuidWrappersEncodeAsPlainIDs() throws {
        let session = SessionRecord(providerID: .codex)
        let data = try JSONEncoder().encode(session.id)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("value"))
        #expect(UUID(uuidString: text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) != nil)
    }

    @Test func toolCallIDsCarryProviderStrings() {
        #expect(ToolCallID("toolu_abc123").rawValue == "toolu_abc123")
    }
}

@Suite("SkynetError")
struct SkynetErrorTests {
    @Test func everyCaseHasALocalizedDescription() {
        let errors: [SkynetError] = [
            .notFound(what: "Session", id: "abc"),
            .invalidProviderConfiguration(detail: "bad"),
            .attachmentUnsupported(provider: "Codex", reason: "inline images"),
            .unsupportedOnPlatform(operation: "Local process", platform: "iOS"),
            .executionFailed(reason: "nope"),
            .agentExited(code: 2, stderr: "boom"),
            .protocolViolation(detail: "malformed"),
            .unsupportedStoreSchema(found: 2, supported: 1),
            .persistenceFailure(underlying: "disk"),
            .permissionDenied(tool: "Bash", reason: "policy"),
            .timedOut(after: 30),
            .relayNotPaired,
            .relayUnreachable(detail: "timeout"),
        ]
        for error in errors {
            #expect(!(error.localizedDescription.isEmpty))
        }
    }
}
