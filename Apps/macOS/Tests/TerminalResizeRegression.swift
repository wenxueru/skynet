// Compile the imports and TerminalWebView/controller section of
// IntegratedTerminalView.swift, then this fixture, in the SAME input unit:
// awk 'FNR==NR {if(/^private struct TerminalWebView:/) t=1;
//   if(FNR<=4 || t) print;next}{print}' <source> <fixture> |
//   xcrun swiftc - -parse-as-library ...
// Link the built SkynetCore module/object. No production source is rewritten.
// The temporary executable bundle must contain
// the real TerminalAssets and Contents/Helpers/SkynetPTYLauncher. This fixture
// owns a hidden window and a local shell; it never opens a Skynet session.
@main
@MainActor
enum TerminalResizeRegression {
    static func main() async {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let controller = TerminalController()
        let usesUserLoginStartup = CommandLine.arguments.contains("--user-login-startup")
        controller.configure(
            workingDirectory: FileManager.default.currentDirectoryPath,
            sshHost: nil,
            launchCommand: "exec /usr/bin/env 'PS1=QA_NATIVE_PROMPT> ' /bin/sh -i +H",
            // Optional diagnostic uses the same global/user startup files as
            // the installed shell. The normal fixture remains hermetic.
            extraEnvironment: usesUserLoginStartup ? [:]
                : ["ZDOTDIR": Bundle.main.bundleURL.deletingLastPathComponent().path]
        )
        let webView = controller.makeWebView()
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 430),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 720, height: 430)
        defer { controller.stop(); window.close() }
        var shellPID: pid_t?
        do {
            try await eventually("terminal initialization") {
                if let error = controller.errorMessage { throw Failure(message: error) }
                return controller.isReady
            }
            try await eventually("fixture shell prompt") {
                try await terminalText(webView).split(separator: "\n").contains {
                    $0.trimmingCharacters(in: .whitespaces) == "QA_NATIVE_PROMPT>"
                }
            }
            if usesUserLoginStartup {
                print("PASS: global/user login startup reached the owned fixture prompt")
            }
            if CommandLine.arguments.contains("--foreground-stop") {
                try await verifyForegroundStop(controller, webView)
                return
            }
            // Read-only shell queries. The command/marker are distinct from any
            // user session, and the shell is owned entirely by this fixture.
            var previousGrid: [Int]?
            for (label, width, height) in [("A", 720.0, 430.0), ("B", 1040.0, 650.0), ("C", 600.0, 350.0)] {
                webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
                try await eventually("\(label) DOM viewport") {
                    let dimensions = try await js(webView, "[innerWidth,innerHeight]") as? [Int]
                    return dimensions == [Int(width), Int(height)]
                }
                // Wait for actual fit/resize callbacks, not a manually posted
                // resize event or manually assigned PTY dimensions.
                try await eventually("\(label) fitted xterm grid") {
                    try await js(webView, "(()=>{const d=fit.proposeDimensions();return !!d && terminal.rows===d.rows && terminal.cols===d.cols})()") as? Bool == true
                }
                let expected = try await js(webView, "[terminal.rows,terminal.cols]") as? [Int]
                guard let expected, expected.count == 2 else { throw Failure(message: "missing xterm grid") }
                guard previousGrid != expected else { throw Failure(message: "viewport changed without a new grid") }
                previousGrid = expected
                let marker = "QA_NATIVE_RESIZE_\(label)"
                let command = "printf '\(marker) '; /bin/stty size; printf 'QA_NATIVE_SHELL_PID %s\\n' \"$$\"\r"
                let json = String(data: try JSONSerialization.data(withJSONObject: [command]), encoding: .utf8)!
                _ = try await js(webView, "window.webkit.messageHandlers.terminal.postMessage({type:'input',data:\(json)[0]}); null")
                let result = "\(marker) \(expected[0]) \(expected[1])"
                try await eventually("\(label) real stty matches xterm \(expected)") {
                    let text = try await js(webView, "Array.from({length:terminal.buffer.active.length},(_,i)=>terminal.buffer.active.getLine(i).translateToString(true)).join('\\n')") as? String ?? ""
                    if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("QA_NATIVE_SHELL_PID ") }),
                       let pid = pid_t(line.dropFirst("QA_NATIVE_SHELL_PID ".count)), pid > 0 {
                        if let shellPID, shellPID != pid { throw Failure(message: "shell identity changed") }
                        shellPID = pid
                    }
                    return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == result }
                }
                print("PASS: \(label) viewport \(Int(width))x\(Int(height)), PTY \(expected[0])x\(expected[1])")
            }
            guard let shellPID else { throw Failure(message: "shell identity not recorded") }
            controller.stop()
            try await eventually("owned shell exit after Stop") {
                kill(shellPID, 0) == -1 && errno == ESRCH
            }
            print("PASS: owned shell \(shellPID) absent after Stop (not an exit-code-0 claim)")
            print("PASS: real terminal DOM resize -> fit -> native bridge -> PTY stty")
        } catch {
            print("FAIL: \(error)")
            if let text = try? await terminalText(webView) { print("Fixture terminal output:\n\(text)") }
            print("Fixture foreground group: \(controller.regressionForegroundGroup)")
            controller.stop()
            exit(1)
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let parent: pid_t
        let birthSeconds: UInt64
        let birthMicroseconds: UInt64

        static func read(_ pid: pid_t) -> Self? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Self(pid: pid, parent: pid_t(info.pbi_ppid),
                        birthSeconds: info.pbi_start_tvsec, birthMicroseconds: info.pbi_start_tvusec)
        }
    }

    private static func verifyForegroundStop(_ controller: TerminalController, _ view: WKWebView) async throws {
        // A sibling fixture process proves Stop is scoped to the PTY, not every
        // sleep process owned by the test runner. Never enumerate other sessions.
        let sibling = Process()
        sibling.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sibling.arguments = ["45"]
        try sibling.run()
        guard let siblingIdentity = ProcessIdentity.read(sibling.processIdentifier),
              siblingIdentity.parent == getpid() else { throw Failure(message: "sibling ownership") }
        defer {
            if ProcessIdentity.read(siblingIdentity.pid) == siblingIdentity {
                sibling.terminate()
                sibling.waitUntilExit()
            }
        }

        let command = "set -m; printf 'QA_FOREGROUND_SHELL %s\\n' \"$$\"; /bin/sleep 45 & printf 'QA_FOREGROUND_JOB %s\\n' \"$!\"; fg\r"
        let json = String(data: try JSONSerialization.data(withJSONObject: [command]), encoding: .utf8)!
        _ = try await js(view, "window.webkit.messageHandlers.terminal.postMessage({type:'input',data:\(json)[0]}); null")
        var shellPID: pid_t?
        var jobPID: pid_t?
        try await eventually("owned foreground job", timeout: 10) {
            let text = try await terminalText(view)
            for line in text.split(separator: "\n") {
                if line.hasPrefix("QA_FOREGROUND_SHELL ") { shellPID = pid_t(line.dropFirst("QA_FOREGROUND_SHELL ".count)) }
                if line.hasPrefix("QA_FOREGROUND_JOB ") { jobPID = pid_t(line.dropFirst("QA_FOREGROUND_JOB ".count)) }
            }
            guard let shellPID, let jobPID else { return false }
            return controller.regressionForegroundGroup == jobPID && jobPID != shellPID
        }
        guard let shellPID, let jobPID,
              let shell = ProcessIdentity.read(shellPID), shell.parent == getpid(),
              let job = ProcessIdentity.read(jobPID), job.parent == shellPID,
              getpgid(jobPID) == jobPID, controller.regressionForegroundGroup == jobPID else {
            throw Failure(message: "foreground PID/parent/group evidence missing")
        }
        print("LIVE: owned shell \(shellPID), foreground job \(jobPID), separate group \(getpgid(jobPID)), sibling \(siblingIdentity.pid)")
        let stopTime = Date()
        controller.stop()
        try await eventually("foreground job and shell absent after Stop", timeout: 5) {
            kill(shellPID, 0) == -1 && errno == ESRCH && kill(jobPID, 0) == -1 && errno == ESRCH
        }
        guard ProcessIdentity.read(siblingIdentity.pid) == siblingIdentity, sibling.isRunning else {
            throw Failure(message: "unrelated fixture sibling was stopped")
        }
        print("PASS: foreground job and shell absent within \(Date().timeIntervalSince(stopTime))s, before 45s natural duration")
        print("PASS: fixture sibling remains live; Stop is PTY-scoped (no child exit-code-0 claim)")
    }

    private static func terminalText(_ view: WKWebView) async throws -> String {
        try await js(view, "Array.from({length:terminal.buffer.active.length},(_,i)=>terminal.buffer.active.getLine(i).translateToString(true)).join('\\n')") as? String ?? ""
    }

    private static func js(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: Failure(message: "JS \(script.prefix(100)): \(error)")) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private static func eventually(_ label: String, timeout: TimeInterval = 20, condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure(message: "timeout: \(label)")
    }
}

// Same-file extension reads the actual PTY foreground group without changing
// production visibility or adding a diagnostic API to the installed app.
extension TerminalController {
    fileprivate var regressionForegroundGroup: pid_t { tcgetpgrp(masterFD) }
}
