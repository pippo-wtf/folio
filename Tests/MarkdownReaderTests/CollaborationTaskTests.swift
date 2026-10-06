import XCTest
import AppKit
import ReaderCore
@testable import MarkdownReader

final class CollaborationTaskTests: XCTestCase {
    @MainActor func testTaskStatusIsDurableBeforePendingSourceAndDoesNotResolveThread() async throws {
        let (c, source, _) = try await CollaborationReviewTests().fixture()
        let doc = try XCTUnwrap(c.currentDocument), snapshot = try DocumentSnapshot(url: source)
        let offset = (snapshot.text as NSString).range(of: "[ ]").location + 1
        let raw = CollaborationSnapshotID.hash(snapshot.bytes)
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: offset, in: snapshot.text, rawSourceRevision: raw))
        let taskValue = await c.registerSharedTask(document: doc, anchor: anchor)
        let task = try XCTUnwrap(taskValue)
        for status in [SharedTaskState.open, .inProgress, .done, .open] {
            let result = await c.setSharedTask(document: doc, taskID: task, state: status)
            XCTAssertNotNil(result)
            XCTAssertEqual(c.sharedTaskStates(taskID: task), [status == .done ? .done : .open])
            if let event = c.events.first(where: { $0.id == result }), case .taskState(_, let written, _, _) = event.payload {
                XCTAssertNotEqual(written, .inProgress, "New events must use binary checkbox states")
            }
        }
        let heads = c.state?.taskHeads[task] ?? []
        let origin = try XCTUnwrap(c.state?.tasks[task])
        let profile = try XCTUnwrap(c.profile)
        let legacy = CollaborationEvent(workspaceID: doc.workspaceID, documentID: doc.documentID, participantID: profile.participantID, deviceID: profile.deviceID, authorName: profile.displayName, rawSourceRevision: raw, parents: heads + [origin.id], payload: .taskState(taskID: task, state: .inProgress, supersedes: heads, rawSourceRevision: raw))
        let accepted = await c.submit(legacy)
        XCTAssertTrue(accepted)
        XCTAssertEqual(c.sharedTaskStates(taskID: task), [.open], "Legacy unfinished work is an open checkbox")
        if case .taskState(_, let historicalState, _, _) = legacy.payload {
            XCTAssertEqual(historicalState, .inProgress, "Do not rewrite historical shared events")
        }
        XCTAssertEqual(try Data(contentsOf: source), snapshot.bytes)
        XCTAssertTrue(c.state?.threadHeads.isEmpty == true)
        XCTAssertEqual(c.sharedTaskSourceStatus(taskID: task, source: snapshot.text), "Aligned with Markdown")
        let done = await c.setSharedTask(document: doc, taskID: task, state: .done)
        XCTAssertNotNil(done)
        XCTAssertEqual(c.sharedTaskSourceStatus(taskID: task, source: snapshot.text), "Task status saved · Markdown update pending")
        await c.stopWatching()
    }
    @MainActor func testContraryConcurrentStatesRetainBothHeadsAndExplicitResolutionUsesAll() async throws {
        let (a, source, root) = try await CollaborationReviewTests().fixture()
        let doc = try XCTUnwrap(a.currentDocument), snapshot = try DocumentSnapshot(url: source)
        let offset = (snapshot.text as NSString).range(of: "[ ]").location + 1
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: offset, in: snapshot.text, rawSourceRevision: CollaborationSnapshotID.hash(snapshot.bytes)))
        let registered = await a.registerSharedTask(document: doc, anchor: anchor)
        let id = try XCTUnwrap(registered)
        let b = CollaborationCoordinator(enabled: true, localRoot: root.appendingPathComponent("b"))
        await b.join(folder: source.deletingLastPathComponent(), create: false, displayName: "Alex")
        _ = await b.openDocument(id: doc.documentID); b.selectDocument(url: source)
        let one = await a.setSharedTask(document: doc, taskID: id, state: .done)
        let two = await b.setSharedTask(document: doc, taskID: id, state: .open)
        XCTAssertNotNil(one); XCTAssertNotNil(two)
        await a.refresh()
        XCTAssertEqual(a.state?.taskHeads[id]?.count, 2)
        XCTAssertEqual(Set(a.sharedTaskStates(taskID: id).map(\.rawValue)), ["done", "open"])
        let resolution = await a.setSharedTask(document: doc, taskID: id, state: .inProgress)
        XCTAssertNotNil(resolution)
        XCTAssertEqual(a.state?.taskHeads[id]?.count, 1)
        XCTAssertEqual(a.events.last(where: { $0.id == resolution })?.supersedes.count, 2)
        await a.stopWatching(); await b.stopWatching()
    }
    @MainActor func testDirtyDraftRetainsTaskStatusAndLeavesSourcePending() async throws {
        _ = NSApplication.shared
        let (c, source, _) = try await CollaborationReviewTests().fixture()
        let doc = try XCTUnwrap(c.currentDocument), snapshot = try DocumentSnapshot(url: source)
        let offset = (snapshot.text as NSString).range(of: "[ ]").location + 1
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: offset, in: snapshot.text, rawSourceRevision: CollaborationSnapshotID.hash(snapshot.bytes)))
        let registered = await c.registerSharedTask(document: doc, anchor: anchor)
        let id = try XCTUnwrap(registered)
        let model = ReaderModel(collaboration: c)
        model.recoveryStartupReady = true; model.load(source)
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        model.text = snapshot.text + "Unsaved draft stays here.\n"
        let draft = model.text
        c.sourceSavingEnabled = true
        model.setSharedTask(id, state: .done)
        for _ in 0..<100 where c.sharedTaskStates(taskID: id) != [.done] { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(c.sharedTaskStates(taskID: id), [.done])
        XCTAssertEqual(model.text, draft); XCTAssertTrue(model.dirty)
        XCTAssertEqual(try Data(contentsOf: source), snapshot.bytes)
        XCTAssertTrue(model.sharedReview.issue?.contains("Markdown update pending") == true)
        await c.stopWatching()
    }

}
