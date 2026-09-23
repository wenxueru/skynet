import Foundation

/// A GitHub-style pipe table extracted from consecutive Markdown lines.
public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    public let headers: [String]
    public let alignments: [Alignment]
    public let rows: [[String]]

    public static func parse(
        _ lines: [String], startingAt start: Int
    ) -> (table: MarkdownTable, nextLineIndex: Int)? {
        guard lines.indices.contains(start), lines.indices.contains(start + 1),
              lines[start].contains("|"),
              let headers = cells(in: lines[start]),
              let separators = cells(in: lines[start + 1]),
              !headers.isEmpty, headers.count == separators.count else { return nil }

        var alignments: [Alignment] = []
        for separator in separators {
            let marker = separator.trimmingCharacters(in: .whitespaces)
            let dashes = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(
                marker.hasPrefix(":") && marker.hasSuffix(":") ? .center
                    : marker.hasSuffix(":") ? .trailing : .leading
            )
        }

        var rows: [[String]] = []
        var next = start + 2
        while lines.indices.contains(next),
              !lines[next].trimmingCharacters(in: .whitespaces).isEmpty,
              lines[next].contains("|"),
              let row = cells(in: lines[next]) {
            rows.append(Array(row.prefix(headers.count))
                + Array(repeating: "", count: max(0, headers.count - row.count)))
            next += 1
        }
        return (MarkdownTable(headers: headers, alignments: alignments, rows: rows), next)
    }

    private static func cells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if trimmed.hasSuffix("|") { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }
}
