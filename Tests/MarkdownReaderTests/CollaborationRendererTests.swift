import XCTest
import AppKit
import WebKit
@testable import MarkdownReader

final class CollaborationRendererTests: XCTestCase {
    @MainActor final class Bridge: NSObject, WKScriptMessageHandler {
        let coordinator: ReaderWebView.Coordinator?
        init(model: ReaderModel? = nil) { coordinator = model.map(ReaderWebView.Coordinator.init) }
        var ready = false
        var messages = [[String: Any]]()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.userContentController(controller, didReceive: message)
            if let value = message.body as? [String: Any] { messages.append(value); if value["type"] as? String == "ready" { ready = true } }
        }
    }
    @MainActor func web(model: ReaderModel? = nil) async throws -> (WKWebView, Bridge) {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let bridge = Bridge(model: model); config.userContentController.add(bridge, name: "folio")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), configuration: config)
        model?.webView = view
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.js"), encoding: .utf8).replacingOccurrences(of: "</script", with: #"<\/script"#)
        view.loadHTMLString("<html><body><main id='document'></main><script>\(js)</script></body></html>", baseURL: nil)
        for _ in 0..<300 { if bridge.ready && (model == nil || bridge.messages.contains(where: { $0["type"] as? String == "outline" })) { return (view, bridge) }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Renderer did not become ready"); return (view, bridge)
    }
    let record = #"{id:'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',start:0,quote:'Original',prefix:'',suffix:'.',rawSourceRevision:'a'.repeat(64),decodedSourceRevision:'b'.repeat(64)}"#
    @MainActor func testIncomingReviewPreservesEditorDOMSelectionAndExactSource() async throws {
        let (view, bridge) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript(#"Folio.render('Original.\r\n\r\n```js\r\nx()  \r\n```\r\n','','current',[],true,null,true); window.host=document.getElementById('document'); window.paragraph=host.querySelector('p'); window.textNode=paragraph.firstChild; host.focus(); window.range=document.createRange(); range.setStart(textNode,2); range.setEnd(textNode,5); getSelection().removeAllRanges(); getSelection().addRange(range); window.beforeHTML=host.innerHTML; window.mutations=[]; window.observer=new MutationObserver(records=>mutations.push(...records)); observer.observe(host,{subtree:true,childList:true,characterData:true,attributes:true}); void 0"#)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await view.evaluateJavaScript("window.beforeHTML=host.innerHTML; mutations.length=0; void 0")
        let selectedAnchor = try await view.evaluateJavaScript("Folio.sharedSelection('current')") as! [String: Any]
        XCTAssertEqual(selectedAnchor["start"] as? Int, 2); XCTAssertEqual(selectedAnchor["quote"] as? String, "igi")
        XCTAssertEqual(selectedAnchor["token"] as? String, "current")
        let result = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[\(record),{...\(record),id:'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',authorName:'Alex'}])") as? [String: Any]
        XCTAssertEqual(result?["accepted"] as? Bool, true)
        let check = try await view.evaluateJavaScript(#"({same:host.innerHTML===beforeHTML&&paragraph===host.querySelector('p')&&textNode===paragraph.firstChild,selected:getSelection().toString(),focus:document.activeElement===host,mutations:mutations.length,rangeCount:CSS.highlights?[...CSS.highlights.keys()].filter(k=>k.startsWith('folio-shared-')).length:0,painting:typeof Highlight==='function'&&!!CSS.highlights})"#) as! [String: Any]
        XCTAssertEqual(check["same"] as? Bool, true); XCTAssertEqual(check["selected"] as? String, "igi")
        XCTAssertEqual(check["focus"] as? Bool, true); XCTAssertEqual(check["mutations"] as? Int, 0)
        let expectedPainting = check["painting"] as? Bool == true ? "painted" : "unsupported"
        XCTAssertEqual(result?["painting"] as? String, expectedPainting)
        XCTAssertEqual(check["rangeCount"] as? Int, expectedPainting == "painted" ? 2 : 0)
        _ = try await view.evaluateJavaScript("Folio.requestContent('snapshot'); void 0")
        XCTAssertEqual(bridge.messages.last(where: { $0["type"] as? String == "contentReady" })?["text"] as? String, "Original.\r\n\r\n```js\r\nx()  \r\n```\r\n")
        XCTAssertFalse(bridge.messages.contains(where: { $0["type"] as? String == "saveHighlights" }))
        if expectedPainting == "painted" {
            _ = try await view.evaluateJavaScript("getSelection().collapse(textNode,0); window.hit=[...CSS.highlights.get('folio-shared-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')][0].getClientRects()[0]; paragraph.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:(hit.left+hit.right)/2,clientY:(hit.top+hit.bottom)/2})); void 0")
            let clicked = try XCTUnwrap(bridge.messages.last(where: { $0["type"] as? String == "sharedHighlightClicked" }))
            XCTAssertEqual(clicked["token"] as? String, "current")
            XCTAssertEqual(clicked["ids"] as? [String], ["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"])
        }
    }
    @MainActor func testStaleTokenAndCompositionCannotPaintOrNavigateWrongPassage() async throws {
        let (view, _) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript(#"Folio.render('Original.','','current',[],true,null,true); void 0"#)
        let stale = try await view.evaluateJavaScript("Folio.updateSharedReview('old',[\(record)])") as! [String: Any]
        XCTAssertEqual(stale["accepted"] as? Bool, false)
        _ = try await view.evaluateJavaScript(#"document.getElementById('document').dispatchEvent(new CompositionEvent('compositionstart')); void 0"#)
        let deferred = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[\(record)])") as! [String: Any]
        XCTAssertEqual(deferred["painting"] as? String, "deferred")
        let jump = try await view.evaluateJavaScript(#"Folio.navigateSharedHighlight('current','AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA')"#) as! [String: Any]
        XCTAssertEqual(jump["status"] as? String, "deferred")
        _ = try await view.evaluateJavaScript(#"document.getElementById('document').dispatchEvent(new CompositionEvent('compositionend')); document.querySelector('.edit-passage p').textContent='Original Original'; void 0"#)
        let ambiguous = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[{...\(record),suffix:''}])") as! [String: Any]
        XCTAssertEqual((ambiguous["records"] as? [[String: Any]])?.first?["status"] as? String, "ambiguous")
        let missing = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[{...\(record),quote:'Deleted'}])") as! [String: Any]
        XCTAssertEqual((missing["records"] as? [[String: Any]])?.first?["status"] as? String, "missing")
    }
    @MainActor func testSharedRefreshPreservesFolioNativeUndo() async throws {
        let model = ReaderModel(); model.text = "Original."; model.baseline = model.text; model.editingEnabled = true
        let (view, bridge) = try await web(model: model)
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("window.originalRender=Folio.render; Folio.render=(...args)=>{window.reviewToken=args[2]; return originalRender(...args)}; void 0")
        model.render(); _ = try await view.evaluateJavaScript("void 0")
        _ = try await view.evaluateJavaScript("window.host=document.getElementById('document'); host.focus(); window.range=document.createRange(); range.selectNodeContents(host.querySelector('p')); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); document.execCommand('insertText',false,' Added'); void 0")
        for _ in 0..<100 { if model.text.contains("Added") { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.text, "Original. Added\n\n")
        _ = try await view.evaluateJavaScript("Folio.updateSharedReview(reviewToken,[\(record)]); void 0")
        XCTAssertEqual(model.text, "Original. Added\n\n")
        model.undoEdit(); XCTAssertEqual(model.text, "Original.")
        model.redoEdit(); XCTAssertEqual(model.text, "Original. Added\n\n")
        XCTAssertFalse(bridge.messages.contains(where: { $0["type"] as? String == "saveHighlights" }))
    }
    @MainActor func testUnsupportedHighlightEngineKeepsJumpAndAnchorStatus() async throws {
        let (view, _) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.','','current',[],true,null,false); Object.defineProperty(window,'Highlight',{value:undefined,configurable:true}); void 0")
        let result = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[\(record)])") as! [String: Any]
        XCTAssertEqual(result["painting"] as? String, "unsupported")
        XCTAssertEqual((result["records"] as? [[String: Any]])?.first?["status"] as? String, "located")
        let jump = try await view.evaluateJavaScript("Folio.navigateSharedHighlight('current','AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA')") as! [String: Any]
        XCTAssertEqual(jump["status"] as? String, "located")
        let markup = try await view.evaluateJavaScript("document.getElementById('document').innerHTML") as! String
        XCTAssertFalse(markup.contains("folio-shared"))
    }
    @MainActor func testSharedRefreshPreservesPrivateMarks() async throws {
        let (view, bridge) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.','','current',[{...\(record),id:'private',comment:'Private comment'}],true,null,true); window.host=document.getElementById('document'); host.focus(); window.node=host.querySelector('p').firstChild.firstChild; window.range=document.createRange(); range.selectNodeContents(host.querySelector('p')); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); document.execCommand('insertText',false,' Added'); void 0")
        _ = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[\(record)]); void 0")
        let result = try await view.evaluateJavaScript(#"({privateCount:host.querySelectorAll('mark.folio-highlight').length,text:host.querySelector('p').textContent})"#) as! [String: Any]
        XCTAssertEqual(result["text"] as? String, "Original. Added")
        XCTAssertGreaterThan(result["privateCount"] as? Int ?? 0, 0)
        _ = try await view.evaluateJavaScript("Folio.highlightsSaved('current',[]); void 0")
        try await Task.sleep(for: .milliseconds(50))
        let afterRemoval = try await view.evaluateJavaScript("({privateCount:host.querySelectorAll('mark.folio-highlight').length,sharedCount:CSS.highlights?[...CSS.highlights.keys()].filter(k=>k.startsWith('folio-shared-')).length:0,supported:typeof Highlight==='function'&&!!CSS.highlights})") as! [String: Any]
        XCTAssertEqual(afterRemoval["privateCount"] as? Int, 0)
        XCTAssertEqual(afterRemoval["sharedCount"] as? Int, afterRemoval["supported"] as? Bool == true ? 1 : 0)
        XCTAssertFalse(bridge.messages.contains(where: { $0["type"] as? String == "saveHighlights" }))
    }
    @MainActor func testDeferredSharedPaintResumesAfterRealLinkFieldCancel() async throws {
        let (view, _) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.','','current',[],true,null,true); window.host=document.getElementById('document'); host.focus(); window.range=document.createRange(); range.selectNodeContents(host.querySelector('p')); getSelection().removeAllRanges(); getSelection().addRange(range); document.querySelector('#format-bar [data-link]').click(); void 0")
        let deferred = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[\(record)])") as! [String: Any]
        XCTAssertEqual(deferred["painting"] as? String, "deferred")
        _ = try await view.evaluateJavaScript("window.beforeCancelHTML=host.innerHTML; document.querySelector('#format-bar input').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})); void 0")
        try await Task.sleep(for: .milliseconds(150))
        let after = try await view.evaluateJavaScript("({input:!!document.querySelector('#format-bar input'),same:host.innerHTML===beforeCancelHTML,ranges:CSS.highlights?[...CSS.highlights.keys()].filter(k=>k.startsWith('folio-shared-')).length:0,supported:typeof Highlight==='function'&&!!CSS.highlights})") as! [String: Any]
        XCTAssertEqual(after["input"] as? Bool, false); XCTAssertEqual(after["same"] as? Bool, true)
        XCTAssertEqual(after["ranges"] as? Int, after["supported"] as? Bool == true ? 1 : 0)
    }
    @MainActor func testCanonicalDuplicateUUIDsNeverReplaceOneAnotherInRegistry() async throws {
        let (view, _) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original. second.','','current',[],true,null,true); void 0")
        let result = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[\(record),{...\(record),id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',start:10,quote:'second',prefix:'',suffix:'.'}])") as! [String: Any]
        XCTAssertEqual((result["records"] as? [[String: Any]])?.compactMap { $0["status"] as? String }, ["invalid", "invalid"])
        let count = try await view.evaluateJavaScript("CSS.highlights?[...CSS.highlights.keys()].filter(k=>k.startsWith('folio-shared-')).length:0") as? Int
        XCTAssertEqual(count, 0)
    }
    @MainActor func testPrivateSharePreviewLocatesWithoutChangingSharedLayerDOMOrCallbacks() async throws {
        let (view, bridge) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original. second.','','current',[],true,null,true); Folio.updateSharedReview('current',[\(record)]); window.host=document.getElementById('document'); window.beforePreviewHTML=host.innerHTML; window.originalHighlight=CSS.highlights?.get('folio-shared-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'); window.range=document.createRange(); range.setStart(host.querySelector('p').firstChild,1); range.setEnd(host.querySelector('p').firstChild,4); getSelection().removeAllRanges(); getSelection().addRange(range); void 0")
        try await Task.sleep(for: .milliseconds(50))
        let callbackCount = bridge.messages.filter { $0["type"] as? String == "sharedReviewAnchors" }.count
        let preview = try await view.evaluateJavaScript("Folio.locateSharedReview('current',[{...\(record),id:'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',start:0,quote:'second',prefix:'',suffix:'.'},{...\(record),id:'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC',quote:'gone'}])") as! [String: Any]
        XCTAssertEqual(preview["accepted"] as? Bool, true); XCTAssertEqual(preview["token"] as? String, "current")
        let records = try XCTUnwrap(preview["records"] as? [[String: Any]])
        XCTAssertEqual(records[0]["status"] as? String, "located"); XCTAssertEqual(records[0]["start"] as? Int, 10); XCTAssertEqual(records[0]["end"] as? Int, 16)
        XCTAssertEqual(records[1]["status"] as? String, "missing")
        let after = try await view.evaluateJavaScript("({same:host.innerHTML===beforePreviewHTML,selected:getSelection().toString(),sameHighlight:CSS.highlights?.get('folio-shared-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')===originalHighlight,previewRange:!!CSS.highlights?.get('folio-shared-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')})") as! [String: Any]
        XCTAssertEqual(after["same"] as? Bool, true); XCTAssertEqual(after["selected"] as? String, "rig")
        XCTAssertEqual(after["sameHighlight"] as? Bool, true); XCTAssertEqual(after["previewRange"] as? Bool, false)
        XCTAssertEqual(bridge.messages.filter { $0["type"] as? String == "sharedReviewAnchors" }.count, callbackCount)
        let stale = try await view.evaluateJavaScript("Folio.locateSharedReview('old',[\(record)])") as! [String: Any]
        XCTAssertEqual(stale["accepted"] as? Bool, false); XCTAssertTrue((stale["records"] as? [Any])?.isEmpty == true)
    }
    @MainActor func testExplicitSharedToolbarIntentNeverSavesPrivateHighlightsAndResetsOnRender() async throws {
        let (view, bridge) = try await web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.','','current',[],true,null,true); window.selectPassage=()=>{const range=document.createRange();range.selectNodeContents(document.querySelector('#document p'));getSelection().removeAllRanges();getSelection().addRange(range)}; selectPassage(); void 0")
        let available = try await view.evaluateJavaScript("typeof Folio.setSharedReviewMode==='function'") as? Bool
        XCTAssertEqual(available, true); guard available == true else { return }
        let mode = try await view.evaluateJavaScript("Folio.setSharedReviewMode('current','shared')") as? Bool
        XCTAssertEqual(mode, true)
        _ = try await view.evaluateJavaScript("document.querySelectorAll('#highlight-tools button')[0].click(); document.querySelectorAll('#highlight-tools button')[1].click(); void 0")
        let shared = bridge.messages.filter { $0["type"] as? String == "sharedSelectionAction" }
        XCTAssertEqual(shared.compactMap { $0["comment"] as? Bool }, [false, true])
        XCTAssertEqual(shared.compactMap { $0["token"] as? String }, ["current", "current"])
        XCTAssertFalse(bridge.messages.contains { ["saveHighlights", "commentHighlight"].contains($0["type"] as? String ?? "") })
        let retainedSelection = try await view.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(retainedSelection, "Original.")
        let stale = try await view.evaluateJavaScript("Folio.setSharedReviewMode('old','private')") as? Bool
        XCTAssertEqual(stale, false)
        _ = try await view.evaluateJavaScript("Folio.highlightSelection(); void 0")
        XCTAssertEqual(bridge.messages.filter { $0["type"] as? String == "sharedSelectionAction" }.count, 3)
        _ = try await view.evaluateJavaScript("Folio.setSharedReviewMode('current','private'); Folio.highlightSelection(); void 0")
        let privateSave = try XCTUnwrap(bridge.messages.last { $0["type"] as? String == "saveHighlights" })
        XCTAssertEqual((privateSave["highlights"] as? [[String: Any]])?.first?["quote"] as? String, "Original.")
        _ = try await view.evaluateJavaScript("Folio.render('New.','','new',[],true,null,true); selectPassage(); Folio.highlightSelection(); void 0")
        let resetSave = try XCTUnwrap(bridge.messages.last { $0["type"] as? String == "saveHighlights" })
        XCTAssertEqual(resetSave["token"] as? String, "new")
        XCTAssertEqual((resetSave["highlights"] as? [[String: Any]])?.first?["quote"] as? String, "New.")
    }
}
