import XCTest
import WebKit
import ReaderCore
@testable import MarkdownReader

final class ComplexEditingAcceptanceTests: XCTestCase {
    private let prefix = "---\r\ntitle: Kept 😀\r\n---\r\n\r\n<!-- authored  -->\r\n\r\n"
    private let suffix = "\r\nUntouched  \r\n\r\nReference[^a]\r\n\r\n[^a]: exact  \r\n"

    @MainActor private func js(_ view: WKWebView, _ script: String) async throws {
        _ = try await view.evaluateJavaScript("(()=>{\(script)})()")
    }
    @MainActor private func settle(_ view: WKWebView) async throws {
        try await js(view, "return undefined;")
        try await Task.sleep(for: .milliseconds(80))
    }
    @MainActor private func open(_ view: WKWebView, _ kind: String) async throws {
        try await js(view, kind == "link" ? "document.querySelector('.edit-passage a').click();" : "document.querySelector('[data-kind=\(kind)] .complex-edit-button').click();")
    }
    @MainActor private func field(_ view: WKWebView, _ index: Int, _ value: String) async throws {
        let encoded = String(data: try JSONEncoder().encode(value), encoding: .utf8)!
        try await js(view, "const input=document.querySelectorAll('#complex-editor input, #complex-editor textarea')[\(index)]; input.value=\(encoded); input.dispatchEvent(new Event('input',{bubbles:true}));")
    }
    @MainActor private func button(_ view: WKWebView, _ label: String) async throws {
        try await js(view, "[...document.querySelectorAll('#complex-editor button')].find(b=>b.textContent==='\(label)').click();")
        try await settle(view)
    }

    @MainActor func testContextualEditsCancelHistoryAndDiskRoundtrip() async throws {
        let cases: [(String, String, [String], String)] = [
            ("code", "```js\r\nold();  \r\n```\r\n", ["swift", "print(\"😀\")\n```"], "````swift\r\nprint(\"😀\")\r\n```\r\n````\r\n"),
            ("link", "See [old](https://example.com/old).\r\n", ["new 😀", "https://example.com/new"], "See [new 😀](<https://example.com/new>).\r\n\r\n"),
            ("image", "![old](old.png)\r\n", ["New image", "folder/new image.png"], "![New image](<folder/new%20image.png>)\r\n")
        ]
        for (kind, before, values, after) in cases {
            let source = prefix + before + suffix
            let (model, view, _) = try await CopyContentTests().web(source) { _ in true }
            defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
            try await open(view, kind)
            let labelled = try await view.evaluateJavaScript("[...document.querySelectorAll('#complex-editor input,#complex-editor textarea')].every(x=>x.closest('label')?.textContent.trim())") as? Bool
            XCTAssertEqual(labelled, true)
            for (index, value) in values.enumerated() { try await field(view, index, value) }
            try await button(view, "Cancel")
            XCTAssertEqual(model.text, source); XCTAssertFalse(model.dirty)
            try await open(view, kind)
            for (index, value) in values.enumerated() { try await field(view, index, value) }
            try await button(view, "Apply")
            let expected = prefix + after + suffix
            XCTAssertEqual(model.text, expected, kind)
            model.undoEdit(); try await settle(view); XCTAssertEqual(model.text, source, kind)
            model.redoEdit(); try await settle(view); XCTAssertEqual(model.text, expected, kind)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
            try Data(source.utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let snapshot = try DocumentSnapshot(url: url)
            try snapshot.save(model.text, to: url)
            XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8))
            let reopened = try DocumentSnapshot(url: url)
            let (_, reopenedView, _) = try await CopyContentTests().web(reopened.text) { _ in true }
            defer { reopenedView.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
            try await open(reopenedView, kind)
            let actual = try await reopenedView.evaluateJavaScript("Array.from(document.querySelectorAll('#complex-editor input,#complex-editor textarea'),x=>x.value)") as? [String]
            XCTAssertEqual(actual, kind == "image" ? [values[0], "folder/new%20image.png"] : values)
        }
    }

    @MainActor func testTableCellsAndRowColumnOperationsPreserveUnrelatedBytes() async throws {
        let table = "| A | B |\r\n|:---|---:|\r\n| one | two |\r\n"
        let source = prefix + table + suffix
        let (model, view, _) = try await CopyContentTests().web(source) { _ in true }
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        try await open(view, "table")
        try await field(view, 2, "discarded draft")
        try await button(view, "Add row")
        try await button(view, "Cancel")
        XCTAssertEqual(model.text, source)
        try await open(view, "table")
        try await field(view, 2, "literal | pipe")
        try await button(view, "Add row"); try await button(view, "Add column")
        try await field(view, 8, "extra")
        try await button(view, "Apply")
        let expanded = prefix + "| A | B |  |\r\n| :--- | ---: | --- |\r\n| literal \\| pipe | two |  |\r\n|  |  | extra |\r\n" + suffix
        XCTAssertEqual(model.text, expanded)
        try await open(view, "table")
        try await button(view, "Remove row 2"); try await button(view, "Remove last column")
        try await button(view, "Apply")
        XCTAssertEqual(model.text, prefix + "| A | B |\r\n| :--- | ---: |\r\n| literal \\| pipe | two |\r\n" + suffix)
        model.undoEdit(); try await settle(view); XCTAssertEqual(model.text, expanded)
        model.undoEdit(); try await settle(view); XCTAssertEqual(model.text, source)
        model.redoEdit(); try await settle(view); XCTAssertEqual(model.text, expanded)
    }

    @MainActor func testInvalidInputsStayOpenAndEscapeCancelsWithoutMutatingSource() async throws {
        for (kind, block, index, unsafe) in [
            ("code", "```js\nold\n```\n", 0, "bad language"),
            ("link", "[old](https://example.com)\n", 1, "javascript:alert(1)"),
            ("image", "![old](old.png)\n", 1, "../outside.png")
        ] {
            let source = prefix + block + suffix
            let (model, view, _) = try await CopyContentTests().web(source) { _ in true }
            defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
            try await open(view, kind); try await field(view, index, unsafe); try await button(view, "Apply")
            XCTAssertEqual(model.text, source)
            let error = try await view.evaluateJavaScript("!!document.querySelector('#complex-editor [role=alert]:not([hidden])')") as? Bool
            XCTAssertEqual(error, true)
            try await js(view, "document.querySelector('#complex-editor').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));")
            try await settle(view)
            XCTAssertEqual(model.text, source)
            let closed = try await view.evaluateJavaScript("document.querySelector('#complex-editor')===null && !document.querySelector('#document').inert") as? Bool
            XCTAssertEqual(closed, true)
        }
    }
}
