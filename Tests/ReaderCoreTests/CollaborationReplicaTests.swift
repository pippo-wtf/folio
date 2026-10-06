import XCTest
@testable import ReaderCore

final class CollaborationReplicaTests: XCTestCase {
  func fixture(limits: CollaborationLimits = .pilot) throws -> (URL, CollaborationReplicaStore, SharedDocumentRef) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let shared = root.appendingPathComponent("shared")
    try FileManager.default.createDirectory(at:shared,withIntermediateDirectories:true)
    try Data("base".utf8).write(to:shared.appendingPathComponent("one.md"))
    let store = CollaborationReplicaStore(localRoot:root.appendingPathComponent("a"),sharedRoot:shared,workspaceID:UUID(),limits:limits)
    try store.createWorkspace()
    let doc = try store.registerDocument(relativePath:"one.md",initialBytes:Data("base".utf8))
    addTeardownBlock { try? FileManager.default.removeItem(at:root) }
    return (root,store,doc)
  }
  func highlight(_ doc: SharedDocumentRef, actor: UUID = UUID(), id: UUID = UUID()) -> CollaborationEvent {
    let h = CollaborationSnapshotID.hash(Data("base".utf8))
    return CollaborationEvent(id:id,workspaceID:doc.workspaceID,documentID:doc.documentID,participantID:actor,deviceID:UUID(),authorName:"Alex",rawSourceRevision:h,payload:.highlightAdded(highlightID:UUID(),anchor:SharedAnchor(start:0,quote:"base",prefix:"",suffix:"",rawSourceRevision:h,decodedSourceRevision:h)))
  }
  func testSameEventIDDifferentBytesQuarantinesBoth() throws {
    let (_,store,doc) = try fixture()
    let e = highlight(doc); try store.enqueue(e); try store.publishOutbox()
    var other = e; other.authorName = "Changed"
    try CollaborationIO.encode(other).write(to:store.transportRoot.appendingPathComponent("events/conflicted-copy.json"))
    let report = try store.reconcile()
    XCTAssertEqual(report.status,.identityConflict)
    XCTAssertTrue(report.state?.invalidIDs.contains(e.id) ?? false)
    XCTAssertFalse(report.state?.acceptedIDs.contains(e.id) ?? true)
  }
  func testUnknownOversizedSiblingDoesNotBlockValidEvent() throws {
    let (_,store,doc) = try fixture(); let e = highlight(doc); try store.enqueue(e); try store.publishOutbox()
    try Data(repeating:65,count:70000).write(to:store.transportRoot.appendingPathComponent("events/unknown.json"))
    let report = try store.reconcile()
    XCTAssertEqual(report.state?.acceptedIDs,[e.id]); XCTAssertGreaterThan(report.diagnosticCount,0)
  }
  func testThreeActorsRetainDistinctContributionsAcrossRestart() throws {
    let (root,store,doc) = try fixture(); let events = (0..<3).map { _ in highlight(doc) }
    for e in events { try store.enqueue(e) }; try store.publishOutbox()
    let next = CollaborationReplicaStore(localRoot:root.appendingPathComponent("b"),sharedRoot:store.sharedRoot,workspaceID:store.workspaceID)
    try next.join()
    XCTAssertEqual(Set(try next.reconcile().state!.acceptedIDs),Set(events.map(\.id)))
  }
  func testReadyInterruptionPreservesSameIDsOnRetry() throws {
    let (_,store,doc) = try fixture(); let e = highlight(doc)
    XCTAssertThrowsError(try store.enqueue(e,fault:.afterReady))
    try store.enqueue(e); try store.publishOutbox(); try store.publishOutbox()
    XCTAssertEqual(try store.reconcile().state?.acceptedIDs,[e.id])
  }
  func testCapacityBlocksNewActionWithoutPartialState() throws {
    var limits=CollaborationLimits(); limits.events=1
    let (_,store,doc)=try fixture(limits:limits); try store.enqueue(highlight(doc))
    XCTAssertThrowsError(try store.enqueue(highlight(doc)))
  }
  func testSchemaOneJoinLeavesBothRootsUnchanged() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),shared=root.appendingPathComponent("shared")
    defer { try? FileManager.default.removeItem(at:root) }
    let meta=shared.appendingPathComponent("Folio Review");try FileManager.default.createDirectory(at:meta,withIntermediateDirectories:true)
    let id=UUID(),bytes=Data("{\"schemaVersion\":1,\"workspaceID\":\"\(id.uuidString)\"}".utf8)
    try bytes.write(to:meta.appendingPathComponent("workspace.json"))
    let local=root.appendingPathComponent("local"),store=CollaborationReplicaStore(localRoot:local,sharedRoot:shared,workspaceID:id)
    XCTAssertThrowsError(try store.join())
    XCTAssertFalse(FileManager.default.fileExists(atPath:local.path))
    XCTAssertEqual(try Data(contentsOf:meta.appendingPathComponent("workspace.json")),bytes)
  }
  func testUnregisteredEventRemainsPendingUntilDocumentManifestArrives() throws {
    let (_,store,doc)=try fixture();let missing=SharedDocumentRef(workspaceID:doc.workspaceID,documentID:UUID(),relativePath:"two.md"),e=highlight(missing)
    let events=store.transportRoot.appendingPathComponent("events");try FileManager.default.createDirectory(at:events,withIntermediateDirectories:true)
    try CollaborationIO.encode(e).write(to:events.appendingPathComponent(e.id.uuidString+".json"))
    let report=try store.reconcile()
    XCTAssertEqual(report.status,.pending)
    XCTAssertEqual(report.state?.pendingEventIDs,[e.id])
    XCTAssertEqual(report.state?.acceptedIDs,[])
  }
  func testBeforeReadyInterruptionLeavesNoAcknowledgedAction() throws {
    let (_,store,doc)=try fixture();let e=highlight(doc)
    XCTAssertThrowsError(try store.enqueue(e,fault:.beforeReady))
    XCTAssertEqual(try store.reconcile().state?.acceptedIDs,[])
    try store.enqueue(e);XCTAssertEqual(try store.reconcile().state?.acceptedIDs,[e.id])
  }
  func testTaskRegistrationIsNotAStatusConflict() throws {
    let (_,store,doc)=try fixture(), h=CollaborationSnapshotID.hash(Data("base".utf8)),task=UUID()
    let anchor=SharedTaskAnchor(sourceOffsetUTF16:0,line:"- [ ] base",prefix:"",suffix:"",rawSourceRevision:h,decodedSourceRevision:h)
    let first=CollaborationEvent(workspaceID:doc.workspaceID,documentID:doc.documentID,participantID:UUID(),deviceID:UUID(),authorName:"Alex",rawSourceRevision:h,payload:.taskRegistered(taskID:task,anchor:anchor))
    var status=first;status.id=UUID();status.parents=[first.id];status.payload = .taskState(taskID:task,state:.done,supersedes:[],rawSourceRevision:h)
    let state=CollaborationReducer.reduce(events:[first,status],snapshots:[:])
    XCTAssertEqual(state.taskHeads[task],[status.id]);XCTAssertEqual(state.conflictHeadSets,[])
  }

  func testUnknownManifestFieldsBlockJoinWithoutMutation() throws {
    let (_,store,_)=try fixture()
    let path=store.transportRoot.appendingPathComponent("workspace.json")
    var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any]);object["unknown"]="ignored?"
    try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:path)
    let next=CollaborationReplicaStore(localRoot:store.localRoot.deletingLastPathComponent().appendingPathComponent("other"),sharedRoot:store.sharedRoot,workspaceID:store.workspaceID)
    XCTAssertThrowsError(try next.join())
    XCTAssertFalse(FileManager.default.fileExists(atPath:next.localRoot.path))
  }
  func testCandidateCapacityIncludesRetainedAndSharedEvidence() throws {
    var limits=CollaborationLimits();limits.candidates=50
    let (_,store,doc)=try fixture(limits:limits),e=highlight(doc);try store.enqueue(e);try store.publishOutbox()
    let events=store.transportRoot.appendingPathComponent("events")
    for i in 0..<50 { try Data("bad".utf8).write(to:events.appendingPathComponent("bad-\(i).json")) }
    let report=try store.reconcile();XCTAssertEqual(report.status,.capacityExceeded);XCTAssertNil(report.state)
    XCTAssertThrowsError(try store.enqueue(highlight(doc)))
  }

  func testFreshReplicaCannotReconnectToAnotherRegisteredManifestPath() throws {
    let (root,store,a)=try fixture();let bytes=Data("base".utf8);try bytes.write(to:store.sharedRoot.appendingPathComponent("two.md"))
    _ = try store.registerDocument(relativePath:"two.md",initialBytes:bytes)
    let other=CollaborationReplicaStore(localRoot:root.appendingPathComponent("other"),sharedRoot:store.sharedRoot,workspaceID:store.workspaceID);try other.join()
    XCTAssertThrowsError(try other.reconnectDocument(id:a.documentID,relativePath:"two.md"))
  }
  func testCorruptBindingFailsClosedRatherThanTargetingOldPath() throws {
    let (_,store,a)=try fixture();try FileManager.default.moveItem(at:store.sharedRoot.appendingPathComponent("one.md"),to:store.sharedRoot.appendingPathComponent("moved.md"))
    _ = try store.reconnectDocument(id:a.documentID,relativePath:"moved.md")
    try Data("unrelated".utf8).write(to:store.sharedRoot.appendingPathComponent("one.md"))
    try Data("bad-json".utf8).write(to:store.localRoot.appendingPathComponent("bindings.json"))
    XCTAssertThrowsError(try store.sourceURL(document:a))
  }
  func testMalformedWorkspaceAfterJoinBlocksWrites() throws {
    let (_,store,doc)=try fixture();try Data("bad".utf8).write(to:store.transportRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(try store.reconcile().status,.identityConflict)
    XCTAssertThrowsError(try store.enqueue(highlight(doc)))
  }

  func testMalformedSameIDVariantQuarantinesValidOriginAcrossRestart() throws {
    let (root,store,doc)=try fixture(),e=highlight(doc);try store.enqueue(e);try store.publishOutbox()
    var object=try XCTUnwrap(JSONSerialization.jsonObject(with:CollaborationIO.encode(e)) as? [String:Any]);object["unknown"]="reject"
    try JSONSerialization.data(withJSONObject:object).write(to:store.transportRoot.appendingPathComponent("events/conflicted.json"))
    XCTAssertEqual(try store.reconcile().status,.identityConflict)
    try FileManager.default.removeItem(at:store.transportRoot.appendingPathComponent("events/conflicted.json"))
    let restarted=CollaborationReplicaStore(localRoot:root.appendingPathComponent("a"),sharedRoot:store.sharedRoot,workspaceID:store.workspaceID)
    XCTAssertTrue(try restarted.reconcile().state?.invalidIDs.contains(e.id) ?? false)
  }
  func testDeniedDirectoryIsIncompleteAndBlocksWrites() throws {
    let (_,store,doc)=try fixture();let directory=store.transportRoot.appendingPathComponent("events")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    try CollaborationIO.encode(highlight(doc)).write(to:directory.appendingPathComponent("unseen.json"))
    try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path) }
    let report=try store.reconcile();XCTAssertEqual(report.status,.unavailable);XCTAssertFalse(report.coverageComplete);XCTAssertNil(report.state)
    XCTAssertThrowsError(try store.enqueue(highlight(doc)))
  }
  func testEmptyDirectoryCandidatesCannotBypassCapacity() throws {
    var limits=CollaborationLimits();limits.candidates=50
    let (_,store,_)=try fixture(limits:limits)
    for i in 0..<51 { try FileManager.default.createDirectory(at:store.transportRoot.appendingPathComponent("empty-\(i)"),withIntermediateDirectories:true) }
    XCTAssertEqual(try store.reconcile().status,.capacityExceeded)
  }

  func testCaseAliasAndHardLinkCannotRegisterSameFileTwice() throws {
    let (_,store,_)=try fixture(),path=store.sharedRoot.appendingPathComponent("one.md")
    XCTAssertThrowsError(try store.registerDocument(relativePath:"ONE.md",initialBytes:Data("base".utf8)))
    try FileManager.default.linkItem(at:path,to:store.sharedRoot.appendingPathComponent("linked.md"))
    XCTAssertThrowsError(try store.registerDocument(relativePath:"linked.md",initialBytes:Data("base".utf8)))
  }

  func testCaseAliasCannotPlacePrivateReplicaInsideSharedRoot() throws {
    let (root,store,_)=try fixture(),alias=root.appendingPathComponent("SHARED")
    guard FileManager.default.fileExists(atPath:alias.path) else { throw XCTSkip("case-sensitive filesystem") }
    let nested=CollaborationReplicaStore(localRoot:alias.appendingPathComponent("private-cache"),sharedRoot:store.sharedRoot,workspaceID:store.workspaceID)
    XCTAssertThrowsError(try nested.join())
    XCTAssertFalse(FileManager.default.fileExists(atPath:store.sharedRoot.appendingPathComponent("private-cache").path))
  }
  func testCaseAliasRootOverlapCannotMutateEitherRootDuringCreation() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let local=root.appendingPathComponent("local")
    try FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)
    let alias=root.appendingPathComponent("LOCAL")
    guard FileManager.default.fileExists(atPath:alias.path) else { throw XCTSkip("case-sensitive filesystem") }
    let shared=alias.appendingPathComponent("shared")
    let store=CollaborationReplicaStore(localRoot:local,sharedRoot:shared,workspaceID:UUID())
    XCTAssertThrowsError(try store.createWorkspace())
    XCTAssertFalse(FileManager.default.fileExists(atPath:shared.path))
  }

}
