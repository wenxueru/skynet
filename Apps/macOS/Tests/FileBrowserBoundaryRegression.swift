// Compile the real FileEntry/SessionFileBrowser/BrowserError source section
// from SessionFilesView.swift and this fixture in the same Swift input unit.
// Every target is self-created inside Skynet/DerivedData. No session is opened.
@main
enum FileBrowserBoundaryRegression {
    static func main() {
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() throws {
        let manager = FileManager.default
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)
        let fixture = parent.appendingPathComponent("qa-file-boundary-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("root", isDirectory: true)
        let outside = fixture.appendingPathComponent("root-sibling", isDirectory: true)
        let folder = root.appendingPathComponent("inside-folder", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let content = Data("QA_INSIDE_LINK_CONTENT\n".utf8)
        let outsideFile = outside.appendingPathComponent("outside.txt")
        try Data("QA_OUTSIDE_NEVER_READ\n".utf8).write(to: outsideFile)
        let insideFile = folder.appendingPathComponent("inside.txt")
        try content.write(to: insideFile)
        let insideLink = root.appendingPathComponent("inside-file-link")
        let directoryLink = root.appendingPathComponent("inside-directory-link")
        let outsideLink = root.appendingPathComponent("outside-file-link")
        let outsideDirectory = root.appendingPathComponent("outside-directory-link")
        let relativeEscape = root.appendingPathComponent("relative-escape-link")
        let chain = root.appendingPathComponent("escape-chain")
        try manager.createSymbolicLink(atPath: insideLink.path, withDestinationPath: "inside-folder/inside.txt")
        try manager.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: "inside-folder")
        try manager.createSymbolicLink(atPath: outsideLink.path, withDestinationPath: outsideFile.path)
        try manager.createSymbolicLink(atPath: outsideDirectory.path, withDestinationPath: outside.path)
        try manager.createSymbolicLink(atPath: relativeEscape.path, withDestinationPath: "../root-sibling/outside.txt")
        try manager.createSymbolicLink(atPath: chain.path, withDestinationPath: "outside-file-link")
        let browser = SessionFileBrowser(root: root.path, backendID: nil)
        var failures: [String] = []
        func expect(_ result: Bool, _ label: String) {
            if result { print("PASS: \(label)") }
            else { failures.append(label); print("FAIL: \(label)") }
        }
        func rejectsOutside(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); expect(false, label) }
            catch BrowserError.invalidPath { expect(true, label) }
            catch { failures.append("\(label): unexpected \(error)") }
        }
        expect(try browser.readFile(insideLink.path) == content, "inside file link reads exact content")
        do {
            let children = try browser.entries(in: directoryLink.path)
            expect(children.map(\.name) == ["inside.txt"], "inside directory link lists contents")
            expect(children.first?.path == directoryLink.appendingPathComponent("inside.txt").path,
                   "linked directory preserves alias path for parent navigation")
        } catch {
            expect(false, "inside directory link lists contents: \(error)")
        }
        let entries = try browser.entries(in: root.path)
        expect(entries.first(where: { $0.path == directoryLink.path })?.isDirectory == true,
               "inside directory link is navigable as a directory")
        expect(entries.first(where: { $0.path == insideLink.path })?.isDirectory == false,
               "inside file link remains a file")
        for (label, path) in [("absolute link escape", outsideLink.path),
                              ("relative link escape", relativeEscape.path),
                              ("chained link escape", chain.path),
                              ("prefix sibling escape", outsideFile.path),
                              ("dot-dot escape", root.path + "/../root-sibling/outside.txt")] {
            rejectsOutside(label) { _ = try browser.readFile(path) }
        }
        rejectsOutside("outside directory traversal") { _ = try browser.entries(in: outsideDirectory.path) }
        rejectsOutside("outside diff rejected before git") { _ = try browser.diff(for: outsideLink.path) }
        let alias = fixture.appendingPathComponent("root-alias")
        try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)
        let aliasedBrowser = SessionFileBrowser(root: alias.path, backendID: nil)
        expect(try aliasedBrowser.readFile(alias.appendingPathComponent("inside-folder/inside.txt").path) == content,
               "symlinked root canonical boundary")
        expect(try aliasedBrowser.entries(in: alias.path).allSatisfy { $0.path.hasPrefix(alias.path + "/") },
               "symlinked root preserves display paths")
        if !failures.isEmpty { throw RegressionFailure(failures: failures) }
    }

    private struct RegressionFailure: Error {
        let failures: [String]
    }
}
