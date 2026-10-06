import AppKit
import Foundation

/// Directory notifications are hints. Every hint/fallback requests a bounded full scan.
final class SharedFolderMonitor: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let queue = DispatchQueue(label: "wtf.pippo.folio.collaboration.monitor")
    private let debounce: TimeInterval
    private let changed: () -> Void
    private var pending: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var stopped = false

    init(folder: URL, debounce: TimeInterval = 0.25, fallbackInterval: TimeInterval = 30, changed: @escaping () -> Void) {
        presentedItemURL = folder; self.debounce = debounce; self.changed = changed
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.name = "Folio shared folder presenter"
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + fallbackInterval, repeating: fallbackInterval)
        timer.setEventHandler { [weak self] in self?.request() }
        self.timer = timer; timer.resume()
        for (center, name) in [(NotificationCenter.default, NSApplication.didBecomeActiveNotification),
                                (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)] {
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.request() }
            observers.append((center, observer))
        }
    }
    func request() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.pending = nil; self.changed()
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }
    func presentedItemDidChange() { request() }
    func presentedSubitemDidAppear(at url: URL) { request() }
    func presentedSubitemDidChange(at url: URL) { request() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { request() }
    func presentedItemDidMove(to newURL: URL) { request() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) { request(); completionHandler(nil) }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) { request(); completionHandler(nil) }
    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        queue.sync { stopped = true; pending?.cancel(); pending = nil; timer?.cancel(); timer = nil }
    }
    deinit { timer?.cancel(); for (center, observer) in observers { center.removeObserver(observer) } }
}
