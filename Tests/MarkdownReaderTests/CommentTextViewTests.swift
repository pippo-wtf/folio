import XCTest
import AppKit
@testable import MarkdownReader

final class CommentTextViewTests: XCTestCase {
    @MainActor func testEnterSavesWithoutAddingNewlineAndShiftEnterAddsNewline() {
        _ = NSApplication.shared
        let field = CommentTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        field.string = "Feedback"
        field.setSelectedRange(NSRange(location: 8, length: 0))
        var submitted = 0
        field.submit = { submitted += 1 }
        func enter(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        field.keyDown(with: enter())
        XCTAssertEqual(submitted, 1)
        XCTAssertEqual(field.string, "Feedback")
        field.keyDown(with: enter(.shift))
        XCTAssertEqual(submitted, 1)
        XCTAssertEqual(field.string, "Feedback\n")
    }
}
