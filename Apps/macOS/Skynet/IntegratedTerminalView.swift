import Darwin
import SkynetCore
import SwiftUI
import WebKit

struct IntegratedTerminalView: View {
    enum Mode: String, Identifiable {
        case shell, agent
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
                Label(mode == .shell ? "Terminal" : "Agent terminal", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(12)
            Divider()
            if mode == .agent {
                Text("Starts a separate interactive CLI for this conversation; it does not attach to an already-running terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            TerminalWebView(controller: terminal)
            if let error = terminal.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            terminal.configure(
                workingDirectory: session.workingDirectory,
                sshHost: session.backendID?.rawValue.hasPrefix("ssh:") == true
                    ? String(session.backendID!.rawValue.dropFirst("ssh:".count)) : nil,
                launchCommand: agentCommand,
                extraEnvironment: mode == .agent ? provider?.environment ?? [:] : [:]
            )
        }
        .onDisappear { terminal.stop() }
    }

    private var agentCommand: String? {
        guard mode == .agent, let token = session.providerResumeToken,
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
}

private struct TerminalWebView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController

    func makeNSView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor
private final class TerminalController: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var errorMessage: String?
    private var webView: WKWebView?
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var workingDirectory: String?
    private var sshHost: String?
    private var launchCommand: String?
    private var extraEnvironment: [String: String] = [:]
    private var isReady = false

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
        let content = WKUserContentController()
        content.add(self, name: "terminal")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        webView = view
        if let url = Bundle.main.url(
            forResource: "terminal", withExtension: "html", subdirectory: "TerminalAssets"
        ) {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            errorMessage = "Terminal resources are missing from the app bundle."
        }
        return view
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
        posix_spawn_file_actions_addclose(&actions, master)
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
        let argumentPointers: [UnsafeMutablePointer<CChar>?] = arguments.map {
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
        let status = executable.withCString { path in
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
