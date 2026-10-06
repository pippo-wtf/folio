import XCTest
import WebKit
@testable import MarkdownReader

final class NarrowLayoutAcceptanceTests: XCTestCase {
    @MainActor func testNarrowReadingWidthComplexControlsAndScrollableFormatting() async throws {
        let (_, view, _) = try await CopyContentTests().web("# Everyday QA\n\nParagraph.\n\n```js\nx()\n```\n") { _ in true }
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.css"), encoding: .utf8)
        let encoded = String(data: try JSONEncoder().encode(css), encoding: .utf8)!
        _ = try await view.evaluateJavaScript("(()=>{const s=document.createElement('style');s.textContent=\(encoded);document.head.prepend(s);Folio.appearance('light',1.5,{bodySize:24,pageInset:100,topInset:160});})()")
        let wide = try await view.evaluateJavaScript("(()=>{const s=getComputedStyle(document.querySelector('main'));return [parseFloat(s.paddingLeft),parseFloat(s.paddingTop),parseFloat(getComputedStyle(document.querySelector('h1')).fontSize)];})()") as! [Double]
        XCTAssertEqual(wide[0], 96); XCTAssertEqual(wide[1], 160)
        XCTAssertEqual(wide[2], 59.4, accuracy: 0.001)
        view.setFrameSize(NSSize(width: 360, height: 468))
        try await Task.sleep(for: .milliseconds(100))
        let narrow = try await view.evaluateJavaScript("(()=>{const m=document.querySelector('main'),s=getComputedStyle(m),b=document.querySelector('.complex-edit-button').getBoundingClientRect();return [m.clientWidth-parseFloat(s.paddingLeft)-parseFloat(s.paddingRight),parseFloat(s.paddingTop),b.left,b.right,innerWidth,parseFloat(getComputedStyle(document.querySelector('h1')).fontSize)];})()") as! [Double]
        XCTAssertGreaterThanOrEqual(narrow[0], 280, "Narrow pane must retain a usable text measure")
        XCTAssertLessThanOrEqual(narrow[1], 48)
        XCTAssertGreaterThanOrEqual(narrow[2], 0)
        XCTAssertLessThanOrEqual(narrow[3], narrow[4], "Complex Edit control must stay on screen")
        XCTAssertEqual(narrow[5], wide[2], "User typography and zoom remain unchanged")
        let toolbar = try await view.evaluateJavaScript("(()=>{const a=document.querySelector('.format-actions');a.scrollLeft=a.scrollWidth;const last=a.lastElementChild.getBoundingClientRect(),bounds=a.getBoundingClientRect();return [a.scrollWidth>a.clientWidth,a.scrollLeft>0,last.right<=bounds.right+1,last.left>=bounds.left];})()") as! [Bool]
        XCTAssertEqual(toolbar, [true,true,true,true], "Every formatting action remains horizontally reachable")
    }
}
