import XCTest
import AppKit
import Combine
import WebKit
import ReaderCore
@testable import MarkdownReader

final class CollaborationReviewTests: XCTestCase {
    @MainActor func fixture() async throws -> (CollaborationCoordinator, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let share = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let source = share.appendingPathComponent("review.md")
        try Data("# Quote\n\n- [ ] Review this\n".utf8).write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let c = CollaborationCoordinator(enabled: true, localRoot: root.appendingPathComponent("local"))
        await c.join(folder: share, create: true, displayName: "Alex")
        await c.registerDocument(relativePath: "review.md")
        c.selectDocument(url: source)
        return (c, source, root)
    }
    @MainActor func testExplicitSharedMarkHasNewIdentityAndStaleDocumentCannotAuthor() async throws {
        let (c, _, _) = try await fixture()
        let doc = try XCTUnwrap(c.currentDocument)
        let raw = CollaborationSnapshotID.hash(try XCTUnwrap(c.sourceObservations[doc.documentID]))
        let anchor = SharedAnchor(start: 0, quote: "Quote", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: HighlightStore.revision("# Quote\n\n- [ ] Review this\n"))
        let first = await c.addSharedHighlight(document: doc, anchor: anchor)
        let second = await c.addSharedHighlight(document: doc, anchor: anchor)
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second)
        XCTAssertEqual(c.state?.annotations.count, 2)
        c.selectDocument(url: nil)
        let stale = await c.addSharedHighlight(document: doc, anchor: anchor)
        XCTAssertNil(stale); XCTAssertEqual(c.state?.annotations.count, 2)
        await c.stopWatching()
    }
    @MainActor func testConcurrentRepliesSurviveAndResolveDoesNotDeleteMessages() async throws {
        let (a, source, root) = try await fixture()
        let doc = try XCTUnwrap(a.currentDocument)
        let raw = CollaborationSnapshotID.hash(try XCTUnwrap(a.sourceObservations[doc.documentID]))
        let anchor = SharedAnchor(start: 0, quote: "Quote", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: raw)
        let added = await a.addSharedHighlight(document: doc, anchor: anchor)
        let thread = try XCTUnwrap(added)
        let b = CollaborationCoordinator(enabled: true, localRoot: root.appendingPathComponent("other"))
        await b.join(folder: source.deletingLastPathComponent(), create: false, displayName: "Alex")
        _ = await b.openDocument(id: doc.documentID); b.selectDocument(url: source)
        let one = await a.addSharedMessage(document: doc, threadID: thread, replyTo: nil, text: "A reply")
        let two = await b.addSharedMessage(document: doc, threadID: thread, replyTo: nil, text: "B reply")
        XCTAssertNotNil(one); XCTAssertNotNil(two)
        await a.refresh()
        XCTAssertEqual(a.sharedMessages(document: doc, threadID: thread).count, 2)
        let resolved = await a.setSharedThread(document: doc, threadID: thread, resolved: true)
        XCTAssertTrue(resolved)
        XCTAssertEqual(a.sharedMessages(document: doc, threadID: thread).count, 2)
        XCTAssertTrue(a.sharedThreadResolved(threadID: thread))
        await a.stopWatching(); await b.stopWatching()
    }
    @MainActor func testPrivateModeAndStaleSelectionGuard() {
        let review = SharedReviewController()
        XCTAssertEqual(review.mode, .privateReview)
        let doc = UUID()
        review.bind(document: doc, token: "current")
        XCTAssertTrue(review.accepts(document: doc, token: "current"))
        XCTAssertFalse(review.accepts(document: doc, token: "previous"))
        review.bind(document: UUID(), token: "new")
        XCTAssertFalse(review.accepts(document: doc, token: "current"))
    }
    @MainActor func testTokenRotationCancelsBusyWithoutLosingComment() {
        let review = SharedReviewController(), document = UUID()
        review.bind(document: document, token: "old")
        review.comment = "Composing a reply"; review.busy = true
        review.bind(document: document, token: "new")
        XCTAssertFalse(review.busy)
        XCTAssertEqual(review.comment, "Composing a reply")
        XCTAssertFalse(review.accepts(document: document, token: "old"))
    }
    @MainActor func testSwitchingThreadsPreservesSeparateCommentDrafts() {
        let review = SharedReviewController(), first = UUID(), second = UUID()
        review.selectedThread = first; review.comment = "First draft"
        review.selectedThread = second
        XCTAssertEqual(review.comment, "")
        review.comment = "Second draft"; review.selectedThread = first
        XCTAssertEqual(review.comment, "First draft")
    }
    @MainActor func testStaleTaskFailureCannotChangeNewDocumentReview() async throws {
        _ = NSApplication.shared
        let (c, _, _) = try await fixture()
        let model = ReaderModel(collaboration: c)
        model.refreshSharedReview()
        model.setSharedTask(UUID(), state: .done)
        model.documentID = UUID(); c.selectDocument(url: nil); model.refreshSharedReview()
        model.sharedReview.issue = "New document issue"
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.sharedReview.issue, "New document issue")
        XCTAssertFalse(model.sharedReview.busy)
        await c.stopWatching()
    }

    @MainActor func testSuccessfulSendClearsInactiveThreadDraft() async throws {
        _ = NSApplication.shared
        let (c, _, _) = try await fixture()
        let doc = try XCTUnwrap(c.currentDocument)
        let raw = CollaborationSnapshotID.hash(try XCTUnwrap(c.sourceObservations[doc.documentID]))
        let anchor = SharedAnchor(start: 0, quote: "Quote", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: raw)
        let firstValue = await c.addSharedHighlight(document: doc, anchor: anchor)
        let secondValue = await c.addSharedHighlight(document: doc, anchor: anchor)
        let first = try XCTUnwrap(firstValue), second = try XCTUnwrap(secondValue)
        let model = ReaderModel(collaboration: c); model.refreshSharedReview()
        model.sharedReview.selectedThread = first; model.sharedReview.comment = "Submitted once"
        model.submitSharedComment(); model.sharedReview.selectedThread = second
        model.sharedReview.comment = "Other thread draft"
        for _ in 0..<200 where model.sharedReview.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(c.sharedMessages(document: doc, threadID: first).count, 1)
        XCTAssertEqual(model.sharedReview.comment, "Other thread draft")
        model.sharedReview.selectedThread = first
        XCTAssertEqual(model.sharedReview.comment, "")
        model.submitSharedComment()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(c.sharedMessages(document: doc, threadID: first).count, 1)
        await c.stopWatching()
    }
    @MainActor func testPrivateShareCleanupWhenSourceBecomesDirtyBetweenReceipts() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await fixture()
        let model = ReaderModel(collaboration: c); model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        let (view, _) = try await CollaborationRendererTests().web(model: model)
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        var first = SavedHighlight(id: UUID().uuidString, start: 0, quote: "Quote", prefix: "", suffix: "")
        var second = SavedHighlight(id: UUID().uuidString, start: 0, quote: "Review this", prefix: "", suffix: "")
        first.revision = HighlightStore.revision(model.text); second.revision = first.revision
        model.marked = [first, second]; model.previewPrivateSharing()
        // A real first durable receipt changes only the same document's draft between awaits.
        // This tests cleanup invariants; the modal sheet may prevent ordinary editing behind it.
        let observation = c.$state.dropFirst().sink { state in
            if state?.annotations.count == 1 { model.text += "Unsaved input during the batch.\n" }
        }
        defer { observation.cancel() }
        model.sharePreviewedPrivateMarks()
        for _ in 0..<300 where c.state?.annotations.isEmpty == true { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.state?.annotations.count, 1)
        XCTAssertTrue(model.dirty)
        XCTAssertFalse(model.sharedReview.busy)
        XCTAssertEqual(model.sharedReview.previewSelected.count, 1)
        XCTAssertTrue(model.sharedReview.showPrivatePreview)
        XCTAssertTrue(model.sharedReview.issue?.contains("Save first") == true)
        await c.stopWatching()
    }

    @MainActor func testEditingModeChangeKeepsPendingCommentBusy() async throws {
        _ = NSApplication.shared
        let (c, _, _) = try await fixture()
        let doc = try XCTUnwrap(c.currentDocument)
        let raw = CollaborationSnapshotID.hash(try XCTUnwrap(c.sourceObservations[doc.documentID]))
        let anchor = SharedAnchor(start: 0, quote: "Quote", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: raw)
        let created = await c.addSharedHighlight(document: doc, anchor: anchor)
        let id = try XCTUnwrap(created)
        let model = ReaderModel(collaboration: c); model.refreshSharedReview()
        model.sharedReview.selectedThread = id; model.sharedReview.comment = "One pending send"
        model.submitSharedComment()
        XCTAssertTrue(model.sharedReview.busy)
        model.editingEnabled.toggle()
        XCTAssertTrue(model.sharedReview.busy)
        model.submitSharedComment()
        for _ in 0..<200 where model.sharedReview.busy { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(c.sharedMessages(document: doc, threadID: id).count, 1)
        XCTAssertFalse(model.sharedReview.busy)
        XCTAssertEqual(model.sharedReview.comment, "")
        await c.stopWatching()
    }

    @MainActor func testActualNativeBridgeSharedCommentAfterCheckboxCreatesComposer() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await fixture()
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        let (view, bridge) = try await CollaborationRendererTests().web(model: model)
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        model.sharedReview.mode = .shared; model.refreshSharedReview(); c.sourceSavingEnabled = true
        _ = try await view.evaluateJavaScript("void 0")
        _ = try await view.evaluateJavaScript("document.querySelector('#document input[type=checkbox]').click(); void 0")
        for _ in 0..<300 where !model.text.contains("[x]") || model.sharedReview.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.text.contains("[x]")); XCTAssertFalse(model.dirty)
        _ = try await view.evaluateJavaScript("window.range=document.createRange(); range.selectNodeContents(document.querySelector('#document h1')); getSelection().removeAllRanges(); getSelection().addRange(range); void 0")
        try await Task.sleep(for: .milliseconds(50))
        let selection = try await view.evaluateJavaScript("Folio.sharedSelection('\(model.reviewRenderToken)')") as? [String: Any]
        XCTAssertEqual(selection?["quote"] as? String, "Quote")
        _ = try await view.evaluateJavaScript("document.querySelectorAll('#highlight-tools button')[1].focus(); document.querySelectorAll('#highlight-tools button')[1].click(); void 0")
        for _ in 0..<300 where c.state?.annotations.isEmpty == true || model.sharedReview.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(bridge.messages.filter { $0["type"] as? String == "sharedSelectionAction" }.count, 1)
        XCTAssertEqual(c.state?.annotations.count, 1, model.sharedReview.issue ?? "No shared annotation and no issue")
        XCTAssertNotNil(model.sharedReview.selectedThread)
        XCTAssertEqual(model.sharedReview.mode, .shared)
        XCTAssertNil(model.sharedReview.issue)
        XCTAssertFalse(model.dirty)
        await c.stopWatching()
    }

    @MainActor func testContextDraftRejectsStaleTokenUnknownThreadAndForeignReply() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await fixture()
        let doc = try XCTUnwrap(c.currentDocument)
        let raw = CollaborationSnapshotID.hash(try XCTUnwrap(c.sourceObservations[doc.documentID]))
        let anchor = SharedAnchor(start: 0, quote: "Quote", prefix: "", suffix: "", rawSourceRevision: raw, decodedSourceRevision: raw)
        let created = await c.addSharedHighlight(document: doc, anchor: anchor)
        let id = try XCTUnwrap(created)
        let otherValue = await c.addSharedHighlight(document: doc, anchor: anchor)
        let other = try XCTUnwrap(otherValue)
        _ = await c.addSharedMessage(document: doc, threadID: other, replyTo: nil, text: "Another discussion")
        let otherMessage = try XCTUnwrap(c.sharedMessages(document: doc, threadID: other).first)
        guard case .commentAdded(_, let foreignReply, _, _) = otherMessage.payload else { return XCTFail("Missing comment") }
        let model = ReaderModel(collaboration: c); model.refreshSharedReview(); model.sharedReview.mode = .shared
        func draft(_ token: String, _ thread: UUID, _ reply: UUID? = nil) {
            var body: [String: Any] = ["type": "reviewCommentDraft", "token": token, "id": thread.uuidString, "text": "Retained draft"]
            if let reply { body["replyTo"] = reply.uuidString }
            model.acceptReviewContextEvent(body)
        }
        draft("stale", id); XCTAssertNil(model.sharedReview.selectedThread)
        draft(model.reviewRenderToken, UUID()); XCTAssertNil(model.sharedReview.selectedThread)
        draft(model.reviewRenderToken, id, UUID()); XCTAssertNil(model.sharedReview.selectedThread)
        draft(model.reviewRenderToken, id, foreignReply); XCTAssertNil(model.sharedReview.selectedThread)
        model.sharedReview.mode = .privateReview
        draft(model.reviewRenderToken, id); XCTAssertNil(model.sharedReview.selectedThread)
        model.sharedReview.mode = .shared
        draft(model.reviewRenderToken, id)
        XCTAssertEqual(model.sharedReview.comment, "Retained draft")
        model.sharedReview.selectedThread = nil
        model.sharedHighlightClicked(id: id.uuidString, token: model.reviewRenderToken)
        XCTAssertEqual(model.sharedReview.comment, "Retained draft")
        let context = model.sharedReviewContext()
        XCTAssertEqual(context["draft"] as? String, "Retained draft")
        let threads = try XCTUnwrap(context["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.count, 2)
        XCTAssertTrue((threads[0]["author"] as? String)?.contains(String(c.profile!.participantID.uuidString.prefix(8))) == true)
        XCTAssertTrue(c.sharedMessages(document: doc, threadID: id).isEmpty)
        let nextSource = source.deletingLastPathComponent().appendingPathComponent("other.md")
        try Data("Another document".utf8).write(to: nextSource)
        await c.registerDocument(relativePath: "other.md"); c.selectDocument(url: nextSource)
        model.refreshSharedReview(); model.sharedReview.mode = .shared
        draft(model.reviewRenderToken, id)
        XCTAssertNil(model.sharedReview.selectedThread, "An existing thread from another document must not receive a draft")
        XCTAssertEqual((model.sharedReviewContext()["threads"] as? [[String: Any]])?.count, 0)
        await c.stopWatching()
    }

    @MainActor func testContextTaskRecoveryReportsFailedJumpAndValidatesApply() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await fixture()
        let doc = try XCTUnwrap(c.currentDocument)
        let bytes = try XCTUnwrap(c.sourceObservations[doc.documentID])
        let text = String(decoding: bytes, as: UTF8.self)
        let offset = try XCTUnwrap((text as NSString).range(of: "[ ]").location == NSNotFound ? nil : (text as NSString).range(of: "[ ]").location + 1)
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: offset, in: text, rawSourceRevision: CollaborationSnapshotID.hash(bytes)))
        let created = await c.registerSharedTask(document: doc, anchor: anchor)
        let id = try XCTUnwrap(created)
        _ = await c.setSharedTask(document: doc, taskID: id, state: .done)
        let model = ReaderModel(collaboration: c); model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        let (view, _) = try await CollaborationRendererTests().web(model: model)
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.openReviewTask=()=>false; void 0")
        model.navigateSharedTask(id)
        for _ in 0..<100 where model.sharedReview.issue == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.sharedReview.issue?.contains("Task passage changed") == true)
        model.sharedReview.issue = nil
        model.acceptReviewContextEvent(["type": "reviewTaskApply", "token": "stale", "id": id.uuidString])
        XCTAssertNil(model.sharedReview.issue)
        model.acceptReviewContextEvent(["type": "reviewTaskApply", "token": model.reviewRenderToken, "id": UUID().uuidString])
        XCTAssertNil(model.sharedReview.issue)
        model.acceptReviewContextEvent(["type": "reviewTaskApply", "token": model.reviewRenderToken, "id": id.uuidString])
        XCTAssertTrue(model.sharedReview.issue?.contains("Markdown update pending") == true)
        await c.stopWatching()
    }

}
