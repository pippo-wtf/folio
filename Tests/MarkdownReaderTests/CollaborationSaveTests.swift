import XCTest
import AppKit
import WebKit
import ReaderCore
@testable import MarkdownReader

final class CollaborationSaveTests: XCTestCase {
    @MainActor func fixture(bytes: Data = Data("# First\r\n".utf8), limits: CollaborationLimits = .pilot, leavePrompt: @escaping @MainActor (String) -> NSApplication.ModalResponse = { _ in .alertThirdButtonReturn }, saveDestination: (@MainActor (String) -> URL?)? = nil) async throws -> (CollaborationCoordinator, ReaderModel, NSTextView, URL, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = root.appendingPathComponent("shared"), local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let url = shared.appendingPathComponent("first.md"); try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let c = CollaborationCoordinator(enabled: true, localRoot: local, limits: limits)
        await c.join(folder: shared, create: true, displayName: "Philip")
        await c.registerDocument(relativePath: "first.md")
        let model = ReaderModel(collaboration: c, leavePrompt: leavePrompt, saveDestination: saveDestination, pasteboardWriter: { _ in XCTFail("Saving must not write clipboard"); return false })
        model.recoveryStartupReady = true; model.load(url)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        model.writing = true
        let editor = NSTextView(); editor.string = model.text; model.editor = editor
        return (c, model, editor, url, root)
    }
    @MainActor func save(_ model: ReaderModel) async -> Bool {
        await withCheckedContinuation { reply in model.requestSharedSave { reply.resume(returning: $0) } }
    }
    @MainActor func testPilotDisabledKeepsDraftAndSource() async throws {
        let (c, m, editor, url, _) = try await fixture(); editor.string = "draft\r\n"
        let saved = await save(m)
        XCTAssertFalse(saved); XCTAssertEqual(try Data(contentsOf: url), Data("# First\r\n".utf8))
        await c.stopWatching()
    }
    @MainActor func testActualSourceEditorSavePreservesUTF16BOMCRLFAndSentinel() async throws {
        let original = "# First\r\n<!-- sentinel -->\r\n😀\r\n"
        let bytes = Data([0xff, 0xfe]) + original.data(using: .utf16LittleEndian)!
        let (c, m, editor, url, _) = try await fixture(bytes: bytes)
        c.sourceSavingEnabled = true; editor.string = original.replacingOccurrences(of: "First", with: "Changed")
        XCTAssertEqual(m.text, original)
        let saved = await save(m)
        XCTAssertTrue(saved); XCTAssertFalse(m.dirty)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xff, 0xfe]) + editor.string.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(c.events.count, 1); XCTAssertEqual(c.events.first?.authorName, "Philip")
        XCTAssertEqual(c.lastSourceSave?.localApply, .applied)
        await c.stopWatching()
    }
    @MainActor func testSameSizeSameTimeExternalChangePreservesDraftAndExportsObservedBytes() async throws {
        let (c, m, editor, url, root) = try await fixture()
        c.sourceSavingEnabled = true; editor.string = "my draft\r\n"; m.sourceEditorDidChange(editor.string)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let external = Data("# Other\r\n".utf8); try external.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: url.path)
        await c.refresh()
        XCTAssertEqual(m.text, editor.string); XCTAssertEqual(m.baseline, "# First\r\n")
        let saved = await save(m); XCTAssertFalse(saved); XCTAssertTrue(m.dirty)
        XCTAssertEqual(try Data(contentsOf: url), external)
        let doc = try XCTUnwrap(c.currentDocument)
        let output = root.appendingPathComponent("recovery")
        try await c.exportSourceRecovery(document: doc, to: output)
        let files = try FileManager.default.subpathsOfDirectory(atPath: output.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("observed-") || $0.contains("observed-") })
        await c.stopWatching()
    }
    @MainActor func testMarkedSourceWaitsThenCompletesAndStaleDocumentCancels() async throws {
        let (c, m, editor, url, _) = try await fixture(); c.sourceSavingEnabled = true
        editor.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0), replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        var reply: Bool?
        m.requestSharedSave { reply = $0 }
        XCTAssertNil(reply); XCTAssertTrue(m.sharedSaveBusy)
        m.documentID = UUID()
        XCTAssertEqual(reply, false)
        editor.unmarkText(); m.sourceEditorPostChange(editor); await Task.yield()
        XCTAssertEqual(try Data(contentsOf: url), Data("# First\r\n".utf8))
        await c.stopWatching()
    }
    @MainActor func testNewerDraftDuringSaveNeverLeavesOrClearsIt() async throws {
        let (c, m, editor, _, _) = try await fixture(); c.sourceSavingEnabled = true
        editor.string = "first draft\r\n"
        var reply: Bool?
        m.requestSharedSave { reply = $0 }
        editor.string = "newer draft\r\n"; m.sourceEditorDidChange(editor.string)
        for _ in 0..<300 where reply == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reply, false); XCTAssertEqual(m.text, "newer draft\r\n"); XCTAssertTrue(m.dirty)
        await c.stopWatching()
    }
    @MainActor func testPrivateCopyRequiresAbsentDestinationAndNeverInheritsIdentity() async throws {
        let (c, m, editor, url, root) = try await fixture(); editor.string = "copy\r\n"
        let target = root.appendingPathComponent("private.md")
        let copied = await withCheckedContinuation { reply in m.requestSharedSave(asCopy: true, destination: target) { reply.resume(returning: $0) } }
        XCTAssertTrue(copied); XCTAssertNil(c.currentDocument); XCTAssertEqual(try String(contentsOf: target), "copy\r\n")
        XCTAssertEqual(try Data(contentsOf: url), Data("# First\r\n".utf8)); XCTAssertTrue(c.events.isEmpty)
        let second = await withCheckedContinuation { reply in m.requestSharedSave(asCopy: true, destination: target) { reply.resume(returning: $0) } }
        XCTAssertFalse(second)
        await c.stopWatching()
    }
    @MainActor func testActualNewOpenAndWelcomeContinueOnlyAfterCompletedSave() async throws {
        for action in 0..<3 {
            let (c, m, editor, url, root) = try await fixture(leavePrompt: { _ in .alertFirstButtonReturn })
            c.sourceSavingEnabled = true; editor.string = "saved before leaving\r\n"; m.sourceEditorDidChange(editor.string)
            let next = root.appendingPathComponent("next.md"); try Data("Next\n".utf8).write(to: next)
            switch action { case 0: m.newDocument(); case 1: m.load(next); default: m.showWelcome() }
            XCTAssertEqual(m.fileURL, url); XCTAssertTrue(m.sharedSaveBusy)
            for _ in 0..<300 where m.sharedSaveBusy || m.loading { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(try String(contentsOf: url), "saved before leaving\r\n")
            switch action { case 0: XCTAssertNil(m.fileURL); XCTAssertEqual(m.title, "Untitled"); case 1: XCTAssertEqual(m.fileURL, next); default: XCTAssertNil(m.fileURL); XCTAssertEqual(m.title, "Folio") }
            await c.stopWatching()
        }
    }
    @MainActor func testActualQuitReturnsLaterAndRepliesOnlyAfterSaved() async throws {
        let (c, m, editor, url, _) = try await fixture(leavePrompt: { _ in .alertFirstButtonReturn })
        c.sourceSavingEnabled = true; editor.string = "quit draft\r\n"; m.sourceEditorDidChange(editor.string)
        let delegate = AppDelegate(); delegate.readerModel = m
        var reply: Bool?; delegate.terminationReply = { _, result in reply = result }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertNil(reply)
        for _ in 0..<300 where reply == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reply, true); XCTAssertEqual(try String(contentsOf: url), "quit draft\r\n")
        await c.stopWatching()
    }
    @MainActor func testFailedLeaveRetainsDocumentAndNeverContinues() async throws {
        let (c, m, editor, url, _) = try await fixture(leavePrompt: { _ in .alertFirstButtonReturn })
        c.sourceSavingEnabled = true; editor.string = "retained draft\r\n"; m.sourceEditorDidChange(editor.string)
        try Data("External\r\n".utf8).write(to: url, options: .atomic)
        m.newDocument()
        for _ in 0..<300 where m.sharedSaveBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.fileURL, url); XCTAssertEqual(m.text, "retained draft\r\n"); XCTAssertTrue(m.dirty)
        await c.stopWatching()
    }
    @MainActor func testPendingRemoteSourceSnapshotBlocksOnlyItsDocument() async throws {
        let (c, m, _, url, root) = try await fixture(); c.sourceSavingEnabled = true
        let document = try XCTUnwrap(c.currentDocument)
        let missing = CollaborationSnapshotID.hash(Data("Missing\n".utf8))
        let actor = try XCTUnwrap(c.profile)
        let event = CollaborationEvent(workspaceID: document.workspaceID, documentID: document.documentID, participantID: UUID(), deviceID: UUID(), authorName: "Christian", rawSourceRevision: CollaborationSnapshotID.hash(try Data(contentsOf: url)), payload: .sourceProposal(baseRevision: CollaborationSnapshotID.hash(try Data(contentsOf: url)), proposedRevision: missing, triggerEventID: nil))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent("Folio Review/events"), withIntermediateDirectories: true)
        try CollaborationIO.encode(event).write(to: url.deletingLastPathComponent().appendingPathComponent("Folio Review/events/\(event.id.uuidString).json"))
        let other = root.appendingPathComponent("shared/other.md"); try Data("Other\n".utf8).write(to: other)
        await c.registerDocument(relativePath: "other.md"); await c.refresh()
        do { _ = try await c.save(document: document, baseline: try XCTUnwrap(m.snapshot), draft: "Blocked\n"); XCTFail("pending dependency must block") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("# First\r\n".utf8))
        let otherDoc = try XCTUnwrap(c.documents.first { $0.reference.relativePath == "other.md" }?.reference)
        let outcome = try await c.save(document: otherDoc, baseline: DocumentSnapshot(url: other), draft: "Changed\n")
        XCTAssertEqual(outcome.localApply, .applied); XCTAssertEqual(actor.participantID, c.profile?.participantID)
        await c.stopWatching()
    }

    @MainActor func testCapacityFailurePreventsSourceMutationAndKeepsDraft() async throws {
        var limits = CollaborationLimits.pilot; limits.snapshots = 1
        let (c, m, editor, url, _) = try await fixture(limits: limits)
        c.sourceSavingEnabled = true; editor.string = "capacity draft\r\n"
        let saved = await save(m)
        XCTAssertFalse(saved); XCTAssertEqual(m.text, "capacity draft\r\n"); XCTAssertTrue(m.dirty)
        XCTAssertEqual(try Data(contentsOf: url), Data("# First\r\n".utf8)); XCTAssertTrue(c.events.isEmpty)
        await c.stopWatching()
    }
    @MainActor func testFailedReadyOutboxNeverReportsSuccessOrChangesSource() async throws {
        let (c, m, editor, url, root) = try await fixture()
        c.sourceSavingEnabled = true; editor.string = "outbox draft\r\n"
        let ready = root.appendingPathComponent("local/workspaces/\(try XCTUnwrap(c.workspaceID).uuidString)/ready")
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ready.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ready.path) }
        let saved = await save(m)
        XCTAssertFalse(saved); XCTAssertNil(c.lastSourceSave)
        XCTAssertEqual(m.text, "outbox draft\r\n"); XCTAssertTrue(m.dirty)
        XCTAssertEqual(try Data(contentsOf: url), Data("# First\r\n".utf8))
        await c.stopWatching()
    }
    @MainActor func testRegisteredSaveAsTargetIsGuardedAndOtherRegisteredTargetKept() async throws {
        let (c, m, editor, url, root) = try await fixture(); c.sourceSavingEnabled = true; editor.string = "same target\r\n"
        let same: Bool = await withCheckedContinuation { reply in m.requestSharedSave(asCopy: true, destination: url) { reply.resume(returning: $0) } }
        XCTAssertTrue(same); XCTAssertEqual(c.events.count, 1)
        let other = root.appendingPathComponent("shared/other.md"); try Data("Other\n".utf8).write(to: other)
        await c.registerDocument(relativePath: "other.md")
        editor.string = "cannot overwrite\r\n"
        let blocked: Bool = await withCheckedContinuation { reply in m.requestSharedSave(asCopy: true, destination: other) { reply.resume(returning: $0) } }
        XCTAssertFalse(blocked); XCTAssertEqual(try String(contentsOf: other), "Other\n")
        await c.stopWatching()
    }
    @MainActor func testCleanReloadAcknowledgesBufferedNativeDraftBeforeAnyReload() async throws {
        let (c, m, editor, url, _) = try await fixture()
        editor.string = "buffered native draft\r\n"
        try Data("external\r\n".utf8).write(to: url, options: .atomic)
        m.reloadSharedSource()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(m.text, "buffered native draft\r\n"); XCTAssertEqual(editor.string, m.text)
        XCTAssertEqual(m.baseline, "# First\r\n"); XCTAssertTrue(m.dirty)
        await c.stopWatching()
    }

    @MainActor func testActualSaveCommandUsesBufferedWKWebViewSourceWithoutClipboard() async throws {
        let (c, m, _, url, _) = try await fixture(bytes: Data("First.\r\n\r\n<!-- sentinel -->\r\n".utf8))
        c.sourceSavingEnabled = true; m.writing = false; m.editingEnabled = true
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let bridge = CopyContentTests.Bridge(m); config.userContentController.add(bridge, name: "folio")
        let view = FolioWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), configuration: config); m.webView = view
        defer { config.userContentController.removeScriptMessageHandler(forName: "folio") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.js"), encoding: .utf8).replacingOccurrences(of: "</script", with: #"<\/script"#)
        view.loadHTMLString("<html><body><main id='document'></main><script>\(js)</script></body></html>", baseURL: nil)
        for _ in 0..<300 where !bridge.messages.contains(where: { $0["type"] as? String == "outline" }) { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await view.evaluateJavaScript("document.querySelector('.edit-passage p').textContent='Buffered current.'")
        m.saveCommand()
        for _ in 0..<300 where m.sharedSaveBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(m.text.hasPrefix("Buffered current.\r\n")); XCTAssertFalse(m.dirty)
        XCTAssertEqual(try Data(contentsOf: url), Data(m.text.utf8)); XCTAssertTrue(m.text.contains("<!-- sentinel -->\r\n"))
        XCTAssertEqual(c.lastSourceSave?.localApply, .applied)
        await c.stopWatching()
    }
    @MainActor func testAllSourceHeadsResolutionAndLateBranchReopensConflictWithIntendedOnlyReceipt() async throws {
        let (c, m, editor, url, root) = try await fixture(); c.sourceSavingEnabled = true
        let original = try Data(contentsOf: url), document = try XCTUnwrap(c.currentDocument)
        editor.string = "Version A\r\n"; let savedA = await save(m); XCTAssertTrue(savedA)
        func receive(_ bytes: Data) throws -> UUID {
            let hash = CollaborationSnapshotID.hash(bytes)
            let event = CollaborationEvent(workspaceID: document.workspaceID, documentID: document.documentID, participantID: UUID(), deviceID: UUID(), authorName: "Christian", rawSourceRevision: CollaborationSnapshotID.hash(original), displayTime: Date(timeIntervalSince1970: 1), payload: .sourceProposal(baseRevision: CollaborationSnapshotID.hash(original), proposedRevision: hash, triggerEventID: nil))
            let meta = url.deletingLastPathComponent().appendingPathComponent("Folio Review")
            try CollaborationIO.immutable(bytes, at: meta.appendingPathComponent("snapshots/\(hash).bin"))
            try CollaborationIO.immutable(CollaborationIO.encode(event), at: meta.appendingPathComponent("events/\(event.id.uuidString).json"))
            return event.id
        }
        let remote = try receive(Data("Version B\r\n".utf8)); await c.refresh(); await c.compareSource(document: document)
        let comparison = try XCTUnwrap(c.sourceComparison)
        XCTAssertEqual(comparison.heads.count, 2); XCTAssertTrue(comparison.pending.isEmpty)
        XCTAssertEqual(comparison.versions.first { $0.id == remote }?.receipt, "intendedOnly")
        let result = try await c.resolveSource(document: document, expectedCurrent: Data(contentsOf: url), chosen: Data("Version B\r\n".utf8), superseding: comparison.heads)
        XCTAssertEqual(result.localApply, .applied)
        _ = try receive(Data("Late C\r\n".utf8)); await c.refresh()
        XCTAssertEqual(c.state?.sourceHeads[document.documentID]?.count, 2)
        let output = root.appendingPathComponent("all-heads")
        try await c.exportSourceRecovery(document: document, to: output)
        XCTAssertTrue(try FileManager.default.subpathsOfDirectory(atPath: output.path).contains("coverage.json"))
        do { try await c.exportSourceRecovery(document: document, to: output); XCTFail("Existing output must not be overwritten") } catch {}
        XCTAssertFalse(c.sourceSavingEnabled)
        XCTAssertEqual(try String(contentsOf: url), "Version B\r\n")
        await c.stopWatching()
    }
    @MainActor func testReviewRenderedBufferedDraftBlocksLeave() async throws {
        let (c, m, _, url, _) = try await fixture(bytes: Data("First.\r\n\r\n<!-- sentinel -->\r\n".utf8))
        c.sourceSavingEnabled = true; m.writing = false; m.editingEnabled = true
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let bridge = CopyContentTests.Bridge(m); config.userContentController.add(bridge, name: "folio")
        let view = FolioWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), configuration: config); m.webView = view
        defer { config.userContentController.removeScriptMessageHandler(forName: "folio") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.js"), encoding: .utf8).replacingOccurrences(of: "</script", with: #"<\/script"#)
        view.loadHTMLString("<html><body><main id='document'></main><script>\(js)</script></body></html>", baseURL: nil)
        for _ in 0..<300 where !bridge.messages.contains(where: { $0["type"] as? String == "outline" }) { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await view.evaluateJavaScript("document.querySelector('.edit-passage p').textContent='Buffered current.'")
        XCTAssertFalse(m.dirty)
        m.newDocument()
        XCTAssertEqual(m.fileURL, url, "Buffered rendered draft must prevent leaving without acknowledgement")
        XCTAssertFalse(m.title == "Untitled")
        await c.stopWatching()
    }
    @MainActor func testReviewRenderedCompositionBlocksQuit() async throws {
        let (c, m, _, _, _) = try await fixture(bytes: Data("First.\r\n\r\n<!-- sentinel -->\r\n".utf8))
        c.sourceSavingEnabled = true; m.writing = false; m.editingEnabled = true
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let bridge = CopyContentTests.Bridge(m); config.userContentController.add(bridge, name: "folio")
        let view = FolioWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), configuration: config); m.webView = view
        defer { config.userContentController.removeScriptMessageHandler(forName: "folio") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.js"), encoding: .utf8).replacingOccurrences(of: "</script", with: #"<\/script"#)
        view.loadHTMLString("<html><body><main id='document'></main><script>\(js)</script></body></html>", baseURL: nil)
        for _ in 0..<300 where !bridge.messages.contains(where: { $0["type"] as? String == "outline" }) { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await view.evaluateJavaScript("document.getElementById('document').dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));document.querySelector('.edit-passage p').textContent='Composing draft.'")
        XCTAssertFalse(m.dirty)
        let delegate = AppDelegate(); delegate.readerModel = m; delegate.terminationReply = { _, _ in }
        XCTAssertNotEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow, "Active rendered composition must not allow immediate quit")
        m.cancelCopyContent(); await c.stopWatching()
    }

    @MainActor func testUntitledStagingSaveCommandRequestsNewPrivateDestination() async throws {
        let (c, m, editor, _, root) = try await fixture()
        m.newDocument(); m.writing = true; editor.string = "Untitled draft\r\n"; m.editor = editor
        let target = root.appendingPathComponent("untitled.md")
        var requested = false
        let fresh = ReaderModel(collaboration: c, saveDestination: { _ in requested = true; return target })
        fresh.text = "Untitled draft\r\n"; fresh.baseline = ""; fresh.writing = true; fresh.editor = editor
        fresh.saveCommand()
        for _ in 0..<300 where fresh.sharedSaveBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(requested); XCTAssertEqual(fresh.fileURL, target); XCTAssertFalse(fresh.dirty)
        XCTAssertEqual(try String(contentsOf: target), "Untitled draft\r\n"); XCTAssertNil(c.currentDocument)
        await c.stopWatching()
    }
    @MainActor func testReviewExportWithPendingMissingBaseStillExportsAvailableEvidence() async throws {
        let (c, _, _, url, root) = try await fixture()
        let document = try XCTUnwrap(c.currentDocument)
        let bytes = Data("Available proposal\n".utf8)
        let hash = CollaborationSnapshotID.hash(bytes)
        let absentBase = CollaborationSnapshotID.hash(Data("Missing base\n".utf8))
        let event = CollaborationEvent(workspaceID: document.workspaceID, documentID: document.documentID, participantID: UUID(), deviceID: UUID(), authorName: "Christian", rawSourceRevision: absentBase, payload: .sourceProposal(baseRevision: absentBase, proposedRevision: hash, triggerEventID: nil))
        let meta = url.deletingLastPathComponent().appendingPathComponent("Folio Review")
        try CollaborationIO.immutable(bytes, at: meta.appendingPathComponent("snapshots/\(hash).bin"))
        try CollaborationIO.immutable(CollaborationIO.encode(event), at: meta.appendingPathComponent("events/\(event.id.uuidString).json"))
        await c.refresh()
        let output = root.appendingPathComponent("partial-recovery")
        do { try await c.exportSourceRecovery(document: document, to: output) }
        catch { XCTFail("Export must retain available evidence with missing dependency coverage: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("coverage.json").path))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("\(event.id.uuidString)/proposed-\(hash).bin")), bytes)
        let coverage = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("coverage.json"))) as? [String: Any])
        XCTAssertEqual(coverage["complete"] as? Bool, false)
        XCTAssertEqual((coverage["missingSnapshotHashesByEvent"] as? [String: [String]])?[event.id.uuidString], [absentBase])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix("observed-") })
        await c.stopWatching()
    }

    @MainActor func renderedFixture(leavePrompt: @escaping @MainActor (String) -> NSApplication.ModalResponse = { _ in .alertThirdButtonReturn }) async throws -> (CollaborationCoordinator, ReaderModel, WKWebView, URL, URL) {
        let (c, m, _, url, root) = try await fixture(bytes: Data("First.\r\n\r\n<!-- sentinel -->\r\n".utf8), leavePrompt: leavePrompt)
        c.sourceSavingEnabled = true; m.writing = false; m.editingEnabled = true
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let bridge = CopyContentTests.Bridge(m); config.userContentController.add(bridge, name: "folio")
        let view = FolioWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), configuration: config); m.webView = view
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try String(contentsOf: repo.appendingPathComponent("Sources/MarkdownReader/Resources/reader.js"), encoding: .utf8).replacingOccurrences(of: "</script", with: #"<\/script"#)
        view.loadHTMLString("<html><body><main id='document'></main><script>\(js)</script></body></html>", baseURL: nil)
        for _ in 0..<300 where !bridge.messages.contains(where: { $0["type"] as? String == "outline" }) { try await Task.sleep(for: .milliseconds(10)) }
        return (c, m, view, url, root)
    }
    @MainActor func testRenderedBufferedNewOpenWelcomeAndQuitSaveBeforeLeaving() async throws {
        for action in 0..<4 {
            let (c, m, view, url, root) = try await renderedFixture(leavePrompt: { _ in .alertFirstButtonReturn })
            defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
            _ = try await view.evaluateJavaScript("document.querySelector('.edit-passage p').textContent='Buffered leave.'")
            let next = root.appendingPathComponent("next.md"); try Data("Next\n".utf8).write(to: next)
            var quitReply: Bool?
            let delegate = AppDelegate(); delegate.readerModel = m; delegate.terminationReply = { _, answer in quitReply = answer }
            switch action { case 0: m.newDocument(); case 1: m.load(next); case 2: m.showWelcome(); default: XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater) }
            XCTAssertEqual(m.fileURL, url)
            for _ in 0..<500 where m.leaveSavePending || m.sharedSaveBusy || m.loading || (action == 3 && quitReply == nil) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(try String(contentsOf: url).hasPrefix("Buffered leave.\r\n"))
            switch action { case 0: XCTAssertEqual(m.title, "Untitled"); XCTAssertNil(m.fileURL); case 1: XCTAssertEqual(m.fileURL, next); case 2: XCTAssertEqual(m.title, "Folio"); XCTAssertNil(m.fileURL); default: XCTAssertEqual(quitReply, true) }
            await c.stopWatching()
        }
    }
    @MainActor func testSecondEditorAcknowledgementKeepsNewerBufferedDOMDirty() async throws {
        let (c, m, view, url, _) = try await renderedFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("document.querySelector('.edit-passage p').textContent='First draft.'")
        var answer: Bool?; m.requestSharedSave { answer = $0 }
        _ = try await view.evaluateJavaScript("document.querySelector('.edit-passage p').textContent='Newer buffered draft.'")
        for _ in 0..<500 where answer == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(answer, false); XCTAssertTrue(m.text.hasPrefix("Newer buffered draft.")); XCTAssertTrue(m.dirty)
        XCTAssertTrue(try String(contentsOf: url).hasPrefix("First draft."))
        await c.stopWatching()
    }
    @MainActor func testOwnTaskApplicationRereadUsesLocalJournalAndNoUnknownWarning() async throws {
        let (c, m, view, url, _) = try await renderedFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        let doc = try XCTUnwrap(c.currentDocument), base = try XCTUnwrap(m.snapshot)
        let proposed = base.text.replacingOccurrences(of: "First.", with: "Changed by local task.")
        let outcome = try await c.save(document: doc, baseline: base, draft: proposed)
        XCTAssertEqual(outcome.localApply, .applied)
        XCTAssertFalse(m.error?.contains("Author unknown") == true)
        m.reloadSharedSource(journalKind: .renderedEdit, expectedBytes: try base.encoded(proposed))
        for _ in 0..<400 where m.text != proposed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.text, proposed); XCTAssertFalse(m.dirty); XCTAssertFalse(m.error?.contains("Author unknown") == true)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("\(BuildChannel.storage)/EditJournal")
        let journal = try EditJournalStore(directory: directory).load(for: url.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(journal.events.last(where: { $0.replacement != nil })?.kind, .renderedEdit)
        await c.stopWatching()
    }

    @MainActor func testReloadSecondAcknowledgementKeepsBufferedDOMDuringWorkerRead() async throws {
        let (c, m, view, url, _) = try await renderedFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        let baseline = m.baseline
        try Data("External version.\r\n".utf8).write(to: url, options: .atomic)
        m.reloadSharedSource()
        _ = try await view.evaluateJavaScript("document.querySelector('.edit-passage p').textContent='Buffered during reload.'")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(m.text.hasPrefix("Buffered during reload.")); XCTAssertEqual(m.baseline, baseline); XCTAssertTrue(m.dirty)
        XCTAssertEqual(try String(contentsOf: url), "External version.\r\n")
        await c.stopWatching()
    }

}
