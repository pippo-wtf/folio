import AppKit
import SwiftUI
import XCTest
@testable import MarkdownReader

final class SharedReviewSidebarLayoutTests: XCTestCase {
    @MainActor func testRecoveryTextWrapsDespiteSidebarSingleLineEnvironment() {
        _ = NSApplication.shared
        let model = ReaderModel(collaboration: CollaborationCoordinator(enabled: false))
        func height(for issue: String) -> CGFloat {
            model.sharedReview.issue = issue
            let host = NSHostingView(rootView:
                SharedReviewSidebar(model: model, paper: .white, ink: .black, accent: .blue)
                    .lineLimit(1)
                    .frame(width: 192)
                    .fixedSize(horizontal: false, vertical: true)
            )
            return host.fittingSize.height
        }
        let short = height(for: "Try again.")
        let long = height(for: "The shared folder is unavailable. Your comment is retained. Reconnect the folder and try sending your comment again.")
        XCTAssertGreaterThan(long, short + 22, "Recovery text must grow to multiple lines at the default sidebar width.")
    }
}
