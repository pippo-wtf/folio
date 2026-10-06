import Foundation

/// Private seen IDs. Reading has no effect on shared events, task state or resolution.
public struct SharedReadStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private struct Record: Codable {
        let version: Int
        let participantID, workspaceID, documentID: UUID
        let eventIDs: Set<UUID>
    }

    public func seenEventIDs(participantID: UUID, workspaceID: UUID, documentID: UUID) throws -> Set<UUID> {
        let url = file(participantID: participantID, workspaceID: workspaceID, documentID: documentID)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [] }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw CollaborationError.capacityExceeded }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.participantID == participantID,
              record.workspaceID == workspaceID, record.documentID == documentID else {
            throw CollaborationError.identityConflict
        }
        return record.eventIDs
    }

    public func markSeen(eventIDs: Set<UUID>, participantID: UUID, workspaceID: UUID, documentID: UUID) throws {
        let seen = try seenEventIDs(participantID: participantID, workspaceID: workspaceID, documentID: documentID).union(eventIDs)
        let record = Record(version: 1, participantID: participantID, workspaceID: workspaceID, documentID: documentID, eventIDs: seen)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 8 * 1024 * 1024 else { throw CollaborationError.capacityExceeded }
        let url = file(participantID: participantID, workspaceID: workspaceID, documentID: documentID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func unreadEventIDs(eventIDs: Set<UUID>, ownEventIDs: Set<UUID>, participantID: UUID, workspaceID: UUID, documentID: UUID) throws -> Set<UUID> {
        try eventIDs.subtracting(ownEventIDs).subtracting(seenEventIDs(participantID: participantID, workspaceID: workspaceID, documentID: documentID))
    }

    private func file(participantID: UUID, workspaceID: UUID, documentID: UUID) -> URL {
        directory.appendingPathComponent(participantID.uuidString, isDirectory: true)
            .appendingPathComponent(workspaceID.uuidString, isDirectory: true)
            .appendingPathComponent(documentID.uuidString + ".json")
    }
}
