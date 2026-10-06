import XCTest
@testable import ReaderCore

final class CollaborationWorkspaceTests: XCTestCase {
    private func setup(limit: Int = 5000) throws -> (URL, URL, SharedWorkspaceStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("shared")
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (folder, local, SharedWorkspaceStore(folderURL: folder, localRoot: local, workspaceID: UUID(), candidateLimit: limit))
    }

    private func write(_ path: String, folder: URL, text: String = "# Markdown") throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testNestedInventoryTracksAdditionsAndRemovalAndExcludesReviewMetadata() throws {
        let (folder, _, store) = try setup()
        try write("a/same.md", folder: folder)
        try write("b/same.MARKDOWN", folder: folder)
        try write("Folio Review/hidden.md", folder: folder)
        try write("ordinary.txt", folder: folder)
        try store.beginAccess()
        XCTAssertEqual(try store.inventory(), ["a/same.md", "b/same.MARKDOWN"])
        try write("new.md", folder: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a/same.md"))
        XCTAssertEqual(try store.inventory(), ["b/same.MARKDOWN", "new.md"])
    }

    func testSymlinkedFilesAndDirectoriesNeverEscapeSelectedRoot() throws {
        let (folder, _, store) = try setup()
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside")
        try write("secret.md", folder: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("secret.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
        try write("safe.md", folder: folder)
        try store.beginAccess()
        XCTAssertEqual(try store.inventory(), ["safe.md"])
        for path in ["secret.md", "escape/secret.md", "../outside/secret.md", "/secret.md", "Folio Review/secret.md"] {
            XCTAssertThrowsError(try store.bind(document: SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: path)))
        }
    }

    func testInventoryCapacityFailureNeverReturnsPartialMarkdownList() throws {
        let (folder, _, store) = try setup(limit: 3)
        for index in 0..<4 { try write("\(index).md", folder: folder) }
        try store.beginAccess()
        XCTAssertThrowsError(try store.inventory()) { XCTAssertEqual($0 as? CollaborationError, .capacityExceeded) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("3.md"))
        XCTAssertEqual(try store.inventory(), ["0.md", "1.md", "2.md"])
    }

    func testDefaultInventoryLimitStopsAt5001CandidatesIncludingNonMarkdownFiles() throws {
        let (folder, _, store) = try setup()
        for index in 0..<5001 { try write("\(index).txt", folder: folder) }
        try store.beginAccess()
        XCTAssertThrowsError(try store.inventory()) { XCTAssertEqual($0 as? CollaborationError, .capacityExceeded) }
    }

    func testDuplicateBindingSetupIsIdempotentButDifferentIdentitySamePathIsRejected() throws {
        let (folder, local, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")
        try store.bind(document: ref)
        try store.bind(document: ref)
        XCTAssertThrowsError(try store.bind(document: SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")))
        let reopened = SharedWorkspaceStore(localRoot: local, workspaceID: store.workspaceID)
        try reopened.restoreAccess()
        XCTAssertEqual(try reopened.document(documentID: ref.documentID), ref)
        XCTAssertEqual(try reopened.resolve(documentID: ref.documentID), folder.appendingPathComponent("doc.md"))
    }

    func testResourceIdentityPreservesUniqueRenameAndNeverAssignsCopyOriginalIdentity() throws {
        let (folder, _, store) = try setup()
        try write("old.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "old.md")
        try store.bind(document: ref)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("old.md"), to: folder.appendingPathComponent("copy.md"))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("old.md"), to: folder.appendingPathComponent("renamed.md"))
        XCTAssertEqual(try store.document(documentID: ref.documentID).relativePath, "renamed.md")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("renamed.md"))
        XCTAssertThrowsError(try store.resolve(documentID: ref.documentID))
        try store.bind(document: SharedDocumentRef(workspaceID: store.workspaceID, documentID: ref.documentID, relativePath: "copy.md"))
        XCTAssertEqual(try store.document(documentID: ref.documentID).documentID, ref.documentID)
    }

    func testAtomicReplacementAtExplicitBoundPathPreservesDocumentIdentity() throws {
        let (folder, _, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")
        try store.bind(document: ref)
        try Data("# Markdown".utf8).write(to: folder.appendingPathComponent("doc.md"), options: .atomic)
        XCTAssertEqual(try store.document(documentID: ref.documentID), ref)
        XCTAssertEqual(try store.resolve(documentID: ref.documentID), folder.appendingPathComponent("doc.md"))
    }

    func testOriginalMovedElsewhereAndCopyAtBoundPathRequiresExplicitReconnect() throws {
        let (folder, _, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")
        try store.bind(document: ref)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("doc.md"), to: folder.appendingPathComponent("moved.md"))
        try FileManager.default.copyItem(at: folder.appendingPathComponent("moved.md"), to: folder.appendingPathComponent("doc.md"))
        XCTAssertThrowsError(try store.resolve(documentID: ref.documentID))
    }

    func testWorkspaceBindingsCannotOverwriteReplicaBindingsInSameLocalRoot() throws {
        let (folder, local, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")
        let replicaFile = local.appendingPathComponent("bindings.json")
        let replicaBytes = try JSONEncoder().encode([ref.documentID.uuidString: "doc.md"])
        try replicaBytes.write(to: replicaFile)
        try store.bind(document: ref)
        XCTAssertEqual(try Data(contentsOf: replicaFile), replicaBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("workspace-bindings.json").path))
        XCTAssertEqual(try store.document(documentID: ref.documentID), ref)
    }

    func testCorruptBindingsFailClosedAndRemainUnchanged() throws {
        let (folder, local, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")
        try store.bind(document: ref)
        let file = local.appendingPathComponent("workspace-bindings.json")
        let bytes = Data("broken".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.bind(document: ref))
        XCTAssertThrowsError(try store.resolve(documentID: ref.documentID))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testRevokedFolderPermissionsNeverReportsCompleteInventory() throws {
        let (folder, _, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try store.inventory())
    }

    func testAmbiguousHardLinksCannotProveRenameOrRegisterTwoDocumentIDs() throws {
        let (folder, _, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")
        try store.bind(document: ref)
        try FileManager.default.linkItem(at: folder.appendingPathComponent("doc.md"), to: folder.appendingPathComponent("other.md"))
        XCTAssertThrowsError(try store.resolve(documentID: ref.documentID))
        XCTAssertThrowsError(try store.bind(document: SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "other.md")))
    }

    func testBindingsRemainLocalAndEnforceEightExplicitDocuments() throws {
        let (folder, local, store) = try setup()
        try store.beginAccess()
        for index in 0..<9 {
            try write("\(index).md", folder: folder)
            let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "\(index).md")
            if index < 8 { try store.bind(document: ref) }
            else { XCTAssertThrowsError(try store.bind(document: ref)) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("workspace-bindings.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 9)
    }

    func testLocalReplicaUnderSharedFolderIsRejectedBeforeWritingMetadata() throws {
        let (folder, _, old) = try setup()
        let local = folder.appendingPathComponent("local")
        let store = SharedWorkspaceStore(folderURL: folder, localRoot: local, workspaceID: old.workspaceID)
        XCTAssertThrowsError(try store.beginAccess())
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
    }

    func testCaseAliasCannotPlaceLocalReplicaInsideSharedRoot() throws {
        let (folder, _, old) = try setup()
        let aliasRoot = folder.deletingLastPathComponent().appendingPathComponent("SHARED")
        guard FileManager.default.fileExists(atPath: aliasRoot.path) else { throw XCTSkip("Requires case-insensitive filesystem") }
        let local = aliasRoot.appendingPathComponent("local")
        let store = SharedWorkspaceStore(folderURL: folder, localRoot: local, workspaceID: old.workspaceID)
        XCTAssertThrowsError(try store.beginAccess())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("local").path))
    }

    func testEndAccessPreservesBookmarkForRelaunchButStopWatchingOnlyRemovesBookmark() throws {
        let (folder, local, store) = try setup()
        try write("doc.md", folder: folder)
        try store.beginAccess()
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: UUID(), relativePath: "doc.md")
        try store.bind(document: ref)
        let bindings = try Data(contentsOf: local.appendingPathComponent("workspace-bindings.json"))
        let recovery = local.appendingPathComponent("recovery.bin")
        try Data("recovery".utf8).write(to: recovery)
        store.endAccess()
        XCTAssertThrowsError(try store.inventory())
        let reopened = SharedWorkspaceStore(localRoot: local, workspaceID: store.workspaceID)
        try reopened.restoreAccess()
        try reopened.stopWatching()
        XCTAssertThrowsError(try reopened.restoreAccess())
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("doc.md").path))
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("workspace-bindings.json")), bindings)
        XCTAssertEqual(try Data(contentsOf: recovery), Data("recovery".utf8))
    }

    func testMissingFolderAndCorruptBookmarkRequireReconnectWithoutMutation() throws {
        let (folder, local, store) = try setup()
        try store.beginAccess()
        let bookmark = local.appendingPathComponent("folder.bookmark")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: bookmark)
        store.endAccess()
        XCTAssertThrowsError(try store.restoreAccess())
        XCTAssertEqual(try Data(contentsOf: bookmark), corrupt)
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try store.beginAccess(folderURL: folder))
    }
}
