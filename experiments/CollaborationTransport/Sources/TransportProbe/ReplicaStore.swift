import Foundation

public enum ProbeStatus: String, Codable {
  case complete, pending, identityConflict, capacityExceeded, unavailable, needsReconnection,
    injectedInterruption
}
public struct ReconciliationReport: Codable, Equatable {
  public var status: ProbeStatus, state: ProbeState?, diagnostics: [String], diagnosticCount: Int
  public init(
    status: ProbeStatus = .complete, state: ProbeState? = nil, diagnostics: [String] = [],
    diagnosticCount: Int = 0
  ) {
    self.status = status
    self.state = state
    self.diagnostics = diagnostics
    self.diagnosticCount = diagnosticCount
  }
}
public struct PublishReport: Codable {
  public var status: ProbeStatus
  public var materialized: Int
  public var guarantee = "local shared-folder materialization only"
}
public enum PreparationFault { case beforeReady, afterReady }
public struct ProbeArchive {
  var events: [UUID: ProbeEvent] = [:]
  var snapshots: [String: Data] = [:]
  var bytes: [String: Data] = [:]
  var documents: [UUID: DocumentManifest] = [:]
}
public final class ReplicaStore {
  public let localRoot, sharedRoot: URL
  public let workspaceID: UUID
  public let limits: ProbeLimits
  let fm = FileManager.default
  public var transportRoot: URL { sharedRoot.appendingPathComponent("Folio Review") }
  public init(localRoot: URL, sharedRoot: URL, workspaceID: UUID, limits: ProbeLimits = .pilot) {
    self.localRoot = localRoot
    self.sharedRoot = sharedRoot
    self.workspaceID = workspaceID
    self.limits = limits
  }
  func checkRoots() throws {
    let a = localRoot.standardizedFileURL.resolvingSymlinksInPath().path
    let b = sharedRoot.standardizedFileURL.resolvingSymlinksInPath().path
    guard a != b, !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else {
      throw ProbeError.invalid("roots must be distinct and separate")
    }
    try ProbeIO.safe(localRoot, root: localRoot)
    try ProbeIO.safe(sharedRoot, root: sharedRoot)
  }
  public func initialize(documentID: UUID, source: Data = Data("# Disposable pilot\n".utf8)) throws
  {
    try checkRoots()
    for root in [localRoot, sharedRoot] {
      if fm.fileExists(atPath: root.path), !(try fm.contentsOfDirectory(atPath: root.path)).isEmpty
      {
        throw ProbeError.identityConflict
      }
    }
    try ProbeIO.snapshot(source, hash: SnapshotID.hash(source), limits: limits)
    try fm.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
    try ProbeIO.immutable(
      ProbeIO.encode(WorkspaceManifest(workspaceID: workspaceID)),
      at: transportRoot.appendingPathComponent("workspace.json"))
    try ProbeIO.immutable(
      ProbeIO.encode(
        DocumentManifest(
          workspaceID: workspaceID, documentID: documentID, relativePath: "fixture.md",
          initialRevision: SnapshotID.hash(source))),
      at: transportRoot.appendingPathComponent("documents/\(documentID.uuidString).json"))
    try ProbeIO.immutable(source, at: sharedRoot.appendingPathComponent("fixture.md"))
    try join()
  }
  public func join() throws {
    try checkRoots()
    let manifest = try ProbeIO.read(
      transportRoot.appendingPathComponent("workspace.json"), limit: limits.manifestBytes)
    let w = try JSONDecoder().decode(WorkspaceManifest.self, from: manifest)
    guard w.schemaVersion == 1, w.workspaceID == workspaceID else {
      throw ProbeError.identityConflict
    }
    try ProbeIO.immutable(manifest, at: localRoot.appendingPathComponent("identity/workspace.json"))
    for sub in [
      "ready", "received/events", "received/snapshots", "received/documents", "conflicts",
    ] {
      try fm.createDirectory(
        at: localRoot.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    let report = try reconcile()
    guard report.status == .complete || report.status == .pending else {
      throw ProbeError.invalid("join \(report.status)")
    }
  }
  public func document() throws -> DocumentManifest {
    let (_, archive) = try load()
    guard archive.documents.count == 1, let document = archive.documents.values.first else {
      throw ProbeError.invalid("one disposable document required")
    }
    return document
  }
  public func enqueue(
    _ event: ProbeEvent, snapshots: [String: Data] = [:], fault: PreparationFault? = nil
  ) throws {
    try event.validate(limits: limits)
    let (report, archive) = try load()
    try permit(report)
    guard event.workspaceID == workspaceID, archive.documents[event.documentID] != nil else {
      throw ProbeError.invalid("unregistered identity")
    }
    let eventBytes = try ProbeIO.encode(event)
    _ = try ProbeIO.decodeEvent(eventBytes, limits: limits)
    for (hash, bytes) in snapshots { try ProbeIO.snapshot(bytes, hash: hash, limits: limits) }
    var projected = archive.bytes
    projected["events/\(event.id.uuidString).json"] = eventBytes
    for (h, b) in snapshots { projected["snapshots/\(h).bin"] = b }
    guard Set(archive.events.keys).union([event.id]).count <= limits.events,
      Set(archive.snapshots.keys).union(snapshots.keys).count <= limits.snapshots,
      Set(projected.values).reduce(0, { $0 + $1.count }) <= limits.totalBytes
    else { throw ProbeError.capacityExceeded }
    let ready = localRoot.appendingPathComponent("ready/\(event.id.uuidString)")
    if fm.fileExists(atPath: ready.path) {
      guard
        try ProbeIO.read(
          ready.appendingPathComponent("events/\(event.id.uuidString).json"),
          limit: limits.eventBytes) == eventBytes
      else { throw ProbeError.identityConflict }
      return
    }
    if let previous = archive.bytes["events/\(event.id.uuidString).json"], previous != eventBytes {
      throw ProbeError.identityConflict
    }
    let temp = localRoot.appendingPathComponent("preparing-\(UUID().uuidString).tmp")
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    try ProbeIO.immutable(
      eventBytes, at: temp.appendingPathComponent("events/\(event.id.uuidString).json"))
    for (hash, bytes) in snapshots {
      try ProbeIO.immutable(bytes, at: temp.appendingPathComponent("snapshots/\(hash).bin"))
    }
    if fault == .beforeReady { throw ProbeError.injectedInterruption }
    try fm.moveItem(at: temp, to: ready)
    if fault == .afterReady { throw ProbeError.injectedInterruption }
  }
  func permit(_ report: ReconciliationReport) throws {
    switch report.status {
    case .complete, .pending: return
    case .capacityExceeded: throw ProbeError.capacityExceeded
    case .identityConflict, .needsReconnection: throw ProbeError.identityConflict
    default: throw ProbeError.unavailable
    }
  }
  func files(_ root: URL, bound: Int) throws -> [URL] {
    guard fm.fileExists(atPath: root.path) else { return [] }
    guard
      let enumerator = fm.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
    else { throw ProbeError.unavailable }
    var values = [URL]()
    for case let file as URL in enumerator {
      if file.lastPathComponent.hasSuffix(".tmp") {
        enumerator.skipDescendants()
        continue
      }
      let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if attrs.isSymbolicLink == true { throw ProbeError.invalid("symlink candidate") }
      if attrs.isRegularFile == true {
        values.append(file)
        if values.count > bound { throw ProbeError.capacityExceeded }
      }
    }
    return values.sorted { $0.path < $1.path }
  }
  func load() throws -> (ReconciliationReport, ProbeArchive) {
    try checkRoots()
    var archive = ProbeArchive()
    var diagnostics = [String]()
    var diagnosticCount = 0
    var status = ProbeStatus.complete
    var conflictingIDs = Set<UUID>()
    func diagnose(_ message: String) {
      diagnosticCount += 1
      if diagnostics.count < limits.diagnostics { diagnostics.append(message) }
    }
    guard fm.fileExists(atPath: localRoot.appendingPathComponent("identity/workspace.json").path)
    else { return (ReconciliationReport(status: .unavailable), archive) }
    let sharedAvailable = fm.fileExists(
      atPath: transportRoot.appendingPathComponent("workspace.json").path)
    if !sharedAvailable {
      status = .unavailable
      diagnose("shared workspace unavailable; local retained evidence is stale")
    }
    var shared = [URL]()
    var local = [URL]()
    do {
      if sharedAvailable {
        do { shared = try files(transportRoot, bound: limits.candidates) } catch ProbeError
          .capacityExceeded
        { throw ProbeError.capacityExceeded } catch {
          status = .unavailable
          diagnose("shared scan unavailable; local retained evidence is stale")
        }
      }
      var budget = limits.candidates - shared.count
      for sub in ["received", "ready", "conflicts"] {
        let values = try files(localRoot.appendingPathComponent(sub), bound: budget)
        local += values
        budget -= values.count
      }
    } catch ProbeError.capacityExceeded {
      return (ReconciliationReport(status: .capacityExceeded), archive)
    } catch {
      return (
        ReconciliationReport(status: .unavailable, diagnostics: ["scan unavailable or unsafe"]),
        archive
      )
    }
    let expected = try ProbeIO.read(
      localRoot.appendingPathComponent("identity/workspace.json"), limit: limits.manifestBytes)
    archive.bytes["workspace.json"] = expected
    var rawVariants = Set<String>()
    var admittedBytes = 0
    var sourcePaths: [String: UUID] = [:]
    for file in shared + local {
      do {
        try ProbeIO.safe(file, root: shared.contains(file) ? sharedRoot : localRoot)
        let parent = file.deletingLastPathComponent().lastPathComponent
        let kind: String
        if parent == "events" || parent == "snapshots" || parent == "documents"
          || parent == "observed"
        {
          kind = parent
        } else if file.lastPathComponent.hasPrefix("workspace") {
          kind = "workspace"
        } else if parent == "conflicts" {
          kind = "conflicts"
        } else {
          continue
        }
        let limit =
          (kind == "snapshots" || kind == "observed")
          ? limits.snapshotBytes
          : kind == "events" || kind == "conflicts" ? limits.eventBytes : limits.manifestBytes
        let bytes = try ProbeIO.read(file, limit: limit)
        let fingerprint = SnapshotID.hash(bytes)
        if rawVariants.insert(fingerprint).inserted { admittedBytes += bytes.count }
        if admittedBytes > limits.totalBytes {
          return (ReconciliationReport(status: .capacityExceeded), archive)
        }
        if kind == "workspace" {
          let m = try JSONDecoder().decode(WorkspaceManifest.self, from: bytes)
          if m.schemaVersion != 1 || m.workspaceID != workspaceID || bytes != expected {
            status = .identityConflict
            diagnose("workspace identity conflict")
          }
          archive.bytes["workspace.json"] = expected
          continue
        }
        var key: String
        if kind == "events" || kind == "conflicts" {
          let e = try ProbeIO.decodeEvent(bytes, limits: limits)
          guard e.workspaceID == workspaceID else { throw ProbeError.invalid("event workspace") }
          key = "events/\(e.id.uuidString).json"
          if kind == "conflicts" {
            conflictingIDs.insert(e.id)
            status = .identityConflict
            continue
          }
          if let old = archive.bytes[key], old != bytes {
            conflictingIDs.insert(e.id)
            status = .identityConflict
            try ProbeIO.immutable(
              bytes, at: localRoot.appendingPathComponent("conflicts/\(fingerprint).json"))
            continue
          }
          archive.events[e.id] = e
        } else if kind == "snapshots" || kind == "observed" {
          let hash = file.deletingPathExtension().lastPathComponent
          try ProbeIO.snapshot(bytes, hash: hash, limits: limits)
          key = "\(kind)/\(hash).bin"
          archive.snapshots[hash] = bytes
        } else {
          let m = try JSONDecoder().decode(DocumentManifest.self, from: bytes)
          guard m.schemaVersion == 1, m.workspaceID == workspaceID,
            ProbeIO.validHash(m.initialRevision), !m.relativePath.hasPrefix("/"),
            !m.relativePath.split(separator: "/").contains("..")
          else { throw ProbeError.invalid("document manifest") }
          try ProbeIO.safe(sharedRoot.appendingPathComponent(m.relativePath), root: sharedRoot)
          key = "documents/\(m.documentID.uuidString).json"
          if let old = archive.bytes[key], old != bytes {
            status = .identityConflict
            diagnose("document identity conflict")
            continue
          }
          if let existing = sourcePaths[m.relativePath], existing != m.documentID {
            status = .needsReconnection
            diagnose("copied document registration")
          }
          sourcePaths[m.relativePath] = m.documentID
          archive.documents[m.documentID] = m
          if !fm.fileExists(atPath: sharedRoot.appendingPathComponent(m.relativePath).path) {
            status = .needsReconnection
            diagnose("registered source missing or renamed")
          }
        }
        archive.bytes[key] = bytes
        if shared.contains(file) {
          try ProbeIO.immutable(bytes, at: localRoot.appendingPathComponent("received/" + key))
        }
        if archive.events.count > limits.events || archive.snapshots.count > limits.snapshots {
          return (ReconciliationReport(status: .capacityExceeded), archive)
        }
      } catch ProbeError.identityConflict {
        status = .identityConflict
        diagnose("immutable identity conflict")
      } catch { diagnose("invalid/unavailable \(file.lastPathComponent)") }
    }
    for (id, e) in archive.events where archive.documents[e.documentID] == nil {
      archive.events.removeValue(forKey: id)
      diagnose("unregistered document event")
    }
    for id in conflictingIDs { archive.events.removeValue(forKey: id) }
    let state = ProbeReducer.reduce(
      events: Array(archive.events.values), snapshots: archive.snapshots)
    if status == .complete && !state.pendingEventIDs.isEmpty { status = .pending }
    for id in state.invalidIDs { diagnose("invalid causal event \(id.uuidString)") }
    return (
      ReconciliationReport(
        status: status, state: state, diagnostics: diagnostics, diagnosticCount: diagnosticCount),
      archive
    )
  }
  public func reconcile() throws -> ReconciliationReport { try load().0 }
  @discardableResult public func publishOutbox(only: String? = nil, stopAfter: Int? = nil) throws
    -> PublishReport
  {
    guard only == nil || only == "events" || only == "snapshots", stopAfter == nil || stopAfter! > 0
    else { throw ProbeError.invalid("publish controls") }
    try permit(reconcile())
    let ready = try files(localRoot.appendingPathComponent("ready"), bound: limits.candidates)
    var count = 0
    for file in ready {
      let kind = file.deletingLastPathComponent().lastPathComponent
      guard kind == "events" || kind == "snapshots", only == nil || kind == only else { continue }
      let limit = kind == "events" ? limits.eventBytes : limits.snapshotBytes
      let bytes = try ProbeIO.read(file, limit: limit)
      let target = transportRoot.appendingPathComponent(kind + "/" + file.lastPathComponent)
      try ProbeIO.safe(target, root: sharedRoot)
      do { try ProbeIO.immutable(bytes, at: target) } catch {
        try ProbeIO.immutable(
          bytes, at: localRoot.appendingPathComponent("conflicts/\(SnapshotID.hash(bytes)).json"))
        throw error
      }
      count += 1
      if count == stopAfter {
        return PublishReport(status: .injectedInterruption, materialized: count)
      }
    }
    return PublishReport(status: only == nil ? .complete : .pending, materialized: count)
  }
  public func exportEvidence(to output: URL) throws {
    try checkRoots()
    let target = output.standardizedFileURL.resolvingSymlinksInPath().path
    for root in [localRoot, sharedRoot] {
      let path = root.standardizedFileURL.resolvingSymlinksInPath().path
      guard target != path, !target.hasPrefix(path + "/") else {
        throw ProbeError.invalid("separate export directory required")
      }
    }
    if fm.fileExists(atPath: output.path),
      !(try fm.contentsOfDirectory(atPath: output.path)).isEmpty
    {
      throw ProbeError.invalid("export must be empty")
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let (report, archive) = try load()
    var remaining = limits.totalBytes
    var count = 0
    var truncated = false
    var exportedFingerprints = Set<String>()
    for (key, bytes) in archive.bytes.sorted(by: { $0.key < $1.key }) {
      guard count < limits.candidates, bytes.count <= remaining else {
        truncated = true
        break
      }
      try ProbeIO.immutable(bytes, at: output.appendingPathComponent("artifacts/" + key))
      count += 1
      remaining -= bytes.count
      exportedFingerprints.insert(SnapshotID.hash(bytes))
    }
    // Preserve raw rejected/conflicting inputs too. An incomplete bounded export explicitly says so.
    for root in [transportRoot, localRoot.appendingPathComponent("conflicts")] {
      let candidates: [URL]
      do { candidates = try files(root, bound: limits.candidates) } catch {
        truncated = true
        continue
      }
      for file in candidates {
        do {
          try ProbeIO.safe(file, root: root)
          let bytes = try ProbeIO.read(file, limit: limits.snapshotBytes)
          let fingerprint = SnapshotID.hash(bytes)
          if exportedFingerprints.contains(fingerprint) { continue }
          guard count < limits.candidates, bytes.count <= remaining else {
            truncated = true
            continue
          }
          let suffix = file.pathExtension.isEmpty ? "bin" : file.pathExtension
          try ProbeIO.immutable(
            bytes, at: output.appendingPathComponent("raw/\(fingerprint).\(suffix)"))
          exportedFingerprints.insert(fingerprint)
          count += 1
          remaining -= bytes.count
        } catch { truncated = true }
      }
    }
    if report.status == .capacityExceeded || report.status == .unavailable { truncated = true }
    struct Evidence: Codable {
      var schemaVersion = 1
      let workspaceID: UUID
      let machineID: String
      let runID: UUID
      let timestamp: Date
      let monotonicDurationNanoseconds: UInt64
      let limits: ProbeLimits
      let report: ReconciliationReport
      let eventIDs: [UUID]
      let snapshotHashes: [String]
      let participants: [String]
      let devices: [String]
      let guarantee: String
      let exportedFiles: Int
      let exportedBytes: Int
      let exportTruncated: Bool
    }
    let evidence = Evidence(
      workspaceID: workspaceID, machineID: ProcessInfo.processInfo.hostName, runID: UUID(),
      timestamp: Date(), monotonicDurationNanoseconds: DispatchTime.now().uptimeNanoseconds - start,
      limits: limits, report: report, eventIDs: sortedIDs(archive.events.keys),
      snapshotHashes: archive.snapshots.keys.sorted(),
      participants: Set(archive.events.values.map { $0.participantID.uuidString }).sorted(),
      devices: Set(archive.events.values.map { $0.deviceID.uuidString }).sorted(),
      guarantee: "local evidence; remote delivery and power-loss durability unverified",
      exportedFiles: count, exportedBytes: limits.totalBytes - remaining, exportTruncated: truncated
    )
    try ProbeIO.immutable(
      ProbeIO.encode(evidence), at: output.appendingPathComponent("ledger.json"))
  }
}
