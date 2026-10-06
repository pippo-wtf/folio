import XCTest
import AppKit
import ReaderCore
@testable import MarkdownReader

final class CollaborationCoordinatorTests: XCTestCase {
    func fixture() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = base.appendingPathComponent("shared"), local = base.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("# First\n".utf8).write(to: shared.appendingPathComponent("first.md"))
        try Data("# Nested\n".utf8).write(to: shared.appendingPathComponent("nested/second.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, shared, local)
    }
    @MainActor func testPublicDisabledHasNoDiskOrWatcherSideEffects() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: false, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        XCTAssertNil(c.workspaceID); XCTAssertFalse(c.isWatching)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("Folio Review").path))
        #if FOLIO_STAGING && !FOLIO_UPDATE_TEST
        XCTAssertTrue(BuildChannel.collaborationAvailable)
        #else
        XCTAssertFalse(BuildChannel.collaborationAvailable)
        #endif
    }
    @MainActor func testCreateRegisterRestoreAndDisconnectPreserveSourcesAndEvidence() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: " Philip ")
        XCTAssertEqual(c.profile?.displayName, "Philip"); XCTAssertNotNil(c.workspaceID)
        XCTAssertEqual(c.candidates, ["first.md", "nested/second.md"]); XCTAssertTrue(c.documents.isEmpty)
        await c.registerDocument(relativePath: "nested/second.md")
        let id = try XCTUnwrap(c.documents.first?.reference.documentID)
        let profile = c.profile
        XCTAssertTrue(c.protectsSource(at: shared.appendingPathComponent("nested/second.md")))
        let restored = CollaborationCoordinator(enabled: true, localRoot: local)
        await restored.restore()
        XCTAssertEqual(restored.profile, profile); XCTAssertEqual(restored.documents.first?.reference.documentID, id)
        await c.stopWatching(); await restored.stopWatching()
        XCTAssertFalse(c.isWatching)
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("nested/second.md")), "# Nested\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("Folio Review/workspace.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("profile.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("active-workspace.json").path))
    }
    @MainActor func testJoinDetectsDeliveredIdentityAndDuplicateCreateNeverReplacesIt() async throws {
        let (base, shared, local) = try fixture()
        let a = CollaborationCoordinator(enabled: true, localRoot: local)
        await a.join(folder: shared, create: true, displayName: "Alex")
        await a.registerDocument(relativePath: "first.md")
        let b = CollaborationCoordinator(enabled: true, localRoot: base.appendingPathComponent("other"))
        await b.join(folder: shared, create: false, displayName: "Alex")
        XCTAssertEqual(a.workspaceID, b.workspaceID)
        XCTAssertNotEqual(a.profile?.participantID, b.profile?.participantID)
        XCTAssertEqual(b.documents.first?.reference.documentID, a.documents.first?.reference.documentID)
        let before = try Data(contentsOf: shared.appendingPathComponent("Folio Review/workspace.json"))
        await b.join(folder: shared, create: true, displayName: "Alex")
        XCTAssertNotNil(b.error); XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("Folio Review/workspace.json")), before)
        await a.stopWatching(); await b.stopWatching()
    }
    @MainActor func testSchemaOneAndBlankNameFailWithoutCreatingLocalProfile() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "  ")
        XCTAssertNotNil(c.error); XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("profile.json").path))
        let metadata = shared.appendingPathComponent("Folio Review")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":1,\"workspaceID\":\"\(UUID().uuidString)\"}".utf8).write(to: metadata.appendingPathComponent("workspace.json"))
        await c.join(folder: shared, create: false, displayName: "Philip")
        XCTAssertNil(c.workspaceID); XCTAssertTrue(c.error?.contains("schema-1") == true)
    }
    @MainActor func testExactByteRefreshDetectsSameSizeSameTimeAndDoesNotReauthor() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let source = shared.appendingPathComponent("first.md")
        let date = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as! Date
        var observations = [Data]()
        c.onSourceObserved = { _, bytes in observations.append(bytes) }
        try Data("# Other\n".utf8).write(to: source, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        await c.refresh()
        XCTAssertEqual(observations.last, Data("# Other\n".utf8))
        XCTAssertTrue(c.events.isEmpty)
        await c.stopWatching()
    }
    @MainActor func testDurableSubmitRetainsActorAndRetryDoesNotDuplicateEvent() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let doc = try XCTUnwrap(c.documents.first?.reference), actor = try XCTUnwrap(c.profile)
        let bytes = Data("# First\n".utf8), hash = CollaborationSnapshotID.hash(bytes)
        let anchor = SharedAnchor(start: 0, quote: "First", prefix: "", suffix: "", rawSourceRevision: hash, decodedSourceRevision: hash)
        let event = CollaborationEvent(workspaceID: doc.workspaceID, documentID: doc.documentID, participantID: actor.participantID, deviceID: actor.deviceID, authorName: actor.displayName, rawSourceRevision: hash, payload: .highlightAdded(highlightID: UUID(), anchor: anchor))
        let submitted = await c.submit(event, snapshots: [:])
        XCTAssertTrue(submitted)
        await c.refresh(); await c.refresh()
        XCTAssertEqual(c.events.map(\.id), [event.id]); XCTAssertEqual(c.state?.acceptedIDs, [event.id])
        XCTAssertEqual(c.events.first?.authorName, "Philip")
        await c.rename(to: "Pippo")
        XCTAssertEqual(c.events.first?.authorName, "Philip")
        let exported = local.deletingLastPathComponent().appendingPathComponent("export")
        await c.exportEvidence(to: exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        await c.stopWatching()
    }
    @MainActor func testUnavailableKeepsLastReadableStateAndRejectsLateWorkspaceCompletion() async throws {
        let (base, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let state = c.state, id = c.workspaceID
        try FileManager.default.removeItem(at: shared.appendingPathComponent("Folio Review/workspace.json"))
        await c.refresh()
        XCTAssertEqual(c.state, state); XCTAssertEqual(c.workspaceID, id); XCTAssertNotNil(c.error)
        let other = base.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let oldRefresh = Task { await c.refresh() }
        await c.join(folder: other, create: true, displayName: "Philip")
        await oldRefresh.value
        XCTAssertNotEqual(c.workspaceID, id); XCTAssertTrue(c.documents.isEmpty)
        await c.stopWatching()
    }
    @MainActor func testAmbiguousMovedOriginalDoesNotAutomaticallyRebindOnOpen() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let id = try XCTUnwrap(c.documents.first?.id)
        try FileManager.default.moveItem(at: shared.appendingPathComponent("first.md"), to: shared.appendingPathComponent("moved.md"))
        try Data("# First\n".utf8).write(to: shared.appendingPathComponent("first.md"))
        await c.refresh()
        XCTAssertNil(c.documents.first?.url)
        let fresh = CollaborationCoordinator(enabled: true, localRoot: local)
        XCTAssertTrue(fresh.protectsSource(at: shared.appendingPathComponent("first.md")))
        await fresh.restore()
        XCTAssertTrue(fresh.protectsSource(at: shared.appendingPathComponent("first.md")))
        await fresh.stopWatching()
        let opened = await c.openDocument(id: id)
        XCTAssertNil(opened)
        XCTAssertNotNil(c.error)
        await c.reconnectDocument(id: id, relativePath: "moved.md")
        let reconnected = await c.openDocument(id: id)
        XCTAssertEqual(reconnected?.lastPathComponent, "moved.md")
        await c.stopWatching()
    }
    @MainActor func testRegisteredSourceCannotSaveThroughSoloPathAndPrivateMarksRemainLocal() async throws {
        _ = NSApplication.shared
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let source = shared.appendingPathComponent("first.md")
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true
        model.load(source)
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.loading)
        model.text = "Draft stays local.\n"
        XCTAssertFalse(model.save()); XCTAssertTrue(model.dirty)
        XCTAssertEqual(try Data(contentsOf: source), Data("# First\n".utf8))
        let privateStore = HighlightStore(directory: local.deletingLastPathComponent().appendingPathComponent("private"))
        try privateStore.save([SavedHighlight(id: "00000000-0000-0000-0000-000000000001", start: 0, quote: "Draft", prefix: "", suffix: "")], for: "private-doc", revision: HighlightStore.revision(model.text), draft: true)
        XCTAssertEqual(try privateStore.load(for: "private-doc").map(\.id), ["00000000-0000-0000-0000-000000000001"])
        await c.refresh()
        XCTAssertTrue(c.events.isEmpty)
        await c.stopWatching()
        XCTAssertFalse(model.save())
        XCTAssertEqual(try Data(contentsOf: source), Data("# First\n".utf8))
    }

    @MainActor func testFailedFolderInventoryDoesNotReplacePreviouslyActiveWorkspace() async throws {
        let (base, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        let id = c.workspaceID
        let other = base.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let denied = other.appendingPathComponent("nested")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        await c.join(folder: other, create: true, displayName: "Philip")
        XCTAssertEqual(c.workspaceID, id); XCTAssertNotNil(c.error)
        let restored = CollaborationCoordinator(enabled: true, localRoot: local)
        await restored.restore()
        XCTAssertEqual(restored.workspaceID, id)
        await c.refresh()
        XCTAssertEqual(c.workspaceID, id); XCTAssertNil(c.error)
        await c.stopWatching(); await restored.stopWatching()
    }

    @MainActor func testRejectedReconnectPreservesLocalBindingBytes() async throws {
        let (base, shared, local) = try fixture()
        let creator = CollaborationCoordinator(enabled: true, localRoot: local)
        await creator.join(folder: shared, create: true, displayName: "Philip")
        await creator.registerDocument(relativePath: "first.md")
        await creator.registerDocument(relativePath: "nested/second.md")
        let joined = CollaborationCoordinator(enabled: true, localRoot: base.appendingPathComponent("joined"))
        await joined.join(folder: shared, create: false, displayName: "Christian")
        let id = try XCTUnwrap(joined.documents.first(where: { $0.reference.relativePath == "first.md" })?.id)
        _ = await joined.openDocument(id: id)
        let binding = base.appendingPathComponent("joined/workspaces/\(try XCTUnwrap(joined.workspaceID).uuidString)/workspace-bindings.json")
        let before = try Data(contentsOf: binding)
        await joined.reconnectDocument(id: id, relativePath: "nested/second.md")
        XCTAssertNotNil(joined.error)
        XCTAssertEqual(try Data(contentsOf: binding), before)
        let reopened = await joined.openDocument(id: id)
        XCTAssertEqual(reopened?.lastPathComponent, "first.md")
        await joined.stopWatching(); await creator.stopWatching()
    }

    @MainActor func testEmptyRestoreAllowsUnrelatedSoloOriginalSave() async throws {
        _ = NSApplication.shared
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.restore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true
        model.load(shared.appendingPathComponent("first.md"))
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        model.text = "Solo change.\n"
        XCTAssertTrue(model.save())
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("first.md")), "Solo change.\n")
    }

    @MainActor func testSoloMonitorResumesWhenStartupVerificationFinishesAfterOpen() async throws {
        _ = NSApplication.shared
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true
        let source = shared.appendingPathComponent("first.md")
        model.load(source)
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        await c.restore()
        try Data("External solo change.\n".utf8).write(to: source, options: .atomic)
        for _ in 0..<150 where model.text != "External solo change.\n" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.text, "External solo change.\n")
    }

    @MainActor func testVerifiedUniqueRenameUpdatesBothBindingsAndCanOpenSelectSave() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let id = try XCTUnwrap(c.documents.first?.id), workspace = try XCTUnwrap(c.workspaceID)
        let moved = shared.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: shared.appendingPathComponent("first.md"), to: moved)
        await c.refresh()
        XCTAssertEqual(c.documents.first?.reference.relativePath, "moved.md")
        XCTAssertTrue(c.candidates.contains("moved.md")); XCTAssertFalse(c.candidates.contains("first.md"))
        let opened = await c.openDocument(id: id)
        XCTAssertEqual(opened?.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
        c.selectDocument(url: opened)
        let document = try XCTUnwrap(c.currentDocument)
        XCTAssertEqual(document.relativePath, "moved.md")
        let replica = CollaborationReplicaStore(localRoot: local.appendingPathComponent("workspaces/\(workspace.uuidString)"), sharedRoot: shared, workspaceID: workspace)
        XCTAssertEqual(try replica.document(id: id), document)
        c.sourceSavingEnabled = true
        let saved = try await c.save(document: document, baseline: DocumentSnapshot(url: moved), draft: "Renamed and saved.\n")
        XCTAssertEqual(saved.localApply, .applied)
        XCTAssertEqual(try String(contentsOf: moved), "Renamed and saved.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("first.md").path))
        await c.stopWatching()
    }
    @MainActor func testMissingOriginalKeepsReviewAndOffersFreshExplicitReconnectCandidates() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let id = try XCTUnwrap(c.documents.first?.id), previousState = c.state
        let copy = shared.appendingPathComponent("same-content-copy.md")
        try Data("# First\n".utf8).write(to: copy)
        try FileManager.default.removeItem(at: shared.appendingPathComponent("first.md"))
        await c.refresh()
        XCTAssertEqual(c.status, .needsReconnection); XCTAssertEqual(c.state, previousState)
        XCTAssertTrue(c.candidates.contains("same-content-copy.md")); XCTAssertFalse(c.candidates.contains("first.md"))
        XCTAssertEqual(c.documents.first?.reference.relativePath, "first.md"); XCTAssertNil(c.documents.first?.url)
        let guessed = await c.openDocument(id: id); XCTAssertNil(guessed)
        await c.reconnectDocument(id: id, relativePath: "same-content-copy.md")
        let reconnected = await c.openDocument(id: id)
        XCTAssertEqual(reconnected?.resolvingSymlinksInPath(), copy.resolvingSymlinksInPath())
        c.selectDocument(url: reconnected)
        XCTAssertEqual(c.currentDocument?.documentID, id)
        await c.stopWatching()
    }

    @MainActor func testOverlappingRefreshCallersWaitForAppliedSnapshot() async throws {
        let (_, shared, local) = try fixture()
        let c = CollaborationCoordinator(enabled: true, localRoot: local)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let first = Task { @MainActor in
            await c.refresh()
            XCTAssertFalse(c.busy, "Awaited refresh must finish the requested scan before returning")
        }
        let second = Task { @MainActor in
            await c.refresh()
            XCTAssertFalse(c.busy, "Overlapping awaited refresh must not return before the rescan is applied")
        }
        await first.value; await second.value
        await c.stopWatching()
    }

}
