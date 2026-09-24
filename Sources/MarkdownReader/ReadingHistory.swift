import Foundation

struct RecentDocument: Codable, Identifiable {
    var id: String
    var name: String
    var bookmark: Data
}
struct ReadingPosition: Codable {
    var heading: String
    var offset: Double
    var fraction: Double
}
extension ReaderModel {
    func rememberDocument(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let item = RecentDocument(id: url.standardizedFileURL.path, name: url.lastPathComponent, bookmark: bookmark)
        recentDocuments.removeAll { $0.id == item.id }; recentDocuments.insert(item, at: 0)
        recentDocuments = Array(recentDocuments.prefix(20))
        persistHistory()
    }
    func persistHistory() {
        if let data = try? JSONEncoder().encode(recentDocuments) { UserDefaults.standard.set(data, forKey: "recentDocumentsV1") }
    }
    func openRecent(_ item: RecentDocument) {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: item.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            load(url)
        } catch { self.error = "This recent file is unavailable. Choose Open to grant access again." }
    }
    func clearHistory() {
        recentDocuments = []; persistHistory()
        UserDefaults.standard.removeObject(forKey: "readingPositionsV1")
        readingPositions = [:]
    }
    func startReading() {
        guard recoveryPromptReady, !started else { return }; started = true
        let recovered = restoreRecovery()
        if recoveryDecisionInterrupted { return }
        recoveryStartupReady = true
        let requestedURL = pendingStartupURL
        pendingStartupURL = nil
        if recovered { return }
        if let requestedURL { load(requestedURL); return }
        guard fileURL == nil, text.isEmpty else { return }
        if let item = recentDocuments.first { openRecent(item) } else { showWelcome() }
    }
}
