import AppKit
import Combine
import Foundation
import ReaderCore

struct SharedWorkspaceDocument: Identifiable, Equatable {
    let reference: SharedDocumentRef
    let url: URL?
    let issue: String?
    var id: UUID { reference.documentID }
}

/// The worker owns filesystem stores and all provider I/O. A slow provider read
/// occupies this one queue; cancellation does not pretend to interrupt that read.
private final class CollaborationWorkspaceWorker: @unchecked Sendable {
    struct ActiveWorkspace: Codable { let workspaceID: UUID; var folderAlias: URL? = nil }
    struct Snapshot {
        let workspaceID: UUID, folder: URL, profile: ParticipantProfile
        let report: CollaborationReport, publication: CollaborationPublishReport?
        let documents: [SharedWorkspaceDocument], candidates: [String], events: [CollaborationEvent]
        let sourceBytes: [UUID: Data]
        let protectedURLs: [URL]
    }
    let localRoot: URL
    let limits: CollaborationLimits
    var access: SharedWorkspaceStore?
    var replica: CollaborationReplicaStore?
    var profile: ParticipantProfile?
    var sourceBytes: [UUID: Data] = [:]
    var folderAlias: URL?
    var protectedURLs = Set<URL>()
    var identityStore: ParticipantStore { ParticipantStore(profileURL: localRoot.appendingPathComponent("profile.json")) }
    var activeURL: URL { localRoot.appendingPathComponent("active-workspace.json") }
    init(localRoot: URL, limits: CollaborationLimits) { self.localRoot = localRoot; self.limits = limits }
    deinit { access?.endAccess() }

    func connect(folder: URL?, create: Bool, name: String?, restore: Bool) throws -> Snapshot {
        // Validate a new name before any creation. Existing profiles fail closed.
        if let name, !CollaborationIO.validName(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
            throw CollaborationError.invalid("Name must contain 1–100 UTF-8 bytes and no control characters.")
        }
        let id: UUID
        let selected: SharedWorkspaceStore
        let root: URL
        let selectedAlias: URL?
        var previousBookmark: Data?
        var changedBookmarkURL: URL?
        if restore {
            let record = try JSONDecoder().decode(ActiveWorkspace.self, from: CollaborationIO.read(activeURL, limit: 4096))
            id = record.workspaceID; selectedAlias = record.folderAlias
            selected = SharedWorkspaceStore(localRoot: workspaceRoot(id), workspaceID: id, candidateLimit: limits.candidates)
            root = try selected.restoreAccess()
        } else {
            guard let folder else { throw CollaborationError.unavailable }
            selectedAlias = folder
            // Temporary scope covers reading identity before the durable bookmark exists.
            let acquired = folder.startAccessingSecurityScopedResource()
            defer { if acquired { folder.stopAccessingSecurityScopedResource() } }
            if create { id = UUID() }
            else {
                let metadata = folder.appendingPathComponent("Folio Review/workspace.json")
                try CollaborationIO.safe(metadata, root: folder)
                id = try CollaborationIO.decodeWorkspace(CollaborationIO.read(metadata, limit: limits.manifestBytes), limits: limits).workspaceID
            }
            selected = SharedWorkspaceStore(folderURL: folder, localRoot: workspaceRoot(id), workspaceID: id, candidateLimit: limits.candidates)
            let bookmark = workspaceRoot(id).appendingPathComponent("folder.bookmark")
            if FileManager.default.fileExists(atPath: bookmark.path) { previousBookmark = try CollaborationIO.read(bookmark, limit: 64 * 1024) }
            changedBookmarkURL = bookmark
            root = try selected.beginAccess()
        }
        do {
            // Access validation runs before profile writes so local state cannot land in the share.
            let actor = try identityStore.loadOrCreate(displayName: name ?? "")
            let store = CollaborationReplicaStore(localRoot: workspaceRoot(id), sharedRoot: root, workspaceID: id, limits: limits)
            if create { try store.createWorkspace() } else { try store.join() }
            let oldAccess = access, oldReplica = replica, oldProfile = profile, oldBytes = sourceBytes, oldAlias = folderAlias
            access = selected; replica = store; profile = actor; sourceBytes = [:]; folderAlias = selectedAlias
            do {
                let snapshot = try scan(publish: true)
                guard snapshot.report.coverageComplete else { throw CollaborationError.unavailable }
                try CollaborationIO.durable(CollaborationIO.encode(ActiveWorkspace(workspaceID: id, folderAlias: selectedAlias)), at: activeURL)
                oldAccess?.endAccess()
                return snapshot
            } catch {
                access = oldAccess; replica = oldReplica; profile = oldProfile; sourceBytes = oldBytes; folderAlias = oldAlias
                throw error
            }
        } catch {
            selected.endAccess()
            if let bookmark = changedBookmarkURL {
                if let previousBookmark { try CollaborationIO.durable(previousBookmark, at: bookmark) }
                else if FileManager.default.fileExists(atPath: bookmark.path) { try FileManager.default.removeItem(at: bookmark) }
            }
            throw error
        }
    }
    func workspaceRoot(_ id: UUID) -> URL { localRoot.appendingPathComponent("workspaces/\(id.uuidString)") }
    func scan(publish: Bool) throws -> Snapshot {
        guard let access, let store = replica, let folder = access.folderURL, let actor = profile else { throw CollaborationError.unavailable }
        let publication = publish ? try store.publishOutbox() : nil
        let report = try store.reconcile()
        // No incomplete replacement snapshot is emitted. MainActor keeps the last usable state.
        guard report.coverageComplete else { return Snapshot(workspaceID: store.workspaceID, folder: folder, profile: actor, report: report, publication: publication, documents: [], candidates: [], events: [], sourceBytes: [:], protectedURLs: Array(protectedURLs)) }
        let candidates = try access.inventory()
        let cache = store.localRoot.appendingPathComponent("received/documents")
        var failure: Error?, count = 0, documents: [SharedWorkspaceDocument] = [], observed: [UUID: Data] = [:]
        guard let iterator = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in failure = error; return false }) else { throw CollaborationError.unavailable }
        for case let item as URL in iterator {
            count += 1; guard count <= limits.candidates else { throw CollaborationError.capacityExceeded }
            try CollaborationIO.safe(item, root: cache)
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CollaborationError.identityConflict }
            let manifest = try CollaborationIO.decodeDocument(CollaborationIO.read(item, limit: limits.manifestBytes), limits: limits)
            guard manifest.workspaceID == store.workspaceID, !documents.contains(where: { $0.id == manifest.documentID }), documents.count < limits.documents else { throw CollaborationError.identityConflict }
            var ref = try store.document(id: manifest.documentID)
            protectedURLs.insert(folder.appendingPathComponent(ref.relativePath).standardizedFileURL)
            if let folderAlias { protectedURLs.insert(folderAlias.appendingPathComponent(ref.relativePath).standardizedFileURL) }
            var source: URL?, issue: String?
            do {
                // A local binding exists only after explicit registration/open/reconnect.
                ref = try access.document(documentID: manifest.documentID)
                source = try access.resolve(documentID: manifest.documentID)
                if let source {
                    protectedURLs.insert(source.standardizedFileURL)
                    let relative = String(source.path.dropFirst(folder.path.count + 1))
                    if relative != ref.relativePath { ref = try store.reconnectDocument(id: ref.documentID, relativePath: relative) }
                    observed[ref.documentID] = try CollaborationIO.read(source, limit: limits.snapshotBytes)
                }
            } catch CollaborationError.unavailable {
                // Only an absent local binding permits explicit Open at its initial path.
                if candidates.contains(ref.relativePath) { source = folder.appendingPathComponent(ref.relativePath) }
                issue = "Choose Open or Reconnect to verify this document on this Mac."
            } catch {
                source = nil
                issue = "This binding is unavailable or ambiguous. Choose Reconnect; the last readable source is retained."
            }
            documents.append(SharedWorkspaceDocument(reference: ref, url: source, issue: issue))
        }
        if let failure { throw failure }
        return Snapshot(workspaceID: store.workspaceID, folder: folder, profile: actor, report: report, publication: publication,
                        documents: documents.sorted { $0.reference.relativePath < $1.reference.relativePath }, candidates: candidates,
                        events: try store.events(), sourceBytes: observed, protectedURLs: Array(protectedURLs))
    }
    func register(_ path: String) throws -> Snapshot {
        guard let access, let store = replica, let folder = access.folderURL,
              try access.inventory().contains(path) else { throw CollaborationError.invalid("Choose a Markdown file inside the shared folder.") }
        let source = folder.appendingPathComponent(path)
        let bytes = try CollaborationIO.read(source, limit: limits.snapshotBytes)
        let ref = try store.registerDocument(relativePath: path, initialBytes: bytes)
        try access.bind(document: ref)
        return try scan(publish: true)
    }
    func reconnect(_ id: UUID, path: String) throws -> Snapshot {
        guard let access, let store = replica, try access.inventory().contains(path) else { throw CollaborationError.unavailable }
        // Validate local resource/path collisions before changing the replica binding.
        let ref = SharedDocumentRef(workspaceID: store.workspaceID, documentID: id, relativePath: path)
        _ = try store.document(id: id)
        let bindingURL = access.localRoot.appendingPathComponent("workspace-bindings.json")
        let previous = FileManager.default.fileExists(atPath: bindingURL.path)
            ? try CollaborationIO.read(bindingURL, limit: limits.manifestBytes) : nil
        try access.bind(document: ref)
        do { _ = try store.reconnectDocument(id: id, relativePath: path) }
        catch {
            if let previous { try CollaborationIO.durable(previous, at: bindingURL) }
            else { try FileManager.default.removeItem(at: bindingURL) }
            throw error
        }
        return try scan(publish: true)
    }
    func open(_ id: UUID) throws -> URL {
        guard let access, let store = replica else { throw CollaborationError.unavailable }
        do { return try access.resolve(documentID: id) }
        catch CollaborationError.unavailable {
            let ref = try store.document(id: id)
            try access.bind(document: ref)
            return try access.resolve(documentID: id)
        }
    }
    func readSource(_ url: URL) throws -> (DocumentSnapshot, URL, Bool) {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let source = try DocumentSnapshot(url: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        let identity = (attributes[.systemNumber] as? NSNumber)?.stringValue.appending(":")
            .appending((attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "")
        let shared = protectedURLs.contains(canonical) || protectedURLs.contains(where: { known in
            guard let other = try? FileManager.default.attributesOfItem(atPath: known.path),
                  let device = other[.systemNumber] as? NSNumber, let inode = other[.systemFileNumber] as? NSNumber else { return false }
            return identity == device.stringValue + ":" + inode.stringValue
        })
        return (source, canonical, shared)
    }
    func disconnect() throws {
        try access?.stopWatching(); access = nil; replica = nil; sourceBytes = [:]
        if FileManager.default.fileExists(atPath: activeURL.path) { try FileManager.default.removeItem(at: activeURL) }
    }
}

@MainActor final class CollaborationCoordinator: ObservableObject {
    let enabled: Bool
    @Published private(set) var workspaceID: UUID?
    @Published private(set) var folderURL: URL?
    @Published private(set) var profile: ParticipantProfile?
    @Published private(set) var documents: [SharedWorkspaceDocument] = []
    @Published private(set) var candidates: [String] = []
    @Published private(set) var state: CollaborationState?
    @Published private(set) var events: [CollaborationEvent] = []
    @Published private(set) var status: CollaborationStatus = .unavailable
    @Published private(set) var publication: CollaborationPublishReport?
    @Published private(set) var statusMessage = "Choose an already shared OneDrive folder."
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var isWatching = false
    @Published private(set) var sourceAccessUnverified: Bool
    @Published var showFolderSheet = false
    @Published private(set) var currentDocument: SharedDocumentRef?
    @Published private(set) var sourceObservations: [UUID: Data] = [:]
    var onSourceObserved: ((SharedDocumentRef, Data) -> Void)?
    private let queue = DispatchQueue(label: "wtf.pippo.folio.collaboration.io", qos: .utility)
    private let worker: CollaborationWorkspaceWorker?
    private var monitor: SharedFolderMonitor?
    private var generation = UUID()
    private var refreshing = false, refreshAgain = false
    private var operations = 0
    private var protectedSources = Set<URL>()
    private var currentURL: URL?
    private var sourceAliases: [URL: URL] = [:]
    private(set) var localRoot: URL

    init(enabled: Bool = BuildChannel.collaborationAvailable, localRoot: URL? = nil, limits: CollaborationLimits = .pilot) {
        self.enabled = enabled; self.sourceAccessUnverified = enabled
        let root = localRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("\(BuildChannel.storage)/Collaboration")
        self.localRoot = root
        worker = enabled ? CollaborationWorkspaceWorker(localRoot: root, limits: limits) : nil
    }
    deinit { monitor?.stop() }
    private func run<T>(_ operation: @escaping (CollaborationWorkspaceWorker) throws -> T) async throws -> T {
        guard let worker else { throw CollaborationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try operation(worker)) } catch { continuation.resume(throwing: error) } }
        }
    }
    private func begin() { operations += 1; busy = true }
    private func end() { operations -= 1; busy = operations > 0 }
    func restore() async {
        guard enabled, workspaceID == nil, !busy else { return }
        // No absent active record means no workspace and no watcher/store creation.
        begin(); let token = generation; defer { end() }
        do { let snapshot = try await run { worker in
            guard FileManager.default.fileExists(atPath: worker.activeURL.path) else { return Optional<CollaborationWorkspaceWorker.Snapshot>.none }
            return try worker.connect(folder: nil, create: false, name: nil, restore: true)
        }; guard token == generation else { return }
            guard let snapshot else { sourceAccessUnverified = false; return }
            apply(snapshot); startWatching() }
        catch { if token == generation { fail(error) } }
    }
    func join(folder: URL, create: Bool, displayName: String) async {
        guard enabled else { return }
        generation = UUID(); let token = generation
        monitor?.stop(); monitor = nil; isWatching = false
        begin(); defer { end() }
        do {
            let snapshot = try await run { try $0.connect(folder: folder, create: create, name: displayName, restore: false) }
            guard token == generation else { return }
            state = nil; events = []; sourceObservations = [:]
            apply(snapshot); startWatching()
        } catch { if token == generation { fail(error); if workspaceID != nil { startWatching() } } }
    }
    func reconnectFolder(_ folder: URL) async {
        guard enabled, let id = workspaceID, let name = profile?.displayName else { return }
        // Reconnection is to the existing UUID, never a replacement workspace.
        begin(); let token = generation; defer { end() }
        do {
            let snapshot = try await run { worker in
                let acquired = folder.startAccessingSecurityScopedResource(); defer { if acquired { folder.stopAccessingSecurityScopedResource() } }
                let path = folder.appendingPathComponent("Folio Review/workspace.json")
                try CollaborationIO.safe(path, root: folder)
                guard try CollaborationIO.decodeWorkspace(CollaborationIO.read(path, limit: worker.limits.manifestBytes)).workspaceID == id else { throw CollaborationError.identityConflict }
                return try worker.connect(folder: folder, create: false, name: name, restore: false)
            }
            guard token == generation else { return }; apply(snapshot); startWatching()
        } catch { if token == generation { fail(error) } }
    }
    private func startWatching() {
        monitor?.stop(); monitor = nil
        guard enabled, let folderURL else { return }
        let token = generation
        monitor = SharedFolderMonitor(folder: folderURL) { [weak self] in
            Task { @MainActor [weak self] in guard let self, self.generation == token else { return }; await self.refresh() }
        }
        isWatching = true
    }
    func refresh() async {
        guard enabled, workspaceID != nil else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true; begin(); let token = generation
        defer { refreshing = false; end() }
        repeat {
            refreshAgain = false
            do { let snapshot = try await run { try $0.scan(publish: true) }; guard token == generation else { return }; apply(snapshot) }
            catch { if token == generation { fail(error) } }
        } while refreshAgain && token == generation
    }
    func registerDocument(relativePath: String) async { await mutation { try $0.register(relativePath) } }
    func reconnectDocument(id: UUID, relativePath: String) async { await mutation { try $0.reconnect(id, path: relativePath) } }
    private func mutation(_ operation: @escaping (CollaborationWorkspaceWorker) throws -> CollaborationWorkspaceWorker.Snapshot) async {
        guard enabled, let id = workspaceID else { return }; begin(); let token = generation; defer { end() }
        do { let snapshot = try await run { worker in
            guard worker.replica?.workspaceID == id else { throw CollaborationError.unavailable }
            return try operation(worker)
        }; guard token == generation else { return }; apply(snapshot) }
        catch { if token == generation { fail(error) } }
    }
    func openDocument(id: UUID) async -> URL? {
        guard enabled, workspaceID != nil else { return nil }; begin(); let token = generation; defer { end() }
        do {
            let url = try await run { try $0.open(id) }; guard token == generation else { return nil }
            protectedSources.insert(url.standardizedFileURL)
            await refresh(); guard token == generation else { return nil }; return url
        } catch { if token == generation { fail(error) }; return nil }
    }
    /// Returns true only after the same authored ID is durable in the local ready outbox.
    /// Publication failure is reported independently and never destroys that local action.
    func submit(_ event: CollaborationEvent, snapshots: [String: Data] = [:]) async -> Bool {
        guard enabled, let id = workspaceID, let actor = profile, event.workspaceID == id,
              event.participantID == actor.participantID, event.deviceID == actor.deviceID,
              event.authorName == actor.displayName else { return false }
        begin(); let token = generation; defer { end() }
        do {
            try await run { worker in guard let store = worker.replica, store.workspaceID == id else { throw CollaborationError.unavailable }; try store.enqueue(event, snapshots: snapshots) }
            guard token == generation else { return false }
            statusMessage = "Saved on this Mac · OneDrive handles sharing"
            await refresh(); return token == generation
        } catch { if token == generation { fail(error) }; return false }
    }
    func rename(to name: String) async {
        guard enabled else { return }; begin(); let token = generation; defer { end() }
        do { let profile = try await run { worker in let value = try worker.identityStore.rename(to: name); worker.profile = value; return value }; if token == generation { self.profile = profile; error = nil } }
        catch { if token == generation { fail(error) } }
    }
    func exportEvidence(to url: URL) async {
        guard enabled else { return }; begin(); let token = generation; defer { end() }
        do { try await run { worker in guard let store = worker.replica else { throw CollaborationError.unavailable }; try store.exportEvidence(to: url) }; if token == generation { error = nil; statusMessage = "Local collaboration evidence exported." } }
        catch { if token == generation { fail(error) } }
    }
    func stopWatching() async {
        guard enabled else { return }; generation = UUID(); let token = generation
        monitor?.stop(); monitor = nil; isWatching = false; begin(); defer { end() }
        do {
            try await run { try $0.disconnect() }; guard token == generation else { return }
            workspaceID = nil; folderURL = nil; documents = []; candidates = []; state = nil; events = []; currentDocument = nil
            sourceObservations = [:]; error = nil; status = .unavailable; statusMessage = "Stopped watching. Shared files and local evidence are kept."
        } catch { if token == generation { fail(error) } }
    }
    func selectDocument(url: URL?) {
        let canonical = url.flatMap { sourceAliases[$0.standardizedFileURL] } ?? url?.standardizedFileURL
        currentURL = canonical
        currentDocument = documents.first { $0.url?.standardizedFileURL == canonical }?.reference
    }
    func protectsSource(at url: URL) -> Bool {
        guard enabled else { return false }
        if sourceAccessUnverified { return true }
        let path = url.standardizedFileURL.path
        // Conservative spelling-alias protection only; this never establishes identity.
        return protectedSources.contains { $0.path == path || $0.path.lowercased() == path.lowercased() }
    }
    var destinationChangingSaveBlocked: Bool { enabled && (sourceAccessUnverified || !protectedSources.isEmpty) }
    func readSource(at url: URL) async throws -> DocumentSnapshot {
        let token = generation
        let (snapshot, canonical, shared) = try await run { try $0.readSource(url) }
        guard token == generation else { throw CollaborationError.unavailable }
        if shared { protectedSources.insert(url.standardizedFileURL); protectedSources.insert(canonical) }
        sourceAliases[url.standardizedFileURL] = canonical
        return snapshot
    }
    private func apply(_ snapshot: CollaborationWorkspaceWorker.Snapshot) {
        workspaceID = snapshot.workspaceID; folderURL = snapshot.folder; profile = snapshot.profile
        publication = snapshot.publication; status = snapshot.report.status
        protectedSources.formUnion(snapshot.protectedURLs)
        guard snapshot.report.coverageComplete, let state = snapshot.report.state else {
            error = "Folder check is incomplete (\(snapshot.report.status.rawValue)). The last readable review is retained. Retry or export local evidence."
            statusMessage = "Folder check incomplete"; return
        }
        sourceAccessUnverified = false
        documents = snapshot.documents; candidates = snapshot.candidates; events = snapshot.events; self.state = state
        for doc in documents {
            if let url = doc.url { protectedSources.insert(url.standardizedFileURL) }
            if let bytes = snapshot.sourceBytes[doc.id], sourceObservations[doc.id] != bytes { onSourceObserved?(doc.reference, bytes) }
        }
        sourceObservations.merge(snapshot.sourceBytes) { _, new in new }
        selectDocument(url: currentURL)
        error = nil
        if let missing = documents.first(where: { $0.issue != nil }) { error = "\(missing.reference.relativePath): \(missing.issue!)" }
        if snapshot.publication?.status != .complete && snapshot.publication != nil { error = "Some local actions have not been placed in this folder. Retry or export evidence." }
        statusMessage = snapshot.report.status == .pending ? "Review has pending dependencies · Retry after OneDrive delivers them" : "Checked this folder just now"
        if snapshot.report.diagnosticCount > 0 { error = "\(snapshot.report.diagnosticCount) review files need attention. Export local evidence for details." }
    }
    private func fail(_ failure: Error) {
        if let failure = failure as? CollaborationError {
            switch failure {
            case .identityConflict: status = .identityConflict; error = "Workspace or document identity conflicts. Choose Reconnect; existing files were kept."
            case .capacityExceeded: status = .capacityExceeded; error = "This workspace exceeds the pilot limits. Export local evidence and use a smaller disposable workspace."
            case .invalid(let message): status = .unavailable; error = message
            default: status = .unavailable; error = "The shared folder is unavailable. Retry or reconnect; the last readable review is retained."
            }
        } else { status = .unavailable; error = "The shared folder could not be read: \(failure.localizedDescription) Retry or reconnect; the last readable review is retained." }
        statusMessage = "Folder check incomplete"
    }
}
