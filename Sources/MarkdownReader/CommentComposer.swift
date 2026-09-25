import SwiftUI

struct HighlightCommentDraft: Identifiable {
    let id: String
    let quote: String
    let text: String
    let documentKey: String
    let token: String
}

struct CommentComposer: View {
    let draft: HighlightCommentDraft
    let paper: Color
    let ink: Color
    let accent: Color
    let cancel: () -> Void
    let save: (String) -> String?
    @State private var text: String
    @State private var error: String?

    init(draft: HighlightCommentDraft, paper: Color, ink: Color, accent: Color,
         cancel: @escaping () -> Void, save: @escaping (String) -> String?) {
        self.draft = draft
        self.paper = paper
        self.ink = ink
        self.accent = accent
        self.cancel = cancel
        self.save = save
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1).fill(accent.opacity(0.65)).frame(width: 2)
                Text(draft.quote).font(.system(size: 13)).foregroundStyle(ink.opacity(0.65))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Leave feedback for your agent…")
                            .foregroundStyle(ink.opacity(0.5)).padding(.leading, 5).padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    CommentTextField(text: $text, ink: ink, accent: accent) { error = save(text) }
                        .accessibilityLabel("Comment")
                        .frame(height: 120)
                }
                .font(.system(size: 15))
                HStack {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.plain).foregroundStyle(ink.opacity(0.65))
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button { error = save(text) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .frame(width: 32, height: 32).background(accent, in: Circle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Save Comment").help("Enter to save · Shift+Enter for a new line")
                }
                .font(.system(size: 13))
            }
            .padding(14)
            .background(ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ink.opacity(0.16), lineWidth: 1))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(ink).accessibilityAddTraits(.isStaticText) }
        }
        .padding(24).frame(width: 520)
        .background(paper).foregroundStyle(ink).tint(accent)
    }
}
