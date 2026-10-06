import Foundation

public struct PreparedSharedSource: Codable {
  public let event: CollaborationEvent
  public let document: SharedDocumentRef
  public let localRoot, sharedRoot, basePath, proposedPath: URL
  public let limits: CollaborationLimits
}
public enum SharedApplyResult: String, Codable { case applied, unchanged, conflict, unavailable }
public enum CollaborationSourceFault { case beforeLocalWrite, afterLocalWrite }
public struct SharedRecoveryExport: Codable {
  public let proposalID: UUID
  public let hashes: [String]
  public let paths: [URL]
  public let savedOutcome: String
  public let externalRecoveryGap: Bool
  public let coverageComplete: Bool
}
public enum CollaborationSourceRecovery {
  static func directory(_ prepared: PreparedSharedSource) -> URL {
    prepared.localRoot.appendingPathComponent("ready/\(prepared.event.id.uuidString)")
  }
  static func receipt(_ prepared: PreparedSharedSource, _ value: String) throws {
    try CollaborationIO.durable(
      Data(value.utf8), at: directory(prepared).appendingPathComponent("phase.txt"))
  }
  static func verified(_ prepared: PreparedSharedSource) throws -> (Data, Data) {
    guard prepared.event.isSource else { throw CollaborationError.invalid("source event required") }
    let base = prepared.event.revisions[0], proposed = prepared.event.revisions[1]
    for path in [prepared.basePath, prepared.proposedPath] {
      try CollaborationIO.safe(path, root: prepared.localRoot)
    }
    let a = try CollaborationIO.read(prepared.basePath, limit: prepared.limits.snapshotBytes)
    let b = try CollaborationIO.read(prepared.proposedPath, limit: prepared.limits.snapshotBytes)
    try CollaborationIO.snapshot(a, hash: base, limits: prepared.limits)
    try CollaborationIO.snapshot(b, hash: proposed, limits: prepared.limits)
    return (a, b)
  }
  public static func prepare(document:SharedDocumentRef, base:Data, proposed:Data, actor:ParticipantProfile,
    parents:[UUID] = [], triggerEventID:UUID? = nil, store:CollaborationReplicaStore,
    fault:CollaborationPreparationFault? = nil) throws -> PreparedSharedSource {
    _ = try store.sourceURL(document:document)
    let report=try store.reconcile();try store.permit(report)
    guard let state=report.state, (state.sourceHeads[document.documentID] ?? []).count <= 1,
      (state.blockingEventIDsByDocument[document.documentID] ?? []).isEmpty else { throw CollaborationError.invalid("resolve source history first") }
    let a=CollaborationSnapshotID.hash(base), b=CollaborationSnapshotID.hash(proposed)
    let deps=collaborationSortedIDs(Set(parents + (state.sourceHeads[document.documentID] ?? []) + (triggerEventID.map { [$0] } ?? [])))
    let event=CollaborationEvent(workspaceID:document.workspaceID,documentID:document.documentID,
      participantID:actor.participantID,deviceID:actor.deviceID,authorName:actor.displayName,rawSourceRevision:a,
      parents:deps,payload:.sourceProposal(baseRevision:a,proposedRevision:b,triggerEventID:triggerEventID))
    try store.enqueue(event,snapshots:a == b ? [a:base] : [a:base,b:proposed],fault:fault)
    let prepared=try load(proposalID:event.id,from:store);try receipt(prepared,"prepared");return prepared
  }
  public static func prepareResolution(document:SharedDocumentRef, expectedCurrent:Data, chosen:Data,
    superseding:[UUID], actor:ParticipantProfile, store:CollaborationReplicaStore) throws -> PreparedSharedSource {
    _ = try store.sourceURL(document:document)
    let report=try store.reconcile();try store.permit(report)
    guard let state=report.state, !superseding.isEmpty, Set(superseding) == Set(state.sourceHeads[document.documentID] ?? []),
      !(state.pendingEventIDs.contains { state.blockingEventIDsByDocument[document.documentID]?.contains($0) ?? false }) else { throw CollaborationError.invalid("all observed source heads required") }
    let a=CollaborationSnapshotID.hash(expectedCurrent),b=CollaborationSnapshotID.hash(chosen)
    let event=CollaborationEvent(workspaceID:document.workspaceID,documentID:document.documentID,
      participantID:actor.participantID,deviceID:actor.deviceID,authorName:actor.displayName,rawSourceRevision:a,
      parents:superseding,payload:.sourceResolution(baseRevision:a,proposedRevision:b,supersedes:superseding))
    try store.enqueue(event,snapshots:a == b ? [a:expectedCurrent] : [a:expectedCurrent,b:chosen])
    let prepared=try load(proposalID:event.id,from:store);try receipt(prepared,"prepared");return prepared
  }
  public static func load(proposalID: UUID, from store: CollaborationReplicaStore) throws -> PreparedSharedSource {
    let ready = store.localRoot.appendingPathComponent("ready/\(proposalID.uuidString)")
    try CollaborationIO.safe(ready, root: store.localRoot)
    let event = try CollaborationIO.decodeEvent(
      CollaborationIO.read(
        ready.appendingPathComponent("events/\(proposalID.uuidString).json"),
        limit: store.limits.eventBytes), limits: store.limits)
    guard event.id == proposalID, event.workspaceID == store.workspaceID,
      event.isSource
    else { throw CollaborationError.invalid("durable proposal identity") }
    let a=event.revisions[0], b=event.revisions[1]
    let prepared = PreparedSharedSource(
      event: event, document:try store.document(id:event.documentID), localRoot: store.localRoot, sharedRoot: store.sharedRoot,
      basePath: ready.appendingPathComponent("snapshots/\(a).bin"),
      proposedPath: ready.appendingPathComponent("snapshots/\(b).bin"), limits: store.limits)
    _ = try verified(prepared)
    return prepared
  }
  public static func apply(_ prepared: PreparedSharedSource, store:CollaborationReplicaStore, fault: CollaborationSourceFault? = nil)
    throws -> SharedApplyResult
  {
    let (base, proposed) = try verified(prepared)
    guard store.localRoot == prepared.localRoot, store.sharedRoot == prepared.sharedRoot, store.workspaceID == prepared.event.workspaceID else { throw CollaborationError.invalid("prepared store mismatch") }
    let source=try store.sourceURL(document:prepared.document)
    let (report, archive) = try store.load()
    if report.status == .unavailable || report.status == .needsReconnection { return .unavailable }
    try store.permit(report)
    try CollaborationIO.safe(source, root: prepared.sharedRoot)
    guard report.state!.sourceHeads[prepared.document.documentID] == [prepared.event.id],
      (report.state!.blockingEventIDsByDocument[prepared.document.documentID] ?? []).isEmpty
    else { throw CollaborationError.invalid("unresolved or superseded source proposal") }
    guard FileManager.default.fileExists(atPath: source.path) else { return .unavailable }
    // Receipt precedes the coordinated write. An absent final receipt is interpreted only using current bytes.
    try receipt(prepared, "applying")
    if fault == .beforeLocalWrite { throw CollaborationError.injectedInterruption }
    var result = SharedApplyResult.unavailable
    var innerError: Error?
    var coordinatorError: NSError?
    NSFileCoordinator().coordinate(
      writingItemAt: source, options: .forReplacing, error: &coordinatorError
    ) { url in
      do {
        let current = try CollaborationIO.read(url, limit: prepared.limits.snapshotBytes)
        guard current == base else {
          if current == proposed {
            result = .unchanged
            return
          }
          let hash = CollaborationSnapshotID.hash(current)
          let observed = directory(prepared).appendingPathComponent("observed/\(hash).bin")
          var projected = archive.bytes
          projected["observed/\(hash).bin"] = current
          guard Set(archive.snapshots.keys).union([hash]).count <= prepared.limits.snapshots,
            Set(projected.values).reduce(0, { $0 + $1.count }) <= prepared.limits.totalBytes
          else { throw CollaborationError.capacityExceeded }
          try CollaborationIO.immutable(current, at: observed)
          result = .conflict
          return
        }
        if proposed == base {
          result = .unchanged
          return
        }
        try CollaborationIO.durable(proposed, at: url)
        result = .applied
      } catch { innerError = error }
    }
    if let error = innerError { throw error }
    if coordinatorError != nil { result = .unavailable }
    if fault == .afterLocalWrite { throw CollaborationError.injectedInterruption }
    try receipt(prepared, result == .applied ? "localApplied" : result.rawValue)
    return result
  }
  public static func outcome(_ prepared: PreparedSharedSource, store:CollaborationReplicaStore) throws -> String {
    let phase =
      String(
        data: (try? CollaborationIO.read(directory(prepared).appendingPathComponent("phase.txt"), limit: 64))
          ?? Data(), encoding: .utf8) ?? ""
    if phase != "applying" { return phase.isEmpty ? "prepared" : phase }
    // Current shared bytes cannot prove which device performed an interrupted write.
    return "unknownInterrupted"
  }
  public static func recover(proposalID: UUID, from store: CollaborationReplicaStore, to output: URL) throws
    -> SharedRecoveryExport
  {
    let (report, archive) = try store.load()
    switch report.status {
    case .complete, .pending, .needsReconnection, .unavailable: break
    default: try store.permit(report)
    }
    guard !(report.state?.invalidIDs.contains(proposalID) ?? false),
      let event = archive.events[proposalID], event.isSource,
      let base = archive.snapshots[event.revisions[0]], let proposed = archive.snapshots[event.revisions[1]]
    else { throw CollaborationError.invalid("proposal snapshots pending/unavailable") }
    let a=event.revisions[0], b=event.revisions[1]
    try CollaborationIO.snapshot(base, hash: a, limits: store.limits)
    try CollaborationIO.snapshot(proposed, hash: b, limits: store.limits)
    let target = output.standardizedFileURL.resolvingSymlinksInPath().path
    for root in [store.localRoot, store.sharedRoot] {
      let path = root.standardizedFileURL.resolvingSymlinksInPath().path
      guard target != path, !target.hasPrefix(path + "/") else {
        throw CollaborationError.invalid("separate recovery directory")
      }
    }
    if FileManager.default.fileExists(atPath: output.path),
      !(try FileManager.default.contentsOfDirectory(atPath: output.path)).isEmpty
    {
      throw CollaborationError.invalid("empty recovery directory required")
    }
    var exportedBytes = base.count + proposed.count
    guard exportedBytes <= store.limits.totalBytes else { throw CollaborationError.capacityExceeded }
    var paths = [
      output.appendingPathComponent("base-\(a).bin"),
      output.appendingPathComponent("proposed-\(b).bin"),
    ]
    var hashes = [a, b]
    var saved = "intendedOnly"
    try CollaborationIO.immutable(base, at: paths[0])
    try CollaborationIO.immutable(proposed, at: paths[1])
    if let prepared = try? load(proposalID: proposalID, from: store) {
      saved = try outcome(prepared, store:store)
      for observed in try store.files(
        directory(prepared).appendingPathComponent("observed"), bound: store.limits.snapshots)
      {
        let bytes = try CollaborationIO.read(observed, limit: store.limits.snapshotBytes)
        let hash = observed.deletingPathExtension().lastPathComponent
        try CollaborationIO.snapshot(bytes, hash: hash, limits: store.limits)
        guard hashes.count < store.limits.snapshots + 2,
          bytes.count + exportedBytes <= store.limits.totalBytes
        else { throw CollaborationError.capacityExceeded }
        let path = output.appendingPathComponent("observed-\(hash).bin")
        try CollaborationIO.immutable(bytes, at: path)
        paths.append(path)
        hashes.append(hash)
        exportedBytes += bytes.count
      }
    }
    let export = SharedRecoveryExport(
      proposalID: proposalID, hashes: hashes, paths: paths, savedOutcome: saved,
      externalRecoveryGap: true, coverageComplete:report.coverageComplete)
    try CollaborationIO.immutable(
      CollaborationIO.encode(export), at: output.appendingPathComponent("recovery.json"))
    return export
  }
}

public struct SharedSaveOutcome: Codable {
  public let proposalID: UUID
  public let localApply: SharedApplyResult
  public let publication: CollaborationStatus
  public init(proposalID: UUID, localApply: SharedApplyResult, publication: CollaborationStatus) {
    self.proposalID=proposalID;self.localApply=localApply;self.publication=publication
  }
}
