import Foundation

public struct ProbeState: Codable, Equatable {
  public var acceptedIDs: [UUID] = [], pendingDependencyIDs: [UUID] = [],
    pendingEventIDs: [UUID] = [], missingSnapshots: [String] = [], commentIDs: [UUID] = [],
    taskHeads: [String: [UUID]] = [:], sourceHeads: [UUID] = [], conflictHeadSets: [[UUID]] = [],
    invalidIDs: [UUID] = []
  public init() {}
}
func sortedIDs<S: Sequence>(_ ids: S) -> [UUID] where S.Element == UUID {
  ids.sorted { $0.uuidString < $1.uuidString }
}
public enum ProbeReducer {
  public static func reduce(events: [ProbeEvent], snapshots: [String: Data]) -> ProbeState {
    var state = ProbeState()
    var byID: [UUID: ProbeEvent] = [:]
    var invalid = Set<UUID>()
    for e in events {
      if let old = byID[e.id], old != e { invalid.insert(e.id) }
      byID[e.id] = e
      if (try? e.validate()) == nil { invalid.insert(e.id) }
    }
    var ancestry: [UUID: Set<UUID>] = [:]
    var visiting = [UUID]()
    var complete = Set<UUID>()
    func visit(_ id: UUID) -> Set<UUID> {
      if let cycle = visiting.firstIndex(of: id) {
        invalid.formUnion(visiting[cycle...])
        return []
      }
      if complete.contains(id) { return ancestry[id] ?? [] }
      guard let e = byID[id] else { return [] }
      visiting.append(id)
      var ancestors = Set<UUID>()
      for parent in e.parents {
        if let p = byID[parent], p.workspaceID != e.workspaceID || p.documentID != e.documentID {
          invalid.insert(id)
        }
        ancestors.insert(parent)
        ancestors.formUnion(visit(parent))
      }
      _ = visiting.popLast()
      complete.insert(id)
      ancestry[id] = ancestors
      return ancestors
    }
    for id in sortedIDs(byID.keys) { _ = visit(id) }
    func sameEntity(_ e: ProbeEvent, _ p: ProbeEvent) -> Bool {
      guard e.workspaceID == p.workspaceID, e.documentID == p.documentID else { return false }
      switch (e.payload, p.payload) {
      case (.task(let a, _, _, _), .task(let b, _, _, _)): return a == b
      case (.sourceResolution, .sourceProposal), (.sourceResolution, .sourceResolution): return true
      default: return false
      }
    }
    for e in byID.values {
      for id in e.supersedes {
        if let p = byID[id], !(ancestry[e.id, default: []].contains(id) && sameEntity(e, p)) {
          invalid.insert(e.id)
        }
      }
    }
    var accepted = Set<UUID>()
    var remaining = Set(byID.keys).subtracting(invalid)
    var missing = Set<UUID>()
    var missingHashes = Set<String>()
    var changed = true
    while changed {
      changed = false
      for id in sortedIDs(remaining) {
        let e = byID[id]!
        let refs = e.parents + e.supersedes
        guard refs.allSatisfy({ accepted.contains($0) }) else { continue }
        let hashes: [String]
        switch e.payload {
        case .sourceProposal, .sourceResolution: hashes = e.revisions
        default: hashes = []
        }
        guard
          hashes.allSatisfy({ h in
            guard let bytes = snapshots[h] else { return false }
            return SnapshotID.hash(bytes) == h
          })
        else { continue }
        accepted.insert(id)
        remaining.remove(id)
        changed = true
      }
    }
    for id in remaining {
      let e = byID[id]!
      missing.formUnion((e.parents + e.supersedes).filter { !accepted.contains($0) })
      switch e.payload {
      case .sourceProposal, .sourceResolution:
        missingHashes.formUnion(e.revisions.filter { snapshots[$0] == nil })
      default: break
      }
    }
    var taskEvents: [String: [ProbeEvent]] = [:]
    var sourceEvents: [String: [ProbeEvent]] = [:]
    for id in sortedIDs(accepted) {
      let e = byID[id]!
      switch e.payload {
      case .comment(let id, _, _): state.commentIDs.append(id)
      case .task(let id, _, _, _): taskEvents[id.uuidString, default: []].append(e)
      case .sourceProposal, .sourceResolution:
        sourceEvents[e.documentID.uuidString, default: []].append(e)
      }
    }
    for (key, values) in taskEvents {
      let superseded = Set(values.flatMap(\.supersedes))
      let heads = sortedIDs(values.map(\.id).filter { !superseded.contains($0) })
      state.taskHeads[key] = heads
      if heads.count > 1 { state.conflictHeadSets.append(heads) }
    }
    for values in sourceEvents.values {
      var superseded = Set(values.flatMap(\.supersedes))
      for e in values {
        if case .sourceProposal(let base, _) = e.payload {
          for p in values where ancestry[e.id, default: []].contains(p.id) {
            if p.revisions.last == base { superseded.insert(p.id) }
          }
        }
      }
      let heads = sortedIDs(values.map(\.id).filter { !superseded.contains($0) })
      state.sourceHeads += heads
      if heads.count > 1 { state.conflictHeadSets.append(heads) }
    }
    state.acceptedIDs = sortedIDs(accepted)
    state.pendingEventIDs = sortedIDs(remaining)
    state.pendingDependencyIDs = sortedIDs(missing)
    state.missingSnapshots = missingHashes.sorted()
    state.commentIDs = sortedIDs(state.commentIDs)
    state.sourceHeads = sortedIDs(state.sourceHeads)
    state.invalidIDs = sortedIDs(invalid)
    state.conflictHeadSets.sort { $0.map(\.uuidString).joined() < $1.map(\.uuidString).joined() }
    return state
  }
}
