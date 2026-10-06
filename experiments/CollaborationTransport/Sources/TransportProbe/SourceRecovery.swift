import Foundation

public struct PreparedSource: Codable {
  public let event: ProbeEvent
  public let localRoot, sharedRoot, basePath, proposedPath: URL
  public let limits: ProbeLimits
}
public enum LocalApplyResult: String, Codable { case applied, unchanged, conflict, unavailable }
public enum SourceFault { case beforeLocalWrite, afterLocalWrite }
public struct RecoveryExport: Codable {
  public let proposalID: UUID
  public let hashes: [String]
  public let paths: [URL]
  public let savedOutcome: String
  public let externalRecoveryGap: Bool
}
public enum SourceRecovery {
  static func directory(_ prepared: PreparedSource) -> URL {
    prepared.localRoot.appendingPathComponent("ready/\(prepared.event.id.uuidString)")
  }
  static func receipt(_ prepared: PreparedSource, _ value: String) throws {
    try ProbeIO.durable(
      Data(value.utf8), at: directory(prepared).appendingPathComponent("phase.txt"))
  }
  static func verified(_ prepared: PreparedSource) throws -> (Data, Data) {
    guard case .sourceProposal(let base, let proposed) = prepared.event.payload else {
      throw ProbeError.invalid("proposal required")
    }
    for path in [prepared.basePath, prepared.proposedPath] {
      try ProbeIO.safe(path, root: prepared.localRoot)
    }
    let a = try ProbeIO.read(prepared.basePath, limit: prepared.limits.snapshotBytes)
    let b = try ProbeIO.read(prepared.proposedPath, limit: prepared.limits.snapshotBytes)
    try ProbeIO.snapshot(a, hash: base, limits: prepared.limits)
    try ProbeIO.snapshot(b, hash: proposed, limits: prepared.limits)
    return (a, b)
  }
  public static func prepare(
    event: ProbeEvent, base: Data, proposed: Data, store: ReplicaStore,
    fault: PreparationFault? = nil
  ) throws -> PreparedSource {
    guard case .sourceProposal(let a, let b) = event.payload else {
      throw ProbeError.invalid("proposal required")
    }
    try ProbeIO.snapshot(base, hash: a, limits: store.limits)
    try ProbeIO.snapshot(proposed, hash: b, limits: store.limits)
    let report = try store.reconcile()
    try store.permit(report)
    guard report.state!.sourceHeads.count <= 1, report.state!.pendingEventIDs.isEmpty else {
      throw ProbeError.invalid("resolve source branches/pending history first")
    }
    let snapshots = a == b ? [a: base] : [a: base, b: proposed]
    try store.enqueue(event, snapshots: snapshots, fault: fault)
    let prepared = try load(proposalID: event.id, from: store)
    try receipt(prepared, "prepared")
    return prepared
  }
  public static func load(proposalID: UUID, from store: ReplicaStore) throws -> PreparedSource {
    let ready = store.localRoot.appendingPathComponent("ready/\(proposalID.uuidString)")
    try ProbeIO.safe(ready, root: store.localRoot)
    let event = try ProbeIO.decodeEvent(
      ProbeIO.read(
        ready.appendingPathComponent("events/\(proposalID.uuidString).json"),
        limit: store.limits.eventBytes), limits: store.limits)
    guard event.id == proposalID, event.workspaceID == store.workspaceID,
      event.documentID == (try store.document()).documentID,
      case .sourceProposal(let a, let b) = event.payload
    else { throw ProbeError.invalid("durable proposal identity") }
    let prepared = PreparedSource(
      event: event, localRoot: store.localRoot, sharedRoot: store.sharedRoot,
      basePath: ready.appendingPathComponent("snapshots/\(a).bin"),
      proposedPath: ready.appendingPathComponent("snapshots/\(b).bin"), limits: store.limits)
    _ = try verified(prepared)
    return prepared
  }
  public static func apply(_ prepared: PreparedSource, to source: URL, fault: SourceFault? = nil)
    throws -> LocalApplyResult
  {
    let (base, proposed) = try verified(prepared)
    let store = ReplicaStore(
      localRoot: prepared.localRoot, sharedRoot: prepared.sharedRoot,
      workspaceID: prepared.event.workspaceID, limits: prepared.limits)
    let (report, archive) = try store.load()
    if report.status == .unavailable || report.status == .needsReconnection { return .unavailable }
    try store.permit(report)
    guard let document = archive.documents[prepared.event.documentID],
      source.standardizedFileURL
        == prepared.sharedRoot.appendingPathComponent(document.relativePath).standardizedFileURL
    else { throw ProbeError.invalid("registered disposable source required") }
    try ProbeIO.safe(source, root: prepared.sharedRoot)
    guard report.state!.sourceHeads == [prepared.event.id], report.state!.pendingEventIDs.isEmpty
    else { throw ProbeError.invalid("unresolved or superseded source proposal") }
    guard FileManager.default.fileExists(atPath: source.path) else { return .unavailable }
    // Receipt precedes the coordinated write. An absent final receipt is interpreted only using current bytes.
    try receipt(prepared, "applying")
    if fault == .beforeLocalWrite { throw ProbeError.injectedInterruption }
    var result = LocalApplyResult.unavailable
    var innerError: Error?
    var coordinatorError: NSError?
    NSFileCoordinator().coordinate(
      writingItemAt: source, options: .forReplacing, error: &coordinatorError
    ) { url in
      do {
        let current = try ProbeIO.read(url, limit: prepared.limits.snapshotBytes)
        guard current == base else {
          if current == proposed {
            result = .unchanged
            return
          }
          let hash = SnapshotID.hash(current)
          let observed = directory(prepared).appendingPathComponent("observed/\(hash).bin")
          var projected = archive.bytes
          projected["observed/\(hash).bin"] = current
          guard Set(archive.snapshots.keys).union([hash]).count <= prepared.limits.snapshots,
            Set(projected.values).reduce(0, { $0 + $1.count }) <= prepared.limits.totalBytes
          else { throw ProbeError.capacityExceeded }
          try ProbeIO.immutable(current, at: observed)
          result = .conflict
          return
        }
        if proposed == base {
          result = .unchanged
          return
        }
        try ProbeIO.durable(proposed, at: url)
        result = .applied
      } catch { innerError = error }
    }
    if let error = innerError { throw error }
    if coordinatorError != nil { result = .unavailable }
    if fault == .afterLocalWrite { throw ProbeError.injectedInterruption }
    try receipt(prepared, result == .applied ? "localApplied" : result.rawValue)
    return result
  }
  public static func outcome(_ prepared: PreparedSource, source: URL) throws -> String {
    let phase =
      String(
        data: (try? ProbeIO.read(directory(prepared).appendingPathComponent("phase.txt"), limit: 64))
          ?? Data(), encoding: .utf8) ?? ""
    if phase != "applying" { return phase.isEmpty ? "prepared" : phase }
    let (base, proposed) = try verified(prepared)
    guard let current = try? ProbeIO.read(source, limit: prepared.limits.snapshotBytes) else {
      return "unknownInterrupted"
    }
    if current == proposed && proposed != base { return "localApplied" }
    if current == base { return "prepared" }
    return "unknownInterrupted"
  }
  public static func recover(proposalID: UUID, from store: ReplicaStore, to output: URL) throws
    -> RecoveryExport
  {
    let (report, archive) = try store.load()
    switch report.status {
    case .complete, .pending, .needsReconnection, .unavailable: break
    default: try store.permit(report)
    }
    guard !(report.state?.invalidIDs.contains(proposalID) ?? false),
      let event = archive.events[proposalID], case .sourceProposal(let a, let b) = event.payload,
      let base = archive.snapshots[a], let proposed = archive.snapshots[b]
    else { throw ProbeError.invalid("proposal snapshots pending/unavailable") }
    try ProbeIO.snapshot(base, hash: a, limits: store.limits)
    try ProbeIO.snapshot(proposed, hash: b, limits: store.limits)
    let target = output.standardizedFileURL.resolvingSymlinksInPath().path
    for root in [store.localRoot, store.sharedRoot] {
      let path = root.standardizedFileURL.resolvingSymlinksInPath().path
      guard target != path, !target.hasPrefix(path + "/") else {
        throw ProbeError.invalid("separate recovery directory")
      }
    }
    if FileManager.default.fileExists(atPath: output.path),
      !(try FileManager.default.contentsOfDirectory(atPath: output.path)).isEmpty
    {
      throw ProbeError.invalid("empty recovery directory required")
    }
    var exportedBytes = base.count + proposed.count
    guard exportedBytes <= store.limits.totalBytes else { throw ProbeError.capacityExceeded }
    var paths = [
      output.appendingPathComponent("base-\(a).bin"),
      output.appendingPathComponent("proposed-\(b).bin"),
    ]
    var hashes = [a, b]
    var saved = "intendedOnly"
    try ProbeIO.immutable(base, at: paths[0])
    try ProbeIO.immutable(proposed, at: paths[1])
    if let prepared = try? load(proposalID: proposalID, from: store) {
      let source = store.sharedRoot.appendingPathComponent(try store.document().relativePath)
      saved = try outcome(prepared, source: source)
      for observed in try store.files(
        directory(prepared).appendingPathComponent("observed"), bound: store.limits.snapshots)
      {
        let bytes = try ProbeIO.read(observed, limit: store.limits.snapshotBytes)
        let hash = observed.deletingPathExtension().lastPathComponent
        try ProbeIO.snapshot(bytes, hash: hash, limits: store.limits)
        guard hashes.count < store.limits.snapshots + 2,
          bytes.count + exportedBytes <= store.limits.totalBytes
        else { throw ProbeError.capacityExceeded }
        let path = output.appendingPathComponent("observed-\(hash).bin")
        try ProbeIO.immutable(bytes, at: path)
        paths.append(path)
        hashes.append(hash)
        exportedBytes += bytes.count
      }
    }
    let export = RecoveryExport(
      proposalID: proposalID, hashes: hashes, paths: paths, savedOutcome: saved,
      externalRecoveryGap: true)
    try ProbeIO.immutable(
      ProbeIO.encode(export), at: output.appendingPathComponent("recovery.json"))
    return export
  }
}
