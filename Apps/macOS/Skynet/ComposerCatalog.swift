import Foundation
import SkynetCore

struct ComposerCompletionContext {
    let trigger: Character
    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange) {
        let nsText = text as NSString
        guard selection.length == 0, selection.location <= nsText.length else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines
        var start = selection.location
        while start > 0 {
            let scalar = UnicodeScalar(nsText.character(at: start - 1))
            if scalar.map(separators.contains) == true { break }
            start -= 1
        }
        let tokenRange = NSRange(location: start, length: selection.location - start)
        let token = nsText.substring(with: tokenRange)
        guard let first = token.first, first == "$" || first == "/" || first == "@" else { return nil }
        trigger = first
        query = String(token.dropFirst())
        range = tokenRange
    }

    var fingerprint: String { "\(range.location):\(trigger)\(query)" }
}

struct ComposerSuggestion: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case skill
        case command
        case session

        var trigger: Character {
            switch self {
            case .skill: "$"
            case .command: "/"
            case .session: "@"
            }
        }
    }

    let kind: Kind
    let name: String
    let detail: String
    let source: String

    var id: String { "\(kind.rawValue):\(name):\(source)" }
    var title: String { "\(kind.trigger)\(name)" }
}

enum ComposerCatalog {
    static func load(
        projectPath: String?,
        providerKind: AgentProviderDescriptor.Kind?
    ) async -> [ComposerSuggestion] {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var items = builtInCommands(for: providerKind)
            var skillRoots = [
                (home.appendingPathComponent(".codex/skills"), "Local file"),
                (home.appendingPathComponent(".agents/skills"), "Local file"),
            ]
            skillRoots += projectRoots(projectPath, component: ".codex/skills", source: "Project")
            skillRoots += projectRoots(projectPath, component: ".agents/skills", source: "Project")
            items += markdownItems(
                roots: skillRoots,
                fileName: "SKILL.md",
                kind: .skill
            )
            var commandRoots = [(home.appendingPathComponent(".claude/commands"), "Local command")]
            commandRoots += projectRoots(
                projectPath,
                component: ".claude/commands",
                source: "Project command"
            )
            items += markdownItems(
                roots: commandRoots,
                fileName: nil,
                kind: .command
            )
            var seen: Set<String> = []
            return items
                .filter { seen.insert("\($0.kind.rawValue):\($0.name.lowercased())").inserted }
                .sorted {
                    if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        }.value
    }

    private static func projectRoots(
        _ projectPath: String?,
        component: String,
        source: String
    ) -> [(URL, String)] {
        guard let projectPath else { return [] }
        return [(URL(fileURLWithPath: projectPath).appendingPathComponent(component), source)]
    }

    private static func markdownItems(
        roots: [(URL, String)],
        fileName: String?,
        kind: ComposerSuggestion.Kind
    ) -> [ComposerSuggestion] {
        let manager = FileManager.default
        return roots.flatMap { root, source -> [ComposerSuggestion] in
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { value in
                guard let url = value as? URL,
                      url.pathExtension.lowercased() == "md",
                      fileName == nil || url.lastPathComponent == fileName else { return nil }
                let fallbackName = fileName == nil
                    ? url.deletingPathExtension().lastPathComponent
                    : url.deletingLastPathComponent().lastPathComponent
                let metadata = markdownMetadata(at: url, fallbackName: fallbackName)
                return ComposerSuggestion(
                    kind: kind,
                    name: metadata.name,
                    detail: metadata.description,
                    source: url.path.contains("/.system/") ? "Built-in" : source
                )
            }
        }
    }

    private static func markdownMetadata(at url: URL, fallbackName: String) -> (name: String, description: String) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data.prefix(32_768), encoding: .utf8) else {
            return (fallbackName, "")
        }
        let lines = text.components(separatedBy: .newlines)
        let name = frontMatterValue("name", lines: lines) ?? fallbackName
        let bodyStart = lines.first == "---"
            ? lines.dropFirst().firstIndex(of: "---").map { $0 + 1 } ?? 0
            : 0
        let description = frontMatterValue("description", lines: lines)
            ?? lines.dropFirst(bodyStart).first(where: { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" })
            ?? ""
        return (name, description)
    }

    private static func frontMatterValue(_ key: String, lines: [String]) -> String? {
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let fields = Array(lines[1..<end].prefix(80))
        let prefix = "\(key):"
        guard let index = fields.firstIndex(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = fields[index].dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if [">", ">-", ">+", "|", "|-", "|+"].contains(value) {
            let block = fields.dropFirst(index + 1).prefix {
                $0.isEmpty || $0.first?.isWhitespace == true
            }
            let indent = block.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.prefix(while: \.isWhitespace).count }.min() ?? 0
            let result = block.map { String($0.dropFirst(indent)) }
                .joined(separator: value.hasPrefix(">") ? " " : "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        let result = value.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'"))
        return result.isEmpty ? nil : result
    }

    private static func builtInCommands(
        for providerKind: AgentProviderDescriptor.Kind?
    ) -> [ComposerSuggestion] {
        let common = [
            ("compact", "Compact conversation context"),
            ("model", "Choose the active model"),
            ("permissions", "Change tool permission mode"),
            ("status", "Show session and environment status"),
        ]
        let providerCommands: [(String, String)]
        switch providerKind {
        case .codex:
            providerCommands = [
                ("diff", "Review working tree changes"),
                ("review", "Review the current implementation"),
                ("new", "Start a new conversation"),
            ]
        case .claudeCode, .claudeCodeCompatible:
            providerCommands = [
                ("context", "Inspect context usage"),
                ("cost", "Show token usage and cost"),
                ("doctor", "Check Claude Code installation"),
                ("help", "Show available commands"),
                ("init", "Create project instructions"),
                ("memory", "Edit project memory"),
                ("review", "Review the current implementation"),
            ]
        case nil:
            providerCommands = []
        }
        return (common + providerCommands).map {
            ComposerSuggestion(kind: .command, name: $0.0, detail: $0.1, source: "Built-in")
        }
    }
}

