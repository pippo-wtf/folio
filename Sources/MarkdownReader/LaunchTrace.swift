import AppKit

// Bounded local lifecycle log; no document text, titles, or paths.
@MainActor enum LaunchTrace {
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(BuildChannel.storage).appendingPathComponent("launch-events.log")
    static func record(_ event: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) visible=\(NSApp.windows.filter { $0.isVisible }.count) \(event)"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let lines = (previous.split(separator: "\n").suffix(199).map(String.init) + [line]).joined(separator: "\n") + "\n"
            try lines.write(to: file, atomically: true, encoding: .utf8)
        } catch { /* Diagnostics must never interrupt opening a document. */ }
    }
}
