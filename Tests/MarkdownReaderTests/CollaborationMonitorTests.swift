import XCTest
@testable import MarkdownReader

final class CollaborationMonitorTests: XCTestCase {
    func testBurstDebouncesAndFallbackRecoversMissedNotifications() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let burst = expectation(description: "one debounced burst")
        burst.assertForOverFulfill = true
        let fallback = expectation(description: "fallback")
        let lock = NSLock(); var count = 0
        let monitor = SharedFolderMonitor(folder: folder, debounce: 0.04, fallbackInterval: 0.2) {
            lock.lock(); count += 1; let n = count; lock.unlock()
            if n == 1 { burst.fulfill() }; if n == 2 { fallback.fulfill() }
        }
        for _ in 0..<20 { monitor.presentedItemDidChange() }
        await fulfillment(of: [burst, fallback], timeout: 1)
        monitor.stop()
        try await Task.sleep(for: .milliseconds(300))
        let final = lock.withLock { count }
        XCTAssertEqual(final, 2)
    }
    func testRealDirectoryPresenterObservesNestedAtomicReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("nested/test.md")
        try Data("old".utf8).write(to: source)
        let change = expectation(description: "presented subitem")
        let monitor = SharedFolderMonitor(folder: folder, debounce: 0.03, fallbackInterval: 10) { change.fulfill() }
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forReplacing, error: &coordinationError) { url in
            try? Data("new".utf8).write(to: url, options: .atomic)
        }
        XCTAssertNil(coordinationError)
        await fulfillment(of: [change], timeout: 3)
        monitor.stop()
    }
}
