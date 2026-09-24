import Foundation
import CryptoKit

public struct SavedHighlight: Codable, Equatable {
    public var id: String
    public var start: Int
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var comment: String?
    public var revision: String?
    public init(id: String, start: Int, quote: String, prefix: String, suffix: String) {
        self.id = id; self.start = start; self.quote = quote; self.prefix = prefix; self.suffix = suffix
    }
    public var preview: String {
        let text = quote.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var first = text
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, stop in
            if let sentence { first = sentence.trimmingCharacters(in: .whitespacesAndNewlines) }
            stop = true
        }
        return first
    }
    public var isValid: Bool {
        UUID(uuidString: id) != nil && start >= 0 && start <= 32_000_000 &&
        !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quote.utf16.count <= 20_000 &&
        prefix.utf16.count <= 64 && suffix.utf16.count <= 64 && (comment?.utf16.count ?? 0) <= 8000 && (revision == nil || revision!.count == 64)
    }
}

public struct HighlightStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public struct Event: Codable, Equatable {
        public let id: UUID
        public let sequence: Int
        public let date: Date
        public let operation: String
        public let before: SavedHighlight?
        public let after: SavedHighlight?
        public let reviewedRevision: String?
        public let draft: Bool
    }
    private struct Document: Codable {
        var version: Int
        var highlights: [SavedHighlight]
        var events: [Event]?
    }
    public static func revision(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func document(for key: String) throws -> Document {
        let file = url(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return Document(version: 2, highlights: [], events: []) }
        let data = try Data(contentsOf: file)
        guard data.count <= 32_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Document.self, from: data)
        guard [1,2].contains(value.version), Self.valid(value.highlights) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    public func events(for key: String) throws -> [Event] { try document(for: key).events ?? [] }
    public func feedback(for key: String, currentText: String, draft: Bool) throws -> Data {
        struct Packet: Encodable {
            let version = 1
            let documentPath: String
            let currentRevision: String
            let revisionEncoding = "sha256-of-decoded-source-utf8"
            let draft: Bool
            let anchorCoordinates = "rendered-text-utf16; not Markdown source offsets"
            let instruction = "Highlights mean attention only. Comments are user feedback. Verify the current revision and locate each quote unambiguously before changing source. Read does not mean resolved."
            let highlights: [SavedHighlight]
            let events: [Event]
        }
        let value = try document(for: key)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Packet(documentPath: key, currentRevision: Self.revision(currentText), draft: draft, highlights: value.highlights, events: value.events ?? []))
    }
    private func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    public static func valid(_ records: [SavedHighlight]) -> Bool {
        records.count <= 1000 && records.allSatisfy(\.isValid) && Set(records.map(\.id)).count == records.count
    }
    public func load(for key: String) throws -> [SavedHighlight] {
        try document(for: key).highlights
    }
    public func save(_ highlights: [SavedHighlight], for key: String, revision: String? = nil, draft: Bool = false) throws {
        guard Self.valid(highlights) else { throw CocoaError(.fileWriteInvalidFileName) }
        var previous = try document(for: key)
        var events = previous.events ?? []
        let old = Dictionary(uniqueKeysWithValues: previous.highlights.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: highlights.map { ($0.id, $0) })
        for id in Set(old.keys).union(new.keys).sorted() where old[id] != new[id] {
            events.append(Event(id: UUID(), sequence: (events.last?.sequence ?? 0) + 1, date: Date(), operation: old[id] == nil ? "added" : new[id] == nil ? "removed" : "updated", before: old[id], after: new[id], reviewedRevision: revision, draft: draft))
        }
        previous.version = 2; previous.highlights = highlights; previous.events = events
        let data = try JSONEncoder().encode(previous)
        guard data.count <= 32_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: key), options: .atomic)
    }
}
