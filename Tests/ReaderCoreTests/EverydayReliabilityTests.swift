import XCTest
@testable import ReaderCore

final class EverydayReliabilityTests: XCTestCase {
    func testLimitBoundaryAndFailedSavePreserveOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("boundary.md")
        let original = Data(repeating: 65, count: DocumentReader.maximumBytes)
        try original.write(to: url)
        let snapshot = try DocumentSnapshot(url: url)
        XCTAssertEqual(snapshot.bytes.count, DocumentReader.maximumBytes)
        XCTAssertThrowsError(try snapshot.save(snapshot.text + "x", to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try (original + Data([66])).write(to: url)
        XCTAssertThrowsError(try DocumentSnapshot(url: url))
    }

    func testConflictDetectedEvenWithUnchangedSizeAndTimestamp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("conflict.md")
        try Data("before".utf8).write(to: url)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let snapshot = try DocumentSnapshot(url: url)
        try Data("remote".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        XCTAssertThrowsError(try snapshot.save("my edit", to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "remote")
    }

    func testOversizedRecoveryFileIsRejectedWithoutModification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 128_000_000)
        try handle.close()
        XCTAssertThrowsError(try DraftStore(url: url).load())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, 128_000_000)
    }

    func testRecoveryWriteFailureDoesNotReplacePreviousDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(url: root.appendingPathComponent("draft.json"))
        let previous = RecoveryDraft(text: "Unsaved café 😀\r\n", title: "Keep me", originalPath: nil)
        try store.save(previous)
        // JSON escaping makes this exceed the store cap without an excessive allocation.
        let oversized = RecoveryDraft(text: String(repeating: "\u{0001}", count: 11_000_000), title: "Too large", originalPath: nil)
        XCTAssertThrowsError(try store.save(oversized))
        XCTAssertEqual(try DraftStore(url: store.url).load(), previous)
    }
}
