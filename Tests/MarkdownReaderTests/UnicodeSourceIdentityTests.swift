import XCTest
import AppKit
import ReaderCore
@testable import MarkdownReader

final class UnicodeSourceIdentityTests: XCTestCase {
    private let composed = "# Caf\u{e9}\r\n"
    private let decomposed = "# Cafe\u{301}\r\n"

    @MainActor private func model() -> ReaderModel {
        let model = ReaderModel(pasteboardWriter: { _ in true })
        model.text = composed; model.baseline = composed
        return model
    }

    @MainActor func testDirtyRecognizesCanonicalEquivalentByteChanges() {
        let model = model()
        model.text = decomposed
        XCTAssertTrue(model.dirty)
    }

    @MainActor func testSourceEditAndModeSwitchUndoPreserveNormalizationChange() {
        let model = model()
        model.writing = true
        model.sourceEditorDidChange(decomposed)
        XCTAssertEqual(Data(model.text.utf8), Data(decomposed.utf8))
        model.writing = false
        model.undoEdit()
        XCTAssertEqual(Data(model.text.utf8), Data(composed.utf8))
        model.redoEdit()
        XCTAssertEqual(Data(model.text.utf8), Data(decomposed.utf8))
    }

    @MainActor func testRenderedEditAndHistoryPreserveNormalizationChange() {
        let model = model()
        model.editingEnabled = true
        model.acceptRenderedEdit(before: composed, text: decomposed,
            token: model.reviewRenderToken, passage: "paragraph")
        XCTAssertEqual(Data(model.text.utf8), Data(decomposed.utf8))
        model.undoEdit()
        XCTAssertEqual(Data(model.text.utf8), Data(composed.utf8))
        model.redoEdit()
        XCTAssertEqual(Data(model.text.utf8), Data(decomposed.utf8))
    }

    @MainActor func testRenderedEditRejectsCanonicallyEquivalentStaleSource() {
        let model = model()
        model.editingEnabled = true
        model.acceptRenderedEdit(before: decomposed, text: decomposed + "!",
            token: model.reviewRenderToken, passage: "paragraph")
        XCTAssertEqual(Data(model.text.utf8), Data(composed.utf8))
        XCTAssertNotNil(model.error)
    }

    @MainActor func testExternalSnapshotRefreshesExactBytesAndRenderForNormalizationChange() throws {
        let model = model()
        let previousID = model.documentID
        let previousToken = model.reviewRenderToken
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = Data(decomposed.utf8)
        try expected.write(to: url)
        model.applyExternalSnapshot(try DocumentSnapshot(url: url))
        XCTAssertEqual(model.snapshot?.bytes, expected)
        XCTAssertEqual(Data(model.text.utf8), expected)
        XCTAssertEqual(Data(model.baseline.utf8), expected)
        XCTAssertFalse(model.dirty)
        XCTAssertNotEqual(model.documentID, previousID)
        XCTAssertNotEqual(model.reviewRenderToken, previousToken)
    }

    @MainActor func testTaskToggleRejectsNormalizationOnlyStaleSource() {
        let model = model()
        model.text = "- [ ] Caf\u{e9}\r\n"; model.baseline = model.text
        let before = Data(model.text.utf8)
        model.toggleTask(before: "- [ ] Cafe\u{301}\r\n", offset: 3, checked: true,
            token: model.reviewRenderToken)
        XCTAssertEqual(Data(model.text.utf8), before)
        XCTAssertNotNil(model.error)
    }

    @MainActor func testAsyncSaveRetainsNewerNormalizationOnlyDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let coordinator = CollaborationCoordinator(enabled: true, localRoot: root.appendingPathComponent("local"))
        await coordinator.join(folder: shared, create: true, displayName: "Test")
        let model = ReaderModel(collaboration: coordinator, pasteboardWriter: { _ in false })
        model.text = composed; model.baseline = "original"; model.writing = true
        let editor = NSTextView(); editor.string = composed; model.editor = editor
        let destination = root.appendingPathComponent("copy.md")
        var result: Bool?
        model.requestSharedSave(asCopy: true, destination: destination) { result = $0 }
        editor.string = decomposed
        model.sourceEditorDidChange(decomposed)
        for _ in 0..<300 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(result, false)
        XCTAssertEqual(try Data(contentsOf: destination), Data(composed.utf8))
        XCTAssertEqual(Data(model.text.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(editor.string.utf8), Data(decomposed.utf8))
        XCTAssertTrue(model.dirty)
        await coordinator.stopWatching()
    }

}
