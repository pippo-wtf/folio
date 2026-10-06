import XCTest
import AppKit
@testable import MarkdownReader

@MainActor final class SidebarScrollIndicatorTests: XCTestCase {
    final class Rows: NSObject, NSTableViewDataSource {
        var count = 100
        func numberOfRows(in tableView: NSTableView) -> Int { count }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Row" }
    }
    func fixture(rows: Int = 100) -> (NSWindow, NSScrollView, SidebarScrollIndicator.IndicatorView, Rows) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 160))
        window.contentView = root
        let scroll = NSScrollView(frame: root.bounds)
        let table = NSTableView(frame: root.bounds)
        let source = Rows(); source.count = rows
        table.headerView = nil; table.rowHeight = 20
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Text")))
        table.dataSource = source
        scroll.documentView = table
        root.addSubview(scroll)
        table.reloadData()
        let indicator = SidebarScrollIndicator.IndicatorView(frame: root.bounds)
        root.addSubview(indicator)
        window.orderBack(nil)
        root.layoutSubtreeIfNeeded()
        indicator.connect()
        return (window, scroll, indicator, source)
    }
    func pixels(_ view: NSView) throws -> [(Int, Int, NSColor)] {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.clear.setFill(); view.bounds.fill(using: .copy)
        view.draw(view.bounds)
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var result: [(Int, Int, NSColor)] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.01 {
                    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                    result.append((Int(CGFloat(x) / scale), Int(CGFloat(y) / scale), color))
                }
            }
        }
        return result
    }
    func scroll(_ view: NSScrollView, y: CGFloat) {
        view.contentView.scroll(to: NSPoint(x: 0, y: y))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.contentView)
    }
    func testLongSidebarUsesCustomThumbAndFadesWithoutInvisibleHitTarget() async throws {
        let (window, scrollView, indicator, source) = fixture()
        defer { withExtendedLifetime(source) {}; indicator.disconnect(); window.close() }
        indicator.reduceMotion = { false } // Pin the normal-motion branch independently of the host preference.
        XCTAssertTrue(scrollView.verticalScroller is SidebarScrollIndicator.HiddenScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(try pixels(indicator).isEmpty)
        scroll(scrollView, y: 100)
        let parentHit = try XCTUnwrap((0..<160).map { NSPoint(x: 214, y: $0) }.first { indicator.hitTest($0) != nil })
        let active = try pixels(indicator)
        XCTAssertFalse(active.isEmpty)
        let minX = try XCTUnwrap(active.map { $0.0 }.min()), maxX = try XCTUnwrap(active.map { $0.0 }.max())
        XCTAssertEqual(maxX - minX + 1, 3)
        XCTAssertEqual(maxX, 214)
        let strongest = try XCTUnwrap(active.max { $0.2.alphaComponent < $1.2.alphaComponent }?.2)
        XCTAssertEqual(strongest.redComponent, strongest.greenComponent, accuracy: 0.02)
        XCTAssertEqual(strongest.greenComponent, strongest.blueComponent, accuracy: 0.02)
        XCTAssertEqual(strongest.alphaComponent, 0.5, accuracy: 0.02)
        scroll(scrollView, y: 110)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNotNil(indicator.hitTest(parentHit), "Scrolling stays visible before the 700ms idle delay")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(indicator.hitTest(parentHit), "Normal motion fades rather than disappearing at 700ms")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try pixels(indicator).isEmpty)
        XCTAssertNil(indicator.hitTest(parentHit), "An invisible scrollbar must not intercept clicks")
    }
    func testReducedMotionHidesAfterIdleWithoutFade() async throws {
        let (window, scrollView, indicator, source) = fixture()
        defer { withExtendedLifetime(source) {}; indicator.disconnect(); window.close() }
        indicator.reduceMotion = { true }
        scroll(scrollView, y: 100)
        let point = try XCTUnwrap((0..<160).map { NSPoint(x: 214, y: $0) }.first { indicator.hitTest($0) != nil })
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNotNil(indicator.hitTest(point))
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNil(indicator.hitTest(point))
        XCTAssertTrue(try pixels(indicator).isEmpty)
    }
    func testShortSidebarHasNoThumb() throws {
        let (window, scrollView, indicator, source) = fixture(rows: 2)
        defer { withExtendedLifetime(source) {}; indicator.disconnect(); window.close() }
        scroll(scrollView, y: 1)
        XCTAssertTrue(try pixels(indicator).isEmpty)
        XCTAssertNil(indicator.hitTest(NSPoint(x: 214, y: 80)))
    }
}
