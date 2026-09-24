import Foundation
import XCTest
@testable import ReaderCore

final class EditJournalStoreTests: XCTestCase {
    private func fixture() -> (URL, EditJournalStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, EditJournalStore(directory: root))
    }

    func testUTF8OffsetsAndExactReplayAcrossUnicodeAndCRLF() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = "# Café\r\n😀 café\r\nPrice €19\r\n"
        let after = "# Café\r\n😃 café\r\nPrice €29\r\n"
        let event = try XCTUnwrap(store.record(for: "doc", from: before, to: after, kind: .sourceEdit))
        XCTAssertEqual(event.replacement?.offsetUTF8, Array("# Café\r\n".utf8).count)
        XCTAssertEqual(event.replacement?.oldText, "😀 café\r\nPrice €1")
        XCTAssertEqual(event.replacement?.newText, "😃 café\r\nPrice €2")
        XCTAssertEqual(try EditJournalStore.replay(event, on: before), after)
        XCTAssertEqual(try EditJournalStore.replay(event, on: after, reversing: true), before)
        XCTAssertEqual(try store.load(for: "doc").events, [event])
    }

    func testInsertionDeletionUndoRedoAndSaveCheckpoint() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = "A\r\nB\r\n"
        let inserted = "A\r\nB!\r\n"
        let first = try XCTUnwrap(store.record(for: "doc", from: start, to: inserted, kind: .renderedEdit))
        XCTAssertEqual(first.replacement?.oldText, "")
        XCTAssertEqual(first.replacement?.newText, "!")
        let second = try XCTUnwrap(store.record(for: "doc", from: inserted, to: start, kind: .undo))
        XCTAssertEqual(second.replacement?.oldText, "!")
        XCTAssertEqual(second.replacement?.newText, "")
        let third = try XCTUnwrap(store.record(for: "doc", from: start, to: inserted, kind: .redo))
        let saved = try XCTUnwrap(store.record(for: "doc", from: inserted, to: inserted, kind: .save))
        XCTAssertNil(saved.replacement)
        XCTAssertEqual(saved.beforeRevision, saved.afterRevision)
        XCTAssertEqual(try EditJournalStore.replay(saved, on: inserted), inserted)
        XCTAssertEqual(try store.load(for: "doc").events.map(\.kind), [.renderedEdit, .undo, .redo, .save])
        XCTAssertEqual(try store.record(for: "doc", from: inserted, to: inserted, kind: .save), saved)
        XCTAssertEqual(try EditJournalStore.replay(third, on: start), inserted)
    }

    func testRenderedTypingCoalescesButSeparateOperationsRemainDistinct() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(store.record(for: "doc", from: "a", to: "ab", kind: .renderedEdit,
            date: start, coalesceRenderedEdits: true))
        let second = try XCTUnwrap(store.record(for: "doc", from: "ab", to: "abc", kind: .renderedEdit,
            date: start.addingTimeInterval(0.5), coalesceRenderedEdits: true))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.replacement?.oldText, "")
        XCTAssertEqual(second.replacement?.newText, "bc")
        XCTAssertEqual(try store.load(for: "doc").events.count, 1)
        _ = try store.record(for: "doc", from: "abc", to: "abcd", kind: .renderedEdit,
            date: start.addingTimeInterval(2), coalesceRenderedEdits: true)
        XCTAssertEqual(try store.load(for: "doc").events.count, 2)
    }

    func testRevisionMismatchBadPatchAndEventIDCollisionDoNotMutateJournal() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let event = try XCTUnwrap(store.record(for: "doc", from: "hello", to: "hello!", kind: .sourceEdit, id: id))
        let original = try store.load(for: "doc")
        XCTAssertThrowsError(try store.record(for: "doc", from: "stale", to: "different", kind: .save)) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .revisionMismatch)
        }
        XCTAssertThrowsError(try store.record(for: "doc", from: "hello!", to: "other", kind: .undo, id: id)) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .eventIDConflict)
        }
        XCTAssertThrowsError(try EditJournalStore.replay(event, on: "hello?")) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .revisionMismatch)
        }
        let tampered = EditJournalStore.Event(id: event.id, sequence: event.sequence,
            date: event.date, updatedAt: event.updatedAt, kind: event.kind,
            beforeRevision: event.beforeRevision, afterRevision: event.afterRevision,
            replacement: .init(offsetUTF8: 0, oldText: "wrong", newText: "hello!"),
            gapReason: nil)
        XCTAssertThrowsError(try EditJournalStore.replay(tampered, on: "hello")) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .invalidReplacement)
        }
        XCTAssertEqual(try store.load(for: "doc"), original)
    }

    func testOversizeCorruptionAndHistoryLimitPreserveExistingData() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try store.record(for: "big", from: "", to: String(repeating: "x", count: EditJournalStore.maximumDocumentBytes + 1), kind: .sourceEdit)) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .documentTooLarge)
        }
        var text = ""
        for _ in 0..<EditJournalStore.maximumEvents {
            let next = text + "x"
            _ = try store.record(for: "limited", from: text, to: next, kind: .sourceEdit)
            text = next
        }
        let full = try store.load(for: "limited")
        XCTAssertThrowsError(try store.record(for: "limited", from: text, to: text + "x", kind: .sourceEdit)) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .historyFull)
        }
        XCTAssertEqual(try store.load(for: "limited"), full)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try store.load(for: "limited")) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .corruptJournal)
        }
    }

    func testSaveAsCopiesOnlyIntoAnAbsentDestination() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.record(for: "source", from: "one", to: "two", kind: .sourceEdit)
        XCTAssertTrue(try store.copyIfAbsent(from: "source", to: "fresh"))
        XCTAssertEqual(try store.load(for: "fresh"), try store.load(for: "source"))
        XCTAssertFalse(try store.copyIfAbsent(from: "source", to: "fresh"))
        _ = try store.record(for: "existing", from: "other", to: "other!", kind: .sourceEdit)
        let existing = try store.load(for: "existing")
        XCTAssertFalse(try store.copyIfAbsent(from: "source", to: "existing"))
        XCTAssertEqual(try store.load(for: "existing"), existing)
    }

    func testClosedFileDriftIsExplicitNonReplayableGap() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try store.recordExternalGap(for: "doc", observedText: "initial"))
        _ = try store.record(for: "doc", from: "initial", to: "edited", kind: .sourceEdit)
        let reopened = EditJournalStore(directory: root)
        let gap = try XCTUnwrap(reopened.recordExternalGap(for: "doc", observedText: "external"))
        XCTAssertEqual(gap.kind, .externalReload)
        XCTAssertEqual(gap.gapReason, "source-before-unavailable")
        XCTAssertNil(gap.replacement)
        XCTAssertEqual(gap.beforeRevision, EditJournalStore.revision("edited"))
        XCTAssertEqual(gap.afterRevision, EditJournalStore.revision("external"))
        XCTAssertThrowsError(try EditJournalStore.replay(gap, on: "edited")) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .nonReplayableGap)
        }
        XCTAssertNil(try reopened.recordExternalGap(for: "doc", observedText: "external"))
        let next = try XCTUnwrap(reopened.record(for: "doc", from: "external", to: "external!", kind: .sourceEdit))
        XCTAssertEqual(try EditJournalStore.replay(next, on: "external"), "external!")
        XCTAssertEqual(try reopened.load(for: "doc").events.count, 3)
    }

    func testOversizedStoredFileIsReadWithBoundAndLeftUntouched() throws {
        let (root, store) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.record(for: "doc", from: "a", to: "b", kind: .sourceEdit)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(EditJournalStore.maximumJournalBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try store.load(for: "doc")) {
            XCTAssertEqual($0 as? EditJournalStore.JournalError, .journalTooLarge)
        }
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            EditJournalStore.maximumJournalBytes + 1)
    }
}
