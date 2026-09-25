import Foundation

// Retain the SwiftUI window action after its view closes. Queue cold-start file
// requests until SwiftUI supplies the action; reopen the named reader scene.
@MainActor final class ReaderWindowPresenter {
    static let shared = ReaderWindowPresenter()
    private var present: (() -> Void)?
    private var pending = false
    func install(_ action: @escaping () -> Void) {
        present = action
        if pending { pending = false; action() }
    }
    func request() {
        guard let present else { pending = true; return }
        present()
    }
}
