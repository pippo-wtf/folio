import XCTest
@testable import ReaderCore

/// Local transport acceptance: every source, transport and private replica is disposable.
/// File delivery below models provider ordering; it does not claim real provider behavior.
final class CollaborationAcceptanceStressTests: XCTestCase {
    private func fixture() throws -> (URL, CollaborationReplicaStore, SharedDocumentRef) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-local-acceptance-\(UUID())")
        let shared = root.appendingPathComponent("shared-a")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("base".utf8).write(to: shared.appendingPathComponent("review.md"))
        let store = CollaborationReplicaStore(localRoot: root.appendingPathComponent("local-a"), sharedRoot: shared, workspaceID: UUID())
        try store.createWorkspace()
        let doc = try store.registerDocument(relativePath: "review.md", initialBytes: Data("base".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, store, doc)
    }
    private func highlight(_ doc: SharedDocumentRef, actor: ParticipantProfile) -> CollaborationEvent {
        let hash = CollaborationSnapshotID.hash(Data("base".utf8))
        return CollaborationEvent(workspaceID: doc.workspaceID, documentID: doc.documentID, participantID: actor.participantID, deviceID: actor.deviceID, authorName: actor.displayName, rawSourceRevision: hash, payload: .highlightAdded(highlightID: UUID(), anchor: SharedAnchor(start: 0, quote: "base", prefix: "", suffix: "", rawSourceRevision: hash, decodedSourceRevision: hash)))
    }
    private func actor(_ name: String) -> ParticipantProfile {
        ParticipantProfile(participantID: UUID(), deviceID: UUID(), displayName: name)
    }
    private func deliver(_ event: CollaborationEvent, to store: CollaborationReplicaStore, name: String? = nil) throws {
        let directory = store.transportRoot.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CollaborationIO.encode(event).write(to: directory.appendingPathComponent(name ?? "\(event.id).json"))
    }

    func testThreeOfflineParticipantsReplayExactUnionWithDuplicatesAcrossRestart() throws {
        let (root, first, doc) = try fixture()
        var stores = [first]
        for name in ["b", "c"] {
            let shared = root.appendingPathComponent("shared-\(name)")
            try FileManager.default.copyItem(at: first.sharedRoot, to: shared)
            let store = CollaborationReplicaStore(localRoot: root.appendingPathComponent("local-\(name)"), sharedRoot: shared, workspaceID: first.workspaceID)
            try store.join(); stores.append(store)
        }
        let actors = [actor("Alice"), actor("Bob"), actor("Carol")]
        var all: [CollaborationEvent] = []
        let start = Date()
        for (index, store) in stores.enumerated() {
            let events = (0..<100).map { _ in highlight(doc, actor: actors[index]) }
            for event in events { try store.enqueue(event) }
            XCTAssertEqual(Set(try store.reconcile().state!.acceptedIDs), Set(events.map(\.id)))
            // Isolated transport roots cannot receive another participant's offline action.
            XCTAssertEqual(try store.events().count, 100)
            all += events
        }
        for store in stores { XCTAssertEqual(try store.publishOutbox().status, .complete) }
        let expected = Set(all.map(\.id))
        for store in stores {
            for event in all.reversed() { try deliver(event, to: store) }
            for (index, event) in all.prefix(20).enumerated() { try deliver(event, to: store, name: "duplicate-\(index).json") }
            let state = try XCTUnwrap(store.reconcile().state)
            XCTAssertEqual(Set(state.acceptedIDs), expected)
            XCTAssertEqual(state.annotations.count, 300)
            XCTAssertTrue(state.pendingEventIDs.isEmpty)
            XCTAssertTrue(state.invalidIDs.isEmpty)
            let restarted = CollaborationReplicaStore(localRoot: store.localRoot, sharedRoot: store.sharedRoot, workspaceID: store.workspaceID)
            try restarted.join()
            XCTAssertEqual(Set(try restarted.reconcile().state!.acceptedIDs), expected)
            let restoredEvents = try restarted.events()
            for participant in actors { XCTAssertEqual(restoredEvents.filter { $0.participantID == participant.participantID && $0.authorName == participant.displayName }.count, 100) }
        }
        print("ACCEPTANCE offline_3x100_seconds=\(Date().timeIntervalSince(start)) exact_union=300 duplicates_per_replica=20")
    }

    func testChildBeforeParentAndMissingSnapshotConvergeAfterRestart() throws {
        let (root, store, doc) = try fixture(), author = actor("Alice")
        let origin = highlight(doc, actor: author)
        guard case .highlightAdded(let thread, _) = origin.payload else { return XCTFail("Expected highlight") }
        let reply = CollaborationEvent(workspaceID: doc.workspaceID, documentID: doc.documentID, participantID: author.participantID, deviceID: author.deviceID, authorName: author.displayName, rawSourceRevision: origin.rawSourceRevision, parents: [origin.id], payload: .commentAdded(threadID: thread, messageID: UUID(), replyTo: nil, text: "Arrived before highlight"))
        try deliver(reply, to: store)
        XCTAssertEqual(try store.reconcile().state?.pendingEventIDs, [reply.id])
        try deliver(origin, to: store)
        XCTAssertEqual(Set(try store.reconcile().state!.acceptedIDs), [reply.id, origin.id])
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("Exact CRLF\r\n😀\r\n".utf8)
        let proposal = try CollaborationSourceRecovery.prepare(document: doc, base: Data("base".utf8), proposed: bytes, actor: author, store: store)
        try store.publishOutbox(only: "events")
        let receiverRoot = root.appendingPathComponent("receiver")
        let receiver = CollaborationReplicaStore(localRoot: receiverRoot, sharedRoot: store.sharedRoot, workspaceID: store.workspaceID)
        try receiver.join()
        let pending = try receiver.reconcile()
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.state?.pendingEventIDs, [proposal.event.id])
        XCTAssertTrue(pending.state?.missingSnapshots.contains(CollaborationSnapshotID.hash(bytes)) ?? false)
        let restarted = CollaborationReplicaStore(localRoot: receiverRoot, sharedRoot: store.sharedRoot, workspaceID: store.workspaceID)
        XCTAssertEqual(try restarted.reconcile().state?.pendingEventIDs, [proposal.event.id])
        try store.publishOutbox(only: "snapshots")
        let complete = try restarted.reconcile()
        XCTAssertEqual(complete.status, .complete)
        XCTAssertTrue(complete.state?.acceptedIDs.contains(proposal.event.id) ?? false)
        XCTAssertTrue(complete.state?.pendingEventIDs.isEmpty ?? false)
        let recovered = try CollaborationSourceRecovery.recover(proposalID: proposal.event.id, from: restarted, to: root.appendingPathComponent("export"))
        XCTAssertTrue(try recovered.paths.map { try Data(contentsOf: $0) }.contains(bytes))
        XCTAssertEqual(try Data(contentsOf: store.sharedRoot.appendingPathComponent("review.md")), Data("base".utf8))
    }

    func testProcessingAt20010002000AndCapacityRetainsPriorEvidence() throws {
        for count in [200, 1000, 2000] {
            let (root, store, doc) = try fixture(), author = actor("Capacity reader")
            let events = (0..<count).map { _ in highlight(doc, actor: author) }
            for event in events { try deliver(event, to: store) }
            let start = Date()
            let first = try store.reconcile()
            let cold = Date().timeIntervalSince(start)
            XCTAssertEqual(first.status, .complete)
            XCTAssertEqual(Set(first.state!.acceptedIDs), Set(events.map(\.id)))
            XCTAssertEqual(first.state?.annotations.count, count)
            let warmStart = Date()
            XCTAssertEqual(try store.reconcile().state, first.state)
            let warm = Date().timeIntervalSince(warmStart)
            print("ACCEPTANCE events=\(count) cold_reconcile_seconds=\(cold) retained_reconcile_seconds=\(warm)")
            if count == 2000 {
                let overflow = highlight(doc, actor: author)
                XCTAssertThrowsError(try store.enqueue(overflow)) { XCTAssertEqual($0 as? CollaborationError, .capacityExceeded) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.localRoot.appendingPathComponent("ready/\(overflow.id)").path))
                XCTAssertEqual(try store.reconcile().state, first.state)
                try deliver(overflow, to: store)
                let overCapacity = try store.reconcile()
                XCTAssertEqual(overCapacity.status, .capacityExceeded)
                XCTAssertNil(overCapacity.state)
                XCTAssertFalse(overCapacity.coverageComplete)
                let evidence = root.appendingPathComponent("over-capacity-export")
                try store.exportEvidence(to: evidence)
                XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.path))
                for event in events { XCTAssertTrue(FileManager.default.fileExists(atPath: store.transportRoot.appendingPathComponent("events/\(event.id).json").path)) }
                XCTAssertEqual(try Data(contentsOf: store.sharedRoot.appendingPathComponent("review.md")), Data("base".utf8))
            }
        }
    }
}
