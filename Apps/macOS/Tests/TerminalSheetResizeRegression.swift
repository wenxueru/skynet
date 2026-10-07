// Compile actual IntegratedTerminalView and its terminal section in this unit.
// Owns one offscreen SwiftUI sheet and local shell; no session is persisted.
@MainActor
private final class SheetFixtureState: ObservableObject {
    @Published var presented = false
}

private struct SheetFixtureHost: View {
    @ObservedObject var state: SheetFixtureState

    var body: some View {
        Color.clear.sheet(isPresented: $state.presented) {
            IntegratedTerminalView(
                mode: .shell,
                session: SessionRecord(providerID: .codex,
                    workingDirectory: "/workspace/skynet"),
                provider: nil
            )
        }
    }
}

@main
@MainActor
enum TerminalSheetResizeRegression {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() async {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func run() async throws {
        let state = SheetFixtureState()
        let parent = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: SheetFixtureHost(state: state))
        parent.orderFront(nil)
        var cleanupController: TerminalController?
        defer {
            state.presented = false
            if let sheet = parent.attachedSheet { parent.endSheet(sheet) }
            parent.close()
            cleanupController?.stop()
        }
        state.presented = true
        try await eventually("actual SwiftUI sheet") { parent.attachedSheet != nil }
        guard let sheet = parent.attachedSheet else { throw Failure(description: "missing sheet") }
        sheet.isReleasedWhenClosed = false
        print("OBSERVED: actual sheet resizable=\(sheet.styleMask.contains(.resizable)), contentMinSize=\(sheet.contentMinSize), content=\(sheet.contentView?.bounds.size ?? .zero)")
        var page: WKWebView?
        try await eventually("actual Terminal web view") {
            page = sheet.contentView.flatMap(findPage)
            return page != nil
        }
        guard let page else { throw Failure(description: "missing actual terminal page") }
        cleanupController = page.navigationDelegate as? TerminalController
        try await eventually("actual terminal ready") {
            cleanupController?.isReady == true && cleanupController!.regressionSheetChildPID > 0
        }
        print("LIVE: fixture \(getpid()), own shell \(cleanupController!.regressionSheetChildPID)")
        try await eventually("actual terminal sheet resizable style") { sheet.styleMask.contains(.resizable) }
        if #available(macOS 15, *) {
            guard sheet.contentMinSize.width >= 720, sheet.contentMinSize.height >= 480 else {
                throw Failure(description: "fitted sheet lost terminal minimum size")
            }
        }
        var shellPID: pid_t?
        var previousGrid: [Int]?
        for (label, width, height) in [("A", 760.0, 520.0), ("B", 1040.0, 720.0), ("C", 820.0, 560.0)] {
            sheet.setContentSize(NSSize(width: width, height: height))
            try await eventually("\(label) actual sheet layout") {
                guard let content = sheet.contentView else { return false }
                return abs(content.bounds.width - width) < 1 && abs(content.bounds.height - height) < 1
                    && abs(page.bounds.width - width) < 1 && page.bounds.height > 100
            }
            try await eventually("\(label) DOM/fit follows SwiftUI") {
                let viewport = try await js(page, "[innerWidth, innerHeight]") as? [Int]
                let fitted = try await js(page, "(()=>{const d=fit.proposeDimensions();return !!d && terminal.rows===d.rows && terminal.cols===d.cols})()") as? Bool
                return viewport == [Int(page.bounds.width), Int(page.bounds.height)] && fitted == true
            }
            guard let grid = try await js(page, "[terminal.rows,terminal.cols]") as? [Int], grid.count == 2,
                  grid != previousGrid else { throw Failure(description: "\(label) unchanged/missing grid") }
            previousGrid = grid
            let marker = "QA_SWIFTUI_SHEET_\(label)"
            let command = "printf '\(marker) '; /bin/stty size; printf 'QA_SHEET_PID %s\\n' \"$$\"\r"
            let encoded = String(data: try JSONSerialization.data(withJSONObject: [command]), encoding: .utf8)!
            _ = try await js(page, "window.webkit.messageHandlers.terminal.postMessage({type:'input',data:\(encoded)[0]}); null")
            try await eventually("\(label) actual PTY matches fitted grid") {
                let lines = try await text(page).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if let line = lines.first(where: { $0.hasPrefix("QA_SHEET_PID ") }),
                   let pid = pid_t(line.dropFirst("QA_SHEET_PID ".count)), pid > 0 {
                    if let shellPID, shellPID != pid { throw Failure(description: "shell identity changed") }
                    shellPID = pid
                }
                return lines.contains("\(marker) \(grid[0]) \(grid[1])")
            }
            print("PASS: actual SwiftUI sheet \(label) \(Int(width))x\(Int(height)), page \(page.bounds.size), PTY \(grid)")
        }
        guard let shellPID else { throw Failure(description: "own shell PID unavailable") }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { state.presented = false }
        try await eventually("SwiftUI sheet dismissal") { parent.attachedSheet == nil }
        print("DISMISSED: sheet visible=\(sheet.isVisible), controller child=\(cleanupController!.regressionSheetChildPID), terminal shell=\(shellPID)")
        // Offscreen SwiftUI dismissal does not reliably deliver onDisappear.
        // Installed Close is verified separately; never leak the fixture shell.
        cleanupController?.stop()
        try await eventually("owned shell absent after explicit controller Stop") {
            kill(shellPID, 0) == -1 && errno == ESRCH
        }
        print("PASS: actual controller Stop removed own fixture shell \(shellPID)")
    }

    private static func findPage(_ view: NSView) -> WKWebView? {
        if let page = view as? WKWebView { return page }
        return view.subviews.lazy.compactMap(findPage).first
    }

    private static func text(_ page: WKWebView) async throws -> String {
        try await js(page, "Array.from({length:terminal.buffer.active.length},(_,i)=>terminal.buffer.active.getLine(i).translateToString(true)).join('\\n')") as? String ?? ""
    }

    private static func js(_ page: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            page.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result) }
            }
        }
    }

    private static func eventually(_ label: String, condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure(description: "timeout: \(label)")
    }
}

// Same-file fixture access only, no diagnostic API in production.
extension TerminalController {
    fileprivate var regressionSheetChildPID: pid_t { childPID }
}
