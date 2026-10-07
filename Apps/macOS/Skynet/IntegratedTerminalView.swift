import Darwin
import SkynetCore
import SwiftUI
import WebKit

struct CodexSideChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var chat: SideChatController
    @State private var draft = ""

    init(session: SessionRecord, provider: AgentProviderDescriptor, backend: any ExecutionBackend) {
        _chat = StateObject(wrappedValue: SideChatController(session: session, provider: provider, backend: backend))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Side chat", systemImage: "bubble.left.and.bubble.right")
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("A temporary conversation with this session’s context. Main conversation is unchanged. Read-only; closes with this panel.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                TextField("CLI default", text: $chat.model)
                    .textFieldStyle(.roundedBorder).disabled(chat.isRunning)
                Menu(chat.isLoadingModels ? "Loading models…" : "Available models") {
                    Button("Provider default") { chat.model = "" }
                    ForEach(chat.models, id: \.id) { candidate in
                        Button(candidate.displayName) { chat.model = candidate.id.rawValue }
                    }
                }
                .disabled(chat.isLoadingModels || chat.isRunning)
            }
            if let modelNotice = chat.modelNotice {
                Text(modelNotice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(chat.messages.enumerated()), id: \.offset) { _, message in
                            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !chat.reply.isEmpty { Text(chat.reply).textSelection(.enabled) }
                        if chat.isRunning { ProgressView("Working…") }
                        Color.clear.frame(height: 1).id("latest")
                    }
                }
                .onChange(of: chat.reply) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
            if let error = chat.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack(alignment: .bottom) {
                TextField("Ask a side question", text: $draft, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder)
                Button("Send") {
                    let prompt = draft
                    draft = ""
                    chat.send(prompt)
                }
                .disabled(chat.isLoadingModels || chat.isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).frame(minWidth: 640, minHeight: 480)
        .task { await chat.loadModels() }
        .onDisappear { chat.close() }
    }
}

@MainActor
private final class SideChatController: ObservableObject {
    @Published var messages: [String] = []
    @Published var reply = ""
    @Published var error: String?
    @Published var isRunning = false
    @Published var model: String
    @Published var modelNotice: String?
    @Published var models: [ModelDescriptor] = []
    @Published var isLoadingModels = true
    private let session: SessionRecord
    private let provider: AgentProviderDescriptor
    private let backend: any ExecutionBackend
    private let driver: CodexSideConversation
    private var task: Task<Void, Never>?

    init(session: SessionRecord, provider: AgentProviderDescriptor, backend: any ExecutionBackend) {
        self.session = session
        self.provider = provider
        self.backend = backend
        model = session.modelID?.rawValue ?? ""
        driver = CodexSideConversation(backend: backend, provider: provider,
            parentThreadID: session.providerResumeToken ?? "", workingDirectory: session.workingDirectory)
    }

    func loadModels() async {
        let catalog = await ProviderModelDiscovery.models(for: provider, backend: backend,
                                                        workingDirectory: session.workingDirectory)
        guard !Task.isCancelled else { return }
        models = catalog.models
        isLoadingModels = false
        if let error = catalog.error { self.error = error }
        else if !model.isEmpty, !models.isEmpty,
                !models.contains(where: { $0.id.rawValue == model }) {
            modelNotice = "The session model isn’t available in this Codex CLI; using its default."
            model = ""
        }
    }

    func send(_ prompt: String) {
        guard !isRunning else { return }
        messages.append("You: \(prompt)")
        reply = ""
        error = nil
        isRunning = true
        task = Task {
            defer { isRunning = false }
            do {
                let events = try await driver.send(AgentTurnRequest(
                    sessionID: session.id, providerID: session.providerID, prompt: prompt,
                    modelID: model.isEmpty ? nil : ModelID(model), effort: session.effort,
                    workingDirectory: session.workingDirectory))
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let text): reply += text
                    case .turnFailed(let failure): error = failure.error.localizedDescription
                    default: break
                    }
                }
                if !reply.isEmpty { messages.append(reply); reply = "" }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    func close() {
        task?.cancel()
        Task { await driver.close() }
    }
}

struct IntegratedTerminalView: View {
    enum Mode: String, Identifiable {
        case shell, agent, sideChat
        var id: String { rawValue }
    }

    let mode: Mode
    let session: SessionRecord
    let provider: AgentProviderDescriptor?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var terminal = TerminalController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(12)
            Divider()
            if mode == .agent || mode == .sideChat {
                Text(mode == .sideChat
                     ? "Type \(sideChatCommand) in the resumed interactive CLI to start a provider-native side conversation. This does not send to the main Skynet turn."
                     : "Starts a separate interactive CLI for this conversation; it does not attach to an already-running terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            TerminalWebView(controller: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !terminal.isReady {
                Text(terminal.initializationStatus)
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if let error = terminal.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .modifier(TerminalSheetSizing())
        .onAppear {
            terminal.configure(
                workingDirectory: session.workingDirectory,
                sshHost: session.backendID?.rawValue.hasPrefix("ssh:") == true
                    ? String(session.backendID!.rawValue.dropFirst("ssh:".count)) : nil,
                launchCommand: agentCommand,
                extraEnvironment: mode == .shell ? [:] : provider?.environment ?? [:]
            )
        }
        .onDisappear { terminal.stop() }
    }

    private var agentCommand: String? {
        guard mode != .shell, let token = session.providerResumeToken,
              let provider else { return nil }
        let configuredExecutable = provider.executable ?? provider.kind.defaultExecutableName
        let isRemote = session.backendID?.rawValue.hasPrefix("ssh:") == true
        let executable = isRemote ? configuredExecutable
            : LocalProcessBackend.resolveExecutablePath(
                configuredExecutable, requestEnvironment: provider.environment
            ) ?? configuredExecutable
        let arguments = provider.kind == .codex
            ? ["resume", token] : ["--resume", token]
        return ([executable] + provider.defaultArguments + arguments)
            .map(SSHBackend.shellQuote).joined(separator: " ")
    }

    private var title: String {
        switch mode {
        case .shell: "Terminal"
        case .agent: "Agent terminal"
        case .sideChat: "Side chat · \(sideChatCommand)"
        }
    }

    private var sideChatCommand: String {
        guard let kind = provider?.kind else { return "side chat command" }
        return switch kind {
        case .codex: "/side"
        case .claudeCode, .claudeCodeCompatible: "/btw"
        }
    }
}

private struct TerminalSheetSizing: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.presentationSizing(.fitted)
        } else {
            content.background(LegacySheetSizing().frame(width: 0, height: 0))
        }
    }
}

private struct LegacySheetSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ view: SizingView, context: Context) { view.configureWindow() }

    final class SizingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            // SwiftUI attaches the sheet after this view enters its window.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.sheetParent != nil else { return }
                window.styleMask.insert(.resizable)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct TerminalWebView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController

    func makeNSView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private final class TerminalPageWebView: WKWebView {
    var pendingPage: String?
    var onAttached: (() -> Void)?
    private var pageLoadScheduled = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let encoded = Data(text.utf8).base64EncodedString()
        evaluateJavaScript("window.pasteTerminalBase64('\(encoded)')")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, pendingPage != nil, !pageLoadScheduled else { return }
        pageLoadScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.window != nil, let page = self.pendingPage else {
                self.pageLoadScheduled = false
                return
            }
            self.pendingPage = nil
            self.onAttached?()
            self.loadHTMLString(page, baseURL: nil)
        }
    }
}

@MainActor
private final class TerminalController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var errorMessage: String?
    @Published private(set) var initializationStatus = "Creating terminal view…"
    private var webView: WKWebView?
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var workingDirectory: String?
    private var sshHost: String?
    private var launchCommand: String?
    private var extraEnvironment: [String: String] = [:]
    @Published private(set) var isReady = false

    func configure(
        workingDirectory: String?, sshHost: String?, launchCommand: String?,
        extraEnvironment: [String: String]
    ) {
        self.workingDirectory = workingDirectory
        self.sshHost = sshHost
        self.launchCommand = launchCommand
        self.extraEnvironment = extraEnvironment
        if isReady { start() }
    }

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        initializationStatus = "Loading terminal page…"
        let content = WKUserContentController()
        content.add(self, name: "terminal")
        content.addUserScript(WKUserScript(
            source: "window.addEventListener('error', e => window.webkit.messageHandlers.terminal.postMessage({type:'error', data:e.message || 'Terminal script failed'}));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        let view = TerminalPageWebView(frame: .zero, configuration: configuration)
        view.onAttached = { [weak self] in
            Task { @MainActor in self?.initializationStatus = "Terminal view attached; loading page…" }
        }
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        webView = view
        let bundledPage = Bundle.main.url(
            forResource: "terminal", withExtension: "html", subdirectory: "TerminalAssets"
        ) ?? Bundle.main.url(forResource: "terminal", withExtension: "html")
        if let url = bundledPage {
            do {
                var page = try String(contentsOf: url, encoding: .utf8)
                for name in ["xterm.js", "addon-fit.js", "xterm.css"] {
                    let assetURL = url.deletingLastPathComponent().appendingPathComponent(name)
                    let asset = try String(contentsOf: assetURL, encoding: .utf8)
                    if name.hasSuffix(".js") {
                        let script = asset.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
                        page = page.replacingOccurrences(
                            of: "<script src=\"\(name)\"></script>",
                            with: "<script>\(script)</script>"
                        )
                    } else {
                        page = page.replacingOccurrences(
                            of: "<link rel=\"stylesheet\" href=\"\(name)\">",
                            with: "<style>\(asset)</style>"
                        )
                    }
                }
                view.pendingPage = page
            } catch {
                errorMessage = "Could not read terminal resources: \(error.localizedDescription)"
            }
        } else {
            errorMessage = "Terminal resources are missing from the app bundle."
        }
        return view
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        errorMessage = "Could not load terminal: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        errorMessage = "Could not load terminal: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isReady else { return }
        initializationStatus = "Terminal page loaded; waiting for script initialization…"
        webView.evaluateJavaScript("JSON.stringify({terminal:typeof Terminal,fit:typeof FitAddon,body:document.body.innerText})") { [weak self] value, error in
            Task { @MainActor in
                guard let self, !self.isReady else { return }
                if let error {
                    self.errorMessage = "Terminal script inspection failed: \(error.localizedDescription)"
                } else if let value = value as? String {
                    self.initializationStatus = "Terminal initialization: \(value)"
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        initializationStatus = "Terminal navigation started…"
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        initializationStatus = "Terminal page committed; initializing scripts…"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorMessage = "Terminal web process terminated. Close and reopen the terminal to retry."
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let input = body["data"] as? String
        let columns = body["cols"] as? Int
        let rows = body["rows"] as? Int
        switch type {
        case "error":
            errorMessage = "Terminal initialization failed: \(input ?? "Unknown script error")"
        case "ready":
            isReady = true
            start()
            resize(columns: columns ?? 80, rows: rows ?? 24)
        case "input":
            if let input { send(input) }
        case "resize":
            resize(columns: columns ?? 80, rows: rows ?? 24)
        default: break
        }
    }

    private func start() {
        guard isReady, masterFD < 0 else { return }
        let launcher = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/SkynetPTYLauncher").path
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            errorMessage = "Terminal launcher is missing from the app bundle."
            return
        }
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            errorMessage = "Could not create a terminal PTY."
            return
        }
        defer { close(slave) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        // GUI launches may leave stdin closed, so openpty can return master == 0.
        // The dup2 actions above replace standard descriptors with the slave;
        // closing the old master number then would close the child's stdin.
        if master > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, master)
        }
        if slave > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, slave)
        }
        if sshHost == nil, let workingDirectory {
            let changeDirectoryStatus = workingDirectory.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
            guard changeDirectoryStatus == 0 else {
                close(master)
                errorMessage = "Could not open project directory in terminal."
                return
            }
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0 else {
            close(master)
            errorMessage = "Could not configure terminal session."
            return
        }

        let executable = sshHost == nil ? "/bin/zsh" : "/usr/bin/ssh"
        let arguments: [String]
        if let sshHost {
            let remote = workingDirectory.map {
                "cd \(SSHBackend.shellQuote($0)) && exec ${SHELL:-/bin/sh} -l"
            } ?? "exec ${SHELL:-/bin/sh} -l"
            arguments = [executable, "-tt"] + SSHBackend.connectionReuseOptions
                + ["--", sshHost, remote]
        } else {
            arguments = [executable, "-l"]
        }
        let environment = ProcessInfo.processInfo.environment
            .merging(extraEnvironment) { _, new in new }
            .filter { $0.key != "TERM" && $0.key != "COLORTERM" }
            .map { "\($0.key)=\($0.value)" }
            + ["TERM=xterm-256color", "COLORTERM=truecolor"]
        let argumentPointers: [UnsafeMutablePointer<CChar>?] = ([launcher] + arguments).map {
            $0.withCString { strdup($0) }
        }
        let environmentPointers: [UnsafeMutablePointer<CChar>?] = environment.map {
            $0.withCString { strdup($0) }
        }
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        var argv = argumentPointers + [nil]
        var envp = environmentPointers + [nil]
        var pid: pid_t = -1
        let status = launcher.withCString { path in
            argv.withUnsafeMutableBufferPointer { args in
                envp.withUnsafeMutableBufferPointer { env in
                    posix_spawn(&pid, path, &actions, &attributes, args.baseAddress, env.baseAddress)
                }
            }
        }
        guard status == 0 else {
            close(master)
            errorMessage = "Could not start terminal: \(String(cString: strerror(status)))"
            return
        }
        masterFD = master
        childPID = pid
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else {
                Task { @MainActor [weak self] in self?.stop() }
                return
            }
            let output = Data(buffer.prefix(count))
            Task { @MainActor [weak self] in self?.append(output) }
        }
        source.resume()
        readSource = source
        if let launchCommand { send(launchCommand + "\r") }
    }

    private func append(_ output: Data) {
        webView?.evaluateJavaScript("window.writeTerminalBase64('\(output.base64EncodedString())')")
    }

    private func send(_ input: String) {
        guard masterFD >= 0 else { return }
        let bytes = Array(input.utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(masterFD, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { break }
                offset += count
            }
        }
    }

    private func resize(columns: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: 0, ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
        if childPID > 0 { _ = kill(childPID, SIGWINCH) }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        // The interactive shell can put its foreground CLI in a separate job
        // group. Signal that group before closing the PTY, not just the shell.
        if masterFD >= 0, childPID > 0 {
            let foregroundGroup = tcgetpgrp(masterFD)
            if foregroundGroup > 0, foregroundGroup != getpgrp() {
                _ = kill(-foregroundGroup, SIGHUP)
            }
            if getpgid(childPID) == childPID, childPID != getpgrp() {
                _ = kill(-childPID, SIGHUP)
            }
        }
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        if childPID > 0 {
            let pid = childPID
            _ = kill(pid, SIGHUP)
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
            childPID = -1
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        webView = nil
    }

}
