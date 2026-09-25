import XCTest
import AppKit
@testable import MarkdownReader

final class WindowChromeTests: XCTestCase {
    @MainActor func testChromeDoesNotOverrideTheAppearanceOwner() {
        _ = NSApplication.shared
        let window = AppearanceCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WindowChrome.ConfiguratorView()
        window.contentView = view
        // SwiftUI owns the window appearance. During a transition its value may
        // legitimately differ from the representable's pending color scheme.
        for name: NSAppearance.Name in [.aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: name)
            let applied = window.appearanceAssignments
            for dark in [false, true, false, true, false] {
                view.dark = dark
                view.applyIfPossible()
            }
            XCTAssertEqual(window.appearanceAssignments, applied, "Chrome must not fight the SwiftUI appearance owner")
            XCTAssertEqual(window.appearance?.name, name)
        }
        window.contentView = nil
    }
}

@MainActor private final class AppearanceCountingWindow: NSWindow {
    var appearanceAssignments = 0
    override var appearance: NSAppearance? {
        didSet { appearanceAssignments += 1 }
    }
}
