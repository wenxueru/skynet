import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var onSend: () -> Void
    var onPasteImage: (Data) -> Void = { _ in }
    var onPasteFiles: ([URL]) -> Void = { _ in }
    var suggestionsPresented = false
    var onMoveSuggestion: (Int) -> Void = { _ in }
    var onAcceptSuggestion: () -> Void = {}
    var onDismissSuggestions: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let view = ComposerNativeTextView()
        view.delegate = context.coordinator
        view.onPasteImage = { [weak coordinator = context.coordinator] data in
            coordinator?.parent.onPasteImage(data)
        }
        view.onPasteFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onPasteFiles(urls)
        }
        view.font = .preferredFont(forTextStyle: .body)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 4, height: 7)
        view.textContainer?.widthTracksTextView = true
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Do not replace NSTextView's contents while an IME owns a marked-text
        // composition; doing so cancels the in-progress input method session.
        guard !view.hasMarkedText() else { return }
        if view.string != text {
            // A sent/cleared/replaced draft is a new editing context. Do not
            // let Undo restore text from the previous draft.
            view.undoManager?.removeAllActions()
            view.string = text
        }
        if view.selectedRange() != selection, NSMaxRange(selection) <= view.string.utf16.count {
            view.setSelectedRange(selection)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        // Keep draft edits separate from other controls sharing the window.
        private let draftUndoManager = UndoManager()
        private weak var undoTextView: NSTextView?

        init(parent: ComposerTextView) {
            self.parent = parent
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(undoDidChange(_:)), name: name, object: draftUndoManager
                )
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoTextView = view
            return draftUndoManager
        }

        @objc private func undoDidChange(_ notification: Notification) {
            // Native Undo/Redo can mutate text storage without textDidChange.
            // Sync the binding before SwiftUI can restore the old draft.
            textDidChange(Notification(name: NSText.didChangeNotification, object: undoTextView))
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // Candidate confirmation/navigation belongs to the active IME,
            // not message sending or the composer's completion menu.
            guard !textView.hasMarkedText() else { return false }
            if parent.suggestionsPresented {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onMoveSuggestion(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onMoveSuggestion(1)
                    return true
                case #selector(NSResponder.insertTab(_:)),
                     #selector(NSResponder.insertNewline(_:)):
                    parent.onAcceptSuggestion()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onDismissSuggestions()
                    return true
                default:
                    break
                }
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSend()
            }
            return true
        }
    }
}

private final class ComposerNativeTextView: NSTextView {
    var onPasteImage: ((Data) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageFileURLs(on: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = imageFileURLs(on: sender.draggingPasteboard)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        onPasteFiles?(files)
        return true
    }

    private func imageFileURLs(on board: NSPasteboard) -> [URL] {
        (board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []).filter {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        }
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        let imageFiles = imageFileURLs(on: board)
        if !imageFiles.isEmpty {
            onPasteFiles?(imageFiles)
            return
        }

        if let data = board.data(forType: NSPasteboard.PasteboardType("public.png")) {
            onPasteImage?(data)
            return
        }
        if let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
            return
        }
        super.paste(sender)
    }
}
