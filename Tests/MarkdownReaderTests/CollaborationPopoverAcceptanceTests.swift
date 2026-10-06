import XCTest
import AppKit
import WebKit
import ReaderCore
@testable import MarkdownReader

final class CollaborationPopoverAcceptanceTests: XCTestCase {
    @MainActor private func fixture() async throws -> (CollaborationCoordinator, URL, URL) {
        let value = try await CollaborationReviewTests().fixture()
        let source = value.1, root = value.2
        let key = source.standardizedFileURL.resolvingSymlinksInPath().path
        let highlightFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(BuildChannel.storage)/Highlights")
            .appendingPathComponent(HighlightStore.revision(key) + ".json")
        // This UUID fixture owns this exact key; never clear another document's marks.
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: highlightFile.path) {
                try FileManager.default.removeItem(at: highlightFile)
            }
            try FileManager.default.removeItem(at: root)
        }
        return value
    }

    @MainActor private func selectHeading(_ view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("window.range=document.createRange(); range.selectNodeContents(document.querySelector('#document h1')); getSelection().removeAllRanges(); getSelection().addRange(range); void 0")
        try await Task.sleep(for: .milliseconds(50))
    }

    // Exercise the exact Keep private action without presenting a blocking modal.
    // The recording bridge intentionally avoids reentering the known-broken alert on RED;
    // the emitted private payload is then passed to the real native persistence method.
    @MainActor func testKeepPrivateOnDirtySharedSelectionPersistsOnlyDraftPrivateMark() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await fixture()
        let original = try Data(contentsOf: source)
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        let (view, bridge) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        model.webView = view; model.ready = true
        model.text += "Unsaved draft.\n"
        model.sharedReview.mode = .shared; model.render()
        _ = try await view.evaluateJavaScript("void 0")
        try await selectHeading(view)
        let rawSelection = try await view.evaluateJavaScript("Folio.sharedSelection('\(model.reviewRenderToken)')")
        let captured = try XCTUnwrap(rawSelection as? [String: Any])
        // Native focus/modal interaction can discard the live DOM range.
        _ = try await view.evaluateJavaScript("getSelection().removeAllRanges(); void 0")
        try await Task.sleep(for: .milliseconds(50))
        model.keepSelectedTextPrivate(captured, token: model.reviewRenderToken)
        _ = try await view.evaluateJavaScript("void 0")
        XCTAssertEqual(model.sharedReview.mode, .privateReview)
        XCTAssertFalse(bridge.messages.contains { $0["type"] as? String == "sharedSelectionAction" })
        let payload = try XCTUnwrap(bridge.messages.last { $0["type"] as? String == "saveHighlights" })
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(payload["highlights"]))
        let records = try JSONDecoder().decode([SavedHighlight].self, from: data)
        model.saveHighlights(records, token: try XCTUnwrap(payload["token"] as? String))
        XCTAssertEqual(model.marked.count, 1)
        XCTAssertEqual(model.marked.first?.quote, "Quote")
        XCTAssertEqual(model.marked.first?.revision, HighlightStore.revision(model.text))
        let store = HighlightStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("\(BuildChannel.storage)/Highlights"))
        let key = source.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(try store.load(for: key), model.marked)
        XCTAssertEqual(try store.events(for: key).last?.draft, true)
        XCTAssertEqual(try store.events(for: key).last?.reviewedRevision, HighlightStore.revision(model.text))
        XCTAssertTrue(model.dirty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(c.state?.annotations.count, 0)
        await c.stopWatching()
    }

    @MainActor func testCapturedPrivateFallbackRejectsStaleTokenAndChangedPassage() async throws {
        let (view, bridge) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('# Quote','','current',[],true,null,false); Folio.setSharedReviewMode('current','shared'); void 0")
        try await selectHeading(view)
        _ = try await view.evaluateJavaScript("window.captured=Folio.sharedSelection('current'); getSelection().removeAllRanges(); void 0")
        let stale = try await view.evaluateJavaScript("Folio.keepSelectionPrivate('old',captured)")
        XCTAssertEqual(stale as? Bool, false)
        _ = try await view.evaluateJavaScript("document.querySelector('#document h1').textContent='Changed'; void 0")
        let changed = try await view.evaluateJavaScript("Folio.keepSelectionPrivate('current',captured)")
        XCTAssertEqual(changed as? Bool, false)
        _ = try await view.evaluateJavaScript("Folio.render('# Quote','','next',[],true,null,false); void 0")
        let rerendered = try await view.evaluateJavaScript("Folio.keepSelectionPrivate('current',captured)")
        XCTAssertEqual(rerendered as? Bool, false)
        XCTAssertFalse(bridge.messages.contains { $0["type"] as? String == "saveHighlights" || $0["type"] as? String == "sharedSelectionAction" })
    }

    // Removing pointerdown cancellation or clearing the range before native async capture
    // must break this test. Synthetic events do not prove physical mouse hit testing.
    @MainActor func testDelayedPointerSequencePreservesSelectionForNativeSharedComment() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await fixture()
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        let (view, bridge) = try await CollaborationRendererTests().web(model: model)
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        model.sharedReview.mode = .shared; model.refreshSharedReview()
        _ = try await view.evaluateJavaScript("void 0")
        try await selectHeading(view)
        let down = try await view.evaluateJavaScript("window.button=document.querySelectorAll('#highlight-tools button')[1]; window.down=new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerType:'mouse',button:0}); button.dispatchEvent(down); ({prevented:down.defaultPrevented,hidden:document.querySelector('#highlight-tools').hidden,selected:getSelection().toString()})") as! [String: Any]
        XCTAssertEqual(down["prevented"] as? Bool, true)
        XCTAssertEqual(down["hidden"] as? Bool, false)
        XCTAssertEqual(down["selected"] as? String, "Quote")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await view.evaluateJavaScript("button.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,pointerType:'mouse',button:0})); button.dispatchEvent(new MouseEvent('click',{bubbles:true,button:0})); void 0")
        for _ in 0..<300 where c.state?.annotations.isEmpty == true || model.sharedReview.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(bridge.messages.filter { $0["type"] as? String == "sharedSelectionAction" }.count, 1)
        XCTAssertEqual(c.state?.annotations.count, 1, model.sharedReview.issue ?? "No annotation")
        XCTAssertNotNil(model.sharedReview.selectedThread)
        XCTAssertNil(model.sharedReview.issue)
        await c.stopWatching()
    }

    // A missing second dirty guard would share text from the obsolete saved revision.
    @MainActor func testDirtyChangeBeforeAsyncSelectionReplyCannotCreateSharedAnnotation() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await fixture()
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        let (view, _) = try await CollaborationRendererTests().web(model: model)
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        try await selectHeading(view)
        model.shareSelectedText(comment: true)
        model.text += "Unsaved draft.\n"
        for _ in 0..<200 where model.sharedReview.issue == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.dirty)
        XCTAssertEqual(c.state?.annotations.count, 0)
        XCTAssertNil(model.sharedReview.selectedThread)
        XCTAssertNotNil(model.sharedReview.issue)
        XCTAssertFalse(model.sharedReview.busy)
        await c.stopWatching()
    }

    // Mode changes must select the private/shared authoring boundary and not reuse a
    // stale renderer token; read/edit transitions must retain that routing contract.
    @MainActor func testPrivateSharedActionsAcrossReadEditRenders() async throws {
        let (view, bridge) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        for editing in [false, true] {
            let token = editing ? "edit" : "read"
            _ = try await view.evaluateJavaScript("Folio.render('# Quote','','\(token)',[],true,null,\(editing)); Folio.setSharedReviewMode('\(token)','shared'); void 0")
            try await selectHeading(view)
            _ = try await view.evaluateJavaScript("Folio.highlightSelection(); void 0")
            let shared = try XCTUnwrap(bridge.messages.last(where: { $0["type"] as? String == "sharedSelectionAction" }))
            XCTAssertEqual(shared["token"] as? String, token)
            XCTAssertEqual(shared["comment"] as? Bool, false)
            _ = try await view.evaluateJavaScript("Folio.setSharedReviewMode('\(token)','private'); document.querySelectorAll('#highlight-tools button')[1].click(); void 0")
            let saved = try XCTUnwrap(bridge.messages.last(where: { $0["type"] as? String == "saveHighlights" }))
            XCTAssertEqual(saved["token"] as? String, token)
            let records = try XCTUnwrap(saved["highlights"] as? [[String: Any]])
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?["quote"] as? String, "Quote")
            XCTAssertEqual(saved["commentID"] as? String, records.first?["id"] as? String)
        }
        XCTAssertEqual(bridge.messages.filter { $0["type"] as? String == "sharedSelectionAction" }.count, 2)
        XCTAssertEqual(bridge.messages.filter { $0["type"] as? String == "saveHighlights" }.count, 2)
    }
}
