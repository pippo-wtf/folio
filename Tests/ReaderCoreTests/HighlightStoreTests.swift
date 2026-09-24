import XCTest
@testable import ReaderCore
final class HighlightStoreTests: XCTestCase {
    func testPreviewUsesFirstSentenceAndCollapsesWhitespace() {
        let mark = SavedHighlight(id: UUID().uuidString, start: 0, quote: "First sentence spans\n two lines. Second sentence stays hidden.", prefix: "", suffix: "")
        XCTAssertEqual(mark.preview, "First sentence spans two lines.")
        let fragment = SavedHighlight(id: UUID().uuidString, start: 0, quote: "  A passage without punctuation  ", prefix: "", suffix: "")
        XCTAssertEqual(fragment.preview, "A passage without punctuation")
    }
    func testPersistenceIsolationRemovalAndOriginalUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("notes.md")
        let bytes = Data("# Notes\n\nKeep **these words**.\n".utf8)
        try bytes.write(to: original)
        let store = HighlightStore(directory: root.appendingPathComponent("marks"))
        let mark = SavedHighlight(id: UUID().uuidString, start: 4, quote: "these words", prefix: "Keep ", suffix: ".")
        try store.save([mark], for: original.path)
        XCTAssertEqual(try HighlightStore(directory: store.directory).load(for: original.path), [mark])
        XCTAssertEqual(try store.load(for: "another-document"), [])
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        try store.save([], for: original.path)
        XCTAssertEqual(try store.load(for: original.path), [])
    }
    func testInvalidRecordsCannotReplaceSavedHighlights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HighlightStore(directory: root)
        let mark = SavedHighlight(id: UUID().uuidString, start: 0, quote: "words", prefix: "", suffix: "")
        try store.save([mark], for: "a")
        var bad = mark; bad.start = -1
        XCTAssertThrowsError(try store.save([bad], for: "a"))
        XCTAssertThrowsError(try store.save([mark, mark], for: "a"))
        XCTAssertEqual(try store.load(for: "a"), [mark])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("bad json".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(for: "a"))
    }
}
