import Foundation

public struct CollaborationState: Codable, Equatable {
  public var acceptedIDs: [UUID] = [], pendingDependencyIDs: [UUID] = [], pendingEventIDs: [UUID] = [],
    missingSnapshots: [String] = [], invalidIDs: [UUID] = [], conflictHeadSets: [[UUID]] = []
  public var sourceHeads: [UUID: [UUID]] = [:], annotationHeads: [UUID: [UUID]] = [:],
    threadHeads: [UUID: [UUID]] = [:], taskHeads: [UUID: [UUID]] = [:]
  public var annotations: [UUID: CollaborationEvent] = [:], messages: [UUID: CollaborationEvent] = [:],
    tasks: [UUID: CollaborationEvent] = [:]
  public var blockingEventIDsByDocument: [UUID: [UUID]] = [:]
  public init() {}
}
func collaborationSortedIDs<S: Sequence>(_ ids: S) -> [UUID] where S.Element == UUID {
  ids.sorted { $0.uuidString < $1.uuidString }
}
public enum CollaborationReducer {
  public static func reduce(events: [CollaborationEvent], snapshots: [String: Data]) -> CollaborationState {
    var state = CollaborationState(), byID: [UUID: CollaborationEvent] = [:], invalid = Set<UUID>()
    for e in events {
      if let old = byID[e.id], old != e { invalid.insert(e.id) }
      byID[e.id] = e
      if (try? e.validate()) == nil { invalid.insert(e.id) }
    }
    var ancestry: [UUID: Set<UUID>] = [:], visiting: [UUID] = [], complete = Set<UUID>()
    func visit(_ id: UUID) -> Set<UUID> {
      if let cycle = visiting.firstIndex(of:id) { invalid.formUnion(visiting[cycle...]); return [] }
      if complete.contains(id) { return ancestry[id] ?? [] }
      guard let e = byID[id] else { return [] }
      visiting.append(id)
      var found = Set<UUID>()
      for p in e.parents {
        if let parent = byID[p], parent.workspaceID != e.workspaceID || parent.documentID != e.documentID { invalid.insert(id) }
        found.insert(p); found.formUnion(visit(p))
      }
      visiting.removeLast(); complete.insert(id); ancestry[id] = found; return found
    }
    for id in collaborationSortedIDs(byID.keys) { _ = visit(id) }
    // Stable entity IDs may be registered once; identical text never establishes identity.
    var origins: [String: [UUID]] = [:]
    for e in byID.values {
      switch e.payload {
      case .highlightAdded, .taskRegistered, .commentAdded:
        origins[e.workspaceID.uuidString+"/"+e.entityKey, default:[]].append(e.id)
      default:break
      }
      for id in e.supersedes {
        if let old = byID[id], !(ancestry[e.id,default:[]].contains(id) && old.documentID == e.documentID && old.workspaceID == e.workspaceID && old.entityKey == e.entityKey) { invalid.insert(e.id) }
      }
    }
    for ids in origins.values where ids.count > 1 { invalid.formUnion(ids) }
    func entityOrigin(_ key: String, event: CollaborationEvent) -> CollaborationEvent? {
      byID.values.first { $0.workspaceID == event.workspaceID && $0.documentID == event.documentID && $0.entityKey == key && {
        switch $0.payload { case .highlightAdded,.taskRegistered,.commentAdded:return true; default:return false }
      }($0) }
    }
    var accepted = Set<UUID>(), remaining = Set(byID.keys).subtracting(invalid), changed = true
    while changed {
      changed = false
      for id in collaborationSortedIDs(remaining) {
        let e = byID[id]!, ancestors = ancestry[id,default:[]]
        guard (e.parents+e.supersedes).allSatisfy(accepted.contains) else { continue }
        var dependencies = [CollaborationEvent](), absentEntity = false
        func require(_ key: String) {
          if let origin = entityOrigin(key,event:e) { dependencies.append(origin) } else { absentEntity = true }
        }
        switch e.payload {
        case .highlightRemoved(let h,_), .highlightReattached(let h,_,_), .threadState(let h,_,_):require("highlight/"+h.uuidString)
        case .commentAdded(let h,_,let reply,_):
          require("highlight/"+h.uuidString)
          if let reply = reply { require("message/"+reply.uuidString) }
        case .taskState(let t,_,_,_):require("task/"+t.uuidString)
        case .sourceProposal(_,_,let trigger):
          if let trigger = trigger {
            if let dep = byID[trigger] {
              guard dep.documentID == e.documentID, dep.workspaceID == e.workspaceID,
                case .taskState = dep.payload else { invalid.insert(id); remaining.remove(id); changed=true; continue }
              dependencies.append(dep)
            } else { absentEntity=true }
          }
        default:break
        }
        if absentEntity { continue }
        if dependencies.contains(where: { !ancestors.contains($0.id) }) { invalid.insert(id); remaining.remove(id); changed=true; continue }
        guard dependencies.allSatisfy({ accepted.contains($0.id) }) else { continue }
        if case .commentAdded(let thread,_,let reply,_) = e.payload, let reply = reply,
          let parent = entityOrigin("message/"+reply.uuidString,event:e),
          case .commentAdded(let parentThread,_,_,_) = parent.payload, parentThread != thread {
          invalid.insert(id); remaining.remove(id); changed=true; continue
        }
        if e.isSource && !e.revisions.allSatisfy({ h in snapshots[h].map { CollaborationSnapshotID.hash($0) == h } ?? false }) { continue }
        if !e.supersedes.isEmpty {
          let observed = byID.values.filter { old in
            if case .taskRegistered = old.payload { return false }
            return accepted.contains(old.id) && ancestors.contains(old.id) && old.workspaceID == e.workspaceID && old.documentID == e.documentID && old.entityKey == e.entityKey }
          var removed = Set(observed.flatMap(\.supersedes))
          for child in observed {
            if case .sourceProposal(let base,_,_) = child.payload {
              for old in observed where ancestry[child.id,default:[]].contains(old.id) && old.revisions.last == base { removed.insert(old.id) }
            }
          }
          let observedHeads = Set(observed.map(\.id)).subtracting(removed)
          if !observedHeads.isSubset(of:Set(e.supersedes)) { invalid.insert(id); remaining.remove(id); changed=true; continue }
        }
        accepted.insert(id); remaining.remove(id); changed=true
      }
    }
    var missing = Set<UUID>(), hashes = Set<String>()
    for id in remaining {
      let e = byID[id]!
      missing.formUnion((e.parents+e.supersedes).filter { !accepted.contains($0) })
      if e.isSource { hashes.formUnion(e.revisions.filter { h in snapshots[h].map { CollaborationSnapshotID.hash($0) != h } ?? true }) }
      if e.isSource { state.blockingEventIDsByDocument[e.documentID,default:[]].append(id) }
    }
    var groups: [String:[CollaborationEvent]] = [:]
    for id in collaborationSortedIDs(accepted) {
      let e = byID[id]!
      switch e.payload {
      case .highlightAdded(let h,_):state.annotations[h] = e
      case .commentAdded(_,let m,_,_):state.messages[m] = e
      case .taskRegistered(let t,_):state.tasks[t] = e
      default:break
      }
      switch e.payload { case .commentAdded,.taskRegistered:continue; default:break }
      groups[e.documentID.uuidString+"/"+e.entityKey,default:[]].append(e)
    }
    for values in groups.values {
      var removed = Set(values.flatMap(\.supersedes))
      for e in values where e.isSource {
        if case .sourceProposal(let base,_,_) = e.payload {
          for old in values where ancestry[e.id,default:[]].contains(old.id) && old.revisions.last == base { removed.insert(old.id) }
        }
      }
      let heads = collaborationSortedIDs(values.map(\.id).filter { !removed.contains($0) })
      guard let first = values.first else { continue }
      switch first.payload {
      case .sourceProposal,.sourceResolution:
        state.sourceHeads[first.documentID] = heads
        if heads.count > 1 { state.blockingEventIDsByDocument[first.documentID,default:[]] += heads }
      case .highlightAdded(let h,_),.highlightRemoved(let h,_),.highlightReattached(let h,_,_):state.annotationHeads[h] = heads
      case .threadState(let h,_,_):state.threadHeads[h] = heads
      case .taskRegistered(let t,_),.taskState(let t,_,_,_):state.taskHeads[t] = heads
      default:break
      }
      if heads.count > 1 { state.conflictHeadSets.append(heads) }
    }
    state.acceptedIDs=collaborationSortedIDs(accepted); state.pendingEventIDs=collaborationSortedIDs(remaining)
    state.pendingDependencyIDs=collaborationSortedIDs(missing); state.missingSnapshots=hashes.sorted(); state.invalidIDs=collaborationSortedIDs(invalid)
    for (id,ids) in state.blockingEventIDsByDocument { state.blockingEventIDsByDocument[id] = collaborationSortedIDs(Set(ids)) }
    state.conflictHeadSets.sort { $0.map(\.uuidString).joined() < $1.map(\.uuidString).joined() }
    return state
  }
}
