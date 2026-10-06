import XCTest

@testable import TransportProbe

final class SourceRecoveryTests: XCTestCase {
  let w = fixed(1), d = fixed(2), p = fixed(3), device = fixed(4)
  func proposal(_ n: Int, base: Data, proposed: Data, parents: [UUID] = []) -> ProbeEvent {
    ProbeEvent(
      id: fixed(n), workspaceID: w, documentID: d, participantID: p, deviceID: device,
      parents: parents,
      payload: .sourceProposal(
        baseRevision: SnapshotID.hash(base), proposedRevision: SnapshotID.hash(proposed)))
  }
  func setup(_ root: URL) throws -> (ReplicaStore, ReplicaStore) {
    let a = ReplicaStore(
      localRoot: root.appendingPathComponent("al"), sharedRoot: root.appendingPathComponent("as"),
      workspaceID: w)
    let b = ReplicaStore(
      localRoot: root.appendingPathComponent("bl"), sharedRoot: root.appendingPathComponent("bs"),
      workspaceID: w)
    try a.initialize(documentID: d, source: Data("S0".utf8))
    try SimulatedCourier.transfer(
      from: a.sharedRoot, to: b.sharedRoot,
      relativePaths: [
        "Folio Review/workspace.json", "Folio Review/documents/\(d.uuidString).json", "fixture.md",
      ])
    try b.join()
    return (a, b)
  }
  func testConcurrentSourceWritersRecoverBothVersions() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, b) = try setup(root)
    let base = Data("S0".utf8)
    let sa = Data("SA".utf8)
    let sb = Data("SB".utf8)
    let pa = try SourceRecovery.prepare(
      event: proposal(100, base: base, proposed: sa), base: base, proposed: sa, store: a)
    let pb = try SourceRecovery.prepare(
      event: proposal(101, base: base, proposed: sb), base: base, proposed: sb, store: b)
    XCTAssertEqual(
      try SourceRecovery.apply(pa, to: a.sharedRoot.appendingPathComponent("fixture.md")), .applied)
    XCTAssertEqual(
      try SourceRecovery.apply(pb, to: b.sharedRoot.appendingPathComponent("fixture.md")), .applied)
    _ = try a.publishOutbox(only: "events")
    _ = try b.publishOutbox(only: "events")
    try SimulatedCourier.transfer(
      from: a.sharedRoot, to: b.sharedRoot,
      relativePaths: SimulatedCourier.paths(a.sharedRoot, kind: "events"))
    try SimulatedCourier.transfer(
      from: b.sharedRoot, to: a.sharedRoot,
      relativePaths: SimulatedCourier.paths(b.sharedRoot, kind: "events"))
    XCTAssertEqual(try a.reconcile().status, .pending)
    XCTAssertThrowsError(
      try SourceRecovery.recover(
        proposalID: pb.event.id, from: a, to: root.appendingPathComponent("early")))
    _ = try a.publishOutbox(only: "snapshots")
    _ = try b.publishOutbox(only: "snapshots")
    try SimulatedCourier.transfer(
      from: a.sharedRoot, to: b.sharedRoot,
      relativePaths: SimulatedCourier.paths(a.sharedRoot, kind: "snapshots"))
    try SimulatedCourier.transfer(
      from: b.sharedRoot, to: a.sharedRoot,
      relativePaths: SimulatedCourier.paths(b.sharedRoot, kind: "snapshots"))
    for s in [a, b] {
      try sb.write(to: s.sharedRoot.appendingPathComponent("fixture.md"))
      XCTAssertEqual(try s.reconcile().state!.sourceHeads, [fixed(100), fixed(101)])
      for (n, expected) in [(100, sa), (101, sb)] {
        let export = try SourceRecovery.recover(
          proposalID: fixed(n), from: s,
          to: root.appendingPathComponent("export-\(s.localRoot.lastPathComponent)-\(n)"))
        XCTAssertEqual(try Data(contentsOf: export.paths[0]), base)
        XCTAssertEqual(try Data(contentsOf: export.paths[1]), expected)
      }
      XCTAssertThrowsError(
        try SourceRecovery.prepare(
          event: proposal(102, base: sb, proposed: Data("next".utf8)), base: sb,
          proposed: Data("next".utf8), store: s))
    }
    let resolution = ProbeEvent(
      id: fixed(103), workspaceID: w, documentID: d, participantID: p, deviceID: device,
      parents: [fixed(100), fixed(101)],
      payload: .sourceResolution(
        proposedRevision: SnapshotID.hash(sa), supersedes: [fixed(100), fixed(101)]))
    try a.enqueue(resolution)
    XCTAssertEqual(try a.reconcile().state!.sourceHeads, [fixed(103)])
    let third = proposal(104, base: base, proposed: Data("SC".utf8))
    try a.enqueue(third, snapshots: [SnapshotID.hash(Data("SC".utf8)): Data("SC".utf8)])
    XCTAssertEqual(try a.reconcile().state!.sourceHeads, [fixed(103), fixed(104)])
  }
  func testGuardUsesBytesDespiteMatchingMetadataAndRetainsObservedEvidence() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    let source = a.sharedRoot.appendingPathComponent("fixture.md")
    let base = Data("S0".utf8)
    let next = Data("SA".utf8)
    let prepared = try SourceRecovery.prepare(
      event: proposal(100, base: base, proposed: next), base: base, proposed: next, store: a)
    let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
    try Data("XX".utf8).write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: attrs[.modificationDate]!], ofItemAtPath: source.path)
    XCTAssertEqual(try SourceRecovery.apply(prepared, to: source), .conflict)
    XCTAssertEqual(try Data(contentsOf: source), Data("XX".utf8))
    let export = try SourceRecovery.recover(
      proposalID: fixed(100), from: a, to: root.appendingPathComponent("recovery"))
    XCTAssertTrue(export.externalRecoveryGap)
    XCTAssertEqual(export.savedOutcome, "conflict")
    XCTAssertTrue(export.paths.contains { (try? Data(contentsOf: $0)) == Data("XX".utf8) })
  }
  func testCrashReceiptsAndUnknownInterruptedOutcome() throws {
    for fault in [SourceFault.beforeLocalWrite, .afterLocalWrite] {
      let root = temporary()
      defer { try? FileManager.default.removeItem(at: root) }
      let (a, _) = try setup(root)
      let source = a.sharedRoot.appendingPathComponent("fixture.md")
      let base = Data("S0".utf8)
      let next = Data("SA".utf8)
      let prepared = try SourceRecovery.prepare(
        event: proposal(100, base: base, proposed: next), base: base, proposed: next, store: a)
      XCTAssertThrowsError(try SourceRecovery.apply(prepared, to: source, fault: fault))
      let restarted = ReplicaStore(localRoot: a.localRoot, sharedRoot: a.sharedRoot, workspaceID: w)
      let loaded = try SourceRecovery.load(proposalID: fixed(100), from: restarted)
      XCTAssertEqual(
        try SourceRecovery.outcome(loaded, source: source),
        fault == .beforeLocalWrite ? "prepared" : "localApplied")
      try Data("external".utf8).write(to: source)
      XCTAssertEqual(try SourceRecovery.outcome(loaded, source: source), "unknownInterrupted")
      _ = try restarted.publishOutbox(stopAfter: 1)
      _ = try restarted.publishOutbox()
    }
  }
  func testUnavailableUnchangedChecksumAndPreparationFailure() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    let source = a.sharedRoot.appendingPathComponent("fixture.md")
    let base = Data("S0".utf8)
    XCTAssertThrowsError(
      try SourceRecovery.prepare(
        event: proposal(100, base: base, proposed: base), base: Data("wrong".utf8), proposed: base,
        store: a))
    XCTAssertEqual(try Data(contentsOf: source), base)
    XCTAssertThrowsError(
      try SourceRecovery.prepare(
        event: proposal(100, base: base, proposed: base), base: base, proposed: base, store: a,
        fault: .beforeReady))
    XCTAssertEqual(try Data(contentsOf: source), base)
    let prepared = try SourceRecovery.prepare(
      event: proposal(101, base: base, proposed: base), base: base, proposed: base, store: a)
    XCTAssertEqual(try SourceRecovery.apply(prepared, to: source), .unchanged)
    try FileManager.default.removeItem(at: source)
    XCTAssertEqual(try SourceRecovery.apply(prepared, to: source), .unavailable)
  }
  func testBOMCRLFEmojiAndCorruptStaging() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    let base = Data("S0".utf8)
    let next = Data([0xef, 0xbb, 0xbf]) + Data("Hello 👋\r\n".utf8)
    let prepared = try SourceRecovery.prepare(
      event: proposal(100, base: base, proposed: next), base: base, proposed: next, store: a)
    let export = try SourceRecovery.recover(
      proposalID: fixed(100), from: a, to: root.appendingPathComponent("raw"))
    XCTAssertEqual(try Data(contentsOf: export.paths[1]), next)
    try Data("corrupt".utf8).write(to: prepared.proposedPath)
    XCTAssertThrowsError(
      try SourceRecovery.apply(prepared, to: a.sharedRoot.appendingPathComponent("fixture.md")))
    XCTAssertEqual(try Data(contentsOf: a.sharedRoot.appendingPathComponent("fixture.md")), base)
  }
  func testRecoverySurvivesDeletedSourceAndMissingSharedWorkspace() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    let base = Data("S0".utf8)
    let next = Data("SA".utf8)
    _ = try SourceRecovery.prepare(
      event: proposal(100, base: base, proposed: next), base: base, proposed: next, store: a)
    try FileManager.default.removeItem(at: a.sharedRoot.appendingPathComponent("fixture.md"))
    let deleted = try SourceRecovery.recover(
      proposalID: fixed(100), from: a, to: root.appendingPathComponent("deleted-recovery"))
    XCTAssertEqual(try Data(contentsOf: deleted.paths[1]), next)
    try FileManager.default.moveItem(
      at: a.sharedRoot, to: root.appendingPathComponent("moved-shared"))
    let restarted = ReplicaStore(localRoot: a.localRoot, sharedRoot: a.sharedRoot, workspaceID: w)
    let absent = try SourceRecovery.recover(
      proposalID: fixed(100), from: restarted, to: root.appendingPathComponent("offline-recovery"))
    XCTAssertEqual(try Data(contentsOf: absent.paths[0]), base)
  }
  func testSupersededPreparationCannotWriteAndObservedEvidenceIsBounded() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, _) = try setup(root)
    let base = Data("S0".utf8)
    let next = Data("SA".utf8)
    let source = a.sharedRoot.appendingPathComponent("fixture.md")
    let prepared = try SourceRecovery.prepare(
      event: proposal(100, base: base, proposed: next), base: base, proposed: next, store: a)
    let resolution = ProbeEvent(
      id: fixed(101), workspaceID: w, documentID: d, participantID: p, deviceID: device,
      parents: [fixed(100)],
      payload: .sourceResolution(proposedRevision: SnapshotID.hash(base), supersedes: [fixed(100)]))
    try a.enqueue(resolution)
    XCTAssertThrowsError(try SourceRecovery.apply(prepared, to: source))
    XCTAssertEqual(try Data(contentsOf: source), base)
    let freshRoot = temporary()
    defer { try? FileManager.default.removeItem(at: freshRoot) }
    let (b, _) = try setup(freshRoot)
    let freshSource = b.sharedRoot.appendingPathComponent("fixture.md")
    let old = try SourceRecovery.prepare(
      event: proposal(102, base: base, proposed: next), base: base, proposed: next, store: b)
    let (_, archive) = try b.load()
    var limits = ProbeLimits.pilot
    limits.totalBytes = archive.bytes.values.reduce(0, { $0 + $1.count }) + 30
    let bounded = PreparedSource(
      event: old.event, localRoot: old.localRoot, sharedRoot: old.sharedRoot,
      basePath: old.basePath, proposedPath: old.proposedPath, limits: limits)
    try Data(repeating: 65, count: 24).write(to: freshSource)
    XCTAssertEqual(try SourceRecovery.apply(bounded, to: freshSource), .conflict)
    try Data(repeating: 66, count: 24).write(to: freshSource)
    XCTAssertThrowsError(try SourceRecovery.apply(bounded, to: freshSource))
    XCTAssertEqual(try Data(contentsOf: freshSource), Data(repeating: 66, count: 24))
  }

}
