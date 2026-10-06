import SwiftUI
import AppKit

struct MarkdownEditor: NSViewRepresentable {
    @ObservedObject var model: ReaderModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        let view = NSTextView(frame: .zero)
        view.isRichText = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 40, height: 40)
        view.font = .monospacedSystemFont(ofSize: 19, weight: .regular)
        view.string = model.text; view.delegate = context.coordinator
        view.setAccessibilityLabel("Markdown source")
        scroll.documentView = view; model.editor = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        updateEditor(scroll, coordinator: context.coordinator)
    }
    // Use the same path for representable updates and regression coverage.
    func updateEditor(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if model.writing && view.string != model.text && !view.hasMarkedText(),
           !coordinator.wasWriting || coordinator.documentID != model.documentID ||
           (model.text != coordinator.lastModelText && view.string == coordinator.lastModelText) {
            view.string = model.text; view.undoManager?.removeAllActions()
        }
        coordinator.lastModelText = model.text; coordinator.documentID = model.documentID
        view.isEditable = !model.loading && model.writing
        scroll.isHidden = !model.writing
        if coordinator.wasWriting != model.writing {
            coordinator.wasWriting = model.writing
            if model.writing { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
            else if view.window?.firstResponder === view { view.window?.makeFirstResponder(model.webView) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if coordinator.model.editor === scroll.documentView { coordinator.model.editor = nil }
        (scroll.documentView as? NSTextView)?.delegate = nil
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ReaderModel
        var wasWriting = false
        var lastModelText: String
        var documentID: UUID
        init(_ model: ReaderModel) { self.model = model; lastModelText = model.text; documentID = model.documentID }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            model.sourceEditorDidChange(view.string)
            model.sourceEditorPostChange(view)
        }
    }
}
