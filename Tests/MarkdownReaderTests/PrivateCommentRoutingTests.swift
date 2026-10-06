import AppKit
import WebKit
import XCTest
import ReaderCore
@testable import MarkdownReader

@MainActor private final class CommentRoutingWebView: WKWebView {
    var scripts: [String] = []
    var result = true
    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        scripts.append(javaScriptString)
        completionHandler?(result, nil)
    }
}

final class PrivateCommentRoutingTests: XCTestCase {
    @MainActor func testLocatedPrivateCommentOpensBesideTextWithoutSheet() {
        _ = NSApplication.shared
        let model = ReaderModel(collaboration: CollaborationCoordinator(enabled: false))
        let view = CommentRoutingWebView(frame: .zero)
        model.webView = view; model.ready = true
        let id = UUID().uuidString
        model.marked = [SavedHighlight(id: id, start: 0, quote: "Passage", prefix: "", suffix: "")]
        model.commentOnHighlight(id)
        XCTAssertTrue(view.scripts.contains { $0.contains("openPrivateComment") })
        XCTAssertNil(model.commentDraft, "Located passages must not open a detached sheet.")
    }
    @MainActor func testUnlocatablePrivateCommentStillHasRecoveryComposer() {
        _ = NSApplication.shared
        let model = ReaderModel(collaboration: CollaborationCoordinator(enabled: false))
        let view = CommentRoutingWebView(frame: .zero); view.result = false
        model.webView = view; model.ready = true
        let id = UUID().uuidString
        model.marked = [SavedHighlight(id: id, start: 0, quote: "Passage", prefix: "", suffix: "")]
        model.commentOnHighlight(id)
        XCTAssertEqual(model.commentDraft?.id, id)
    }
    @MainActor func testPrivateOverlaySubmissionPersistsFeedbackWithoutChangingSource() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("private.md")
        let original = Data("# Passage\n".utf8); try original.write(to: source)
        let store = HighlightStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("\(BuildChannel.storage)/Highlights"))
        let key = source.standardizedFileURL.resolvingSymlinksInPath().path
        addTeardownBlock {
            try? FileManager.default.removeItem(at: store.directory.appendingPathComponent(HighlightStore.revision(key) + ".json"))
            try? FileManager.default.removeItem(at: root)
        }
        let model = ReaderModel(collaboration: CollaborationCoordinator(enabled: false))
        model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<200 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.loading)
        let token = model.reviewRenderToken, id = UUID().uuidString
        model.saveHighlights([SavedHighlight(id: id, start: 0, quote: "Passage", prefix: "", suffix: "")], token: token)
        model.submitPrivateComment(id, text: "Feedback", token: "stale")
        XCTAssertNil(model.marked.first?.comment)
        model.submitPrivateComment(id, text: "Feedback", token: token)
        XCTAssertEqual(try store.load(for: key).first?.comment, "Feedback")
        XCTAssertEqual(model.reviewRenderToken, token, "Saving feedback must not rerender the document under the composer.")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

}
