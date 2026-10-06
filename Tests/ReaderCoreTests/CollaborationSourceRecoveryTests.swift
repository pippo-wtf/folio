import XCTest
@testable import ReaderCore
final class CollaborationSourceRecoveryTests: XCTestCase {
  func fixture() throws -> (URL,CollaborationReplicaStore,SharedDocumentRef,SharedDocumentRef) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), shared=root.appendingPathComponent("shared")
    try FileManager.default.createDirectory(at:shared,withIntermediateDirectories:true)
    for file in ["a.md","b.md"] { try Data("base".utf8).write(to:shared.appendingPathComponent(file)) }
    let store=CollaborationReplicaStore(localRoot:root.appendingPathComponent("local"),sharedRoot:shared,workspaceID:UUID())
    try store.createWorkspace()
    let a=try store.registerDocument(relativePath:"a.md",initialBytes:Data("base".utf8)), b=try store.registerDocument(relativePath:"b.md",initialBytes:Data("base".utf8))
    addTeardownBlock { try? FileManager.default.removeItem(at:root) }
    return (root,store,a,b)
  }
  let actor=ParticipantProfile(participantID:UUID(),deviceID:UUID(),displayName:"Alex")
  func testPerDocumentHeadsDoNotBlockOtherDocument() throws {
    let (_,store,a,b)=try fixture()
    let p=try CollaborationSourceRecovery.prepare(document:a,base:Data("base".utf8),proposed:Data("A".utf8),actor:actor,store:store)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(p,store:store),.applied)
    let q=try CollaborationSourceRecovery.prepare(document:b,base:Data("base".utf8),proposed:Data("B".utf8),actor:actor,store:store)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(q,store:store),.applied)
    XCTAssertEqual(try Data(contentsOf:store.sharedRoot.appendingPathComponent("a.md")),Data("A".utf8))
  }
  func testEventBeforeSnapshotRemainsPendingThenRecoversExactBytes() throws {
    let (root,store,a,_)=try fixture()
    let proposed=Data([0xff,0xfe,0x3d,0xd8,0x00,0xde,0x0d,0,0x0a,0])
    let p=try CollaborationSourceRecovery.prepare(document:a,base:Data("base".utf8),proposed:proposed,actor:actor,store:store)
    try store.publishOutbox(only:"events")
    let other=CollaborationReplicaStore(localRoot:root.appendingPathComponent("other"),sharedRoot:store.sharedRoot,workspaceID:store.workspaceID);try other.join()
    XCTAssertEqual(try other.reconcile().state?.pendingEventIDs,[p.event.id])
    try store.publishOutbox(only:"snapshots")
    let recovered=try CollaborationSourceRecovery.recover(proposalID:p.event.id,from:other,to:root.appendingPathComponent("export"))
    XCTAssertEqual(recovered.savedOutcome,"intendedOnly")
    XCTAssertEqual(try Data(contentsOf:recovered.paths[1]),proposed)
  }
  func testObservedCompareConflictRetainsBytesAndNeverOverwrites() throws {
    let (root,store,a,_)=try fixture()
    let p=try CollaborationSourceRecovery.prepare(document:a,base:Data("base".utf8),proposed:Data("mine".utf8),actor:actor,store:store)
    let source=store.sharedRoot.appendingPathComponent("a.md");try Data("external".utf8).write(to:source)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(p,store:store),.conflict)
    XCTAssertEqual(try Data(contentsOf:source),Data("external".utf8))
    let export=try CollaborationSourceRecovery.recover(proposalID:p.event.id,from:store,to:root.appendingPathComponent("export"))
    XCTAssertTrue(export.hashes.contains(CollaborationSnapshotID.hash(Data("external".utf8))))
  }
  func testInterruptedAfterWriteDoesNotInventAppliedReceipt() throws {
    let (_,store,a,_)=try fixture();let p=try CollaborationSourceRecovery.prepare(document:a,base:Data("base".utf8),proposed:Data("mine".utf8),actor:actor,store:store)
    XCTAssertThrowsError(try CollaborationSourceRecovery.apply(p,store:store,fault:.afterLocalWrite))
    XCTAssertEqual(try CollaborationSourceRecovery.outcome(p,store:store),"unknownInterrupted")
    XCTAssertEqual(try CollaborationSourceRecovery.apply(p,store:store),.unchanged)
  }
  func testResolutionRequiresAllHeadsAndLateBranchReopensConflict() throws {
    let (_,store,a,_)=try fixture(),base=Data("base".utf8),chosen=Data("chosen".utf8),baseHash=CollaborationSnapshotID.hash(base)
    let p=try CollaborationSourceRecovery.prepare(document:a,base:base,proposed:chosen,actor:actor,store:store)
    let otherBytes=Data("other".utf8), otherHash=CollaborationSnapshotID.hash(otherBytes)
    let other=CollaborationEvent(workspaceID:a.workspaceID,documentID:a.documentID,participantID:UUID(),deviceID:UUID(),authorName:"Christian",rawSourceRevision:baseHash,payload:.sourceProposal(baseRevision:baseHash,proposedRevision:otherHash,triggerEventID:nil))
    try store.enqueue(other,snapshots:[baseHash:base,otherHash:otherBytes])
    XCTAssertThrowsError(try CollaborationSourceRecovery.prepareResolution(document:a,expectedCurrent:base,chosen:chosen,superseding:[p.event.id],actor:actor,store:store))
    let resolution=try CollaborationSourceRecovery.prepareResolution(document:a,expectedCurrent:base,chosen:chosen,superseding:[p.event.id,other.id],actor:actor,store:store)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(resolution,store:store),.applied)
    var late=other;late.id=UUID();try store.enqueue(late,snapshots:[baseHash:base,otherHash:otherBytes])
    XCTAssertEqual(Set(try store.reconcile().state!.sourceHeads[a.documentID] ?? []),Set([resolution.event.id,late.id]))
    XCTAssertThrowsError(try CollaborationSourceRecovery.apply(resolution,store:store))
  }
  func testInterruptionBeforeWritePreservesSourceAndDraftSnapshots() throws {
    let (_,store,a,_)=try fixture(),proposed=Data([0xef,0xbb,0xbf])+Data("sentinel\r\n😀\r\n".utf8)
    let p=try CollaborationSourceRecovery.prepare(document:a,base:Data("base".utf8),proposed:proposed,actor:actor,store:store)
    XCTAssertThrowsError(try CollaborationSourceRecovery.apply(p,store:store,fault:.beforeLocalWrite))
    XCTAssertEqual(try Data(contentsOf:store.sharedRoot.appendingPathComponent("a.md")),Data("base".utf8))
    XCTAssertEqual(try Data(contentsOf:p.proposedPath),proposed)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(p,store:store),.applied)
    XCTAssertEqual(try Data(contentsOf:store.sharedRoot.appendingPathComponent("a.md")),proposed)
  }

  func testResolutionAfterSequentialSavesSupersedesOnlyCurrentHead() throws {
    let (_,store,a,_)=try fixture(),one=Data("one".utf8),two=Data("two".utf8)
    let p=try CollaborationSourceRecovery.prepare(document:a,base:Data("base".utf8),proposed:one,actor:actor,store:store)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(p,store:store),.applied)
    let q=try CollaborationSourceRecovery.prepare(document:a,base:one,proposed:two,actor:actor,store:store)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(q,store:store),.applied)
    let r=try CollaborationSourceRecovery.prepareResolution(document:a,expectedCurrent:two,chosen:one,superseding:[q.event.id],actor:actor,store:store)
    XCTAssertEqual(try CollaborationSourceRecovery.apply(r,store:store),.applied)
  }

}
