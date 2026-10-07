import AppKit
import SwiftUI

// Own offscreen hosting window; no installed app, session, provider or clipboard.
@main
@MainActor
enum ComposerUndoRegression {
    static func main() {
        _ = NSApplication.shared
        var draft = ""
        var selection = NSRange(location: 0, length: 0)
        var sends = 0
        var contextID = UUID()
        func composer() -> ComposerTextView {
            ComposerTextView(
                text: Binding(get: { draft }, set: { draft = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 }),
                onSend: { sends += 1 }
            )
        }
        let host = NSHostingView(rootView: composer().id(contextID).frame(width: 500, height: 180))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        func findTextView(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { findTextView($0) }.first
        }
        settle()
        guard let view = findTextView(host) else {
            print("FAIL: actual hosted composer missing")
            exit(1)
        }
        window.makeFirstResponder(view)
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures.append(label) }
        }
        let text = "撤销测试，Skynet 🧪\nsecond line"
        expect(view.allowsUndo, "real composer enables native undo")
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        view.breakUndoCoalescing()
        expect(draft == text && view.string == text, "Unicode multiline insert updates binding")
        expect(view.undoManager?.canUndo == true, "insert registers native undo")
        expect(view.tryToPerform(NSSelectorFromString("undo:"), with: nil), "native Undo responder handles action")
        settle()
        expect(view.string.isEmpty && draft.isEmpty, "undo clears text and binding")
        expect(view.undoManager?.canRedo == true, "undo registers redo")
        expect(view.tryToPerform(NSSelectorFromString("redo:"), with: nil), "native Redo responder handles action")
        settle()
        expect(view.string == text && draft == text, "redo restores exact text and binding")

        // A normal SwiftUI update must not destroy a user's undo history.
        host.rootView = composer().id(contextID).frame(width: 500, height: 180)
        settle()
        expect(view.undoManager?.canUndo == true, "unchanged binding update preserves undo")

        // Sends, take-back edits and selected-session changes replace the binding.
        // Undo must never resurrect the prior draft after such a replacement.
        draft = ""
        selection = NSRange(location: 0, length: 0)
        host.rootView = composer().id(contextID).frame(width: 500, height: 180)
        settle()
        expect(view.string.isEmpty, "external clear reaches native view")
        expect(view.undoManager?.canUndo == false && view.undoManager?.canRedo == false,
               "external clear removes stale undo and redo")
        view.insertText("new draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.breakUndoCoalescing()
        _ = view.tryToPerform(NSSelectorFromString("undo:"), with: nil)
        settle()
        expect(view.string.isEmpty && draft.isEmpty, "new draft undo stays within current draft")

        view.insertText("same text", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.breakUndoCoalescing()
        contextID = UUID()
        host.rootView = composer().id(contextID).frame(width: 500, height: 180)
        settle()
        if let nextView = findTextView(host) {
            expect(nextView !== view && nextView.string == "same text", "new context recreates equal-text composer")
            expect(nextView.undoManager?.canUndo == false && nextView.undoManager?.canRedo == false,
                   "equal-text context cannot undo previous context")

            // Each settle is a genuine run-loop boundary, like separate user
            // edits; do not fabricate undo groups or edit the binding afterward.
            draft = "A🧪中B"
            selection = NSRange(location: 3, length: 1)
            host.rootView = composer().id(contextID).frame(width: 500, height: 180)
            settle()
            window.makeFirstResponder(nextView)
            nextView.insertText("新", replacementRange: nextView.selectedRange())
            nextView.breakUndoCoalescing()
            settle()
            expect(draft == "A🧪新B" && selection == nextView.selectedRange(),
                   "UTF-16 selection replacement synchronizes binding")
            nextView.setSelectedRange(NSRange(location: nextView.string.utf16.count, length: 0))
            nextView.insertText("\n尾", replacementRange: nextView.selectedRange())
            nextView.breakUndoCoalescing()
            settle()
            expect(draft == "A🧪新B\n尾", "second independent edit appends newline and CJK")

            let undo = NSSelectorFromString("undo:")
            let redo = NSSelectorFromString("redo:")
            _ = nextView.tryToPerform(undo, with: nil)
            settle()
            expect(draft == "A🧪新B" && nextView.string == draft,
                   "first undo reverses only second edit")
            expect(selection == nextView.selectedRange(), "first undo selection binding matches native")
            _ = nextView.tryToPerform(undo, with: nil)
            settle()
            expect(draft == "A🧪中B" && nextView.string == draft,
                   "second undo restores original Unicode replacement")
            expect(selection == nextView.selectedRange(), "second undo selection binding matches native")
            _ = nextView.tryToPerform(redo, with: nil)
            settle()
            expect(draft == "A🧪新B" && selection == nextView.selectedRange(),
                   "first redo restores only first edit and selection")
            _ = nextView.tryToPerform(redo, with: nil)
            settle()
            expect(draft == "A🧪新B\n尾" && selection == nextView.selectedRange(),
                   "second redo restores multiline edit and selection")

            _ = nextView.tryToPerform(undo, with: nil)
            settle()
            nextView.setSelectedRange(NSRange(location: nextView.string.utf16.count, length: 0))
            nextView.insertText("Z", replacementRange: nextView.selectedRange())
            nextView.breakUndoCoalescing()
            settle()
            expect(draft == "A🧪新BZ" && nextView.undoManager?.canRedo == false,
                   "new edit after undo invalidates obsolete redo branch")
        } else {
            expect(false, "new context composer present")
        }
        expect(sends == 0, "editing never invokes Send")
        if !failures.isEmpty { exit(1) }
    }
}
