import XCTest
import AppKit
import WebKit
import ReaderCore
@testable import MarkdownReader

final class CopyContentTests: XCTestCase {
    final class NativeUndoTextView: NSTextView {
        private let nativeUndo = UndoManager()
        override var undoManager: UndoManager? { nativeUndo }
    }
    @MainActor final class Bridge: NSObject, WKScriptMessageHandler {
        let coordinator: ReaderWebView.Coordinator
        var messages = [[String: Any]]()
        init(_ model: ReaderModel) { coordinator = ReaderWebView.Coordinator(model) }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
            coordinator.userContentController(controller, didReceive: message)
        }
    }
    @MainActor func web(_ source: String, editing: Bool = true, writer: @escaping (String) -> Bool) async throws -> (ReaderModel, WKWebView, Bridge) {
        _ = NSApplication.shared
        let model = ReaderModel(pasteboardWriter: writer); model.text = source; model.baseline = source; model.editingEnabled = editing
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let bridge = Bridge(model); config.userContentController.add(bridge, name: "folio")
        let view = FolioWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700), configuration: config)
        model.webView = view
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.js"), encoding: .utf8).replacingOccurrences(of: "</script", with: #"<\/script"#)
        view.loadHTMLString("<html><body><main id='document'></main><script>\(js)</script></body></html>", baseURL: nil)
        for _ in 0..<300 {
            if bridge.messages.contains(where: { $0["type"] as? String == "outline" }) { return (model, view, bridge) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("WKWebView did not finish rendering"); return (model, view, bridge)
    }
    @MainActor func waitForCopy(_ model: ReaderModel) async throws {
        for _ in 0..<300 {
            if !model.copyContentBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Copy handshake did not finish")
    }
    @MainActor func testWKWebViewFlushesUnsavedDOMBeforeSnapshotAndRejectsDuplicates() async throws {
        var copied = [String]()
        let (model, view, bridge) = try await web("Original.\r\n\r\n```js\r\nx()  \r\n```\r\n- [ ] task\r\n") { copied.append($0); return true }
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("document.querySelector('.edit-passage p').textContent='Current.'")
        model.copyContent(); try await waitForCopy(model)
        let relevant = bridge.messages.filter { ["editDocument", "contentReady"].contains($0["type"] as? String ?? "") }
        XCTAssertEqual(relevant.map { $0["type"] as? String ?? "" }, ["editDocument", "contentReady"])
        XCTAssertEqual(copied, [model.text]); XCTAssertTrue(model.text.hasPrefix("Current.\r\n"))
        XCTAssertTrue(model.text.contains("x()  \r\n")); XCTAssertTrue(model.text.contains("- [ ] task\r\n")); XCTAssertTrue(model.dirty)
        let snapshot = try XCTUnwrap(relevant.last)
        model.acceptContentSnapshot(requestID: snapshot["requestID"] as! String, token: snapshot["token"] as! String, text: snapshot["text"] as! String)
        XCTAssertEqual(copied.count, 1)
    }
    @MainActor func testWKWebViewCompositionAndModalFailure() async throws {
        var copied = [String]()
        let (model, view, _) = try await web("Original.\n\n```js\nx()\n```\n") { copied.append($0); return true }
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        _ = try await view.evaluateJavaScript("document.getElementById('document').dispatchEvent(new CompositionEvent('compositionstart'))")
        model.copyContent()
        _ = try await view.evaluateJavaScript("void 0")
        XCTAssertTrue(copied.isEmpty); XCTAssertTrue(model.copyContentBusy)
        _ = try await view.evaluateJavaScript("const root=document.getElementById('document');root.dispatchEvent(new CompositionEvent('compositionend'));root.querySelector('.edit-passage p').textContent='Final.';root.dispatchEvent(new InputEvent('input'))")
        try await waitForCopy(model); XCTAssertEqual(copied.count, 1); XCTAssertTrue(copied[0].hasPrefix("Final."))
        _ = try await view.evaluateJavaScript("document.querySelector('.complex-edit-button').click()")
        model.copyContent(); try await waitForCopy(model)
        XCTAssertEqual(copied.count, 1); XCTAssertFalse(model.contentCopied)
        XCTAssertEqual(model.error, "Apply or cancel the open edit before copying.")
    }
    @MainActor func testWKWebViewMismatchAndCancelledLateSnapshotsNeverCopy() async throws {
        for change in 0..<5 {
            var copied = [String]()
            let (model, view, _) = try await web("Original.\n") { copied.append($0); return true }
            _ = try await view.evaluateJavaScript("window.savedRender=window.Folio.render;window.Folio.render=(...args)=>{window.copyToken=args[2];return window.savedRender(...args)};void 0")
            model.render(); _ = try await view.evaluateJavaScript("void 0")
            _ = try await view.evaluateJavaScript("window.originalRequest=window.Folio.requestContent;window.Folio.requestContent=id=>{window.copyID=id;window.requestToken=window.copyToken};void 0")
            model.copyContent(); _ = try await view.evaluateJavaScript("void 0")
            switch change {
            case 0: model.documentID = UUID()
            case 1: model.editingEnabled = false
            case 2: model.render()
            case 3: ReaderWebView.Coordinator(model).webViewWebContentProcessDidTerminate(view)
            default: break
            }
            _ = try await view.evaluateJavaScript("window.webkit.messageHandlers.folio.postMessage({type:'contentReady',requestID:window.copyID,token:window.requestToken,text:'stale'});void 0")
            if change == 4 {
                // A matching token with text unequal to the current accepted model must fail visibly.
                try await waitForCopy(model)
                XCTAssertNotNil(model.error)
            }
            XCTAssertTrue(copied.isEmpty)
            view.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
        }
    }
    @MainActor func source(_ text: String, writer: @escaping (String) -> Bool) -> (ReaderModel, NSTextView) {
        _ = NSApplication.shared
        let model = ReaderModel(pasteboardWriter: writer)
        model.text = "older"; model.baseline = "baseline"; model.writing = true
        let editor = NativeUndoTextView(); editor.allowsUndo = true; editor.string = text; model.editor = editor
        return (model, editor)
    }
    @MainActor func testSourceCopiesWholeCurrentStringAndPreservesSelectionAndBaseline() {
        var copied = [String]()
        let text = "---\r\ntitle: Mine\r\n---\r\n<!-- authored -->\r\n```swift\r\nx()  \r\n```\r\n- [x] Done\r\n"
        let (model, editor) = source(text) { copied.append($0); return true }
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        model.copyContent()
        XCTAssertEqual(copied, [text]); XCTAssertEqual(model.text, text)
        XCTAssertEqual(model.baseline, "baseline"); XCTAssertTrue(model.dirty)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertTrue(model.contentCopied); XCTAssertFalse(model.copyContentBusy)
    }
    @MainActor func testCopyKeepsOriginalFileBytesAndSnapshotUntouched() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let bytes = Data("original\r\n".utf8); try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (model, editor) = source("unsaved\r\n") { _ in true }
        model.snapshot = try DocumentSnapshot(url: url); model.baseline = "original\r\n"
        model.copyContent()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(model.snapshot?.bytes, bytes); XCTAssertEqual(model.baseline, "original\r\n")
        XCTAssertEqual(editor.string, "unsaved\r\n"); XCTAssertTrue(model.dirty)
    }
    @MainActor func testTimeoutNeverForcesMarkedSourceOrAcceptsLateCompletion() async throws {
        var copied = [String]()
        let (model, editor) = source("old") { copied.append($0); return true }
        editor.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 3))
        model.copyContent()
        try await Task.sleep(for: .milliseconds(15200))
        XCTAssertFalse(model.copyContentBusy); XCTAssertFalse(model.contentCopied)
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertTrue(copied.isEmpty)
        editor.unmarkText(); model.sourceEditorPostChange(editor)
        await Task.yield(); XCTAssertTrue(copied.isEmpty)
    }
    @MainActor func testWKWebViewReadModeExactSourceAndDispatchFailure() async throws {
        var copied = [String]()
        let text = "---\r\ntitle: Mine\r\n---\r\n<!-- authored -->\r\n- [x] done\r\n"
        let (model, view, _) = try await web(text, editing: false) { copied.append($0); return true }
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        model.copyContent(); try await waitForCopy(model)
        XCTAssertEqual(copied, [text]); XCTAssertFalse(model.dirty)
        _ = try await view.evaluateJavaScript("window.Folio.requestContent=()=>{throw new Error('unavailable')};void 0")
        model.copyContent(); try await waitForCopy(model)
        XCTAssertEqual(copied.count, 1); XCTAssertFalse(model.contentCopied); XCTAssertNotNil(model.error)
    }
    @MainActor func testEmptyLeavesClipboardUntouchedAndWhitespaceIsExact() {
        var copied = [String]()
        let (model, editor) = source("") { copied.append($0); return true }
        model.copyContent(); XCTAssertTrue(copied.isEmpty); XCTAssertFalse(model.contentCopied)
        XCTAssertEqual(model.error, "The document is empty. There’s nothing to copy.")
        editor.string = " \t\r\n"; model.copyContent()
        XCTAssertEqual(copied, [" \t\r\n"])
    }
    @MainActor func testClipboardFailureNeverShowsCopiedAndMissingEditorFails() {
        let (model, editor) = source("draft") { _ in false }
        model.copyContent(); XCTAssertFalse(model.contentCopied)
        XCTAssertEqual(model.error, "Couldn’t copy the content. Try again.")
        model.editor = nil; model.copyContent()
        XCTAssertFalse(model.contentCopied); XCTAssertNotNil(model.error)
        _ = editor
    }
    @MainActor func testRepresentableUpdateKeepsNewerNativeTextAndUndo() {
        let (model, editor) = source("newer") { _ in true }
        let coordinator = MarkdownEditor.Coordinator(model)
        coordinator.lastModelText = model.text; coordinator.wasWriting = true
        let scroll = NSScrollView(); scroll.documentView = editor
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.undoManager?.registerUndo(withTarget: editor) { $0.string = "undo" }
        model.copyContentBusy = true
        MarkdownEditor(model: model).updateEditor(scroll, coordinator: coordinator)
        XCTAssertEqual(editor.string, "newer")
        XCTAssertEqual(editor.selectedRange().location, 3)
        XCTAssertTrue(editor.undoManager?.canUndo ?? false)
    }
    @MainActor func testEnteringSourceSynchronizesHiddenEditor() {
        let (model, editor) = source("hidden old") { _ in true }
        let coordinator = MarkdownEditor.Coordinator(model)
        let scroll = NSScrollView(); scroll.documentView = editor
        model.writing = false; model.text = "current rendered edit"
        MarkdownEditor(model: model).updateEditor(scroll, coordinator: coordinator)
        model.writing = true
        MarkdownEditor(model: model).updateEditor(scroll, coordinator: coordinator)
        XCTAssertEqual(editor.string, "current rendered edit")
    }
    @MainActor func testMarkedTextSurvivesRepresentableUpdate() {
        let (model, editor) = source("old") { _ in true }
        let coordinator = MarkdownEditor.Coordinator(model); coordinator.wasWriting = true
        let scroll = NSScrollView(); scroll.documentView = editor
        editor.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 3))
        model.text = "older update"
        MarkdownEditor(model: model).updateEditor(scroll, coordinator: coordinator)
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.string, "draft")
    }
    @MainActor func testSourceCompositionWaitsForCoordinatorPostChange() async {
        var copied = [String]()
        let (model, _) = source("old") { copied.append($0); return true }
        let editor = NSTextView(); editor.string = "old"; model.editor = editor
        let coordinator = MarkdownEditor.Coordinator(model)
        editor.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(editor.hasMarkedText())
        model.copyContent(); XCTAssertTrue(model.copyContentBusy); XCTAssertTrue(copied.isEmpty)
        editor.unmarkText(); editor.string = "final"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(copied, ["final"]); XCTAssertFalse(model.copyContentBusy)
    }
    @MainActor func testSourcePendingCancellationRejectsLateCompletion() async {
        for change in 0..<5 {
            var copied = [String]()
            let (model, _) = source("old") { copied.append($0); return true }
            let editor = NSTextView(); editor.string = "old"; model.editor = editor
            editor.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 3))
            model.copyContent()
            switch change {
            case 0: model.documentID = UUID()
            case 1: model.writing = false
            case 2: model.render()
            case 3: model.editor = nil
            default: model.cancelCopyContent()
            }
            editor.unmarkText(); editor.string = "late"; model.sourceEditorPostChange(editor)
            await Task.yield()
            XCTAssertTrue(copied.isEmpty); XCTAssertFalse(model.copyContentBusy)
        }
    }
}
