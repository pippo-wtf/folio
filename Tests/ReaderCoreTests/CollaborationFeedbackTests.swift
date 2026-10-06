import XCTest
@testable import ReaderCore

final class CollaborationFeedbackTests: XCTestCase {
  let document = SharedDocumentRef(workspaceID: UUID(), documentID: UUID(), relativePath: "nested/review.md")
  let raw = CollaborationSnapshotID.hash(Data([0xff, 0xfe, 0x41, 0x00]))
  let decoded = CollaborationSnapshotID.hash(Data("A".utf8))
  func event(_ payload: CollaborationPayload, parents: [UUID] = [], actor: UUID = UUID()) -> CollaborationEvent {
    CollaborationEvent(workspaceID: document.workspaceID, documentID: document.documentID,
      participantID: actor, deviceID: UUID(), authorName: "Alex", rawSourceRevision: raw,
      parents: parents, displayTime: Date(timeIntervalSince1970: 0), payload: payload)
  }
  func packet(_ events: [CollaborationEvent], state: CollaborationState? = nil, report: CollaborationReport? = nil) throws -> SharedFeedbackPacket {
    try JSONDecoder().decode(SharedFeedbackPacket.self, from: SharedFeedback.export(document: document,
      state: state ?? CollaborationReducer.reduce(events: events, snapshots: [:]), events: events,
      currentRawRevision: raw, currentDecodedRevision: decoded, report: report))
  }
  func testRoundTripPreservesOriginalActorsIDsMessagesAndExplicitCoordinateSpaces() throws {
    let highlight = UUID(), message = UUID()
    let anchor = SharedAnchor(start: 4, quote: "😀 A", prefix: "", suffix: "",
      rawSourceRevision: raw, decodedSourceRevision: decoded)
    let a = event(.highlightAdded(highlightID: highlight, anchor: anchor))
    let b = event(.commentAdded(threadID: highlight, messageID: message, replyTo: nil, text: "Review this"), parents: [a.id])
    let exported = try packet([b, a, b])
    XCTAssertEqual(exported.version, 2)
    XCTAssertEqual(exported.document, document)
    XCTAssertEqual(exported.events, [a,b].sorted { $0.id.uuidString < $1.id.uuidString })
    XCTAssertEqual(exported.currentRawRevision, raw)
    XCTAssertEqual(exported.currentDecodedRevision, decoded)
    XCTAssertEqual(exported.conventions.highlightCoordinates, "renderedUTF16")
    XCTAssertEqual(exported.conventions.taskCoordinates, "sourceUTF16")
    XCTAssertEqual(exported.conventions.rawRevision, "SHA256(exact saved bytes)")
    XCTAssertEqual(exported.conventions.decodedRevision, "SHA256(decoded source UTF8)")
    XCTAssertEqual(exported.annotations.first?.entityID, highlight)
    XCTAssertEqual(exported.messages, [b])
    XCTAssertEqual(exported.annotations.first?.headEventIDs, [a.id])
  }
  func testTaskAndThreadConcurrentHeadsAreRetainedWithoutClockWinner() throws {
    let task = UUID(), thread = UUID()
    let h = event(.highlightAdded(highlightID: thread, anchor: SharedAnchor(start: 0, quote: "A", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: decoded)))
    let registered = event(.taskRegistered(taskID: task, anchor: SharedTaskAnchor(sourceOffsetUTF16: 2, line: "- [ ] A", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: decoded)))
    let done = event(.taskState(taskID: task, state: .done, supersedes: [], rawSourceRevision: raw), parents: [registered.id])
    let open = event(.taskState(taskID: task, state: .open, supersedes: [], rawSourceRevision: raw), parents: [registered.id])
    let resolved = event(.threadState(threadID: thread, resolved: true, supersedes: []), parents: [h.id])
    let exported = try packet([h, registered, done, open, resolved])
    XCTAssertEqual(Set(exported.tasks.first!.headEventIDs), Set([done.id,open.id]))
    XCTAssertEqual(exported.threads.first?.headEventIDs, [resolved.id])
    XCTAssertEqual(exported.tasks.first?.originEventID, registered.id)
  }
  func testSourceIntentNeverClaimsApplicationAndCoverageRequiresExplicitReport() throws {
    let proposed = CollaborationSnapshotID.hash(Data("B".utf8))
    let source = event(.sourceProposal(baseRevision: raw, proposedRevision: proposed, triggerEventID: nil))
    let exported = try packet([source])
    XCTAssertEqual(exported.sourceIntents.first?.eventID, source.id)
    XCTAssertEqual(exported.sourceIntents.first?.localApplication, "unknownNoLocalReceipt")
    XCTAssertEqual(exported.sourceIntents.first?.meaning, "intendedVersion")
    XCTAssertFalse(exported.coverage.complete)
    XCTAssertEqual(exported.coverage.status, "unknown")
    XCTAssertTrue(exported.externalRecoveryGap)
    XCTAssertEqual(exported.externalAuthor, "unknown")
    XCTAssertEqual(Set(exported.pendingEventIDs), [source.id])
    XCTAssertEqual(Set(exported.missingSnapshots), [raw, proposed])
    let incomplete = try packet([source], report: CollaborationReport(status: .capacityExceeded))
    XCTAssertFalse(incomplete.coverage.complete)
    XCTAssertEqual(incomplete.coverage.status, "capacityExceeded")
  }
  func testExportDoesNotMutateStateAndScopesOutOtherDocumentsAndPrivateData() throws {
    let highlight = UUID()
    let a = event(.highlightAdded(highlightID: highlight, anchor: SharedAnchor(start: 0, quote: "A", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: decoded)))
    var other = event(.commentAdded(threadID: UUID(), messageID: UUID(), replyTo: nil, text: "Other document secret"))
    other.documentID = UUID()
    let state = CollaborationReducer.reduce(events: [a,other], snapshots: [:]), before = state
    let bytes = try SharedFeedback.export(document: document, state: state, events: [a,other], currentRawRevision: raw, currentDecodedRevision: decoded)
    XCTAssertEqual(state, before)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Other document secret"))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
    XCTAssertNil(json["privateHighlights"]); XCTAssertNil(json["journal"]); XCTAssertNil(json["seenEventIDs"])
  }
  func testRejectsConflictingEventIdentityInvalidHashesAndInconsistentState() throws {
    let a = event(.commentAdded(threadID: UUID(), messageID: UUID(), replyTo: nil, text: "A"))
    var alias = a; alias.authorName = "Different"
    XCTAssertThrowsError(try packet([a,alias]))
    XCTAssertThrowsError(try SharedFeedback.export(document: document, state: CollaborationState(), events: [], currentRawRevision: "bad", currentDecodedRevision: decoded))
    var state = CollaborationState(); state.acceptedIDs = [UUID()]
    let exported = try packet([], state: state, report: CollaborationReport(status: .complete, state: state))
    XCTAssertFalse(exported.coverage.complete)
    XCTAssertEqual(exported.coverage.unavailableEventIDs, state.acceptedIDs)
  }
  func testRegisteredTaskWithoutStatusRemainsExportedAndCompleteReportIsExplicit() throws {
    let task = UUID()
    let registered = event(.taskRegistered(taskID: task, anchor: SharedTaskAnchor(sourceOffsetUTF16: 2, line: "- [ ] A", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: decoded)))
    let state = CollaborationReducer.reduce(events: [registered], snapshots: [:])
    let exported = try packet([registered], state: state, report: CollaborationReport(status: .complete, state: state))
    XCTAssertEqual(exported.tasks.first?.originEventID, registered.id)
    XCTAssertEqual(exported.tasks.first?.headEventIDs, [])
    XCTAssertTrue(exported.coverage.complete)
    let stale = try packet([registered], state: state, report: CollaborationReport(status: .complete, state: CollaborationState()))
    XCTAssertFalse(stale.coverage.complete)
  }
  func testBoundsAndOtherWorkspaceRecordsCannotLeak() throws {
    let a = event(.sourceProposal(baseRevision: raw, proposedRevision: decoded, triggerEventID: nil))
    var other = a; other.id = UUID(); other.workspaceID = UUID(); other.authorName = "SECRET-WORKSPACE"
    let state = CollaborationReducer.reduce(events: [a,other], snapshots: [:])
    let exported = try packet([a,other], state: state)
    XCTAssertEqual(exported.events, [a])
    XCTAssertFalse(exported.pendingEventIDs.contains(other.id))
    XCTAssertFalse(exported.sourceHeadEventIDs.contains(other.id))
    var limits = CollaborationLimits(); limits.events = 0
    XCTAssertThrowsError(try SharedFeedback.export(document: document, state: state, events: [a], currentRawRevision: raw, currentDecodedRevision: decoded, limits: limits))
    limits.events = 2; limits.totalBytes = 1
    XCTAssertThrowsError(try SharedFeedback.export(document: document, state: state, events: [a], currentRawRevision: raw, currentDecodedRevision: decoded, limits: limits))
  }

}
