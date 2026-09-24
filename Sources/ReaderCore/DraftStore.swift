import Foundation
public struct RecoveryDraft: Codable, Equatable {
    public var text: String
    public var title: String
    public var originalPath: String?
    public init(text: String, title: String, originalPath: String?) { self.text = text; self.title = title; self.originalPath = originalPath }
}
public struct DraftStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> RecoveryDraft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 64_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(RecoveryDraft.self, from: data)
    }
    public func save(_ value: RecoveryDraft) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    public func clear() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
