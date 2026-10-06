import Foundation
import ReaderCore

extension CollaborationCoordinator {
    var sharedReadStore: SharedReadStore { SharedReadStore(directory: localRoot.appendingPathComponent("seen")) }
    func reviewEvents(document: SharedDocumentRef) -> [CollaborationEvent] {
        events.filter { $0.workspaceID == document.workspaceID && $0.documentID == document.documentID }
    }
    /// Display order follows parents, with UUID ordering for otherwise unrelated actions.
    func sharedActivity(document: SharedDocumentRef) -> [CollaborationEvent] {
        let selected = reviewEvents(document: document)
        let byID = Dictionary(selected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>(), ordered: [CollaborationEvent] = []
        func visit(_ event: CollaborationEvent) {
            guard seen.insert(event.id).inserted else { return }
            for parent in event.parents.sorted(by: { $0.uuidString < $1.uuidString }) { if let value = byID[parent] { visit(value) } }
            ordered.append(event)
        }
        for event in selected.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { visit(event) }
        return ordered.reversed()
    }
    func sharedUnreadIDs(document: SharedDocumentRef) throws -> Set<UUID> {
        guard let profile, workspaceID == document.workspaceID else { throw CollaborationError.unavailable }
        let selected = reviewEvents(document: document)
        return try sharedReadStore.unreadEventIDs(eventIDs: Set(selected.map(\.id)), ownEventIDs: Set(selected.filter { $0.participantID == profile.participantID }.map(\.id)), participantID: profile.participantID, workspaceID: document.workspaceID, documentID: document.documentID)
    }
    func markSharedRead(document: SharedDocumentRef) throws {
        guard let profile, workspaceID == document.workspaceID else { throw CollaborationError.unavailable }
        try sharedReadStore.markSeen(eventIDs: Set(reviewEvents(document: document).map(\.id)), participantID: profile.participantID, workspaceID: document.workspaceID, documentID: document.documentID)
    }
    func observedSharedSource(document: SharedDocumentRef) -> String? {
        guard let bytes = sourceObservations[document.documentID] else { return nil }
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { return String(data: bytes, encoding: .utf16) }
        return String(data: bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(bytes.dropFirst(3)) : bytes, encoding: .utf8)
    }
    func sharedFeedback(document: SharedDocumentRef, decodedRevision: String) throws -> Data {
        guard let state, workspaceID == document.workspaceID, let bytes = sourceObservations[document.documentID] else { throw CollaborationError.unavailable }
        guard let decoded = observedSharedSource(document: document), HighlightStore.revision(decoded) == decodedRevision else { throw CollaborationError.invalid("Saved source revisions changed. Retry the shared export.") }
        // No private stores or read cursors enter this separate version-2 packet.
        return try SharedFeedback.export(document: document, state: state, events: events, currentRawRevision: CollaborationSnapshotID.hash(bytes), currentDecodedRevision: decodedRevision, report: reviewReport)
    }
    private func authorReview(document: SharedDocumentRef, payload: CollaborationPayload, rawRevision: String? = nil, parents: [UUID] = []) async -> CollaborationEvent? {
        guard enabled, currentDocument == document, let profile, let bytes = sourceObservations[document.documentID], [.complete, .pending].contains(status) else { return nil }
        let raw = CollaborationSnapshotID.hash(bytes)
        guard rawRevision == nil || rawRevision == raw else { return nil }
        let event = CollaborationEvent(workspaceID: document.workspaceID, documentID: document.documentID, participantID: profile.participantID, deviceID: profile.deviceID, authorName: profile.displayName, rawSourceRevision: raw, parents: Array(Set(parents)).sorted { $0.uuidString < $1.uuidString }, payload: payload)
        guard (try? event.validate()) != nil, await submit(event) else { return nil }
        return event
    }
    func addSharedHighlight(document: SharedDocumentRef, anchor: SharedAnchor) async -> UUID? {
        let id = UUID()
        return await authorReview(document: document, payload: .highlightAdded(highlightID: id, anchor: anchor), rawRevision: anchor.rawSourceRevision) == nil ? nil : id
    }
    func sharedAnchor(highlightID: UUID) -> SharedAnchor? {
        guard let state, let origin = state.annotations[highlightID] else { return nil }
        let heads = state.annotationHeads[highlightID] ?? []
        guard heads.count == 1, let event = events.first(where: { $0.id == heads[0] }) else { return nil }
        switch event.payload {
        case .highlightAdded(_, let anchor), .highlightReattached(_, let anchor, _): return anchor
        case .highlightRemoved: return nil
        default: if case .highlightAdded(_, let anchor) = origin.payload { return anchor }; return nil
        }
    }
    func reattachSharedHighlight(document: SharedDocumentRef, highlightID: UUID, anchor: SharedAnchor) async -> Bool {
        guard let origin = state?.annotations[highlightID], origin.documentID == document.documentID else { return false }
        let heads = state?.annotationHeads[highlightID] ?? []
        return await authorReview(document: document, payload: .highlightReattached(highlightID: highlightID, anchor: anchor, supersedes: heads), rawRevision: anchor.rawSourceRevision, parents: heads + [origin.id]) != nil
    }
    func addSharedMessage(document: SharedDocumentRef, threadID: UUID, replyTo: UUID?, text: String) async -> UUID? {
        guard let origin = state?.annotations[threadID], origin.documentID == document.documentID else { return nil }
        var parents = [origin.id]
        if let replyTo {
            guard let reply = state?.messages[replyTo], case .commentAdded(let thread, _, _, _) = reply.payload, thread == threadID else { return nil }
            parents.append(reply.id)
        }
        return await authorReview(document: document, payload: .commentAdded(threadID: threadID, messageID: UUID(), replyTo: replyTo, text: text), parents: parents)?.id
    }
    func sharedMessages(document: SharedDocumentRef, threadID: UUID) -> [CollaborationEvent] {
        sharedActivity(document: document).reversed().filter { event in
            guard state?.acceptedIDs.contains(event.id) == true else { return false }
            if case .commentAdded(let thread, _, _, _) = event.payload { return thread == threadID }; return false
        }
    }
    func sharedThreadResolved(threadID: UUID) -> Bool {
        guard let heads = state?.threadHeads[threadID], heads.count == 1, let event = events.first(where: { $0.id == heads[0] }), case .threadState(_, let resolved, _) = event.payload else { return false }
        return resolved
    }
    func setSharedThread(document: SharedDocumentRef, threadID: UUID, resolved: Bool) async -> Bool {
        guard let origin = state?.annotations[threadID], origin.documentID == document.documentID else { return false }
        let heads = state?.threadHeads[threadID] ?? []
        return await authorReview(document: document, payload: .threadState(threadID: threadID, resolved: resolved, supersedes: heads), parents: heads + [origin.id]) != nil
    }
    func registerSharedTask(document: SharedDocumentRef, anchor: SharedTaskAnchor) async -> UUID? {
        let id = UUID()
        return await authorReview(document: document, payload: .taskRegistered(taskID: id, anchor: anchor), rawRevision: anchor.rawSourceRevision) == nil ? nil : id
    }
    func setSharedTask(document: SharedDocumentRef, taskID: UUID, state value: SharedTaskState) async -> UUID? {
        guard let origin = state?.tasks[taskID], origin.documentID == document.documentID, let bytes = sourceObservations[document.documentID] else { return nil }
        let heads = state?.taskHeads[taskID] ?? [], raw = CollaborationSnapshotID.hash(bytes)
        return await authorReview(document: document, payload: .taskState(taskID: taskID, state: value, supersedes: heads, rawSourceRevision: raw), parents: heads + [origin.id])?.id
    }
    func sharedTaskStates(taskID: UUID) -> [SharedTaskState] {
        let heads = Set(state?.taskHeads[taskID] ?? [])
        return events.filter { heads.contains($0.id) }.compactMap { if case .taskState(_, let value, _, _) = $0.payload { return value }; return nil }
    }
    func sharedTaskSourceStatus(taskID: UUID, source: String) -> String {
        guard let origin = state?.tasks[taskID], case .taskRegistered(_, let anchor) = origin.payload, let offset = SharedTaskMatcher.locate(anchor, in: source) else { return "Task location changed · Source update blocked" }
        let values = sharedTaskStates(taskID: taskID)
        if values.count > 1 { return "Task status conflict · Choose a state" }
        guard let value = values.first else { return "Choose a task state" }
        let checked = (source as NSString).substring(with: NSRange(location: offset, length: 1)).lowercased() == "x"
        return checked == (value == .done) ? "Aligned with Markdown" : "Task status saved · Markdown update pending"
    }
}
