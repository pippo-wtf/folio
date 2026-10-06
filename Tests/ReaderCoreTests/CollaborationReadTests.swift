import XCTest
@testable import ReaderCore

final class CollaborationReadTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSeenIDsRemainLocalAndScopedAcrossRestart() throws {
        let root = try directory()
        let a = UUID(), b = UUID(), workspace = UUID(), document = UUID(), event = UUID()
        let store = SharedReadStore(directory: root)
        try store.markSeen(eventIDs: [event], participantID: a, workspaceID: workspace, documentID: document)
        XCTAssertEqual(try SharedReadStore(directory: root).seenEventIDs(participantID: a, workspaceID: workspace, documentID: document), [event])
        XCTAssertTrue(try store.seenEventIDs(participantID: b, workspaceID: workspace, documentID: document).isEmpty)
        XCTAssertTrue(try store.seenEventIDs(participantID: a, workspaceID: UUID(), documentID: document).isEmpty)
        XCTAssertTrue(try store.seenEventIDs(participantID: a, workspaceID: workspace, documentID: UUID()).isEmpty)
    }

    func testLateDeliveryIsUnreadAndOwnEventsAreExcludedWithoutTimestampWatermarks() throws {
        let store = SharedReadStore(directory: try directory())
        let actor = UUID(), workspace = UUID(), document = UUID()
        let seen = UUID(), late = UUID(), own = UUID()
        try store.markSeen(eventIDs: [seen], participantID: actor, workspaceID: workspace, documentID: document)
        XCTAssertEqual(try store.unreadEventIDs(eventIDs: [seen, late, own], ownEventIDs: [own], participantID: actor, workspaceID: workspace, documentID: document), [late])
        XCTAssertEqual(try store.seenEventIDs(participantID: actor, workspaceID: workspace, documentID: document), [seen])
    }

    func testMarkSeenUnionsExactIDsRatherThanReplacingPreviousReadState() throws {
        let store = SharedReadStore(directory: try directory())
        let actor = UUID(), workspace = UUID(), document = UUID(), first = UUID(), second = UUID()
        try store.markSeen(eventIDs: [first], participantID: actor, workspaceID: workspace, documentID: document)
        try store.markSeen(eventIDs: [second], participantID: actor, workspaceID: workspace, documentID: document)
        try store.markSeen(eventIDs: [first], participantID: actor, workspaceID: workspace, documentID: document)
        XCTAssertEqual(try store.seenEventIDs(participantID: actor, workspaceID: workspace, documentID: document), [first, second])
    }

    func testCorruptReadStateCannotBeSilentlyOverwritten() throws {
        let root = try directory()
        let actor = UUID(), workspace = UUID(), document = UUID()
        let store = SharedReadStore(directory: root)
        try store.markSeen(eventIDs: [UUID()], participantID: actor, workspaceID: workspace, documentID: document)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        let file = try XCTUnwrap(enumerator.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try store.markSeen(eventIDs: [UUID()], participantID: actor, workspaceID: workspace, documentID: document))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
