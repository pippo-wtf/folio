import Combine
import Foundation
import Sparkle
import ReaderCore

/// The packaged app enables Sparkle only when both the HTTPS feed and EdDSA
/// public key have been injected into Info.plist by the release packaging step.
@MainActor
final class FolioUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?

    init() {
        guard UpdateConfiguration.isSafe(Bundle.main.infoDictionary ?? [:]) else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // A stale preference must never opt this product into background
        // downloads. The Info.plist also forbids presenting that option.
        controller.updater.automaticallyDownloadsUpdates = false
        controller.startUpdater()
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
