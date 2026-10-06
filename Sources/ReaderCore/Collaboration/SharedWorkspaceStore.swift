import Darwin
import Foundation

/// Local access and document bindings, separate from immutable shared manifests.
/// Use on the coordinator's serial worker; filesystem reads can wait on a provider.
public final class SharedWorkspaceStore {
    public let localRoot: URL
    public let workspaceID: UUID
    public private(set) var folderURL: URL?
    public private(set) var hasSecurityScopedAccess = false
    private var selectedFolder: URL?
    private var scopedURL: URL?
    private let candidateLimit: Int

    private struct ResourceIdentity: Codable, Hashable {
        let device: Int32
        let inode: UInt64
        let birthSeconds, birthNanoseconds: Int64
    }
    private struct Binding: Codable {
        var document: SharedDocumentRef
        let resource: ResourceIdentity
    }
    private struct Bindings: Codable {
        let version: Int
        let workspaceID: UUID
        var items: [Binding]
    }
    private struct Candidate {
        let relativePath: String
        let url: URL
        let resource: ResourceIdentity
    }

    public init(folderURL: URL? = nil, localRoot: URL, workspaceID: UUID, candidateLimit: Int = 5000) {
        self.selectedFolder = folderURL
        self.localRoot = localRoot
        self.workspaceID = workspaceID
        self.candidateLimit = min(candidateLimit, 5000)
    }
    deinit { endAccess() }

    /// Explicit folder selection/reconnection. Only local bookmark metadata is written.
    @discardableResult public func beginAccess(folderURL: URL? = nil) throws -> URL {
        guard let selected = folderURL ?? selectedFolder else { throw CollaborationError.unavailable }
        endAccess()
        let acquired = selected.startAccessingSecurityScopedResource()
        do {
            let root = try validatedRoot(selected)
            let bookmark = try selected.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
            try bookmark.write(to: bookmarkURL, options: .atomic)
            activate(selected: selected, root: root, acquired: acquired)
            return root
        } catch {
            if acquired { selected.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Resolve the persisted URL, including supported folder moves. Stale or invalid
    /// bookmarks require an explicit folder choice; they are never silently replaced.
    @discardableResult public func restoreAccess() throws -> URL {
        endAccess()
        let handle = try FileHandle(forReadingFrom: bookmarkURL)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard bytes.count <= 64 * 1024 else { throw CollaborationError.invalid("Invalid folder bookmark; reconnect the folder.") }
        var stale = false
        let selected = try URL(resolvingBookmarkData: bytes, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw CollaborationError.invalid("Folder bookmark is stale; reconnect the folder.") }
        let acquired = selected.startAccessingSecurityScopedResource()
        do {
            let root = try validatedRoot(selected)
            activate(selected: selected, root: root, acquired: acquired)
            return root
        } catch {
            if acquired { selected.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// App shutdown/suspension releases access but keeps the bookmark for relaunch.
    public func endAccess() {
        if hasSecurityScopedAccess { scopedURL?.stopAccessingSecurityScopedResource() }
        hasSecurityScopedAccess = false
        scopedURL = nil
        folderURL = nil
    }

    /// Explicit Stop watching forgets access only. Shared files, bindings and recovery remain.
    public func stopWatching() throws {
        endAccess()
        selectedFolder = nil
        do { try FileManager.default.removeItem(at: bookmarkURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
    }

    public func inventory() throws -> [String] { try candidates().map(\.relativePath) }

    /// An explicit registration/reconnect choice may change one current local binding.
    public func bind(document: SharedDocumentRef) throws {
        guard document.workspaceID == workspaceID, validPath(document.relativePath) else { throw CollaborationError.identityConflict }
        let inventory = try candidates()
        guard let selected = inventory.first(where: { $0.relativePath == document.relativePath }) else { throw CollaborationError.unavailable }
        guard inventory.filter({ $0.resource == selected.resource }).count == 1 else { throw CollaborationError.identityConflict }
        var records = try loadBindings()
        guard !records.items.contains(where: {
            $0.document.documentID != document.documentID && ($0.document.relativePath == document.relativePath || $0.resource == selected.resource)
        }) else { throw CollaborationError.identityConflict }
        records.items.removeAll { $0.document.documentID == document.documentID }
        guard records.items.count < 8 else { throw CollaborationError.capacityExceeded }
        records.items.append(Binding(document: document, resource: selected.resource))
        try saveBindings(records)
    }

    /// Return only a verified current binding. Content equality never proves identity.
    public func resolve(documentID: UUID) throws -> URL {
        var records = try loadBindings()
        guard let index = records.items.firstIndex(where: { $0.document.documentID == documentID }) else { throw CollaborationError.unavailable }
        let inventory = try candidates()
        let old = records.items[index]
        let identityMatches = inventory.filter { $0.resource == old.resource }
        let candidate: Candidate
        if let atBoundPath = inventory.first(where: { $0.relativePath == old.document.relativePath }) {
            // The explicit path binding survives a provider's atomic source replacement.
            // Resource identity proves moves only; a surviving original elsewhere makes
            // replacement-versus-copy ambiguous and requires the user's choice.
            guard identityMatches.allSatisfy({ $0.relativePath == atBoundPath.relativePath }),
                  inventory.filter({ $0.resource == atBoundPath.resource }).count == 1 else { throw CollaborationError.identityConflict }
            candidate = atBoundPath
        } else {
            guard identityMatches.count == 1, let renamed = identityMatches.first else { throw CollaborationError.identityConflict }
            candidate = renamed
        }
        guard !records.items.contains(where: {
            $0.document.documentID != documentID && ($0.document.relativePath == candidate.relativePath || $0.resource == candidate.resource)
        }) else { throw CollaborationError.identityConflict }
        if candidate.relativePath != old.document.relativePath || candidate.resource != old.resource {
            records.items[index] = Binding(document: SharedDocumentRef(workspaceID: workspaceID, documentID: documentID, relativePath: candidate.relativePath), resource: candidate.resource)
            try saveBindings(records)
        }
        // Check again immediately before returning; consumers must compare source bytes
        // under file coordination before writing because a later replacement can race.
        guard try identity(at: verifiedURL(relativePath: candidate.relativePath)) == candidate.resource else { throw CollaborationError.identityConflict }
        return candidate.url
    }

    public func document(documentID: UUID) throws -> SharedDocumentRef {
        _ = try resolve(documentID: documentID)
        guard let binding = try loadBindings().items.first(where: { $0.document.documentID == documentID }) else { throw CollaborationError.unavailable }
        return binding.document
    }

    private var bookmarkURL: URL { localRoot.appendingPathComponent("folder.bookmark") }
    private var bindingsURL: URL { localRoot.appendingPathComponent("workspace-bindings.json") }

    private func activate(selected: URL, root: URL, acquired: Bool) {
        selectedFolder = selected
        scopedURL = selected
        folderURL = root
        hasSecurityScopedAccess = acquired
    }
    private func validatedRoot(_ selected: URL) throws -> URL {
        guard selected.isFileURL, candidateLimit > 0 else { throw CollaborationError.invalid("Choose a readable local folder.") }
        let root = selected.resolvingSymlinksInPath().standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true, FileManager.default.isReadableFile(atPath: root.path) else { throw CollaborationError.unavailable }
        let local = localRoot.resolvingSymlinksInPath().standardizedFileURL
        guard !isInside(local, root: root), !isInside(root, root: local),
              try !physicallyOverlap(root: root, local: local) else { throw CollaborationError.invalid("Collaboration storage must be outside the shared folder.") }
        return root
    }
    private func physicallyOverlap(root: URL, local: URL) throws -> Bool {
        guard let rootIdentity = try directoryIdentity(at: root) else { throw CollaborationError.unavailable }
        let localAncestors = try ancestorIdentities(of: local)
        if localAncestors.contains(rootIdentity) { return true }
        if let localIdentity = try directoryIdentity(at: local) {
            return try ancestorIdentities(of: root).contains(localIdentity)
        }
        return false
    }
    private func ancestorIdentities(of url: URL) throws -> Set<ResourceIdentity> {
        var current = url
        var result: Set<ResourceIdentity> = []
        while true {
            if let resource = try directoryIdentity(at: current) { result.insert(resource) }
            if current.path == "/" { return result }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return result }
            current = parent
        }
    }
    private func directoryIdentity(at url: URL) throws -> ResourceIdentity? {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.fstatat(AT_FDCWD, path, &value, 0)
        }
        if status != 0 {
            let failure = errno
            if failure == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR else { throw CollaborationError.unavailable }
        return ResourceIdentity(device: value.st_dev, inode: value.st_ino,
                                birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec))
    }
    private func isInside(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }
    private func validPath(_ path: String) -> Bool {
        CollaborationIO.validRelativePath(path) && !path.split(separator: "/").contains { $0.caseInsensitiveCompare("Folio Review") == .orderedSame }
    }
    private func verifiedURL(relativePath: String) throws -> URL {
        guard let root = folderURL, validPath(relativePath) else { throw CollaborationError.unavailable }
        var url = root
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true, isInside(url.resolvingSymlinksInPath().standardizedFileURL, root: root) else { throw CollaborationError.identityConflict }
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CollaborationError.unavailable }
        return url.standardizedFileURL
    }
    private func identity(at url: URL) throws -> ResourceIdentity {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &value)
        }
        guard status == 0, (value.st_mode & S_IFMT) == S_IFREG else { throw CollaborationError.unavailable }
        return ResourceIdentity(device: value.st_dev, inode: value.st_ino,
                                birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec))
    }
    private func candidates() throws -> [Candidate] {
        guard let root = folderURL else { throw CollaborationError.unavailable }
        _ = try validatedRoot(root)
        var enumerationError: Error?
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CollaborationError.unavailable }
        var found: [Candidate] = []
        var examined = 0
        while let url = enumerator.nextObject() as? URL {
            examined += 1
            guard examined <= candidateLimit else { throw CollaborationError.capacityExceeded }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent.caseInsensitiveCompare("Folio Review") == .orderedSame {
                enumerator.skipDescendants()
                continue
            }
            let normalized = url.resolvingSymlinksInPath().standardizedFileURL
            guard isInside(normalized, root: root) else { throw CollaborationError.identityConflict }
            let path = String(normalized.path.dropFirst(root.path.hasSuffix("/") ? root.path.count : root.path.count + 1))
            if values.isRegularFile == true, validPath(path) {
                let verified = try verifiedURL(relativePath: path)
                found.append(Candidate(relativePath: path, url: verified, resource: try identity(at: verified)))
            }
        }
        if let enumerationError { throw enumerationError }
        return found.sorted { $0.relativePath < $1.relativePath }
    }
    private func loadBindings() throws -> Bindings {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: bindingsURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Bindings(version: 1, workspaceID: workspaceID, items: [])
        }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard bytes.count <= 64 * 1024 else { throw CollaborationError.capacityExceeded }
        let value = try JSONDecoder().decode(Bindings.self, from: bytes)
        guard value.version == 1, value.workspaceID == workspaceID, value.items.count <= 8,
              value.items.allSatisfy({ $0.document.workspaceID == workspaceID && validPath($0.document.relativePath) }),
              Set(value.items.map { $0.document.documentID }).count == value.items.count,
              Set(value.items.map { $0.document.relativePath }).count == value.items.count else { throw CollaborationError.identityConflict }
        return value
    }
    private func saveBindings(_ bindings: Bindings) throws {
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(bindings).write(to: bindingsURL, options: .atomic)
    }
}
