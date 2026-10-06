import Foundation
import TransportProbe

struct Actor: Codable { let participantID, deviceID: UUID }
struct Output: Codable {
  var schemaVersion = 1
  var command: String
  var status: String
  var guarantee = "local probe only; OneDrive receipt is unverified"
  var workspaceID: UUID?, proposalID: UUID?, eventIDs: [UUID]?,
    reconciliation: ReconciliationReport?, publication: PublishReport?, recovery: RecoveryExport?,
    error: String?
  var machineID = ProcessInfo.processInfo.hostName, runID = UUID(), timestamp = Date(),
    monotonicDurationNanoseconds: UInt64 = 0
}
func uuid(_ value: String) throws -> UUID {
  guard let id = UUID(uuidString: value), id.uuidString == value else {
    throw ProbeError.invalid("canonical UUID required")
  }
  return id
}
func seededID(_ value: String) throws -> UUID {
  let hash = SnapshotID.hash(Data(value.utf8))
  let chars = Array(hash.prefix(32))
  return try uuid(
    [
      String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]),
      String(chars[20..<32]),
    ].joined(separator: "-").uppercased())
}
let start = DispatchTime.now().uptimeNanoseconds
var output = Output(command: CommandLine.arguments.dropFirst().first ?? "", status: "invalid")
var exitCode: Int32 = 2
func required(_ options: [String: String], _ name: String) throws -> String {
  guard let value = options[name], !value.isEmpty else {
    throw ProbeError.invalid("missing --\(name)")
  }
  return value
}
func path(_ options: [String: String], _ key: String) throws -> URL {
  URL(fileURLWithPath: try required(options, key)).standardizedFileURL
}
do {
  let command = output.command
  let allowed: [String: [String]] = [
    "init": ["workspace-id", "document-id"], "join": ["workspace-id"],
    "generate": ["participant-id", "device-id", "count", "seed"],
    "prepare-source": ["base", "proposed"], "apply-source": ["proposal-id"],
    "publish": ["only", "stop-after"], "scan": [], "recover": ["proposal-id", "output"],
    "export": ["output"],
  ]
  guard let commandKeys = allowed[command] else { throw ProbeError.invalid("unknown command") }
  let keys = Set(commandKeys + ["local-root", "shared-root"])
  var options: [String: String] = [:]
  let args = Array(CommandLine.arguments.dropFirst(2))
  guard args.count % 2 == 0 else { throw ProbeError.invalid("options require values") }
  for i in stride(from: 0, to: args.count, by: 2) {
    let key = String(args[i].dropFirst(2))
    guard args[i].hasPrefix("--"), keys.contains(key), options[key] == nil else {
      throw ProbeError.invalid("unknown/duplicate option")
    }
    options[key] = args[i + 1]
  }
  let local = try path(options, "local-root")
  let shared = try path(options, "shared-root")
  let workspace: UUID
  if command == "init" || command == "join" {
    workspace = try uuid(required(options, "workspace-id"))
  } else {
    let m = try JSONDecoder().decode(
      WorkspaceManifest.self,
      from: ProbeIO.read(
        local.appendingPathComponent("identity/workspace.json"),
        limit: ProbeLimits.pilot.manifestBytes))
    guard m.schemaVersion == 1 else { throw ProbeError.invalid("schema") }
    workspace = m.workspaceID
  }
  output.workspaceID = workspace
  let store = ReplicaStore(localRoot: local, sharedRoot: shared, workspaceID: workspace)
  let actorPath = local.appendingPathComponent("actor.json")
  func actor() throws -> Actor {
    try JSONDecoder().decode(Actor.self, from: ProbeIO.read(actorPath, limit: 1024))
  }
  switch command {
  case "init":
    try store.initialize(documentID: uuid(required(options, "document-id")))
    try ProbeIO.immutable(
      ProbeIO.encode(Actor(participantID: UUID(), deviceID: UUID())), at: actorPath)
    output.status = "complete"
  case "join":
    if FileManager.default.fileExists(atPath: local.path),
      !(try FileManager.default.contentsOfDirectory(atPath: local.path)).isEmpty,
      !FileManager.default.fileExists(
        atPath: local.appendingPathComponent("identity/workspace.json").path)
    {
      throw ProbeError.invalid("unmarked local root")
    }
    try store.join()
    if !FileManager.default.fileExists(atPath: actorPath.path) {
      try ProbeIO.immutable(
        ProbeIO.encode(Actor(participantID: UUID(), deviceID: UUID())), at: actorPath)
    }
    output.status = "complete"
  case "generate":
    let participant = try uuid(required(options, "participant-id"))
    let device = try uuid(required(options, "device-id"))
    guard let count = Int(options["count"] ?? "100"), count > 0, count <= store.limits.events,
      let seed = UInt64(options["seed"] ?? "1")
    else { throw ProbeError.invalid("count/seed") }
    try ProbeIO.durable(
      ProbeIO.encode(Actor(participantID: participant, deviceID: device)), at: actorPath)
    let document = try store.document()
    var parent: [UUID] = []
    var ids = [UUID]()
    for i in 0..<count {
      let key =
        "\(workspace.uuidString)/\(document.documentID.uuidString)/\(participant.uuidString)/\(device.uuidString)/\(seed)/\(i)"
      let id = try seededID(key)
      let commentID = try seededID("comment/" + key)
      let event = ProbeEvent(
        id: id, workspaceID: workspace, documentID: document.documentID, participantID: participant,
        deviceID: device, parents: parent,
        payload: .comment(
          id: commentID, text: "Disposable action \(i+1)", sourceRevision: document.initialRevision)
      )
      try store.enqueue(event)
      ids.append(id)
      parent = [id]
    }
    output.eventIDs = ids
    output.status = "complete"
  case "prepare-source":
    let base = try path(options, "base")
    let proposed = try path(options, "proposed")
    for file in [base, proposed] {
      if file.path.hasPrefix(local.path + "/") {
        try ProbeIO.safe(file, root: local)
      } else {
        try ProbeIO.safe(file, root: shared)
      }
    }
    let a = try ProbeIO.read(base, limit: store.limits.snapshotBytes)
    let b = try ProbeIO.read(proposed, limit: store.limits.snapshotBytes)
    let identity = try actor()
    let document = try store.document()
    let heads = try store.reconcile().state?.sourceHeads ?? []
    let event = ProbeEvent(
      workspaceID: workspace, documentID: document.documentID,
      participantID: identity.participantID, deviceID: identity.deviceID, parents: heads,
      payload: .sourceProposal(
        baseRevision: SnapshotID.hash(a), proposedRevision: SnapshotID.hash(b)))
    let prepared = try SourceRecovery.prepare(event: event, base: a, proposed: b, store: store)
    output.proposalID = prepared.event.id
    output.status = "prepared"
  case "apply-source":
    let id = try uuid(required(options, "proposal-id"))
    let prepared = try SourceRecovery.load(proposalID: id, from: store)
    let result = try SourceRecovery.apply(
      prepared, to: shared.appendingPathComponent(try store.document().relativePath))
    output.proposalID = id
    output.status = result.rawValue
  case "publish":
    var stop: Int?
    if let value = options["stop-after"] {
      guard let number = Int(value), number > 0 else { throw ProbeError.invalid("stop-after") }
      stop = number
    }
    let report = try store.publishOutbox(only: options["only"], stopAfter: stop)
    output.publication = report
    output.status = report.status.rawValue
  case "scan":
    let report = try store.reconcile()
    output.reconciliation = report
    output.status = report.status.rawValue
  case "recover":
    let id = try uuid(required(options, "proposal-id"))
    output.recovery = try SourceRecovery.recover(
      proposalID: id, from: store, to: path(options, "output"))
    output.proposalID = id
    output.status = "complete"
  case "export":
    try store.exportEvidence(to: path(options, "output"))
    output.status = "complete"
  default: throw ProbeError.invalid("command")
  }
  switch output.status {
  case "complete", "pending", "prepared", "applied", "unchanged": exitCode = 0
  case "injectedInterruption": exitCode = 3
  default: exitCode = 2
  }
} catch {
  output.error = String(describing: error)
  switch error {
  case ProbeError.capacityExceeded: output.status = "capacityExceeded"
  case ProbeError.identityConflict: output.status = "identityConflict"
  case ProbeError.unavailable: output.status = "unavailable"
  default: output.status = "invalid"
  }
}
output.monotonicDurationNanoseconds = DispatchTime.now().uptimeNanoseconds - start
if let bytes = try? ProbeIO.encode(output), let text = String(data: bytes, encoding: .utf8) {
  print(text)
}
exit(exitCode)
