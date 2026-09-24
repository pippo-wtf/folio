import Combine
import Foundation
import Sparkle
import ReaderCore

/// The packaged app enables Sparkle only when both the HTTPS feed and EdDSA
/// public key have been injected into Info.plist by the release packaging step.
@MainActor
final class FolioUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private var updater: SPUUpdater?
    private let driver = FolioUpdateDriver()

    init() {
        guard UpdateConfiguration.isSafe(Bundle.main.infoDictionary ?? [:]) else { return }

        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        // A stale preference must never opt this product into background
        // downloads. The Info.plist also forbids presenting that option.
        updater.automaticallyDownloadsUpdates = false
        do { try updater.start() }
        catch { driver.showUpdaterError(error, acknowledgement: {}) ; return }
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater?.checkForUpdates()
    }
}
