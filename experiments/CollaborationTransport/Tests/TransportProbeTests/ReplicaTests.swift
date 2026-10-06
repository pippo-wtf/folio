import XCTest

@testable import TransportProbe

final class ReplicaTests: XCTestCase {
  let w = fixed(1), d = fixed(2), participant = fixed(3), device = fixed(4), task = fixed(5)
  func store(_ root: URL, _ name: String, limits: ProbeLimits = .pilot) -> ReplicaStore {
    ReplicaStore(
      localRoot: root.appendingPathComponent(name + "-local"),
      sharedRoot: root.appendingPathComponent(name + "-shared"), workspaceID: w, limits: limits)
  }
  func event(_ n: Int, parents: [UUID] = [], payload: ProbePayload? = nil) -> ProbeEvent {
    ProbeEvent(
      id: fixed(n), workspaceID: w, documentID: d, participantID: participant, deviceID: device,
      parents: parents, displayTime: Date(timeIntervalSince1970: Double(10000 - n)),
      payload: payload
        ?? .comment(
          id: fixed(n + 1000), text: "action \(n)",
          sourceRevision: SnapshotID.hash(Data("base".utf8))))
  }
  func setup(_ root: URL, limits: ProbeLimits = .pilot) throws -> (ReplicaStore, ReplicaStore) {
    let a = store(root, "a", limits: limits)
    let b = store(root, "b", limits: limits)
    try a.initialize(documentID: d, source: Data("base".utf8))
    try SimulatedCourier.transfer(
      from: a.sharedRoot, to: b.sharedRoot,
      relativePaths: [
        "Folio Review/workspace.json", "Folio Review/documents/\(d.uuidString).json", "fixture.md",
      ])
    try b.join()
    return (a, b)
  }
  func testTwoReplicasConvergeAfter100EventsEach() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var (a, b) = try setup(root)
    let expected = (100..<300).map(fixed)
    for n in 100..<300 {
      let s = n < 200 ? a : b
      try s.enqueue(event(n, parents: n == 100 || n == 200 ? [] : [fixed(n - 1)]))
    }
    a = store(root, "a")
    b = store(root, "b")
    try a.publishOutbox()
    try b.publishOutbox()
    let ap = SimulatedCourier.paths(a.sharedRoot, kind: "events")
    let bp = SimulatedCourier.paths(b.sharedRoot, kind: "events")
    try SimulatedCourier.transfer(
      from: a.sharedRoot, to: b.sharedRoot, relativePaths: Array(ap.suffix(50).reversed()),
      repeats: 2)
    XCTAssertFalse(try b.reconcile().state!.pendingEventIDs.isEmpty)
    a = store(root, "a")
    b = store(root, "b")
    try SimulatedCourier.transfer(
      from: a.sharedRoot, to: b.sharedRoot, relativePaths: Array(ap.reversed()), repeats: 2)
    try SimulatedCourier.transfer(
      from: b.sharedRoot, to: a.sharedRoot, relativePaths: Array(bp.reversed()), repeats: 2)
    let sa = try a.reconcile()
    let sb = try b.reconcile()
    XCTAssertEqual(sa.status, .complete)
    XCTAssertEqual(sa.state, sb.state)
    XCTAssertEqual(Set(sa.state!.acceptedIDs), Set(expected))
    XCTAssertEqual(sa.state!.commentIDs.count, 200)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: a.localRoot.appendingPathComponent("ready"), includingPropertiesForKeys: nil
      ).count, 100)
  }
  func testConcurrentTaskHeadsAndExplicitResolution() throws {
    let hash = SnapshotID.hash(Data("base".utf8))
    let done = event(
      100, payload: .task(taskID: task, state: .done, supersedes: [], sourceRevision: hash))
    let reopen = event(
      101, payload: .task(taskID: task, state: .open, supersedes: [], sourceRevision: hash))
    let partial = event(
      102, parents: [done.id],
      payload: .task(taskID: task, state: .done, supersedes: [done.id], sourceRevision: hash))
    XCTAssertEqual(
      ProbeReducer.reduce(events: [partial, reopen, done], snapshots: [:]).taskHeads[
        task.uuidString], [reopen.id, partial.id])
    let resolution = event(
      103, parents: [partial.id, reopen.id],
      payload: .task(
        taskID: task, state: .done, supersedes: [partial.id, reopen.id], sourceRevision: hash))
    XCTAssertEqual(
      ProbeReducer.reduce(events: [resolution, reopen, done, partial], snapshots: [:]).taskHeads[
        task.uuidString], [resolution.id])
  }
  func testCyclesWrongDocumentAndMissingParents() {
    let a = event(100, parents: [fixed(101)])
    let b = event(101, parents: [fixed(100)])
    let unrelated = event(102)
    let missing = event(103, parents: [fixed(999)])
    var wrong = event(104)
    wrong.documentID = fixed(88)
    let child = event(105, parents: [wrong.id])
    let state = ProbeReducer.reduce(
      events: [a, b, unrelated, missing, wrong, child], snapshots: [:])
    XCTAssertEqual(Set(state.invalidIDs), Set([a.id, b.id, child.id]))
    XCTAssertTrue(state.acceptedIDs.contains(unrelated.id))
    XCTAssertTrue(state.pendingDependencyIDs.contains(fixed(999)))
  }
  func testDuplicateIdentityAndManifestConflicts() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, b) = try setup(root)
    try a.enqueue(event(100))
    try a.publishOutbox()
    var different = event(100)
    different.payload = .comment(
      id: fixed(1100), text: "different", sourceRevision: SnapshotID.hash(Data("base".utf8)))
    try b.enqueue(different)
    try b.publishOutbox()
    XCTAssertThrowsError(
      try SimulatedCourier.transfer(
        from: a.sharedRoot, to: b.sharedRoot,
        relativePaths: SimulatedCourier.paths(a.sharedRoot, kind: "events")))
    let report = try b.reconcile()
    XCTAssertEqual(report.status, .identityConflict)
    XCTAssertFalse(report.state!.acceptedIDs.contains(fixed(100)))
    let bad = WorkspaceManifest(workspaceID: fixed(777))
    try ProbeIO.durable(
      ProbeIO.encode(bad),
      at: b.sharedRoot.appendingPathComponent("Folio Review/workspace-copy.json"))
    XCTAssertEqual(try b.reconcile().status, .identityConflict)
  }
  func testDocumentCopyRenameRequiresReconnection() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    let copied = DocumentManifest(
      workspaceID: w, documentID: fixed(99), relativePath: "fixture.md",
      initialRevision: SnapshotID.hash(Data("base".utf8)))
    try ProbeIO.durable(
      ProbeIO.encode(copied),
      at: a.sharedRoot.appendingPathComponent("Folio Review/documents/copy.json"))
    XCTAssertEqual(try a.reconcile().status, .needsReconnection)
  }
  func testCapacityIsWholeOutcomeAndBlocksActions() throws {
    for mode in 0..<4 {
      let root = temporary()
      defer { try? FileManager.default.removeItem(at: root) }
      var limits = ProbeLimits.pilot
      limits.events = mode == 0 ? 1 : 100
      limits.snapshots = mode == 1 ? 1 : 100
      let (a, b) = try setup(root, limits: limits)
      try a.enqueue(event(100))
      try a.publishOutbox()
      if mode == 0 {
        try ProbeIO.durable(
          ProbeIO.encode(event(101)),
          at: a.sharedRoot.appendingPathComponent("Folio Review/events/101.json"))
      }
      if mode == 1 {
        for bytes in [Data([1]), Data([2])] {
          try ProbeIO.durable(
            bytes,
            at: a.sharedRoot.appendingPathComponent(
              "Folio Review/snapshots/\(SnapshotID.hash(bytes)).bin"))
        }
      }
      if mode == 2 { limits.totalBytes = 1 }
      if mode == 3 { limits.candidates = 1 }
      let constrained = store(root, "a", limits: limits)
      let report = try constrained.reconcile()
      XCTAssertEqual(report.status, .capacityExceeded)
      XCTAssertNil(report.state)
      XCTAssertThrowsError(try constrained.enqueue(event(102)))
      XCTAssertThrowsError(try constrained.publishOutbox())
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: a.sharedRoot.appendingPathComponent(
            "Folio Review/events/\(fixed(100).uuidString).json"
          ).path))
      _ = b
    }
  }
  func testMalformedSiblingsBoundDiagnosticsAndScanBudget() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var limits = ProbeLimits.pilot
    limits.diagnostics = 2
    let (a, _) = try setup(root, limits: limits)
    try a.enqueue(event(100))
    try a.publishOutbox()
    for n in 0..<10 {
      try ProbeIO.durable(
        Data("bad".utf8),
        at: a.sharedRoot.appendingPathComponent("Folio Review/events/bad-\(n).json"))
    }
    let report = try a.reconcile()
    XCTAssertEqual(report.status, .complete)
    XCTAssertEqual(report.state!.acceptedIDs, [fixed(100)])
    XCTAssertEqual(report.diagnostics.count, 2)
    XCTAssertEqual(report.diagnosticCount, 10)
    limits.candidates = 5
    XCTAssertEqual(try store(root, "a", limits: limits).reconcile().status, .capacityExceeded)
  }
  func testPreparationAndPublicationCrashWindows() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    XCTAssertThrowsError(try a.enqueue(event(100), fault: .beforeReady))
    XCTAssertEqual(try a.reconcile().state!.acceptedIDs, [])
    XCTAssertThrowsError(try a.enqueue(event(101), fault: .afterReady))
    let restarted = store(root, "a")
    XCTAssertEqual(try restarted.reconcile().state!.acceptedIDs, [fixed(101)])
    XCTAssertEqual(try restarted.publishOutbox(stopAfter: 1).status, .injectedInterruption)
    XCTAssertEqual(try store(root, "a").publishOutbox().status, .complete)
  }
  func testMissingWorkspaceManifestIsUnavailableAndCapacityBoundaryIsAdmitted() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var limits = ProbeLimits.pilot
    limits.events = 1
    limits.snapshots = 1
    let (a, _) = try setup(root, limits: limits)
    let bytes = Data([1])
    try a.enqueue(event(100), snapshots: [SnapshotID.hash(bytes): bytes])
    XCTAssertEqual(try a.reconcile().status, .complete)
    XCTAssertThrowsError(try a.enqueue(event(101)))
    XCTAssertEqual(try a.reconcile().state!.acceptedIDs, [fixed(100)])
    try FileManager.default.removeItem(
      at: a.sharedRoot.appendingPathComponent("Folio Review/workspace.json"))
    XCTAssertEqual(try a.reconcile().status, .unavailable)
    XCTAssertThrowsError(try a.enqueue(event(102)))
  }
  func testThousandsOfBadCandidatesAreBoundedAndOversizedSiblingsDoNotBlock() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    try a.enqueue(event(100))
    _ = try a.publishOutbox()
    var unknown = event(101)
    unknown.schemaVersion = 77
    try ProbeIO.durable(
      ProbeIO.encode(unknown),
      at: a.sharedRoot.appendingPathComponent("Folio Review/events/unknown.json"))
    try ProbeIO.durable(
      Data(repeating: 32, count: 65537),
      at: a.sharedRoot.appendingPathComponent("Folio Review/events/oversized.json"))
    XCTAssertEqual(try a.reconcile().state!.acceptedIDs, [fixed(100)])
    for n in 0..<1100 {
      try ProbeIO.durable(
        Data("bad".utf8),
        at: a.sharedRoot.appendingPathComponent("Folio Review/events/bad-\(n).json"))
    }
    var limits = ProbeLimits.pilot
    limits.candidates = 1000
    let report = try store(root, "a", limits: limits).reconcile()
    XCTAssertEqual(report.status, .capacityExceeded)
    XCTAssertNil(report.state)
  }
  func testEvidenceExportRetainsConflictingBytesWithExplicitCoverage() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, b) = try setup(root)
    let first = try ProbeIO.encode(event(100))
    var changed = event(100)
    changed.payload = .comment(
      id: fixed(1100), text: "variant", sourceRevision: SnapshotID.hash(Data("base".utf8)))
    let second = try ProbeIO.encode(changed)
    try a.enqueue(event(100))
    _ = try a.publishOutbox()
    try b.enqueue(changed)
    _ = try b.publishOutbox()
    XCTAssertThrowsError(
      try SimulatedCourier.transfer(
        from: a.sharedRoot, to: b.sharedRoot,
        relativePaths: SimulatedCourier.paths(a.sharedRoot, kind: "events")))
    let output = root.appendingPathComponent("evidence")
    try b.exportEvidence(to: output)
    let enumerator = FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)!
    var exported = [Data]()
    for case let path as URL in enumerator {
      if path.pathExtension == "json" {
        if let bytes = try? Data(contentsOf: path) { exported.append(bytes) }
      }
    }
    XCTAssertTrue(exported.contains(first))
    XCTAssertTrue(exported.contains(second))
    let ledger =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: output.appendingPathComponent("ledger.json"))) as! [String: Any]
    XCTAssertNotNil(ledger["exportTruncated"])
    XCTAssertNotNil(ledger["exportedFiles"])
  }
  func testScanBudgetIsAggregateAcrossSharedReceivedAndOutbox() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    try a.enqueue(event(100))
    _ = try a.publishOutbox()
    _ = try a.reconcile()
    var limits = ProbeLimits.pilot
    limits.candidates = 4
    let report = try store(root, "a", limits: limits).reconcile()
    XCTAssertEqual(report.status, .capacityExceeded)
    XCTAssertNil(report.state)
  }
  func testTwentyShuffledReplaySchedules() {
    let events = (100..<200).map { event($0, parents: $0 == 100 ? [] : [fixed($0 - 1)]) }
    let expected = ProbeReducer.reduce(events: events, snapshots: [:])
    XCTAssertEqual(expected.acceptedIDs.count, 100)
    for seed in 1...20 {
      var values = events
      var state = UInt64(seed)
      for i in stride(from: values.count - 1, through: 1, by: -1) {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        values.swapAt(i, Int(state % UInt64(i + 1)))
      }
      XCTAssertEqual(ProbeReducer.reduce(events: values, snapshots: [:]), expected)
    }
  }
}
