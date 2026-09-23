import AppKit
import SkynetCore
import SwiftUI

/// Hapi-style read-only project browser. All paths come from the selected
/// project/session and are resolved on the session's own machine.
struct SessionFilesView: View {
    let session: SessionRecord
    let rootPath: String
    let onReference: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .changes
    @State private var directory: String
    @State private var entries: [FileEntry] = []
    @State private var selected: FileEntry?
    @State private var preview: Data?
    @State private var diff: String?
    @State private var search = ""
    @State private var sort: Sort = .name
    @State private var isLoading = false
    @State private var errorMessage: String?

    private enum Tab: String, CaseIterable { case changes = "Changes", directories = "Directories" }
    private enum Sort: String, CaseIterable { case name = "Name", modified = "Modified", size = "Size" }

    init(session: SessionRecord, rootPath: String, onReference: @escaping (String) -> Void) {
        self.session = session
        self.rootPath = rootPath
        self.onReference = onReference
        _directory = State(initialValue: rootPath)
    }

    private var browser: SessionFileBrowser {
        SessionFileBrowser(root: rootPath, backendID: session.backendID)
    }

    private var visibleEntries: [FileEntry] {
        let filtered = entries.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            switch sort {
            case .name: return left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .modified:
                return (left.modifiedAt ?? .distantPast) > (right.modifiedAt ?? .distantPast)
            case .size: return (left.size ?? 0) > (right.size ?? 0)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Files", systemImage: "folder")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 8) {
                    Picker("Files", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        if tab == .directories {
                            Button {
                                let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
                                if parent == rootPath || parent.hasPrefix(rootPath + "/") {
                                    directory = parent
                                }
                            } label: { Image(systemName: "chevron.left") }
                                .disabled(directory == rootPath)
                                .help("Parent folder")
                        }
                        TextField("Search files", text: $search)
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(Sort.allCases, id: \.self) { option in
                                Button(option.rawValue) { sort = option }
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease") }
                            .help("Sort files")
                        Button { loadEntries() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh files")
                    }
                    if tab == .directories {
                        Text("." + String(directory.dropFirst(rootPath.count)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isLoading { ProgressView().controlSize(.small) }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                    List(visibleEntries) { entry in
                        Button {
                            if entry.isDirectory {
                                directory = entry.path
                                tab = .directories
                            } else {
                                selected = entry
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                Text(entry.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if let status = entry.gitStatus {
                                    Text(status).font(.caption.monospaced().bold())
                                        .foregroundStyle(status == "??" ? .green : .orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selected?.path == entry.path ? Color.accentColor.opacity(0.18) : .clear)
                    }
                    .listStyle(.inset)
                }
                .padding(12)
                .frame(minWidth: 300, idealWidth: 360)

                VStack(spacing: 0) {
                    if let selected {
                        HStack {
                            Text(selected.name).font(.headline).lineLimit(1)
                            Spacer()
                            if !selected.isDirectory {
                                Button("Reference") {
                                    onReference(selected.path)
                                    dismiss()
                                }
                                .help("Insert this file path into the composer")
                                Button("Copy path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(selected.path, forType: .string)
                                }
                            }
                        }
                        .padding(12)
                        Divider()
                        if selected.isDirectory {
                            ContentUnavailableView("Folder", systemImage: "folder")
                            Button("Open folder") { directory = selected.path; tab = .directories }
                                .padding()
                        } else if let preview {
                            filePreview(preview, path: selected.path)
                        } else if isLoading {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { loadEntries() }
        .onChange(of: [tab.rawValue, directory]) { _, _ in
            selected = nil
            loadEntries()
        }
        .onChange(of: selected) { _, entry in loadPreview(entry) }
    }

    @ViewBuilder
    private func filePreview(_ data: Data, path: String) -> some View {
        if ["png", "jpg", "jpeg", "gif", "webp", "tiff"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
           let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().scaledToFit().padding(20)
            }
        } else if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let diff, !diff.isEmpty {
                        Text("Changes").font(.headline)
                        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.prefix(500).enumerated()), id: \.offset) { _, line in
                                let value = String(line)
                                Text(value.isEmpty ? " " : value)
                                    .foregroundStyle(value.hasPrefix("+") ? .green
                                        : value.hasPrefix("-") ? .red : .secondary)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            if lines.count > 500 {
                                Text("Diff preview truncated after 500 lines")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text(text).textSelection(.enabled)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Binary file", systemImage: "doc")
        }
    }

    private func loadEntries() {
        isLoading = true
        errorMessage = nil
        let browser = browser
        let currentTab = tab
        let currentDirectory = directory
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try currentTab == .changes
                        ? browser.changes() : browser.entries(in: currentDirectory)
                }.value
                guard tab == currentTab, directory == currentDirectory else { return }
                entries = loaded
            } catch {
                guard tab == currentTab, directory == currentDirectory else { return }
                if currentTab == .changes,
                   error.localizedDescription.contains("not a git repository") {
                    tab = .directories
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isLoading = false
        }
    }

    private func loadPreview(_ entry: FileEntry?) {
        preview = nil
        diff = nil
        guard let entry, !entry.isDirectory else { return }
        let browser = browser
        Task {
            do {
                let (data, patch) = try await Task.detached(priority: .userInitiated) {
                    (try browser.readFile(entry.path), try? browser.diff(for: entry.path))
                }.value
                guard selected?.path == entry.path else { return }
                preview = data
                diff = patch
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct FileEntry: Hashable, Identifiable, Sendable {
    let path: String
    let isDirectory: Bool
    var gitStatus: String? = nil
    var size: Int64? = nil
    var modifiedAt: Date? = nil
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

private struct SessionFileBrowser: Sendable {
    let root: String
    let backendID: BackendID?
    private var host: String? {
        guard let id = backendID?.rawValue, id.hasPrefix("ssh:") else { return nil }
        return String(id.dropFirst("ssh:".count))
    }

    func entries(in directory: String) throws -> [FileEntry] {
        guard isInsideRoot(directory) else { throw BrowserError.invalidPath }
        if let host {
            let quoted = SSHBackend.shellQuote(directory)
            let command = "for f in \(quoted)/* \(quoted)/.[!.]* \(quoted)/..?*; do "
                + "[ -e \"$f\" ] || [ -L \"$f\" ] || continue; "
                + "if [ -d \"$f\" ]; then printf 'D%s\\0' \"$f\"; "
                + "else printf 'F%s\\0' \"$f\"; fi; done"
            return try run("/usr/bin/ssh", ["-oBatchMode=yes", "-oConnectTimeout=5", "--", host, command])
                .split(separator: 0).prefix(2_000).compactMap { item in
                    guard let kind = item.first,
                          let path = String(data: item.dropFirst(), encoding: .utf8),
                          isInsideRoot(path) else { return nil }
                    return FileEntry(path: path, isDirectory: kind == UInt8(ascii: "D"))
                }
        }
        return try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        ).prefix(2_000).map { url in
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey
            ])
            return FileEntry(
                path: url.path, isDirectory: values.isDirectory ?? false,
                size: values.fileSize.map(Int64.init), modifiedAt: values.contentModificationDate
            )
        }
    }

    func changes() throws -> [FileEntry] {
        let data = try git(["status", "--porcelain=v1", "-z"])
        let pieces = data.split(separator: 0)
        var result: [FileEntry] = []
        var index = 0
        while index < pieces.count, result.count < 2_000 {
            let piece = pieces[index]
            index += 1
            guard piece.count >= 4,
                  let status = String(data: piece.prefix(2), encoding: .utf8),
                  let relative = String(data: piece.dropFirst(3), encoding: .utf8) else { continue }
            let path = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL.path
            if isInsideRoot(path) {
                var isDirectory = false
                if host == nil {
                    var directoryFlag: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: path, isDirectory: &directoryFlag)
                    isDirectory = directoryFlag.boolValue
                }
                result.append(FileEntry(path: path, isDirectory: isDirectory, gitStatus: status))
            }
            if status.contains("R") || status.contains("C") { index += 1 }
        }
        return result
    }

    func readFile(_ path: String) throws -> Data {
        guard isInsideRoot(path) else { throw BrowserError.invalidPath }
        let maxBytes = 2_000_001
        let data: Data
        if let host {
            let command = "head -c \(maxBytes) -- \(SSHBackend.shellQuote(path))"
            data = try run("/usr/bin/ssh", ["-oBatchMode=yes", "-oConnectTimeout=5", "--", host, command])
        } else {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxBytes) ?? Data()
        }
        guard data.count < maxBytes else { throw BrowserError.fileTooLarge }
        return data
    }

    func diff(for path: String) throws -> String {
        guard isInsideRoot(path) else { throw BrowserError.invalidPath }
        let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return String(decoding: try git(["diff", "HEAD", "--", relative]), as: UTF8.self)
    }

    private func git(_ arguments: [String]) throws -> Data {
        if let host {
            let command = "cd \(SSHBackend.shellQuote(root)) && git "
                + arguments.map(SSHBackend.shellQuote).joined(separator: " ")
            return try run("/usr/bin/ssh", ["-oBatchMode=yes", "-oConnectTimeout=5", "--", host, command])
        }
        return try run("/usr/bin/git", ["-C", root] + arguments)
    }

    private func isInsideRoot(_ path: String) -> Bool {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        let normalizedRoot = host == nil ? rootURL.resolvingSymlinksInPath().path : rootURL.path
        let normalizedPath = host == nil ? pathURL.resolvingSymlinksInPath().path : pathURL.path
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            guard data.count + chunk.count <= 4_000_000 else {
                throw BrowserError.fileTooLarge
            }
            data.append(chunk)
        }
        let diagnostic = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BrowserError.commandFailed(String(decoding: diagnostic, as: UTF8.self))
        }
        return data
    }
}

private enum BrowserError: LocalizedError {
    case invalidPath, fileTooLarge, commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidPath: "File is outside this project."
        case .fileTooLarge: "File is larger than the 2 MB preview limit."
        case .commandFailed(let message): message.isEmpty ? "File command failed." : message
        }
    }
}
