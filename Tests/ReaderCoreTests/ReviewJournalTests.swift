import XCTest
@testable import ReaderCore
final class ReviewJournalTests: XCTestCase {
    func testCommentHistoryAndRemovalSurviveRestartWithoutDuplicateEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HighlightStore(directory: root)
        var mark = SavedHighlight(id: UUID().uuidString, start: 3, quote: "café 😀", prefix: "a ", suffix: " end")
        mark.revision = HighlightStore.revision("# café 😀")
        try store.save([mark], for: "file", revision: mark.revision)
        mark.comment = "Explain this for designers."
        try store.save([mark], for: "file", revision: mark.revision, draft: true)
        try store.save([mark], for: "file", revision: mark.revision)
        let reopened = HighlightStore(directory: root)
        XCTAssertEqual(try reopened.load(for: "file"), [mark])
        try reopened.save([], for: "file", revision: mark.revision)
        let events = try reopened.events(for: "file")
        XCTAssertEqual(events.map(\.sequence), [1,2,3])
        XCTAssertEqual(events.map(\.operation), ["added","updated","removed"])
        XCTAssertEqual(events.last?.before?.comment, mark.comment)
        XCTAssertTrue(events[1].draft)
        let packet = try JSONSerialization.jsonObject(with: reopened.feedback(for: "file", currentText: "# café 😀", draft: false)) as! [String: Any]
        XCTAssertEqual(packet["currentRevision"] as? String, mark.revision)
        XCTAssertEqual((packet["events"] as? [Any])?.count, 3)
    }
    func testLegacyMarksMigrateAndOversizedCommentCannotReplaceThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HighlightStore(directory: root)
        var mark = SavedHighlight(id: UUID().uuidString, start: 0, quote: "hello", prefix: "", suffix: "")
        try store.save([mark], for: "file")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let legacy: [String: Any] = ["version": 1, "highlights": [["id": mark.id, "start": 0, "quote": "hello", "prefix": "", "suffix": ""]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        XCTAssertEqual(try store.load(for: "file"), [mark])
        mark.comment = String(repeating: "a", count: 8001)
        XCTAssertThrowsError(try store.save([mark], for: "file"))
        XCTAssertNil(try store.load(for: "file").first?.comment)
        mark.comment = "Keep this."
        try store.save([mark], for: "file")
        XCTAssertEqual(try store.events(for: "file").count, 1)
    }
    func testRecoveryRoundTripAndCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(url: root.appendingPathComponent("draft.json"))
        let value = RecoveryDraft(text: "# Draft\n😀", title: "Notes", originalPath: "/notes.md")
        try store.save(value); XCTAssertEqual(try store.load(), value)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try store.clear(); XCTAssertNil(try store.load())
    }
}
