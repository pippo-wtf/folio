import XCTest
import WebKit
@testable import MarkdownReader

final class TableWidthTests: XCTestCase {
    @MainActor func testTablesExpandWithoutClippingInReadAndWrite() async throws {
        let cells = (0..<8).map { "[Column\($0)](https://example.com) `" + String(repeating: "long_identifier_", count: 5) + "`" }
        let source = "# Heading\n\nNormal paragraph stays in the reading column.\n\n| " + (0..<8).map { "Column \($0)" }.joined(separator: " | ") + " |\n| " + Array(repeating: "---", count: 8).joined(separator: " | ") + " |\n| " + cells.joined(separator: " | ") + " |\n\n| Name | Status |\n| --- | --- |\n| Table editing | Available |\n\n```text\nCode stays in its column\n```\n"
        for editing in [false, true] {
            let (model, view, _) = try await CopyContentTests().web(source, editing: editing) { _ in true }
            defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "folio") }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let css = try String(contentsOf: root.appendingPathComponent("Sources/MarkdownReader/Resources/reader.css"), encoding: .utf8)
            let encoded = String(data: try JSONEncoder().encode(css), encoding: .utf8)!
            _ = try await view.evaluateJavaScript("(()=>{const s=document.createElement('style');s.textContent=\(encoded);document.head.prepend(s)})()")
            for (width, zoom, theme) in [(1400.0,1.0,"light"),(800.0,1.0,"dark"),(360.0,1.5,"light")] {
                view.setFrameSize(NSSize(width: width, height: 780))
                _ = try await view.evaluateJavaScript("Folio.appearance('\(theme)',\(zoom),{bodyFont:'Source Serif 4',bodySize:24,columnWidth:40})")
                let result = try await view.evaluateJavaScript("""
                (()=>{const w=document.querySelector('.table-scroll'),p=document.querySelector('main p'),t=document.querySelector('table'),r=w.getBoundingClientRect(),pr=p.getBoundingClientRect(),code=document.querySelector('.code-block').getBoundingClientRect();
                // WebKit counts hanging whitespace in editable scrollWidth. Check actual
                // scrollability and non-whitespace text bounds instead of that extent.
                w.scrollLeft=100;
                let overflow=0; for(const c of t.querySelectorAll('td,th')){const b=c.getBoundingClientRect(),walk=document.createTreeWalker(c,NodeFilter.SHOW_TEXT);let node;while(node=walk.nextNode()){if(!node.textContent.trim())continue;const range=document.createRange();range.selectNodeContents(node);for(const rect of range.getClientRects())overflow=Math.max(overflow,rect.right-b.right,b.left-rect.left);}}
                return [r.width,pr.width,w.scrollLeft,document.documentElement.scrollWidth-innerWidth,r.left,r.right,Math.abs((r.left+r.right)-(pr.left+pr.right)),code.width,overflow];})()
                """) as! [Double]
                XCTAssertLessThanOrEqual(result[0], result[1]*1.25+1)
                XCTAssertGreaterThanOrEqual(result[0], result[1]-1)
                if width == 1400 { XCTAssertEqual(result[0], result[1]*1.25, accuracy: 1) }
                XCTAssertLessThanOrEqual(result[2], 1, "Table must not scroll")
                XCTAssertLessThanOrEqual(result[3], 1, "Page must not scroll sideways")
                XCTAssertGreaterThanOrEqual(result[4], 16)
                XCTAssertLessThanOrEqual(result[5], width-16)
                XCTAssertLessThanOrEqual(result[6], 1, "Table remains centered on text")
                XCTAssertEqual(result[7], result[1], accuracy: 1, "Code retains normal width")
                XCTAssertLessThanOrEqual(result[8], 1, "Cell contents must wrap, not clip")
                let short = try await view.evaluateJavaScript("(()=>{const t=[...document.querySelectorAll('.table-scroll')].at(-1),r=t.getBoundingClientRect(),b=t.parentElement.querySelector('button')?.getBoundingClientRect();return [r.width,t.scrollWidth-t.clientWidth,b?.right??0]})()") as! [Double]
                XCTAssertEqual(short[0], result[0], accuracy: 1)
                XCTAssertLessThanOrEqual(short[1], 1)
                XCTAssertLessThanOrEqual(short[2], width)
                XCTAssertEqual(model.text, source)
            }
        }
    }
}
