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
        guard let view = scroll.documentView as? NSTextView else { return }
        if model.writing && view.string != model.text { view.string = model.text; view.undoManager?.removeAllActions() }
        view.isEditable = !model.loading && model.writing
        scroll.isHidden = !model.writing
        if context.coordinator.wasWriting != model.writing {
            context.coordinator.wasWriting = model.writing
            if model.writing { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
            else if view.window?.firstResponder === view { view.window?.makeFirstResponder(model.webView) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ReaderModel
        var wasWriting = false
        init(_ model: ReaderModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            model.text = view.string
        }
    }
}
