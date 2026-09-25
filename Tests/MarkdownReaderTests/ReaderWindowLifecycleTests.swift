import XCTest
import AppKit
@testable import MarkdownReader

final class ReaderWindowLifecycleTests: XCTestCase {
    @MainActor func testColdOpenWaitsForPresenterAndLaterOpensStillPresent() {
        let presenter = ReaderWindowPresenter()
        var opened = 0
        presenter.request()
        presenter.request()
        presenter.install { opened += 1 }
        XCTAssertEqual(opened, 1)
        presenter.request()
        XCTAssertEqual(opened, 2)
        presenter.install { opened += 10 }
        XCTAssertEqual(opened, 2)
        presenter.request()
        XCTAssertEqual(opened, 12)
    }
    @MainActor func testClosingLastWindowCannotDiscardFinderOpenEvent() {
        _ = NSApplication.shared
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp),
                       "Finder can deliver an open event while the last window is closing")
    }
}
