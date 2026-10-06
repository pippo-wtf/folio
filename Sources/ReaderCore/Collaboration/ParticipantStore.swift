import Foundation

/// Local claimed identity. An unreadable profile never creates a replacement identity.
public struct ParticipantStore {
    public let profileURL: URL
    public init(profileURL: URL) { self.profileURL = profileURL }

    public func loadOrCreate(displayName: String) throws -> ParticipantProfile {
        if let profile = try load() { return profile }
        let name = try validatedName(displayName)
        let profile = ParticipantProfile(participantID: UUID(), deviceID: UUID(), displayName: name)
        try persist(profile)
        return profile
    }

    public func rename(to displayName: String) throws -> ParticipantProfile {
        let name = try validatedName(displayName)
        guard let old = try load() else { throw CollaborationError.unavailable }
        let profile = ParticipantProfile(participantID: old.participantID, deviceID: old.deviceID, displayName: name)
        try persist(profile)
        return profile
    }

    private func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CollaborationIO.validName(name) else { throw CollaborationError.invalid("Name must contain 1–100 UTF-8 bytes and no control characters.") }
        return name
    }

    public func load() throws -> ParticipantProfile? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: profileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 4097) ?? Data()
        guard bytes.count <= 4096 else { throw CollaborationError.invalid("Corrupt local identity.") }
        let profile = try JSONDecoder().decode(ParticipantProfile.self, from: bytes)
        guard CollaborationIO.validName(profile.displayName), profile.participantID != profile.deviceID else { throw CollaborationError.invalid("Corrupt local identity.") }
        return profile
    }

    private func persist(_ profile: ParticipantProfile) throws {
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: profileURL, options: .atomic)
    }
}
