import AppKit
import Observation
import SkynetCore
import SwiftUI

// Own offscreen window only. The presentation and permission sheet below are
// extracted from SessionDetailView, not a simulated button action order.
@MainActor
@Observable
private final class DialogModel {
    var pending = false {
        didSet { permissionRequestToken = pending ? UUID() : nil }
    }
    var permissionRequestToken: UUID?
    var pendingPermissionRequest: Bool? { pending ? true : nil }
    var decisions: [PermissionResponse.Decision] = []
    var stopCount = 0

    var permissionTurnStopAction: (() -> Void)? {
        guard pending else { return nil }
        return { [weak self] in
            self?.stopCount += 1
            self?.answerPermission(.deny)
        }
    }

    // PRODUCTION_PERMISSION_DECISION_FACTORY

    func answerPermission(_ decision: PermissionResponse.Decision) {
        guard pending else { return }
        decisions.append(decision)
        pending = false
    }
}

private struct DialogHost: View {
    @Bindable var model: DialogModel
    var permissionRequestDescription: String { "Owned native fixture: no provider or command." }
    // PRODUCTION_PERMISSION_PRESENTATION_BINDING
    var body: some View {
        Color.clear
        // PRODUCTION_PERMISSION_PRESENTATION
    }
}

// PRODUCTION_PERMISSION_SHEET

@main
@MainActor
enum PermissionDialogPresentationRegression {
    struct Failure: Error { let message: String }

    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await run() }
            catch { print("FAIL: \(error)"); exit(1) }
            app.terminate(nil)
        }
        // A full native event loop is required for accessibility clients and
        // SwiftUI virtual controls; an async command-line main alone lacks it.
        app.run()
    }

    private static func run() async throws {
        let interactive = CommandLine.arguments.contains("--interactive")
        if interactive { NSApplication.shared.setActivationPolicy(.regular) }
        let model = DialogModel()
        let parent = NSWindow(contentRect: NSRect(x: interactive ? 200 : -10000,
            y: interactive ? 200 : -10000, width: 900, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.title = "Skynet permission presentation fixture — no session"
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: DialogHost(model: model))
        parent.orderFront(nil)
        defer {
            model.pending = false
            if let sheet = parent.attachedSheet { parent.endSheet(sheet) }
            parent.close()
        }
        for (title, decision, stops) in [
            ("Stop turn", PermissionResponse.Decision.deny, 1),
            ("Allow once", .allow, 1),
            ("Always allow this session", .allowAlways, 1),
            ("Deny", .deny, 1),
        ] {
            model.pending = true
            if interactive {
                print("READY: own fixture native button \(title)")
            } else {
                var press: (() -> Bool)?
                try await eventually("native \(title) control") {
                    press = NSApplication.shared.windows.lazy.compactMap {
                        $0.contentView.flatMap { findPress($0, title: title) }
                    }.first
                    return press != nil
                }
                guard let press, press() else { throw Failure(message: "missing/unhandled \(title)") }
            }
            try await eventually("\(title) action/dismissal", timeout: interactive ? 180 : 8) { !model.pending }
            guard model.stopCount == stops, model.decisions.last == decision else {
                throw Failure(message: "\(title): stops=\(model.stopCount), decisions=\(model.decisions)")
            }
            try await eventually("native sheet removed") { parent.attachedSheet == nil }
            print("PASS: actual presentation \(title), exact decision and Stop count")
        }
    }

    private static func findPress(_ view: NSView, title: String) -> (() -> Bool)? {
        if let button = view as? NSButton, button.title == title {
            return { button.performClick(nil); return true }
        }
        if let press = findAccessibilityPress(view, title: title) { return press }
        return view.subviews.lazy.compactMap { findPress($0, title: title) }.first
    }

    private static func findAccessibilityPress(_ object: Any, title: String) -> (() -> Bool)? {
        guard let element = object as? NSAccessibilityProtocol else { return nil }
        if element.accessibilityRole() == .button,
           element.accessibilityLabel() == title || element.accessibilityTitle() == title {
            return { element.accessibilityPerformPress() }
        }
        return (element.accessibilityChildren() ?? []).lazy.compactMap {
            findAccessibilityPress($0, title: title)
        }.first
    }

    private static func eventually(_ label: String, timeout: TimeInterval = 8, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for window in NSApplication.shared.windows {
            print("WINDOW: \(window.title), sheet=\(window.isSheet), visible=\(window.isVisible)")
            if let content = window.contentView { dumpView(content); dumpAccessibility(content) }
        }
        throw Failure(message: "timeout: \(label)")
    }

    private static func dumpView(_ view: NSView) {
        print("VIEW: \(type(of: view)), label=\(view.accessibilityLabel() ?? ""), button=\((view as? NSButton)?.title ?? "")")
        view.subviews.forEach(dumpView)
    }

    private static func dumpAccessibility(_ object: Any) {
        guard let element = object as? NSAccessibilityProtocol else {
            print("AX: \(type(of: object)) does not conform to full protocol")
            return
        }
        print("AX: \(type(of: object)) role=\(element.accessibilityRole()?.rawValue ?? "") label=\(element.accessibilityLabel() ?? "") title=\(element.accessibilityTitle() ?? "")")
        (element.accessibilityChildren() ?? []).forEach(dumpAccessibility)
    }
}
