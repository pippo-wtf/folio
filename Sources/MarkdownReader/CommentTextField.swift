import AppKit
import SwiftUI

/// Intercept Return at the native text view so it cannot insert a newline before saving.
final class CommentTextView: NSTextView {
    var submit: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76),
           !modifiers.contains(.shift), !modifiers.contains(.option),
           !modifiers.contains(.control), !hasMarkedText() {
            if !event.isARepeat { submit() }
            return
        }
        super.keyDown(with: event)
    }
}

struct CommentTextField: NSViewRepresentable {
    @Binding var text: String
    let ink: Color
    let accent: Color
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        let field = CommentTextView(frame: .zero)
        field.isRichText = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 15)
        field.textContainerInset = NSSize(width: 0, height: 8)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Comment")
        field.setAccessibilityHelp("Enter to save. Shift Enter for a new line.")
        scroll.documentView = field
        updateNSView(scroll, context: context)
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let field = scroll.documentView as? CommentTextView else { return }
        if field.string != text { field.string = text }
        field.textColor = NSColor(ink)
        field.insertionPointColor = NSColor(accent)
        field.submit = submit
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentTextField
        init(_ parent: CommentTextField) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextView else { return }
            parent.text = field.string
        }
    }
}
