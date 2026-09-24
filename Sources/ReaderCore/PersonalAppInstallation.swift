import Foundation

/// Only the standalone, non-sandboxed installer calls this transaction.
public enum PersonalAppInstallation {
    public enum Failure: LocalizedError {
        case running, unsafeFolder, rollback(URL)
        public var errorDescription: String? {
            switch self {
            case .running: return "Quit Folio, then run Install Folio again. Your existing app has not been changed."
            case .unsafeFolder: return "Your personal Applications folder points outside your home folder. Installation was stopped without changing any app."
            case .rollback(let location): return "Installation failed. The previous app is preserved at \(location.path)."
            }
        }
    }
    @discardableResult public static func install(source: URL, home: URL, isRunning: () -> Bool,
                                                  verify: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let folder = home.appendingPathComponent("Applications", isDirectory: true)
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedHome) else { throw Failure.unsafeFolder }
        guard !isRunning() else { throw Failure.running }
        try verify(source)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stage = folder.appendingPathComponent(".folio-install-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var retainBackup = false
        defer { if !retainBackup { try? fm.removeItem(at: stage) } }
        let copy = stage.appendingPathComponent("Folio.app")
        let previous = stage.appendingPathComponent("Previous.app")
        let destination = folder.appendingPathComponent("Folio.app", isDirectory: true)
        try fm.copyItem(at: source, to: copy)
        try verify(copy)
        guard !isRunning() else { throw Failure.running }
        let exists = fm.fileExists(atPath: destination.path)
        if exists { try fm.moveItem(at: destination, to: previous) }
        do { try fm.moveItem(at: copy, to: destination) }
        catch {
            if exists {
                do { try fm.moveItem(at: previous, to: destination) }
                catch { retainBackup = true; throw Failure.rollback(previous) }
            }
            throw error
        }
        return destination
    }
}
