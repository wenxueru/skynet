import SkynetCore
import Testing

@Suite("Markdown tables")
struct MarkdownTableTests {
    @Test func parsesClaudeStyleTable() throws {
        let lines = [
            "| 来源 | 内容 |",
            "|---|---|",
            "| job config | agents.[0].kwargs.version = 2.1.251 |",
            "| install.sh | npm install -g claude-code |",
            "",
            "Next paragraph",
        ]
        let result = try #require(MarkdownTable.parse(lines, startingAt: 0))
        #expect(result.table.headers == ["来源", "内容"])
        #expect(result.table.rows.count == 2)
        #expect(result.table.rows[0][1] == "agents.[0].kwargs.version = 2.1.251")
        #expect(result.nextLineIndex == 4)
    }

    @Test func handlesAlignmentAndEscapedPipes() throws {
        let lines = ["Name | Version", ":--- | ---:", "A \\| B | 2.1.251"]
        let result = try #require(MarkdownTable.parse(lines, startingAt: 0))
        #expect(result.table.alignments == [.leading, .trailing])
        #expect(result.table.rows == [["A \\| B", "2.1.251"]])
    }

    @Test func ordinaryPipesAreNotTables() {
        #expect(MarkdownTable.parse(["A | B", "not a separator"], startingAt: 0) == nil)
    }
}
