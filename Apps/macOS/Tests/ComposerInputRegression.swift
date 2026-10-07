import AppKit
import SwiftUI

// Run against the real composer source, without a window, session, or provider:
// DEVELOPER_DIR=<Xcode>/Contents/Developer xcrun swiftc -swift-version 5
//   -parse-as-library Apps/macOS/Skynet/ComposerTextView.swift
//   Apps/macOS/Tests/ComposerInputRegression.swift -o <temporary executable>
@main
@MainActor
enum ComposerInputRegression {
    static func main() {
        _ = NSApplication.shared
        var draft = ""
        var selection = NSRange(location: 0, length: 0)
        var sends = 0
        var accepts = 0
        var moves: [Int] = []
        var dismisses = 0
        let composer = ComposerTextView(
            text: Binding(get: { draft }, set: { draft = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            onSend: { sends += 1 },
            suggestionsPresented: true,
            onMoveSuggestion: { moves.append($0) },
            onAcceptSuggestion: { accepts += 1 },
            onDismissSuggestions: { dismisses += 1 }
        )
        let coordinator = composer.makeCoordinator()
        let view = NSTextView()
        view.delegate = coordinator
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        expect(view.hasMarkedText(), "native marked-text fixture")
        let commands = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.cancelOperation(_:))
        ]
        for command in commands {
            expect(!coordinator.textView(view, doCommandBy: command),
                   "IME retains \(NSStringFromSelector(command))")
        }
        expect(accepts == 0 && moves.isEmpty && dismisses == 0,
               "marked text does not invoke composer suggestions")
        coordinator.parent.suggestionsPresented = false
        expect(!coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))),
               "marked Enter not consumed as Send")
        expect(sends == 0, "marked Enter does not send")
        expect(view.hasMarkedText() && view.string == "中文", "composition remains intact")

        view.unmarkText()
        expect(!view.hasMarkedText(), "native composition commit")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        expect(draft == "中文" && selection == view.selectedRange(), "committed text binding")
        expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))),
               "committed Enter handled")
        expect(sends == 1, "committed Enter sends once")
        coordinator.parent.suggestionsPresented = true
        for command in commands {
            expect(coordinator.textView(view, doCommandBy: command),
                   "committed suggestion handles \(NSStringFromSelector(command))")
        }
        expect(accepts == 2 && moves == [-1, 1] && dismisses == 1,
               "ordinary suggestion commands preserved")
        if failures.isEmpty {
            print("PASS: native composition, committed binding, Send and suggestion commands")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
