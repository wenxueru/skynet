// Compiled with the real file-private ComposerCatalog, not a parser copy.
@main
enum ComposerCatalogRegression {
    static func main() {
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() throws {
        let root = URL(fileURLWithPath: "/workspace/skynet/DerivedData")
            .appendingPathComponent("qa-composer-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, String, String, String)] = [
            ("plain", "---\nname: sample\ndescription: One line description\n---\n# Body", "sample", "One line description"),
            ("quoted", "---\nname: 'quoted'\ndescription: \"Punctuation: preserved!\"\n---", "quoted", "Punctuation: preserved!"),
            ("folded", "---\nname: sample\ndescription: >\n  First line\n  second line.\n---\n# Body", "sample", "First line second line."),
            ("folded-chomp", "---\nname: sample\ndescription: >-\n  First line\n  second line.\n---", "sample", "First line second line."),
            ("literal", "---\nname: sample\ndescription: |\n  First line\n  second line.\n---", "sample", "First line\nsecond line."),
            ("literal-chomp", "---\nname: sample\ndescription: |-\n  First line\n  second line.\n---", "sample", "First line\nsecond line."),
            ("next-field", "---\ndescription: >\n  Only this\nname: sample\n---", "sample", "Only this"),
            ("body-key", "---\nname: sample\n---\n# Body\ndescription: Not front matter", "sample", "description: Not front matter"),
            ("empty-name", "---\nname: \ndescription: Kept\n---", "fallback", "Kept"),
            ("no-frontmatter", "# Command\nBody text\nname: Not metadata", "fallback", "Body text")
        ]
        var failures = 0
        for (label, source, name, description) in cases {
            let url = root.appendingPathComponent("\(label).md")
            try Data(source.utf8).write(to: url)
            let actual = ComposerCatalog.regressionMetadata(at: url, fallbackName: "fallback")
            let passed = actual.name == name && actual.description == description
            print("\(passed ? "PASS" : "FAIL"): \(label) metadata")
            if !passed {
                print("Observed name=\(String(reflecting: actual.name)), description=\(String(reflecting: actual.description))")
                failures += 1
            }
        }
        // Exit after main work returns so defer removes the owned fixture.
        if failures > 0 { throw FixtureFailure.mismatch }
    }

    private enum FixtureFailure: Error { case mismatch }
}

private extension ComposerCatalog {
    static func regressionMetadata(at url: URL, fallbackName: String) -> (name: String, description: String) {
        markdownMetadata(at: url, fallbackName: fallbackName)
    }
}
