import XCTest
import ReaderCore
@testable import MarkdownReader

final class CollaborationLocalIntegrationTests: XCTestCase {
    @MainActor func testTwoLocalParticipantsReviewTasksRestartAndRecoverCompetingEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-two-participant-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("shared"), localA = root.appendingPathComponent("pippo"), localB = root.appendingPathComponent("christian")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = shared.appendingPathComponent("review.md")
        let original = "# Shared quote\r\n\r\n- [ ] Review this\r\n"
        try Data(original.utf8).write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let privateA = HighlightStore(directory: localA.appendingPathComponent("private-marks"))
        let privateB = HighlightStore(directory: localB.appendingPathComponent("private-marks"))
        let privateMark = SavedHighlight(id: UUID().uuidString, start: 0, quote: "PRIVATE ONLY Pippo", prefix: "", suffix: "")
        try privateA.save([privateMark], for: source.path, revision: HighlightStore.revision(original))
        XCTAssertTrue(try privateB.load(for: source.path).isEmpty)
        var workspaceID: UUID!, documentID: UUID!, threadID: UUID!, taskID: UUID!
        var authors: [ParticipantProfile] = [], expectedEvents = Set<UUID>()
        let draftA = original.replacingOccurrences(of: "[ ]", with: "[x]") + "Pippo's competing edit.\r\n"
        let draftB = original.replacingOccurrences(of: "[ ]", with: "[x]") + "Christian's competing edit.\r\n"
        do {
            let a = CollaborationCoordinator(enabled: true, localRoot: localA)
            let b = CollaborationCoordinator(enabled: true, localRoot: localB)
            await a.join(folder: shared, create: true, displayName: "Pippo")
            await a.registerDocument(relativePath: "review.md")
            a.selectDocument(url: source)
            let document = try XCTUnwrap(a.currentDocument)
            workspaceID = document.workspaceID; documentID = document.documentID
            await b.join(folder: shared, create: false, displayName: "Christian")
            let opened = await b.openDocument(id: document.documentID)
            XCTAssertEqual(opened?.resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
            b.selectDocument(url: opened)
            XCTAssertEqual(b.currentDocument, document)
            authors = [try XCTUnwrap(a.profile), try XCTUnwrap(b.profile)]
            XCTAssertNotEqual(authors[0].participantID, authors[1].participantID)
            XCTAssertNotEqual(authors[0].deviceID, authors[1].deviceID)
            let baseline = try DocumentSnapshot(url: source)
            let raw = CollaborationSnapshotID.hash(baseline.bytes)
            let anchor = SharedAnchor(start: 0, quote: "Shared quote", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: HighlightStore.revision(original))
            let sharedMark = await a.addSharedHighlight(document: document, anchor: anchor)
            threadID = try XCTUnwrap(sharedMark)
            let comment = await a.addSharedMessage(document: document, threadID: threadID, replyTo: nil, text: "Please review this paragraph.")
            let commentEvent = try XCTUnwrap(comment)
            await b.refresh()
            let parent = try XCTUnwrap(b.events.first { $0.id == commentEvent })
            guard case .commentAdded(_, let parentMessage, _, _) = parent.payload else { return XCTFail("Missing comment") }
            let reply = await b.addSharedMessage(document: document, threadID: threadID, replyTo: parentMessage, text: "Reviewed; I will finish the task.")
            let replyEvent = try XCTUnwrap(reply)
            await a.refresh()
            let messages = a.sharedMessages(document: document, threadID: threadID)
            XCTAssertEqual(messages.map(\.authorName), ["Pippo", "Christian"])
            XCTAssertEqual(messages.map(\.id), [commentEvent, replyEvent])
            guard case .commentAdded(_, _, let replyTo, _) = messages[1].payload else { return XCTFail("Missing reply") }
            XCTAssertEqual(replyTo, parentMessage)
            let offset = (baseline.text as NSString).range(of: "[ ]").location + 1
            let taskAnchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: offset, in: baseline.text, rawSourceRevision: raw))
            let registered = await a.registerSharedTask(document: document, anchor: taskAnchor)
            taskID = try XCTUnwrap(registered)
            await b.refresh()
            let status = await b.setSharedTask(document: document, taskID: taskID, state: .done)
            let statusID = try XCTUnwrap(status)
            XCTAssertEqual(b.sharedTaskStates(taskID: taskID), [.done])
            XCTAssertEqual(try Data(contentsOf: source), baseline.bytes)
            b.sourceSavingEnabled = true
            let checkedSource = baseline.text.replacingOccurrences(of: "[ ]", with: "[x]")
            let taskSave = try await b.save(document: document, baseline: baseline, draft: checkedSource, triggerEventID: statusID)
            XCTAssertEqual(taskSave.localApply, .applied)
            await a.refresh()
            XCTAssertEqual(a.sharedTaskStates(taskID: taskID), [.done])
            XCTAssertEqual(a.sharedTaskSourceStatus(taskID: taskID, source: checkedSource), "Aligned with Markdown")
            XCTAssertFalse(a.sharedThreadResolved(threadID: threadID))
            try a.markSharedRead(document: document)
            XCTAssertTrue(try a.sharedUnreadIDs(document: document).isEmpty)
            XCTAssertTrue(try b.sharedUnreadIDs(document: document).contains(commentEvent))
            XCTAssertTrue(try a.sharedReadStore.seenEventIDs(participantID: authors[1].participantID, workspaceID: workspaceID, documentID: documentID).isEmpty)
            let feedback = try a.sharedFeedback(document: document, decodedRevision: HighlightStore.revision(checkedSource))
            XCTAssertFalse(String(decoding: feedback, as: UTF8.self).contains(privateMark.quote))
            XCTAssertEqual(try privateA.load(for: source.path), [privateMark])
            XCTAssertTrue(try privateB.load(for: source.path).isEmpty)

            // Prepare both participants' exact drafts before either intent is delivered.
            // These are the same durable core stages used by Coordinator.save.
            let storeA = CollaborationReplicaStore(localRoot: localA.appendingPathComponent("workspaces/\(workspaceID!.uuidString)"), sharedRoot: shared, workspaceID: workspaceID)
            let storeB = CollaborationReplicaStore(localRoot: localB.appendingPathComponent("workspaces/\(workspaceID!.uuidString)"), sharedRoot: shared, workspaceID: workspaceID)
            let current = try Data(contentsOf: source)
            let proposalA = try CollaborationSourceRecovery.prepare(document: document, base: current, proposed: Data(draftA.utf8), actor: authors[0], store: storeA)
            let proposalB = try CollaborationSourceRecovery.prepare(document: document, base: current, proposed: Data(draftB.utf8), actor: authors[1], store: storeB)
            XCTAssertEqual(try CollaborationSourceRecovery.apply(proposalA, store: storeA), .applied)
            XCTAssertEqual(try CollaborationSourceRecovery.apply(proposalB, store: storeB), .conflict)
            XCTAssertEqual(try Data(contentsOf: source), Data(draftA.utf8))
            XCTAssertEqual(try Data(contentsOf: proposalB.proposedPath), Data(draftB.utf8))
            _ = try storeA.publishOutbox(); _ = try storeB.publishOutbox()
            await a.refresh(); await b.refresh()
            XCTAssertEqual(Set(a.state?.sourceHeads[documentID] ?? []), [proposalA.event.id, proposalB.event.id])
            XCTAssertEqual(a.state?.sourceHeads[documentID], b.state?.sourceHeads[documentID])
            expectedEvents = Set(a.events.map(\.id))
            XCTAssertEqual(expectedEvents, Set(b.events.map(\.id)))
            let metadata = shared.appendingPathComponent("Folio Review")
            for relative in try FileManager.default.subpathsOfDirectory(atPath: metadata.path) {
                let file = metadata.appendingPathComponent(relative)
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(privateMark.quote))
            }
            // Deallocation models process exit; Stop Watching would intentionally remove the restore record.
        }
        let restoredA = CollaborationCoordinator(enabled: true, localRoot: localA)
        let restoredB = CollaborationCoordinator(enabled: true, localRoot: localB)
        await restoredA.restore(); await restoredB.restore()
        XCTAssertEqual(restoredA.profile, authors[0]); XCTAssertEqual(restoredB.profile, authors[1])
        XCTAssertEqual(restoredA.workspaceID, workspaceID); XCTAssertEqual(restoredB.workspaceID, workspaceID)
        let reopenedA = await restoredA.openDocument(id: documentID), reopenedB = await restoredB.openDocument(id: documentID)
        restoredA.selectDocument(url: reopenedA); restoredB.selectDocument(url: reopenedB)
        let document = try XCTUnwrap(restoredA.currentDocument)
        XCTAssertEqual(restoredB.currentDocument, document)
        XCTAssertEqual(Set(restoredA.events.map(\.id)), expectedEvents)
        XCTAssertEqual(Set(restoredB.events.map(\.id)), expectedEvents)
        XCTAssertEqual(restoredA.sharedMessages(document: document, threadID: threadID).map(\.authorName), ["Pippo", "Christian"])
        XCTAssertEqual(restoredB.sharedTaskStates(taskID: taskID), [.done])
        XCTAssertEqual(restoredA.state?.sourceHeads[documentID]?.count, 2)
        XCTAssertEqual(try privateA.load(for: source.path), [privateMark])
        XCTAssertTrue(try privateB.load(for: source.path).isEmpty)
        let recovery = root.appendingPathComponent("recovery-after-restart")
        try await restoredB.exportSourceRecovery(document: document, to: recovery)
        let files = try FileManager.default.subpathsOfDirectory(atPath: recovery.path)
        let recovered = try files.filter { $0.hasSuffix(".bin") }.map { try Data(contentsOf: recovery.appendingPathComponent($0)) }
        XCTAssertTrue(recovered.contains(Data(draftA.utf8)))
        XCTAssertTrue(recovered.contains(Data(draftB.utf8)))
        XCTAssertTrue(files.contains("coverage.json"))
        XCTAssertEqual(try Data(contentsOf: source), Data(draftA.utf8))
        await restoredA.stopWatching(); await restoredB.stopWatching()
    }
}
