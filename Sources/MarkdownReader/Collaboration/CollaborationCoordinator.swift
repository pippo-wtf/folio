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
        var report = try store.reconcile()
        // A source rename can make the replica need reconnection before publication.
        // Only that status permits refreshing source choices; review state remains blocked.
        guard report.coverageComplete || report.status == .needsReconnection else { return Snapshot(workspaceID: store.workspaceID, folder: folder, profile: actor, report: report, publication: nil, documents: [], candidates: [], events: [], sourceBytes: [:], protectedURLs: Array(protectedURLs)) }
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
                (ref, source) = try resolveBoundDocument(manifest.documentID)
                if let source {
                    protectedURLs.insert(source.standardizedFileURL)
                    let bytes = try CollaborationIO.read(source, limit: limits.snapshotBytes)
                    try retainSource(ref, baseline: nil, draft: nil, observed: bytes)
                    observed[ref.documentID] = bytes
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
        report = try store.reconcile()
        let publication = publish && report.coverageComplete ? try store.publishOutbox() : nil
        if publication != nil { report = try store.reconcile() }
        return Snapshot(workspaceID: store.workspaceID, folder: folder, profile: actor, report: report, publication: publication,
                        documents: documents.sorted { $0.reference.relativePath < $1.reference.relativePath }, candidates: candidates,
                        events: report.coverageComplete ? try store.events() : [], sourceBytes: observed, protectedURLs: Array(protectedURLs))
    }
    /// WorkspaceStore follows only a unique recorded file resource, never matching text.
    /// Keep its verified path and the replica's source binding together before returning a URL.
    func resolveBoundDocument(_ id: UUID) throws -> (SharedDocumentRef, URL) {
        guard let access, let store = replica else { throw CollaborationError.unavailable }
        let previousRef = try store.document(id: id)
        let bindingURL = access.localRoot.appendingPathComponent("workspace-bindings.json")
        let previous = FileManager.default.fileExists(atPath: bindingURL.path)
            ? try CollaborationIO.read(bindingURL, limit: limits.manifestBytes) : nil
        do {
            let verified = try access.document(documentID: id)
            let source = try access.resolve(documentID: id)
            guard verified.workspaceID == store.workspaceID else { throw CollaborationError.identityConflict }
            let ref = verified == previousRef ? previousRef
                : try store.reconnectDocument(id: id, relativePath: verified.relativePath)
            guard source.standardizedFileURL == (try store.sourceURL(document: ref)).standardizedFileURL else { throw CollaborationError.identityConflict }
            return (ref, source)
        } catch {
            if let previous { try CollaborationIO.durable(previous, at: bindingURL) }
            else if FileManager.default.fileExists(atPath: bindingURL.path) { try FileManager.default.removeItem(at: bindingURL) }
            throw error
        }
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
        do { return try resolveBoundDocument(id).1 }
        catch CollaborationError.unavailable {
            let ref = try store.document(id: id)
            try access.bind(document: ref)
            return try resolveBoundDocument(id).1
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
    func verifiedDocument(_ document: SharedDocumentRef) throws -> CollaborationReplicaStore {
        guard let access, let store = replica, store.workspaceID == document.workspaceID,
              try access.document(documentID: document.documentID) == document else { throw CollaborationError.identityConflict }
        let url = try access.resolve(documentID: document.documentID)
        guard url.standardizedFileURL == (try store.sourceURL(document: document)).standardizedFileURL else { throw CollaborationError.identityConflict }
        return store
    }
    func retainSource(_ document: SharedDocumentRef, baseline: Data?, draft: Data?, observed: Data?) throws {
        guard let store = replica, store.workspaceID == document.workspaceID else { throw CollaborationError.unavailable }
        let root = store.localRoot.appendingPathComponent("source-observations/\(document.documentID.uuidString)")
        for (kind, bytes) in [("base", baseline), ("draft", draft), ("observed", observed)] {
            guard let bytes else { continue }
            guard bytes.count <= limits.snapshotBytes else { throw CollaborationError.capacityExceeded }
            let hash = CollaborationSnapshotID.hash(bytes)
            let path = root.appendingPathComponent("\(kind)-\(hash).bin")
            if FileManager.default.fileExists(atPath: path.path) { continue }
            try admitSourceEvidence(store, adding: [bytes], candidateReservation: 2)
            try CollaborationIO.immutable(bytes, at: path)
        }
    }
    /// Source evidence shares the pilot's total admission envelope with replica evidence.
    /// This is deliberately conservative: invalid oversized files still consume scan/byte budget.
    func admitSourceEvidence(_ store: CollaborationReplicaStore, adding: [Data], candidateReservation: Int) throws {
        var count = 0, oversizedBytes = 0, uniqueBytes = Set<Data>(), hashes = Set<String>()
        for root in [store.localRoot, store.sharedRoot.appendingPathComponent("Folio Review")] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var failure: Error?
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in failure = error; return false }) else { throw CollaborationError.unavailable }
            for case let item as URL in iterator {
                count += 1
                guard count + candidateReservation <= limits.candidates else { throw CollaborationError.capacityExceeded }
                try CollaborationIO.safe(item, root: root)
                let values = try item.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else { throw CollaborationError.identityConflict }
                guard values.isRegularFile == true else { continue }
                let size = values.fileSize ?? 0
                guard size >= 0, size <= limits.totalBytes - oversizedBytes else { throw CollaborationError.capacityExceeded }
                if size > limits.snapshotBytes { oversizedBytes += size; continue }
                let data = try CollaborationIO.read(item, limit: limits.snapshotBytes)
                uniqueBytes.insert(data)
                if item.pathExtension == "bin" { hashes.insert(CollaborationSnapshotID.hash(data)) }
            }
            if let failure { throw failure }
        }
        for data in adding { uniqueBytes.insert(data); hashes.insert(CollaborationSnapshotID.hash(data)) }
        guard hashes.count <= limits.snapshots else { throw CollaborationError.capacityExceeded }
        var admitted = oversizedBytes
        for data in uniqueBytes {
            guard data.count <= limits.totalBytes - admitted else { throw CollaborationError.capacityExceeded }
            admitted += data.count
        }
    }
    func observationFiles(_ store: CollaborationReplicaStore) throws -> [URL] {
        let root = store.localRoot.appendingPathComponent("source-observations")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var failure: Error?, files: [URL] = [], count = 0
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], errorHandler: { _, error in failure = error; return false }) else { throw CollaborationError.unavailable }
        for case let item as URL in iterator {
            count += 1; guard count <= limits.candidates else { throw CollaborationError.capacityExceeded }
            try CollaborationIO.safe(item, root: root)
            if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(item) }
        }
        if let failure { throw failure }; return files
    }
    func saveSource(_ document: SharedDocumentRef, baseline: DocumentSnapshot, draft: String, trigger: UUID?) throws -> SharedSaveOutcome {
        let store = try verifiedDocument(document)
        guard let profile else { throw CollaborationError.unavailable }
        let proposed = try baseline.encoded(draft)
        try retainSource(document, baseline: baseline.bytes, draft: proposed, observed: nil)
        try admitSourceEvidence(store, adding: [baseline.bytes, proposed], candidateReservation: 8)
        let prepared = try CollaborationSourceRecovery.prepare(document: document, base: baseline.bytes, proposed: proposed, actor: profile, triggerEventID: trigger, store: store)
        let result = try CollaborationSourceRecovery.apply(prepared, store: store)
        // Publication failure cannot turn a proved local write into an unsuccessful local write.
        let publication = (try? store.publishOutbox())?.status ?? .unavailable
        return SharedSaveOutcome(proposalID: prepared.event.id, localApply: result, publication: publication)
    }
    func resolveSource(_ document: SharedDocumentRef, expected: Data, chosen: Data, heads: [UUID]) throws -> SharedSaveOutcome {
        let store = try verifiedDocument(document)
        guard let profile else { throw CollaborationError.unavailable }
        try admitSourceEvidence(store, adding: [expected, chosen], candidateReservation: 8)
        let prepared = try CollaborationSourceRecovery.prepareResolution(document: document, expectedCurrent: expected, chosen: chosen, superseding: heads, actor: profile, store: store)
        let result = try CollaborationSourceRecovery.apply(prepared, store: store)
        return SharedSaveOutcome(proposalID: prepared.event.id, localApply: result, publication: (try? store.publishOutbox())?.status ?? .unavailable)
    }
    func compareSource(_ document: SharedDocumentRef) throws -> SharedSourceComparison {
        guard let store = replica, store.workspaceID == document.workspaceID else { throw CollaborationError.unavailable }
        let report = try store.reconcile()
        let events = try store.events(), snapshots = try store.snapshots()
        let heads = report.state?.sourceHeads[document.documentID] ?? []
        let proposals = events.filter { $0.documentID == document.documentID && $0.isSource }.map { event in
            let receipt: String
            if let local = try? CollaborationSourceRecovery.load(proposalID: event.id, from: store) { receipt = (try? CollaborationSourceRecovery.outcome(local, store: store)) ?? "unknownInterrupted" }
            else { receipt = "intendedOnly" }
            return SharedSourceVersion(event: event, bytes: snapshots[event.revisions[1]], isHead: heads.contains(event.id), receipt: receipt)
        }
        return SharedSourceComparison(document: document, versions: proposals, heads: heads,
            pending: (report.blockingEventIDsByDocument[document.documentID] ?? []).filter { report.state?.pendingEventIDs.contains($0) == true }, complete: report.coverageComplete)
    }
    func exportSource(_ document: SharedDocumentRef, to output: URL) throws {
        guard let store = replica, store.workspaceID == document.workspaceID else { throw CollaborationError.unavailable }
        let target = output.standardizedFileURL.resolvingSymlinksInPath().path
        for root in [store.sharedRoot, store.localRoot] {
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            guard target != path, !target.hasPrefix(path + "/") else { throw CollaborationError.invalid("Choose a separate new recovery directory.") }
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CollaborationError.invalid("Choose a new absent recovery directory; existing files are kept.") }
        let comparison = try compareSource(document)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshots = try store.snapshots()
        var missingByEvent: [String: [String]] = [:]
        for version in comparison.versions {
            let absent = version.event.revisions.filter { snapshots[$0] == nil }
            if absent.isEmpty {
                _ = try CollaborationSourceRecovery.recover(proposalID: version.id, from: store, to: output.appendingPathComponent(version.id.uuidString))
            } else {
                missingByEvent[version.id.uuidString] = absent
                let directory = output.appendingPathComponent(version.id.uuidString)
                // Missing dependencies are exported as coverage, never fabricated or silently dropped.
                for (index, hash) in version.event.revisions.enumerated() {
                    if let bytes = snapshots[hash] {
                        try CollaborationIO.immutable(bytes, at: directory.appendingPathComponent("\(index == 0 ? "base" : "proposed")-\(hash).bin"))
                    }
                }
                try CollaborationIO.immutable(CollaborationIO.encode(version.event), at: directory.appendingPathComponent("intent.json"))
            }
        }
        for file in try observationFiles(store) where file.deletingLastPathComponent().lastPathComponent == document.documentID.uuidString {
            try CollaborationIO.immutable(CollaborationIO.read(file, limit: limits.snapshotBytes), at: output.appendingPathComponent(file.lastPathComponent))
        }
        struct Coverage: Codable {
            let heads: [UUID]; let pending: [UUID]; let missing: [UUID]; let missingSnapshotHashesByEvent: [String: [String]]
            let externalRecoveryGap: Bool; let complete: Bool
        }
        let missing = comparison.versions.filter { missingByEvent[$0.id.uuidString] != nil }.map(\.id)
        try CollaborationIO.immutable(CollaborationIO.encode(Coverage(heads: comparison.heads, pending: comparison.pending, missing: missing, missingSnapshotHashesByEvent: missingByEvent, externalRecoveryGap: true, complete: comparison.complete && missing.isEmpty && comparison.pending.isEmpty)), at: output.appendingPathComponent("coverage.json"))
    }
    func privateCopy(bytes: Data, to url: URL, register: Bool) throws -> DocumentSnapshot {
        guard bytes.count <= limits.snapshotBytes else { throw CollaborationError.capacityExceeded }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        var inside = false
        if let folder = access?.folderURL {
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
            inside = target.path.hasPrefix(root + "/")
        }
        guard !inside || register else { throw CollaborationError.invalid("A new file inside the shared folder requires explicit registration. Choose a private destination or Register and Save.") }
        // Exclusive creation prevents the NSSavePanel replacement choice from overwriting any file.
        try CollaborationIO.safe(url, root: url.deletingLastPathComponent())
        try bytes.write(to: url, options: .withoutOverwriting)
        let snapshot = try DocumentSnapshot(url: url)
        if inside {
            guard let access, let store = replica, let folder = access.folderURL else { throw CollaborationError.unavailable }
            let path = String(target.path.dropFirst(folder.path.count + 1))
            let ref = try store.registerDocument(relativePath: path, initialBytes: bytes)
            try access.bind(document: ref)
        }
        return snapshot
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
    @Published private(set) var reviewReport: CollaborationReport?
    @Published private(set) var events: [CollaborationEvent] = []
    @Published private(set) var status: CollaborationStatus = .unavailable
    @Published private(set) var publication: CollaborationPublishReport?
    @Published private(set) var statusMessage = "Choose an already shared OneDrive folder."
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var isWatching = false
    @Published private(set) var sourceAccessUnverified: Bool
    @Published var showNameOnboarding = false
    @Published private(set) var onboardingError: String?
    private var identityPrepared = false
    @Published var showFolderSheet = false
    @Published var sourceSavingEnabled = false
    @Published private(set) var lastSourceSave: SharedSaveOutcome?
    @Published var showSourceConflictSheet = false
    @Published private(set) var sourceComparison: SharedSourceComparison?
    @Published private(set) var currentDocument: SharedDocumentRef?
    @Published private(set) var sourceObservations: [UUID: Data] = [:]
    var onSourceObserved: ((SharedDocumentRef, Data) -> Void)?
    private let queue = DispatchQueue(label: "wtf.pippo.folio.collaboration.io", qos: .utility)
    private let worker: CollaborationWorkspaceWorker?
    private var monitor: SharedFolderMonitor?
    private var generation = UUID()
    private var refreshing = false, refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var operations = 0
    private var protectedSources = Set<URL>()
    private var currentURL: URL?
    private var sourceAliases: [URL: URL] = [:]
    private var locallyAppliedSources: [UUID: Data] = [:]
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
    func prepareIdentity() async {
        guard enabled, !identityPrepared else { return }
        identityPrepared = true
        begin(); defer { end() }
        do {
            let saved = try await run { worker in
                let value = try worker.identityStore.load()
                worker.profile = value
                return value
            }
            profile = saved
            showNameOnboarding = saved == nil
        } catch {
            showNameOnboarding = true
            onboardingError = "Your saved name could not be read. Your existing identity has been kept."
        }
    }
    func saveOnboardingName(_ name: String) async {
        guard enabled, !busy else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CollaborationIO.validName(trimmed) else {
            onboardingError = "Please enter a short name using ordinary letters and spaces."
            return
        }
        begin(); defer { end() }
        do {
            profile = try await run { worker in
                let value = try worker.identityStore.loadOrCreate(displayName: trimmed)
                worker.profile = value
                return value
            }
            onboardingError = nil
            showNameOnboarding = false
        } catch {
            onboardingError = "Your name could not be saved. Please try again; your existing identity has been kept."
        }
    }
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
        sourceSavingEnabled = false; locallyAppliedSources = [:]
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
        if refreshing {
            refreshAgain = true
            // Coalesce I/O, but preserve the awaited refresh contract for every caller.
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshing = true; begin(); let token = generation
        defer {
            refreshing = false; end()
            let waiters = refreshWaiters; refreshWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
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
        sourceSavingEnabled = false; locallyAppliedSources = [:]
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
    var destinationChangingSaveBlocked: Bool { enabled && sourceAccessUnverified }
    func save(document: SharedDocumentRef, baseline: DocumentSnapshot, draft: String, triggerEventID: UUID? = nil) async throws -> SharedSaveOutcome {
        guard enabled, sourceSavingEnabled, !sourceAccessUnverified, workspaceID == document.workspaceID else { throw CollaborationError.invalid("Shared source saving is disabled. Enable changes to shared Markdown files in Shared review to save this source.") }
        begin(); let token = generation; defer { end() }
        do {
            let outcome = try await run { try $0.saveSource(document, baseline: baseline, draft: draft, trigger: triggerEventID) }
            guard token == generation else { throw CollaborationError.unavailable }
            lastSourceSave = outcome
            if outcome.localApply == .applied || outcome.localApply == .unchanged { locallyAppliedSources[document.documentID] = try baseline.encoded(draft) }
            await refresh()
            guard token == generation else { throw CollaborationError.unavailable }
            return outcome
        } catch { if token == generation { fail(error) }; throw error }
    }
    func isLocallyAppliedSource(document: SharedDocumentRef, bytes: Data) -> Bool {
        workspaceID == document.workspaceID && locallyAppliedSources[document.documentID] == bytes
    }
    func retainSource(document: SharedDocumentRef, baseline: Data, draft: Data, observed: Data) async throws {
        let token = generation
        try await run { try $0.retainSource(document, baseline: baseline, draft: draft, observed: observed) }
        guard token == generation else { throw CollaborationError.unavailable }
    }
    func compareSource(document: SharedDocumentRef) async {
        begin(); let token = generation; defer { end() }
        do { let value = try await run { try $0.compareSource(document) }; guard token == generation else { return }; sourceComparison = value; showSourceConflictSheet = true }
        catch { if token == generation { fail(error) } }
    }
    func resolveSource(document: SharedDocumentRef, expectedCurrent: Data, chosen: Data, superseding: [UUID]) async throws -> SharedSaveOutcome {
        guard sourceSavingEnabled, !sourceAccessUnverified else { throw CollaborationError.unavailable }
        begin(); let token = generation; defer { end() }
        let result = try await run { try $0.resolveSource(document, expected: expectedCurrent, chosen: chosen, heads: superseding) }
        guard token == generation else { throw CollaborationError.unavailable }
        lastSourceSave = result; await refresh(); await compareSource(document: document)
        return result
    }
    func exportSourceRecovery(document: SharedDocumentRef, to output: URL) async throws {
        begin(); let token = generation; defer { end() }
        do { try await run { try $0.exportSource(document, to: output) }; guard token == generation else { throw CollaborationError.unavailable }; statusMessage = "Recovery copies exported. Never-observed external history remains unknown." }
        catch { if token == generation { sourceSavingEnabled = false; fail(error) }; throw error }
    }
    func savePrivateCopy(bytes: Data, to url: URL, register: Bool) async throws -> DocumentSnapshot {
        guard !sourceAccessUnverified else { throw CollaborationError.unavailable }
        let token = generation
        let value = try await run { try $0.privateCopy(bytes: bytes, to: url, register: register) }
        guard token == generation else { throw CollaborationError.unavailable }
        await refresh(); return value
    }
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
        publication = snapshot.publication; status = snapshot.report.status; reviewReport = snapshot.report
        protectedSources.formUnion(snapshot.protectedURLs)
        guard snapshot.report.coverageComplete, let state = snapshot.report.state else {
            if snapshot.report.status == .needsReconnection {
                documents = snapshot.documents; candidates = snapshot.candidates
                selectDocument(url: currentURL)
            }
            error = "Folder check is incomplete (\(snapshot.report.status.rawValue)). The last readable review is retained. Retry or export local evidence."
            statusMessage = "Folder check incomplete"; return
        }
        sourceAccessUnverified = false
        documents = snapshot.documents; candidates = snapshot.candidates; events = snapshot.events; self.state = state
        for doc in documents {
            if let url = doc.url { protectedSources.insert(url.standardizedFileURL) }
            if let bytes = snapshot.sourceBytes[doc.id], sourceObservations[doc.id] != bytes {
                if locallyAppliedSources[doc.id] != bytes { locallyAppliedSources[doc.id] = nil; onSourceObserved?(doc.reference, bytes) }
            }
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
            case .capacityExceeded: status = .capacityExceeded; error = "This workspace exceeds the supported limits. Export local evidence and use a smaller workspace."
            case .invalid(let message): status = .unavailable; error = message
            default: status = .unavailable; error = "The shared folder is unavailable. Retry or reconnect; the last readable review is retained."
            }
        } else { status = .unavailable; error = "The shared folder could not be read: \(failure.localizedDescription) Retry or reconnect; the last readable review is retained." }
        statusMessage = "Folder check incomplete"
    }
}
