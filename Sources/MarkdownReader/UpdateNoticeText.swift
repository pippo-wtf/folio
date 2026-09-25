import SwiftUI

/// A short scrambling reveal inspired by AnimateText's ATRandomTypoEffect.
/// Each glyph keeps its final width so the native toolbar never shifts.
struct UpdateNoticeText: View {
    private let message = "App Update available. Check it out."
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0
    private let frameCount = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(message.enumerated()), id: \.offset) { index, character in
                Text(String(character)).hidden()
                    .overlay {
                        Text(glyph(character, index: index))
                            .offset(x: settled(index) ? 0 : 2)
                    }
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            if reduceMotion { frame = frameCount; return }
            frame = 0
            for next in 1...frameCount {
                do { try await Task.sleep(for: .milliseconds(40)) }
                catch { return }
                frame = next
            }
        }
    }

    private func settled(_ index: Int) -> Bool {
        reduceMotion || frame >= frameCount || Double(frame) / Double(frameCount) >= Double(index + 1) / Double(message.count)
    }

    private func glyph(_ character: Character, index: Int) -> String {
        if character.isWhitespace || settled(index) { return String(character) }
        let symbols = Array("--#-+=/01-x-")
        return String(symbols[(index * 7 + frame * 3) % symbols.count])
    }
}
