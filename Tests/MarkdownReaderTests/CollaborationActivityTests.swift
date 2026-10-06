import XCTest
import ReaderCore
@testable import MarkdownReader

final class CollaborationActivityTests: XCTestCase {
    @MainActor func testLateOldTimestampIsUnreadAndReadExportNeverChangeSharedEvents() async throws {
        let (a, source, root) = try await CollaborationReviewTests().fixture()
        let doc = try XCTUnwrap(a.currentDocument)
        let b = CollaborationCoordinator(enabled: true, localRoot: root.appendingPathComponent("b"))
        await b.join(folder: source.deletingLastPathComponent(), create: false, displayName: "Alex")
        _ = await b.openDocument(id: doc.documentID); b.selectDocument(url: source)
        let actor = try XCTUnwrap(b.profile), raw = CollaborationSnapshotID.hash(try XCTUnwrap(b.sourceObservations[doc.documentID]))
        let anchor = SharedAnchor(start: 0, quote: "Quote", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: raw)
        let event = CollaborationEvent(workspaceID: doc.workspaceID, documentID: doc.documentID, participantID: actor.participantID, deviceID: actor.deviceID, authorName: actor.displayName, rawSourceRevision: raw, displayTime: Date(timeIntervalSince1970: 1), payload: .highlightAdded(highlightID: UUID(), anchor: anchor))
        try a.markSharedRead(document: doc)
        let submitted = await b.submit(event)
        XCTAssertTrue(submitted)
        await a.refresh()
        XCTAssertEqual(try a.sharedUnreadIDs(document: doc), [event.id])
        XCTAssertTrue(try b.sharedUnreadIDs(document: doc).isEmpty)
        let before = a.events
        let data = try a.sharedFeedback(document: doc, decodedRevision: raw)
        XCTAssertEqual(try JSONDecoder().decode(SharedFeedbackPacket.self, from: data).events.map(\.id), [event.id])
        XCTAssertEqual(try a.sharedUnreadIDs(document: doc), [event.id])
        try a.markSharedRead(document: doc)
        XCTAssertTrue(try a.sharedUnreadIDs(document: doc).isEmpty)
        XCTAssertEqual(a.events, before)
        XCTAssertTrue(a.state?.threadHeads.isEmpty == true)
        await a.stopWatching(); await b.stopWatching()
    }
}
