import XCTest
import AppKit
import WebKit
@testable import MarkdownReader

final class ContextualReviewRendererTests: XCTestCase {
    @MainActor func testCompletedTasksStrikeOnlyTheirOwnTextAndShowCompleter() async throws {
        let (view, _) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.css"), encoding: .utf8)
        let cssJSON = String(data: try JSONSerialization.data(withJSONObject: [css]), encoding: .utf8)!
        _ = try await view.evaluateJavaScript("window.style=document.createElement('style');style.textContent=\(cssJSON)[0];document.head.append(style);Folio.render('- [x] Parent\\n  - [ ] Child','','current',[],true,null,false);window.offset=Number(document.querySelector('input[data-task-offset]').dataset.taskOffset);Folio.setReviewContext('current',{enabled:true,mode:'shared',tasks:[{id:'task',offset,states:['done'],doneBy:'Alex'}],threads:[]});void 0")
        let result = try await view.evaluateJavaScript("({labels:Array.from(document.querySelectorAll('.review-task-accessory')).filter(b=>!b.hidden).map(b=>b.textContent),strike:Array.from(document.querySelectorAll('.folio-task-text')).map(n=>getComputedStyle(n).textDecorationLine)})") as! [String: Any]
        XCTAssertEqual(result["labels"] as? [String], ["Done by Alex"])
        XCTAssertEqual(result["strike"] as? [String], ["line-through", "none"])
        _ = try await view.evaluateJavaScript("document.querySelector('input[data-task-offset]').checked=false;Folio.setReviewContext('current',{enabled:true,mode:'shared',tasks:[{id:'task',offset,states:['open']}],threads:[]});void 0")
        let visible = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('.review-task-accessory')).filter(b=>!b.hidden).length") as? Int
        XCTAssertEqual(visible, 0)
    }
    @MainActor func testTaskChoicesAreBinaryAndSharedPassagesShowPointerOnlyOnHover() async throws {
        let harness = CollaborationRendererTests(); let (view, _) = try await harness.web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.\\n\\n- [ ] Check','','current',[],true,null,false); Folio.updateSharedReview('current',[\(harness.record)]); Folio.setReviewContext('current',{enabled:true,mode:'shared',threads:[],tasks:[]}); document.querySelector('.review-task-accessory').click(); void 0")
        let choices = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('[data-review-state]'),b=>b.dataset.reviewState)") as? [String]
        XCTAssertEqual(choices, ["open", "done"])
        _ = try await view.evaluateJavaScript("document.querySelector('#review-popover header button').click(); window.node=document.querySelector('#document p').firstChild; window.range=document.createRange(); range.selectNodeContents(node); window.rect=range.getBoundingClientRect(); node.parentElement.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:rect.left+2,clientY:rect.top+2})); void 0")
        let hovered = try await view.evaluateJavaScript("document.documentElement.classList.contains('folio-review-hover')") as? Bool
        XCTAssertEqual(hovered, true)
        _ = try await view.evaluateJavaScript("document.getElementById('document').dispatchEvent(new PointerEvent('pointerleave')); void 0")
        let left = try await view.evaluateJavaScript("document.documentElement.classList.contains('folio-review-hover')") as? Bool
        XCTAssertEqual(left, false)
    }
    @MainActor func testContextualThreadPreservesSourceAndGuardsSubmission() async throws {
        let harness = CollaborationRendererTests()
        let (view, bridge) = try await harness.web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.\\n\\n- [ ] Check','','current',[],true,null,false); window.before=document.getElementById('document').innerHTML; void 0")
        let available = try await view.evaluateJavaScript("typeof Folio.setReviewContext==='function'") as? Bool
        XCTAssertEqual(available, true); guard available == true else { return }
        _ = try await view.evaluateJavaScript("Folio.updateSharedReview('current',[\(harness.record)]); Folio.setReviewContext('current',{enabled:true,mode:'shared',threads:[{id:'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',quote:'Original',author:'Alex',resolved:false,messages:[{id:'message',author:'Sam',text:'<img src=x onerror=alert(1)>'}]}],tasks:[],draft:'',replyTo:null}); Folio.openReviewThread('current','AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',true); void 0")
        let state = try await view.evaluateJavaScript("({same:before===document.getElementById('document').innerHTML,outside:!document.getElementById('document').contains(document.getElementById('review-popover')),literal:document.getElementById('review-popover').textContent.includes('<img src=x'),images:document.getElementById('review-popover').querySelectorAll('img').length,stale:Folio.openReviewThread('old','AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',true)})") as! [String: Any]
        XCTAssertEqual(state["same"] as? Bool, true); XCTAssertEqual(state["outside"] as? Bool, true)
        XCTAssertEqual(state["literal"] as? Bool, true); XCTAssertEqual(state["images"] as? Int, 0); XCTAssertEqual(state["stale"] as? Bool, false)
        _ = try await view.evaluateJavaScript("window.field=document.querySelector('#review-popover textarea'); field.value='Reply'; field.dispatchEvent(new Event('input')); field.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true})); field.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true})); void 0")
        XCTAssertFalse(bridge.messages.contains { $0["type"] as? String == "reviewCommentSubmit" })
        _ = try await view.evaluateJavaScript("field.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true})); void 0")
        let message = try XCTUnwrap(bridge.messages.last { $0["type"] as? String == "reviewCommentSubmit" })
        XCTAssertEqual(message["text"] as? String, "Reply"); XCTAssertEqual(message["token"] as? String, "current")
        _ = try await view.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})); void 0")
        let closed = try await view.evaluateJavaScript("document.getElementById('review-popover').hidden") as? Bool
        XCTAssertEqual(closed, true)
    }
    @MainActor func testTaskStatusAndPrivateDraftStayOutsideDocument() async throws {
        let (view, bridge) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.\\n\\n- [ ] Check','','current',[{id:'private',start:0,quote:'Original',prefix:'',suffix:'.\\n',comment:'Existing'}],true,null,false); window.before=document.getElementById('document').innerHTML; void 0")
        let available = try await view.evaluateJavaScript("typeof Folio.openPrivateComment==='function'") as? Bool
        XCTAssertEqual(available, true); guard available == true else { return }
        _ = try await view.evaluateJavaScript("Folio.setReviewContext('current',{enabled:true,mode:'shared',threads:[],tasks:[]}); document.querySelector('.review-task-accessory').click(); document.querySelector('[data-review-state=done]').click(); void 0")
        let task = try XCTUnwrap(bridge.messages.last { $0["type"] as? String == "reviewTaskAtOffset" })
        XCTAssertEqual(task["before"] as? String, "Original.\n\n- [ ] Check"); XCTAssertEqual(task["state"] as? String, "done")
        _ = try await view.evaluateJavaScript("Folio.openPrivateComment('current','private'); window.field=document.querySelector('#review-popover textarea'); field.value='Changed'; field.dispatchEvent(new Event('input')); field.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true})); Folio.privateCommentResult('current','private','Try again'); void 0")
        let saved = try XCTUnwrap(bridge.messages.last { $0["type"] as? String == "privateCommentSubmit" })
        XCTAssertEqual(saved["id"] as? String, "private"); XCTAssertEqual(saved["text"] as? String, "Changed")
        let final = try await view.evaluateJavaScript("({same:before===document.getElementById('document').innerHTML,draft:document.querySelector('#review-popover textarea').value,error:document.getElementById('review-popover').textContent.includes('Try again')})") as! [String: Any]
        XCTAssertEqual(final["same"] as? Bool, true); XCTAssertEqual(final["draft"] as? String, "Changed"); XCTAssertEqual(final["error"] as? Bool, true)
    }

    @MainActor func testDelayedContextCannotReplaceLiveCompositionOrReopenDismissedThread() async throws {
        let harness = CollaborationRendererTests(); let (view, _) = try await harness.web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('Original.','','current',[],true,null,false); Folio.updateSharedReview('current',[\(harness.record)]); window.ctx={enabled:true,mode:'shared',threads:[{id:'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',quote:'Original',messages:[]}],tasks:[],selectedThread:'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',draft:'',replyTo:null}; Folio.setReviewContext('current',ctx); Folio.openReviewThread('current',ctx.selectedThread,true); window.field=document.querySelector('#review-popover textarea'); field.value='New draft'; field.dispatchEvent(new Event('input')); field.dispatchEvent(new CompositionEvent('compositionstart')); Folio.setReviewContext('current',{...ctx,draft:'Old draft'}); void 0")
        let result = try await view.evaluateJavaScript("({same:field===document.querySelector('#review-popover textarea'),text:document.querySelector('#review-popover textarea').value})") as! [String: Any]
        XCTAssertEqual(result["same"] as? Bool, true); XCTAssertEqual(result["text"] as? String, "New draft")
        _ = try await view.evaluateJavaScript("field.dispatchEvent(new CompositionEvent('compositionend')); document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})); Folio.setReviewContext('current',{...ctx,selectedThread:null}); Folio.setReviewContext('current',ctx); void 0")
        let closed = try await view.evaluateJavaScript("document.getElementById('review-popover').hidden") as? Bool
        XCTAssertEqual(closed, true)
    }
    @MainActor func testRegisteredTaskStatusIsDiscoverableWithoutTextSelectionInPrivateMode() async throws {
        let (view, bridge) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('- [ ] Check','','current',[],true,null,false); Folio.setReviewContext('current',{enabled:true,mode:'private',threads:[],tasks:[]}); void 0")
        let count = try await view.evaluateJavaScript("document.querySelectorAll('.review-task-accessory').length") as? Int
        XCTAssertEqual(count, 1); guard count == 1 else { return }
        _ = try await view.evaluateJavaScript("document.querySelector('.review-task-accessory').click(); document.querySelector('[data-review-state=done]').click(); void 0")
        XCTAssertEqual(bridge.messages.filter { ["reviewModeChanged","reviewTaskAtOffset"].contains($0["type"] as? String ?? "") }.compactMap { $0["type"] as? String }, ["reviewModeChanged","reviewTaskAtOffset"])
    }

    @MainActor func testTaskSourceRecoveryRequiresExplicitApply() async throws {
        let (view, bridge) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("Folio.render('- [ ] Check','','current',[],true,null,false); Folio.setReviewContext('current',{enabled:true,mode:'shared',threads:[],tasks:[{id:'task',offset:Number(document.querySelector('input[data-task-offset]').dataset.taskOffset),line:'Check',states:['done'],status:'Markdown update pending'}]}); Folio.openReviewTask('current','task'); void 0")
        XCTAssertFalse(bridge.messages.contains { $0["type"] as? String == "reviewTaskApply" })
        let recovery = try await view.evaluateJavaScript("!!document.querySelector('[data-review-apply]')&&document.getElementById('review-popover').textContent.includes('Markdown update pending')") as? Bool
        XCTAssertEqual(recovery, true); guard recovery == true else { return }
        _ = try await view.evaluateJavaScript("document.querySelector('[data-review-apply]').click(); void 0")
        XCTAssertEqual(bridge.messages.last { $0["type"] as? String == "reviewTaskApply" }?["id"] as? String, "task")
    }

}

final class ContextualSelectionRendererTests: XCTestCase {
    @MainActor private func installReaderCSS(_ view: WKWebView) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.css"), encoding: .utf8)
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [css]), encoding: .utf8)!
        _ = try await view.evaluateJavaScript("window.testStyle=document.createElement('style'); testStyle.textContent=(\(encoded))[0]; document.head.append(testStyle); void 0")
    }
    @MainActor func testPrivacySwitchKeepsLiveSelectionAndToolbarThroughNativeContextEcho() async throws {
        let (view, bridge) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        try await installReaderCSS(view)
        _ = try await view.evaluateJavaScript("Folio.appearance('light',1,{}); Folio.render('Original.','','current',[],true,null,false); window.ctx={enabled:true,mode:'private',busy:false,issue:null,threads:[],tasks:[],selectedThread:null,draft:'',replyTo:null}; Folio.setReviewContext('current',ctx); void 0")
        try await Task.sleep(for: .milliseconds(80))
        _ = try await view.evaluateJavaScript("window.node=document.querySelector('#document p').firstChild; window.range=document.createRange(); range.setStart(node,2); range.setEnd(node,5); getSelection().removeAllRanges(); getSelection().addRange(range); void 0")
        try await Task.sleep(for: .milliseconds(80))
        let initial = try await view.evaluateJavaScript("!document.getElementById('highlight-tools').hidden && getComputedStyle(document.getElementById('highlight-tools')).display!=='none'") as? Bool
        XCTAssertEqual(initial, true)
        for mode in ["shared", "private", "shared"] {
            let cancelled = try await view.evaluateJavaScript("window.modeButton=document.querySelector('[data-review-mode=\(mode)]'); window.down=new PointerEvent('pointerdown',{bubbles:true,cancelable:true}); modeButton.dispatchEvent(down); modeButton.dispatchEvent(new PointerEvent('pointerup',{bubbles:true})); modeButton.click(); down.defaultPrevented") as? Bool
            XCTAssertEqual(cancelled, true, "Privacy switch must cancel selection-collapsing pointer focus")
            _ = try await view.evaluateJavaScript("ctx={...ctx,mode:'\(mode)'}; Folio.setReviewContext('current',ctx); Folio.setReviewContext('current',{...ctx}); void 0")
            try await Task.sleep(for: .milliseconds(80))
            let after = try await view.evaluateJavaScript("({selected:getSelection().toString(),quote:Folio.sharedSelection('current')?.quote,visible:!document.getElementById('highlight-tools').hidden&&getComputedStyle(document.getElementById('highlight-tools')).display!=='none',pressed:document.querySelector('[data-review-mode=\(mode)]').getAttribute('aria-pressed')})") as! [String: Any]
            XCTAssertEqual(after["selected"] as? String, "igi", mode)
            XCTAssertEqual(after["quote"] as? String, "igi", mode)
            XCTAssertEqual(after["visible"] as? Bool, true, mode)
            XCTAssertEqual(after["pressed"] as? String, "true", mode)
        }
        XCTAssertEqual(bridge.messages.filter { $0["type"] as? String == "reviewModeChanged" }.compactMap { $0["mode"] as? String }, ["shared", "private", "shared"])
        _ = try await view.evaluateJavaScript("document.querySelectorAll('#highlight-tools button')[1].click(); void 0")
        XCTAssertEqual(bridge.messages.last { $0["type"] as? String == "sharedSelectionAction" }?["comment"] as? Bool, true)
        XCTAssertFalse(bridge.messages.contains { $0["type"] as? String == "saveHighlights" })
        let finalQuote = try await view.evaluateJavaScript("Folio.sharedSelection('current')?.quote") as? String
        XCTAssertEqual(finalQuote, "igi")
    }
    @MainActor func testContextPanelUsesDarkPaperOrangeAccentAndFlatSurfaces() async throws {
        let (view, _) = try await CollaborationRendererTests().web()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        try await installReaderCSS(view)
        _ = try await view.evaluateJavaScript("Folio.appearance('dark',1,{}); Folio.render('Original.','','current',[{id:'private',start:0,quote:'Original',prefix:'',suffix:'.',comment:'Comment'}],true,null,false); Folio.openPrivateComment('current','private'); void 0")
        let dark = try await view.evaluateJavaScript("({paper:getComputedStyle(document.getElementById('review-popover')).backgroundColor,ink:getComputedStyle(document.getElementById('review-popover')).color,accent:getComputedStyle(document.querySelector('#review-popover blockquote')).borderLeftColor,radius:getComputedStyle(document.getElementById('review-popover')).borderRadius,shadow:getComputedStyle(document.getElementById('review-popover')).boxShadow,fieldBorder:getComputedStyle(document.querySelector('#review-popover .review-composer')).borderColor,focusOutline:getComputedStyle(document.querySelector('#review-popover textarea')).outlineStyle})") as! [String: Any]
        XCTAssertEqual(dark["paper"] as? String, "rgb(23, 23, 23)")
        XCTAssertEqual(dark["ink"] as? String, "rgb(233, 233, 233)")
        XCTAssertEqual(dark["accent"] as? String, "rgb(255, 155, 84)")
        XCTAssertEqual(dark["radius"] as? String, "0px"); XCTAssertEqual(dark["shadow"] as? String, "none")
        _ = try await view.evaluateJavaScript("Folio.appearance('light',1,{}); void 0")
        let light = try await view.evaluateJavaScript("({paper:getComputedStyle(document.getElementById('review-popover')).backgroundColor,accent:getComputedStyle(document.querySelector('#review-popover blockquote')).borderLeftColor})") as! [String: Any]
        XCTAssertEqual(light["paper"] as? String, "rgb(255, 255, 255)")
        XCTAssertEqual(light["accent"] as? String, "rgb(44, 255, 5)")
    }
    @MainActor func testContextComposerHasSingleAccentFocusBorderWhenHostCanFocus() async throws {
        let (view, _) = try await CollaborationRendererTests().web()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        for _ in 0..<100 {
            if NSApplication.shared.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { window.close(); view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        try await installReaderCSS(view)
        _ = try await view.evaluateJavaScript("Folio.appearance('dark',1,{}); Folio.render('Original.','','current',[{id:'private',start:0,quote:'Original',prefix:'',suffix:'.',comment:'Comment'}],true,null,false); Folio.openPrivateComment('current','private'); void 0")
        try await Task.sleep(for: .milliseconds(80))
        let documentFocused = try await view.evaluateJavaScript("document.hasFocus()") as? Bool
        guard documentFocused == true else { throw XCTSkip("The native test host cannot acquire document focus; focus-only CSS assertions require an active key window.") }
        XCTAssertTrue(NSApplication.shared.isActive, "The focus CSS test requires an active test application")
        XCTAssertTrue(window.isKeyWindow, "The focus CSS test requires a key host window")
        try await Task.sleep(for: .milliseconds(80))
        let focused = try await view.evaluateJavaScript("document.querySelector('#review-popover textarea').focus({preventScroll:true}); ({focused:document.activeElement===document.querySelector('#review-popover textarea'),matches:document.querySelector('#review-popover textarea').matches(':focus'),hidden:document.getElementById('review-popover').hidden})") as! [String: Any]
        XCTAssertEqual(focused["focused"] as? Bool, true, "Composer must own focus before testing focus CSS: \(focused)")
        XCTAssertEqual(focused["matches"] as? Bool, true, "Composer must match :focus before testing focus CSS: \(focused)")
        let dark = try await view.evaluateJavaScript("({fieldBorder:getComputedStyle(document.querySelector('#review-popover .review-composer')).borderColor,focusOutline:getComputedStyle(document.querySelector('#review-popover textarea')).outlineStyle})") as! [String: Any]
        XCTAssertEqual(dark["fieldBorder"] as? String, "rgb(255, 155, 84)")
        XCTAssertEqual(dark["focusOutline"] as? String, "none")
    }

}
