import XCTest
@testable import ReaderCore

final class CollaborationProtocolTests: XCTestCase {
  let workspace = UUID(), document = UUID(), actor = UUID(), device = UUID()
  let revision = String(repeating: "a", count: 64)
  func event(_ payload: CollaborationPayload, parents: [UUID] = []) -> CollaborationEvent {
    CollaborationEvent(workspaceID: workspace, documentID: document, participantID: actor,
      deviceID: device, authorName: "Alex", rawSourceRevision: revision, parents: parents, payload: payload)
  }
  func testSchemaTwoRejectsSchemaOneWithoutMutation() throws {
    var e = event(.sourceProposal(baseRevision: revision, proposedRevision: revision, triggerEventID: nil))
    e.schemaVersion = 1
    XCTAssertThrowsError(try CollaborationIO.decodeEvent(CollaborationIO.encode(e)))
  }
  func testCommentReplyBeforeParentRemainsPending() {
    let highlight = UUID(), message = UUID()
    let anchor = SharedAnchor(start: 0, quote: "Hello", prefix: "", suffix: "", rawSourceRevision: revision, decodedSourceRevision: revision)
    let h = event(.highlightAdded(highlightID: highlight, anchor: anchor))
    let comment = event(.commentAdded(threadID: highlight, messageID: message, replyTo: nil, text: "first"), parents: [h.id])
    let reply = event(.commentAdded(threadID: highlight, messageID: UUID(), replyTo: message, text: "reply"), parents: [comment.id])
    let state = CollaborationReducer.reduce(events: [reply, h], snapshots: [:])
    XCTAssertEqual(state.acceptedIDs, [h.id])
    XCTAssertEqual(state.pendingEventIDs, [reply.id])
    XCTAssertEqual(state.pendingDependencyIDs, [comment.id])
    XCTAssertEqual(Set(CollaborationReducer.reduce(events: [reply, comment, h], snapshots: [:]).acceptedIDs), Set([h.id, comment.id, reply.id]))
  }
  func testConcurrentSameBaselineSavesKeepBothHeadsWithSkewedClocks() {
    let bytes = Data("base".utf8), a = Data("a".utf8), b = Data("b".utf8)
    let base = CollaborationSnapshotID.hash(bytes), ah = CollaborationSnapshotID.hash(a), bh = CollaborationSnapshotID.hash(b)
    var first = event(.sourceProposal(baseRevision: base, proposedRevision: ah, triggerEventID: nil))
    first.rawSourceRevision = base; first.displayTime = Date(timeIntervalSince1970: 900000)
    var second = event(.sourceProposal(baseRevision: base, proposedRevision: bh, triggerEventID: nil))
    second.rawSourceRevision = base; second.displayTime = Date(timeIntervalSince1970: 1)
    let state = CollaborationReducer.reduce(events: [second, first], snapshots: [base:bytes, ah:a, bh:b])
    XCTAssertEqual(Set(state.sourceHeads[document] ?? []), Set([first.id, second.id]))
  }
  func testCrossDocumentAndUnknownFieldsRejected() throws {
    let e = event(.commentAdded(threadID: UUID(), messageID: UUID(), replyTo: nil, text: "x"))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: CollaborationIO.encode(e)) as? [String:Any])
    json["unknown"] = true
    XCTAssertThrowsError(try CollaborationIO.decodeEvent(JSONSerialization.data(withJSONObject: json)))
    var bad = e; bad.documentID = UUID(); bad.parents = [e.id]
    XCTAssertTrue(CollaborationReducer.reduce(events: [e,bad], snapshots: [:]).invalidIDs.contains(bad.id))
  }
  func testEntityReferencesMustBeCausalAndSameThread() {
    let h=UUID(), other=UUID(), m=UUID()
    let anchor=SharedAnchor(start:0,quote:"x",prefix:"",suffix:"",rawSourceRevision:revision,decodedSourceRevision:revision)
    let a=event(.highlightAdded(highlightID:h,anchor:anchor)),b=event(.highlightAdded(highlightID:other,anchor:anchor))
    let comment=event(.commentAdded(threadID:h,messageID:m,replyTo:nil,text:"hello"),parents:[a.id])
    let reply=event(.commentAdded(threadID:other,messageID:UUID(),replyTo:m,text:"bad"),parents:[b.id,comment.id])
    let noncausal=event(.threadState(threadID:h,resolved:true,supersedes:[]))
    let state=CollaborationReducer.reduce(events:[a,b,comment,reply,noncausal],snapshots:[:])
    XCTAssertEqual(Set(state.invalidIDs),Set([reply.id,noncausal.id]))
  }
  func testResolutionOfPartialObservedHeadsIsInvalidAndLateUnknownHeadReopens() {
    let h=UUID(),anchor=SharedAnchor(start:0,quote:"x",prefix:"",suffix:"",rawSourceRevision:revision,decodedSourceRevision:revision)
    let a=event(.highlightAdded(highlightID:h,anchor:anchor))
    let first=event(.threadState(threadID:h,resolved:true,supersedes:[]),parents:[a.id])
    let second=event(.threadState(threadID:h,resolved:false,supersedes:[]),parents:[a.id])
    let partial=event(.threadState(threadID:h,resolved:true,supersedes:[first.id]),parents:[first.id,second.id])
    XCTAssertTrue(CollaborationReducer.reduce(events:[a,first,second,partial],snapshots:[:]).invalidIDs.contains(partial.id))
    let full=event(.threadState(threadID:h,resolved:true,supersedes:[first.id,second.id]),parents:[first.id,second.id])
    let late=event(.threadState(threadID:h,resolved:false,supersedes:[]),parents:[a.id])
    let state=CollaborationReducer.reduce(events:[a,first,second,full,late],snapshots:[:])
    XCTAssertEqual(Set(state.threadHeads[h] ?? []),Set([full.id,late.id]))
  }

}
