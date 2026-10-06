import Foundation

public enum CollaborationStatus: String, Codable {
  case complete, pending, identityConflict, capacityExceeded, unavailable, needsReconnection,
    injectedInterruption
}
public struct CollaborationReport: Codable, Equatable {
  public var status: CollaborationStatus, state: CollaborationState?, diagnostics: [String], diagnosticCount: Int
  public var blockingEventIDsByDocument: [UUID:[UUID]] { state?.blockingEventIDsByDocument ?? [:] }
  public var coverageComplete: Bool { status == .complete || status == .pending }
  public init(
    status: CollaborationStatus = .complete, state: CollaborationState? = nil, diagnostics: [String] = [],
    diagnosticCount: Int = 0
  ) {
    self.status = status
    self.state = state
    self.diagnostics = diagnostics
    self.diagnosticCount = diagnosticCount
  }
}
public struct CollaborationPublishReport: Codable {
  public var status: CollaborationStatus
  public var materialized: Int
  public var guarantee = "local shared-folder materialization only"
}
public enum CollaborationPreparationFault { case beforeReady, afterReady }
public struct CollaborationArchive {
  var events: [UUID: CollaborationEvent] = [:]
  var snapshots: [String: Data] = [:]
  var bytes: [String: Data] = [:]
  var documents: [UUID: CollaborationDocumentManifest] = [:]
}
public final class CollaborationReplicaStore {
  public let localRoot, sharedRoot: URL
  public let workspaceID: UUID
  public let limits: CollaborationLimits
  let fm = FileManager.default
  public var transportRoot: URL { sharedRoot.appendingPathComponent("Folio Review") }
  public init(localRoot: URL, sharedRoot: URL, workspaceID: UUID, limits: CollaborationLimits = .pilot) {
    self.localRoot = localRoot
    self.sharedRoot = sharedRoot
    self.workspaceID = workspaceID
    self.limits = limits
  }
  func checkRoots() throws {
    let a = localRoot.standardizedFileURL.resolvingSymlinksInPath().path
    let b = sharedRoot.standardizedFileURL.resolvingSymlinksInPath().path
    guard a != b, !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else {
      throw CollaborationError.invalid("roots must be distinct and separate")
    }
    let localIdentity=try directoryIdentity(at:localRoot)
    let sharedIdentity=try directoryIdentity(at:sharedRoot)
    if let sharedIdentity=sharedIdentity, try ancestorIdentities(of:localRoot).contains(sharedIdentity) {
      throw CollaborationError.invalid("replica storage physically overlaps shared folder")
    }
    if let localIdentity=localIdentity, try ancestorIdentities(of:sharedRoot).contains(localIdentity) {
      throw CollaborationError.invalid("shared folder physically overlaps replica storage")
    }
    try CollaborationIO.safe(localRoot, root: localRoot)
    try CollaborationIO.safe(sharedRoot, root: sharedRoot)
  }
  private struct DirectoryIdentity: Hashable {
    let device:dev_t
    let inode:ino_t
    let birthSeconds:Int64
    let birthNanoseconds:Int64
  }
  private func directoryIdentity(at url:URL) throws -> DirectoryIdentity? {
    var value=stat()
    let result=url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path=path else { return -1 }
      return Darwin.fstatat(AT_FDCWD,path,&value,0)
    }
    if result != 0 {
      let failure=errno
      if failure == ENOENT { return nil }
      throw NSError(domain:NSPOSIXErrorDomain,code:Int(failure))
    }
    guard (value.st_mode & S_IFMT) == S_IFDIR else { throw CollaborationError.unavailable }
    return DirectoryIdentity(device:value.st_dev,inode:value.st_ino,
      birthSeconds:Int64(value.st_birthtimespec.tv_sec),birthNanoseconds:Int64(value.st_birthtimespec.tv_nsec))
  }
  private func ancestorIdentities(of url:URL) throws -> Set<DirectoryIdentity> {
    var current=url.standardizedFileURL,result=Set<DirectoryIdentity>()
    while true {
      if let identity=try directoryIdentity(at:current) { result.insert(identity) }
      if current.path == "/" { return result }
      let parent=current.deletingLastPathComponent()
      if parent.path == current.path { return result }
      current=parent
    }
  }
  public func createWorkspace() throws {
    try checkRoots()
    guard !fm.fileExists(atPath: transportRoot.path) else { throw CollaborationError.identityConflict }
    try fm.createDirectory(at:sharedRoot,withIntermediateDirectories:true)
    try CollaborationIO.immutable(CollaborationIO.encode(CollaborationWorkspaceManifest(workspaceID:workspaceID)), at:transportRoot.appendingPathComponent("workspace.json"))
    try join()
  }
  public func registerDocument(relativePath:String, initialBytes:Data) throws -> SharedDocumentRef {
    guard CollaborationIO.validRelativePath(relativePath) else { throw CollaborationError.invalid("document path") }
    let source=sharedRoot.appendingPathComponent(relativePath)
    try CollaborationIO.safe(source,root:sharedRoot)
    guard try CollaborationIO.read(source,limit:limits.snapshotBytes) == initialBytes else { throw CollaborationError.invalid("initial bytes differ") }
    let (report,archive)=try load(); try permit(report)
    guard archive.documents.count < limits.documents else { throw CollaborationError.capacityExceeded }
    guard !archive.documents.values.contains(where: { $0.relativePath == relativePath || sameSource(source,sharedRoot.appendingPathComponent((try? bindings()[$0.documentID]) ?? $0.relativePath)) }),
      !(try bindings()).values.contains(relativePath) else { throw CollaborationError.identityConflict }
    let id=UUID(), manifest=CollaborationDocumentManifest(workspaceID:workspaceID,documentID:id,relativePath:relativePath,initialRevision:CollaborationSnapshotID.hash(initialBytes))
    try CollaborationIO.immutable(CollaborationIO.encode(manifest),at:transportRoot.appendingPathComponent("documents/\(id.uuidString).json"))
    _ = try reconcile()
    return try reconnectDocument(id:id,relativePath:relativePath)
  }
  func bindings() throws -> [UUID:String] {
    let path=localRoot.appendingPathComponent("bindings.json")
    guard fm.fileExists(atPath:path.path) else { return [:] }
    try CollaborationIO.safe(path,root:localRoot)
    let bytes=try CollaborationIO.read(path,limit:limits.manifestBytes)
    let result=try JSONDecoder().decode([UUID:String].self,from:bytes)
    guard result.count <= limits.documents, result.values.allSatisfy(CollaborationIO.validRelativePath), Set(result.values).count == result.count else { throw CollaborationError.identityConflict }
    return result
  }
  public func reconnectDocument(id:UUID, relativePath:String) throws -> SharedDocumentRef {
    guard CollaborationIO.validRelativePath(relativePath) else { throw CollaborationError.invalid("binding path") }
    let source=sharedRoot.appendingPathComponent(relativePath);try CollaborationIO.safe(source,root:sharedRoot)
    guard fm.fileExists(atPath:source.path), (try load().1.documents[id]) != nil else { throw CollaborationError.unavailable }
    var current=try bindings()
    let documents=try load().1.documents
    guard !documents.values.contains(where: { $0.documentID != id && ((current[$0.documentID] ?? $0.relativePath) == relativePath || sameSource(source,sharedRoot.appendingPathComponent(current[$0.documentID] ?? $0.relativePath))) }) else { throw CollaborationError.identityConflict }
    current[id]=relativePath
    try CollaborationIO.durable(CollaborationIO.encode(current),at:localRoot.appendingPathComponent("bindings.json"))
    return SharedDocumentRef(workspaceID:workspaceID,documentID:id,relativePath:relativePath)
  }
  public func document(id:UUID) throws -> SharedDocumentRef {
    guard let manifest=try load().1.documents[id] else { throw CollaborationError.invalid("unregistered document") }
    let path=try bindings()[id] ?? manifest.relativePath
    guard CollaborationIO.validRelativePath(path) else { throw CollaborationError.invalid("binding path") }
    try CollaborationIO.safe(sharedRoot.appendingPathComponent(path),root:sharedRoot)
    return SharedDocumentRef(workspaceID:workspaceID,documentID:id,relativePath:path)
  }
  func fileIdentity(_ url:URL) -> String? {
    guard let attrs=try? fm.attributesOfItem(atPath:url.path), attrs[.type] as? FileAttributeType == .typeRegular,
      let device=attrs[.systemNumber] as? NSNumber,let inode=attrs[.systemFileNumber] as? NSNumber else { return nil }
    return device.stringValue+":"+inode.stringValue
  }
  func sameSource(_ a:URL,_ b:URL) -> Bool {
    guard let identity=fileIdentity(a) else { return false };return identity == fileIdentity(b)
  }
  public func sourceURL(document:SharedDocumentRef) throws -> URL {
    guard document.workspaceID == workspaceID, try self.document(id:document.documentID) == document else { throw CollaborationError.invalid("stale document binding") }
    let url=sharedRoot.appendingPathComponent(document.relativePath);try CollaborationIO.safe(url,root:sharedRoot)
    guard fileIdentity(url) != nil else { throw CollaborationError.unavailable };return url
  }
  public func join() throws {
    try checkRoots()
    let manifest = try CollaborationIO.read(
      transportRoot.appendingPathComponent("workspace.json"), limit: limits.manifestBytes)
    let w = try CollaborationIO.decodeWorkspace(manifest,limits:limits)
    guard w.schemaVersion == 2, w.workspaceID == workspaceID else {
      throw CollaborationError.identityConflict
    }
    try CollaborationIO.immutable(manifest, at: localRoot.appendingPathComponent("identity/workspace.json"))
    for sub in [
      "ready", "received/events", "received/snapshots", "received/documents", "conflicts",
    ] {
      try fm.createDirectory(
        at: localRoot.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    let report = try reconcile()
    guard report.status == .complete || report.status == .pending else {
      throw CollaborationError.invalid("join \(report.status)")
    }
  }
  public func enqueue(
    _ event: CollaborationEvent, snapshots: [String: Data] = [:], fault: CollaborationPreparationFault? = nil
  ) throws {
    try event.validate(limits: limits)
    let (report, archive) = try load()
    try permit(report)
    guard event.workspaceID == workspaceID, archive.documents[event.documentID] != nil else {
      throw CollaborationError.invalid("unregistered identity")
    }
    let eventBytes = try CollaborationIO.encode(event)
    _ = try CollaborationIO.decodeEvent(eventBytes, limits: limits)
    for (hash, bytes) in snapshots { try CollaborationIO.snapshot(bytes, hash: hash, limits: limits) }
    var projected = archive.bytes
    projected["events/\(event.id.uuidString).json"] = eventBytes
    for (h, b) in snapshots { projected["snapshots/\(h).bin"] = b }
    guard Set(archive.events.keys).union([event.id]).count <= limits.events,
      Set(archive.snapshots.keys).union(snapshots.keys).count <= limits.snapshots,
      Set(projected.values).reduce(0, { $0 + $1.count }) <= limits.totalBytes
    else { throw CollaborationError.capacityExceeded }
    let addedCandidates = 4 + snapshots.count
    guard try candidateCount() + addedCandidates <= limits.candidates else { throw CollaborationError.capacityExceeded }
    let ready = localRoot.appendingPathComponent("ready/\(event.id.uuidString)")
    if fm.fileExists(atPath: ready.path) {
      guard
        try CollaborationIO.read(
          ready.appendingPathComponent("events/\(event.id.uuidString).json"),
          limit: limits.eventBytes) == eventBytes
      else { throw CollaborationError.identityConflict }
      return
    }
    if let previous = archive.bytes["events/\(event.id.uuidString).json"], previous != eventBytes {
      throw CollaborationError.identityConflict
    }
    let temp = localRoot.appendingPathComponent("preparing-\(UUID().uuidString).tmp")
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at:temp) }
    try CollaborationIO.immutable(
      eventBytes, at: temp.appendingPathComponent("events/\(event.id.uuidString).json"))
    for (hash, bytes) in snapshots {
      try CollaborationIO.immutable(bytes, at: temp.appendingPathComponent("snapshots/\(hash).bin"))
    }
    if fault == .beforeReady { throw CollaborationError.injectedInterruption }
    try fm.moveItem(at: temp, to: ready)
    if fault == .afterReady { throw CollaborationError.injectedInterruption }
  }
  func permit(_ report: CollaborationReport) throws {
    switch report.status {
    case .complete, .pending: return
    case .capacityExceeded: throw CollaborationError.capacityExceeded
    case .identityConflict, .needsReconnection: throw CollaborationError.identityConflict
    default: throw CollaborationError.unavailable
    }
  }
  func files(_ root: URL, bound: Int) throws -> [URL] {
    var examined=0
    return try files(root,bound:bound,examined:&examined)
  }
  func files(_ root:URL, bound:Int, examined:inout Int) throws -> [URL] {
    guard fm.fileExists(atPath:root.path) else { return [] }
    var enumerationError:Error?
    guard let enumerator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[],errorHandler:{ _,error in enumerationError=error;return false }) else { throw CollaborationError.unavailable }
    var values=[URL]()
    for case let file as URL in enumerator {
      examined += 1
      if examined > bound { throw CollaborationError.capacityExceeded }
      if file.lastPathComponent.hasSuffix(".tmp") { enumerator.skipDescendants();continue }
      let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
      if attrs.isSymbolicLink == true { throw CollaborationError.invalid("symlink candidate") }
      if attrs.isRegularFile == true { values.append(file) }
    }
    if enumerationError != nil { throw CollaborationError.unavailable }
    return values.sorted { $0.path < $1.path }
  }
  func candidateCount() throws -> Int {
    var examined=0
    for root in [transportRoot,localRoot.appendingPathComponent("received"),localRoot.appendingPathComponent("ready"),localRoot.appendingPathComponent("conflicts")] {
      _ = try files(root,bound:limits.candidates,examined:&examined)
    }
    return examined
  }
  func load() throws -> (CollaborationReport, CollaborationArchive) {
    try checkRoots()
    var archive = CollaborationArchive()
    var diagnostics = [String]()
    var diagnosticCount = 0
    var status = CollaborationStatus.complete
    var conflictingIDs = Set<UUID>()
    func diagnose(_ message: String) {
      diagnosticCount += 1
      if diagnostics.count < limits.diagnostics { diagnostics.append(message) }
    }
    guard fm.fileExists(atPath: localRoot.appendingPathComponent("identity/workspace.json").path)
    else { return (CollaborationReport(status: .unavailable), archive) }
    let sharedAvailable = fm.fileExists(
      atPath: transportRoot.appendingPathComponent("workspace.json").path)
    if !sharedAvailable {
      status = .unavailable
      diagnose("shared workspace unavailable; local retained evidence is stale")
    }
    var shared = [URL]()
    var local = [URL]()
    var examined=0
    do {
      if sharedAvailable {
        do { shared = try files(transportRoot, bound: limits.candidates,examined:&examined) } catch CollaborationError
          .capacityExceeded
        { throw CollaborationError.capacityExceeded } catch {
          status = .unavailable
          diagnose("shared scan unavailable; local retained evidence is stale")
        }
      }
      for sub in ["received", "ready", "conflicts"] {
        local += try files(localRoot.appendingPathComponent(sub),bound:limits.candidates,examined:&examined)
      }
    } catch CollaborationError.capacityExceeded {
      return (CollaborationReport(status: .capacityExceeded), archive)
    } catch {
      return (
        CollaborationReport(status: .unavailable, diagnostics: ["scan unavailable or unsafe"]),
        archive
      )
    }
    let expected = try CollaborationIO.read(
      localRoot.appendingPathComponent("identity/workspace.json"), limit: limits.manifestBytes)
    archive.bytes["workspace.json"] = expected
    var rawVariants = Set<String>()
    var eventVariants:[UUID:Set<String>] = [:]
    var rejectedEventIDs=Set<UUID>()
    var admittedBytes = 0
    var sourcePaths: [String: UUID] = [:]
    var sourceIdentities:[String:UUID] = [:]
    var currentBindings:[UUID:String] = [:]
    do { currentBindings=try bindings() } catch { status = .identityConflict; diagnose("local document binding corrupt or unavailable") }
    for file in shared + local {
      do {
        try CollaborationIO.safe(file, root: shared.contains(file) ? sharedRoot : localRoot)
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
        let bytes = try CollaborationIO.read(file, limit: limit)
        let fingerprint = CollaborationSnapshotID.hash(bytes)
        if rawVariants.insert(fingerprint).inserted { admittedBytes += bytes.count }
        if admittedBytes > limits.totalBytes {
          return (CollaborationReport(status: .capacityExceeded), archive)
        }
        if kind == "workspace" {
          let m = try CollaborationIO.decodeWorkspace(bytes,limits:limits)
          if m.schemaVersion != 2 || m.workspaceID != workspaceID || bytes != expected {
            status = .identityConflict
            diagnose("workspace identity conflict")
          }
          archive.bytes["workspace.json"] = expected
          continue
        }
        var key: String
        if kind == "events" || kind == "conflicts" {
          let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any]
          let rawID=(object?["id"] as? String).flatMap { value -> UUID? in guard let id=UUID(uuidString:value),id.uuidString == value else { return nil };return id }
          if let id=rawID {
            eventVariants[id,default:[]].insert(fingerprint)
            if eventVariants[id]!.count > 1 || kind == "conflicts" {
              conflictingIDs.insert(id);status = .identityConflict
              try CollaborationIO.immutable(bytes,at:localRoot.appendingPathComponent("conflicts/\(fingerprint).json"))
            }
          }
          let e:CollaborationEvent
          do { e=try CollaborationIO.decodeEvent(bytes,limits:limits) }
          catch { if let id=rawID { rejectedEventIDs.insert(id) };throw error }
          guard e.workspaceID == workspaceID else { throw CollaborationError.invalid("event workspace") }
          key = "events/\(e.id.uuidString).json"
          if kind == "conflicts" {
            conflictingIDs.insert(e.id)
            status = .identityConflict
            continue
          }
          if let old = archive.bytes[key], old != bytes {
            conflictingIDs.insert(e.id)
            status = .identityConflict
            try CollaborationIO.immutable(
              bytes, at: localRoot.appendingPathComponent("conflicts/\(fingerprint).json"))
            continue
          }
          archive.events[e.id] = e
        } else if kind == "snapshots" || kind == "observed" {
          let hash = file.deletingPathExtension().lastPathComponent
          try CollaborationIO.snapshot(bytes, hash: hash, limits: limits)
          key = "\(kind)/\(hash).bin"
          archive.snapshots[hash] = bytes
        } else {
          let m = try CollaborationIO.decodeDocument(bytes,limits:limits)
          guard m.schemaVersion == 2, m.workspaceID == workspaceID,
            CollaborationIO.validHash(m.initialRevision), CollaborationIO.validRelativePath(m.relativePath)
          else { throw CollaborationError.invalid("document manifest") }
          try CollaborationIO.safe(sharedRoot.appendingPathComponent(currentBindings[m.documentID] ?? m.relativePath), root: sharedRoot)
          key = "documents/\(m.documentID.uuidString).json"
          if let old = archive.bytes[key], old != bytes {
            status = .identityConflict
            diagnose("document identity conflict")
            continue
          }
          let boundPath=currentBindings[m.documentID] ?? m.relativePath
          if let existing = sourcePaths[boundPath], existing != m.documentID {
            status = .needsReconnection
            diagnose("copied document registration")
          }
          sourcePaths[boundPath] = m.documentID
          if let identity=fileIdentity(sharedRoot.appendingPathComponent(boundPath)) {
            if let old=sourceIdentities[identity],old != m.documentID { status = .needsReconnection;diagnose("registered paths alias the same source") }
            sourceIdentities[identity]=m.documentID
          }
          archive.documents[m.documentID] = m
          if !fm.fileExists(atPath: sharedRoot.appendingPathComponent(currentBindings[m.documentID] ?? m.relativePath).path) {
            status = .needsReconnection
            diagnose("registered source missing or renamed")
          }
        }
        archive.bytes[key] = bytes
        if shared.contains(file) {
          try CollaborationIO.immutable(bytes, at: localRoot.appendingPathComponent("received/" + key))
        }
        if archive.events.count > limits.events || archive.snapshots.count > limits.snapshots || archive.documents.count > limits.documents {
          return (CollaborationReport(status: .capacityExceeded), archive)
        }
      } catch CollaborationError.identityConflict {
        status = .identityConflict
        diagnose("immutable identity conflict")
      } catch let error as CollaborationError {
        if file.lastPathComponent.hasPrefix("workspace") { status = .identityConflict }
        if error == .capacityExceeded { return (CollaborationReport(status:.capacityExceeded),archive) }
        diagnose("invalid \(file.lastPathComponent)")
      } catch {
        if file.lastPathComponent.hasPrefix("workspace") { status = .identityConflict; diagnose("workspace identity unreadable or malformed");continue }
        if error is DecodingError { diagnose("invalid \(file.lastPathComponent)") }
        else if (error as NSError).domain == NSCocoaErrorDomain { status = .unavailable; diagnose("unavailable \(file.lastPathComponent)") }
        else { diagnose("invalid \(file.lastPathComponent)") }
      }
    }
    for (id, e) in archive.events where archive.documents[e.documentID] == nil {
      diagnose("unregistered document event \(id.uuidString)")
    }
    for id in conflictingIDs { archive.events.removeValue(forKey: id) }
    let unregistered=archive.events.values.filter { archive.documents[$0.documentID] == nil }
    var state = CollaborationReducer.reduce(
      events: archive.events.values.filter { archive.documents[$0.documentID] != nil }, snapshots: archive.snapshots)
    state.pendingEventIDs=collaborationSortedIDs(Set(state.pendingEventIDs).union(unregistered.map(\.id)))
    for e in unregistered where e.isSource { state.blockingEventIDsByDocument[e.documentID,default:[]].append(e.id) }
    state.invalidIDs = collaborationSortedIDs(Set(state.invalidIDs).union(conflictingIDs).union(rejectedEventIDs))
    if status == .complete && !state.pendingEventIDs.isEmpty { status = .pending }
    for id in state.invalidIDs { diagnose("invalid causal event \(id.uuidString)") }
    return (
      CollaborationReport(
        status: status, state: status == .capacityExceeded || status == .unavailable ? nil : state, diagnostics: diagnostics, diagnosticCount: diagnosticCount),
      archive
    )
  }
  public func reconcile() throws -> CollaborationReport { try load().0 }
  public func events() throws -> [CollaborationEvent] {
    let (report,archive)=try load();try permit(report)
    return archive.events.values.sorted { $0.id.uuidString < $1.id.uuidString }
  }
  public func snapshots() throws -> [String:Data] { let (report,archive)=try load();try permit(report);return archive.snapshots }
  @discardableResult public func publishOutbox(only: String? = nil, stopAfter: Int? = nil) throws
    -> CollaborationPublishReport
  {
    guard only == nil || only == "events" || only == "snapshots", stopAfter == nil || stopAfter! > 0
    else { throw CollaborationError.invalid("publish controls") }
    try permit(reconcile())
    let ready = try files(localRoot.appendingPathComponent("ready"), bound: limits.candidates)
    var count = 0
    for file in ready {
      let kind = file.deletingLastPathComponent().lastPathComponent
      guard kind == "events" || kind == "snapshots", only == nil || kind == only else { continue }
      let limit = kind == "events" ? limits.eventBytes : limits.snapshotBytes
      let bytes = try CollaborationIO.read(file, limit: limit)
      let target = transportRoot.appendingPathComponent(kind + "/" + file.lastPathComponent)
      try CollaborationIO.safe(target, root: sharedRoot)
      do { try CollaborationIO.immutable(bytes, at: target) } catch {
        try CollaborationIO.immutable(
          bytes, at: localRoot.appendingPathComponent("conflicts/\(CollaborationSnapshotID.hash(bytes)).json"))
        throw error
      }
      count += 1
      if count == stopAfter {
        return CollaborationPublishReport(status: .injectedInterruption, materialized: count)
      }
    }
    return CollaborationPublishReport(status: only == nil ? .complete : .pending, materialized: count)
  }
  public func exportEvidence(to output: URL) throws {
    try checkRoots()
    let target = output.standardizedFileURL.resolvingSymlinksInPath().path
    for root in [localRoot, sharedRoot] {
      let path = root.standardizedFileURL.resolvingSymlinksInPath().path
      guard target != path, !target.hasPrefix(path + "/") else {
        throw CollaborationError.invalid("separate export directory required")
      }
    }
    if fm.fileExists(atPath: output.path),
      !(try fm.contentsOfDirectory(atPath: output.path)).isEmpty
    {
      throw CollaborationError.invalid("export must be empty")
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
      try CollaborationIO.immutable(bytes, at: output.appendingPathComponent("artifacts/" + key))
      count += 1
      remaining -= bytes.count
      exportedFingerprints.insert(CollaborationSnapshotID.hash(bytes))
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
          try CollaborationIO.safe(file, root: root)
          let bytes = try CollaborationIO.read(file, limit: limits.snapshotBytes)
          let fingerprint = CollaborationSnapshotID.hash(bytes)
          if exportedFingerprints.contains(fingerprint) { continue }
          guard count < limits.candidates, bytes.count <= remaining else {
            truncated = true
            continue
          }
          let suffix = file.pathExtension.isEmpty ? "bin" : file.pathExtension
          try CollaborationIO.immutable(
            bytes, at: output.appendingPathComponent("raw/\(fingerprint).\(suffix)"))
          exportedFingerprints.insert(fingerprint)
          count += 1
          remaining -= bytes.count
        } catch { truncated = true }
      }
    }
    if report.status == .capacityExceeded || report.status == .unavailable { truncated = true }
    struct Evidence: Codable {
      var schemaVersion = 2
      let workspaceID: UUID
      let machineID: String
      let runID: UUID
      let timestamp: Date
      let monotonicDurationNanoseconds: UInt64
      let limits: CollaborationLimits
      let report: CollaborationReport
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
      limits: limits, report: report, eventIDs: collaborationSortedIDs(archive.events.keys),
      snapshotHashes: archive.snapshots.keys.sorted(),
      participants: Set(archive.events.values.map { $0.participantID.uuidString }).sorted(),
      devices: Set(archive.events.values.map { $0.deviceID.uuidString }).sorted(),
      guarantee: "local evidence; remote delivery and power-loss durability unverified",
      exportedFiles: count, exportedBytes: limits.totalBytes - remaining, exportTruncated: truncated
    )
    try CollaborationIO.immutable(
      CollaborationIO.encode(evidence), at: output.appendingPathComponent("ledger.json"))
  }
}
