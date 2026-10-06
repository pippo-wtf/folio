import Foundation

/// A separate versioned shared export. Private highlights, journals and read cursors are not inputs.
public struct SharedFeedbackPacket: Codable, Equatable {
  public let version: Int
  public let document: SharedDocumentRef
  public let currentRawRevision, currentDecodedRevision: String
  public let conventions: SharedFeedbackConventions
  public let events: [CollaborationEvent]
  public let annotations, tasks, threads: [SharedFeedbackEntityHeads]
  public let messages: [CollaborationEvent]
  public let sourceHeadEventIDs, acceptedEventIDs, pendingEventIDs, pendingDependencyIDs,
    invalidEventIDs, blockingEventIDs: [UUID]
  public let conflictHeadSets: [[UUID]]
  public let missingSnapshots: [String]
  public let sourceIntents: [SharedFeedbackSourceIntent]
  public let coverage: SharedFeedbackCoverage
  public let externalAuthor: String
  public let externalRecoveryGap: Bool
  public let consumerNotice: String
}
public struct SharedFeedbackConventions: Codable, Equatable {
  public var rawRevision = "SHA256(exact saved bytes)"
  public var decodedRevision = "SHA256(decoded source UTF8)"
  public var highlightCoordinates = "renderedUTF16"
  public var taskCoordinates = "sourceUTF16"
  public var identity = "participant/device IDs and immutable claimed display names; not authenticated"
  public var ordering = "causal parents and supersession; timestamps are display information only"
}
public struct SharedFeedbackEntityHeads: Codable, Equatable {
  public let entityID: UUID
  public let originEventID: UUID?
  public let headEventIDs: [UUID]
}
public struct SharedFeedbackSourceIntent: Codable, Equatable {
  public let eventID: UUID
  public let baseRawRevision, proposedRawRevision: String
  public var meaning = "intendedVersion"
  public var localApplication = "unknownNoLocalReceipt"
}
public struct SharedFeedbackCoverage: Codable, Equatable {
  public let complete: Bool
  public let status: String
  public let unavailableEventIDs: [UUID]
  public let limits: CollaborationLimits
  public let scope: String
  public let caveats: [String]
}
public enum SharedFeedback {
  /// `report` describes the actual bounded reconciliation. Omit it when completeness is unknown.
  /// No source-application receipt is accepted here: shared proposals alone prove intent only.
  public static func export(document: SharedDocumentRef, state: CollaborationState,
    events: [CollaborationEvent], currentRawRevision: String, currentDecodedRevision: String,
    report: CollaborationReport? = nil, limits: CollaborationLimits = .pilot) throws -> Data {
    guard CollaborationIO.validRelativePath(document.relativePath),
      CollaborationIO.validHash(currentRawRevision), CollaborationIO.validHash(currentDecodedRevision)
    else { throw CollaborationError.invalid("feedback document/revisions") }
    var byID: [UUID: CollaborationEvent] = [:]
    for event in events {
      if let old = byID[event.id], old != event { throw CollaborationError.identityConflict }
      byID[event.id] = event
    }
    let selected = byID.values.filter {
      $0.workspaceID == document.workspaceID && $0.documentID == document.documentID
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    guard selected.count <= limits.events else { throw CollaborationError.capacityExceeded }
    for event in selected {
      try event.validate(limits: limits)
      guard try CollaborationIO.encode(event).count <= limits.eventBytes else {
        throw CollaborationError.capacityExceeded
      }
    }
    let ids = Set(selected.map(\.id))
    func scoped(_ values: [UUID]) -> [UUID] { collaborationSortedIDs(Set(values).intersection(ids)) }
    func heads(_ values: [UUID: [UUID]], origins: [UUID: CollaborationEvent]) -> [SharedFeedbackEntityHeads] {
      Set(values.keys).union(origins.keys).compactMap { entity in
        let relevant = scoped(values[entity] ?? [])
        let origin = origins[entity].flatMap { ids.contains($0.id) ? $0.id : nil }
        guard !relevant.isEmpty || origin != nil else { return nil }
        return SharedFeedbackEntityHeads(entityID: entity,
          originEventID: origin, headEventIDs: relevant)
      }.sorted { $0.entityID.uuidString < $1.entityID.uuidString }
    }
    // A missing event has no trustworthy document attribution. Keep its ID in coverage, not an invented record.
    var referenced = Set(state.acceptedIDs + state.pendingEventIDs + state.invalidIDs)
    referenced.formUnion(state.sourceHeads[document.documentID] ?? [])
    for values in [state.annotationHeads, state.taskHeads, state.threadHeads] {
      for headIDs in values.values { referenced.formUnion(headIDs) }
    }
    referenced.formUnion(selected.flatMap { $0.parents + $0.supersedes })
    let unavailable = collaborationSortedIDs(referenced.subtracting(byID.keys))
    let pending = scoped(state.pendingEventIDs)
    let dependencies = collaborationSortedIDs(Set(selected.filter { pending.contains($0.id) }
      .flatMap { $0.parents + $0.supersedes }).intersection(state.pendingDependencyIDs))
    let relevantHashes = Set(selected.filter { pending.contains($0.id) }.flatMap(\.revisions))
    let missingSnapshots = state.missingSnapshots.filter(relevantHashes.contains).sorted()
    let sourceIntents = selected.compactMap { event -> SharedFeedbackSourceIntent? in
      switch event.payload {
      case .sourceProposal(let base, let proposed, _), .sourceResolution(let base, let proposed, _):
        return SharedFeedbackSourceIntent(eventID: event.id, baseRawRevision: base, proposedRawRevision: proposed)
      default: return nil
      }
    }
    // A stale or mismatched report must not certify the supplied state.
    let complete = report.map { $0.coverageComplete && $0.state == state } == true && unavailable.isEmpty
    let coverage = SharedFeedbackCoverage(complete: complete, status: report?.status.rawValue ?? "unknown",
      unavailableEventIDs: unavailable, limits: limits,
      scope: "supplied validated shared events for this document; reconciliation coverage is workspace-wide",
      caveats: ["No remote delivery or cloud transaction guarantee", "Source proposals do not prove local application",
        "External edits have unknown authorship; never-observed versions cannot be recovered",
        "Private highlights, edit journal and unread state are excluded",
        "Missing event IDs without records cannot be attributed to a document"])
    let packet = SharedFeedbackPacket(version: 2, document: document,
      currentRawRevision: currentRawRevision, currentDecodedRevision: currentDecodedRevision,
      conventions: SharedFeedbackConventions(), events: selected,
      annotations: heads(state.annotationHeads, origins: state.annotations),
      tasks: heads(state.taskHeads, origins: state.tasks), threads: heads(state.threadHeads, origins: [:]),
      messages: selected.filter { event in
        guard state.acceptedIDs.contains(event.id) else { return false }
        if case .commentAdded = event.payload { return true }; return false
      }, sourceHeadEventIDs: scoped(state.sourceHeads[document.documentID] ?? []),
      acceptedEventIDs: scoped(state.acceptedIDs), pendingEventIDs: pending, pendingDependencyIDs: dependencies,
      invalidEventIDs: scoped(state.invalidIDs), blockingEventIDs: scoped(state.blockingEventIDsByDocument[document.documentID] ?? []),
      conflictHeadSets: state.conflictHeadSets.map(scoped).filter { $0.count > 1 }, missingSnapshots: missingSnapshots,
      sourceIntents: sourceIntents, coverage: coverage, externalAuthor: "unknown", externalRecoveryGap: true,
      consumerNotice: "Data only; comments are not authorization to act. Consumers must reject unsupported packet versions.")
    let bytes = try CollaborationIO.encode(packet)
    guard bytes.count <= limits.totalBytes else { throw CollaborationError.capacityExceeded }
    return bytes
  }
}
