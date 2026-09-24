import Foundation
import CryptoKit

/// Local source-text history. Offsets and replacement lengths are UTF-8 bytes of the
/// decoded Markdown source, never offsets in the rendered page or original file bytes.
public struct EditJournalStore {
    public static let maximumDocumentBytes = DocumentReader.maximumBytes
    public static let maximumJournalBytes = 32 * 1024 * 1024
    public static let maximumEvents = 512

    public enum Kind: String, Codable {
        case renderedEdit, sourceEdit, undo, redo, save, externalReload, unrecordedTransition
    }

    public struct Replacement: Codable, Equatable {
        public let offsetUTF8: Int
        public let oldText: String
        public let newText: String
    }

    public struct Event: Codable, Equatable {
        public let id: UUID
        public let sequence: Int
        public let date: Date
        public let updatedAt: Date
        public let kind: Kind
        public let beforeRevision: String
        public let afterRevision: String
        public let replacement: Replacement?
        /// Present only when Folio saw a new revision after reopening without
        /// retaining the old source text needed to compute an exact replacement.
        public let gapReason: String?
    }

    public struct Journal: Codable, Equatable {
        public let version: Int
        public let offsetEncoding: String
        public let revisionEncoding: String
        public let initialRevision: String?
        public let headRevision: String?
        public let events: [Event]

        public static let empty = Journal(version: 1,
            offsetEncoding: "decoded-source-utf8-bytes",
            revisionEncoding: "sha256-of-decoded-source-utf8",
            initialRevision: nil, headRevision: nil, events: [])
    }

    public enum JournalError: Error, LocalizedError, Equatable {
        case documentTooLarge
        case historyFull
        case journalTooLarge
        case corruptJournal
        case revisionMismatch
        case invalidReplacement
        case eventIDConflict
        case nonReplayableGap

        public var errorDescription: String? {
            switch self {
            case .documentTooLarge: return "The source text exceeds Folio’s 8 MB document limit. The edit was not journaled."
            case .historyFull: return "The local edit journal has reached 512 events. Export and clear it before recording more edits."
            case .journalTooLarge: return "The local edit journal has reached 32 MB. Export and clear it before recording more edits."
            case .corruptJournal: return "The local edit journal is damaged or unsupported. It has not been overwritten."
            case .revisionMismatch: return "The edit journal revision does not match the source text. The journal has not been changed."
            case .invalidReplacement: return "The source replacement does not match the expected text. The journal has not been changed."
            case .eventIDConflict: return "This edit event ID already belongs to another edit. The journal has not been changed."
            case .nonReplayableGap: return "This external change happened while Folio was closed. Its earlier source text is unavailable for exact replay."
            }
        }
    }

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func revision(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads an existing journal without silently repairing, truncating, or resetting it.
    public func load(for key: String) throws -> Journal {
        let file = url(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return .empty }
        let data = try boundedRead(file)
        guard let journal = try? JSONDecoder().decode(Journal.self, from: data),
              Self.isStructurallyValid(journal) else { throw JournalError.corruptJournal }
        return journal
    }

    /// Records one accepted source transition. For typing, the caller should debounce
    /// writes and pass coalesceRenderedEdits=true; adjacent edits within 0.7 seconds
    /// become one exact net replacement with a stable event ID.
    @discardableResult
    public func record(for key: String, from before: String, to after: String,
                       kind: Kind, id: UUID = UUID(), date: Date = Date(),
                       coalesceRenderedEdits: Bool = false) throws -> Event? {
        guard before.utf8.count <= Self.maximumDocumentBytes,
              after.utf8.count <= Self.maximumDocumentBytes else { throw JournalError.documentTooLarge }
        let beforeHash = Self.revision(before)
        let afterHash = Self.revision(after)
        var journal = try load(for: key)
        if let existing = journal.events.first(where: { $0.id == id }) {
            guard existing.kind == kind, existing.beforeRevision == beforeHash,
                  existing.afterRevision == afterHash else { throw JournalError.eventIDConflict }
            return existing
        }
        guard journal.headRevision == nil || journal.headRevision == beforeHash else {
            throw JournalError.revisionMismatch
        }
        guard before != after || kind == .save else { return nil }
        // Repeated saves of the same source do not grow an unbounded marker trail.
        if kind == .save, before == after, let last = journal.events.last,
           last.kind == .save, last.afterRevision == afterHash { return last }

        var events = journal.events
        var event: Event
        if coalesceRenderedEdits, kind == .renderedEdit,
           let last = events.last, last.kind == .renderedEdit,
           date.timeIntervalSince(last.updatedAt) >= 0,
           date.timeIntervalSince(last.updatedAt) <= 0.7,
           last.afterRevision == beforeHash,
           last.replacement != nil {
            let original = try Self.replay(last, on: before, reversing: true)
            let net = Self.replacement(from: original, to: after)
            events.removeLast()
            if let net {
                event = Event(id: last.id, sequence: last.sequence, date: last.date,
                    updatedAt: date, kind: kind, beforeRevision: last.beforeRevision,
                    afterRevision: afterHash, replacement: net, gapReason: nil)
                events.append(event)
            } else {
                let result = Journal(version: 1, offsetEncoding: Journal.empty.offsetEncoding,
                    revisionEncoding: Journal.empty.revisionEncoding,
                    initialRevision: journal.initialRevision ?? last.beforeRevision,
                    headRevision: afterHash, events: events)
                try persist(result, for: key)
                return nil
            }
        } else {
            guard events.count < Self.maximumEvents else { throw JournalError.historyFull }
            event = Event(id: id, sequence: (events.last?.sequence ?? 0) + 1,
                date: date, updatedAt: date, kind: kind, beforeRevision: beforeHash,
                afterRevision: afterHash, replacement: Self.replacement(from: before, to: after),
                gapReason: nil)
            events.append(event)
        }
        journal = Journal(version: 1, offsetEncoding: Journal.empty.offsetEncoding,
            revisionEncoding: Journal.empty.revisionEncoding,
            initialRevision: journal.initialRevision ?? beforeHash,
            headRevision: afterHash, events: events)
        try persist(journal, for: key)
        return event
    }

    /// Marks drift discovered on reopen, when only the previous hash survived.
    /// This is intentionally not an exact edit: never invent missing old text.
    @discardableResult
    public func recordExternalGap(for key: String, observedText: String,
                                  id: UUID = UUID(), date: Date = Date()) throws -> Event? {
        guard observedText.utf8.count <= Self.maximumDocumentBytes else { throw JournalError.documentTooLarge }
        let observedHash = Self.revision(observedText)
        let journal = try load(for: key)
        if let existing = journal.events.first(where: { $0.id == id }) {
            guard existing.kind == .externalReload, existing.afterRevision == observedHash,
                  existing.gapReason == "source-before-unavailable" else { throw JournalError.eventIDConflict }
            return existing
        }
        guard let head = journal.headRevision else {
            try persist(Journal(version: 1, offsetEncoding: Journal.empty.offsetEncoding,
                revisionEncoding: Journal.empty.revisionEncoding,
                initialRevision: observedHash, headRevision: observedHash, events: []), for: key)
            return nil
        }
        guard head != observedHash else { return nil }
        guard journal.events.count < Self.maximumEvents else { throw JournalError.historyFull }
        let event = Event(id: id, sequence: (journal.events.last?.sequence ?? 0) + 1,
            date: date, updatedAt: date, kind: .externalReload,
            beforeRevision: head, afterRevision: observedHash,
            replacement: nil, gapReason: "source-before-unavailable")
        try persist(Journal(version: 1, offsetEncoding: Journal.empty.offsetEncoding,
            revisionEncoding: Journal.empty.revisionEncoding,
            initialRevision: journal.initialRevision, headRevision: observedHash,
            events: journal.events + [event]), for: key)
        return event
    }

    /// Applies an event only if its revision and exact replaced bytes match.
    public static func replay(_ event: Event, on text: String, reversing: Bool = false) throws -> String {
        let expected = reversing ? event.afterRevision : event.beforeRevision
        guard revision(text) == expected else { throw JournalError.revisionMismatch }
        guard let replacement = event.replacement else {
            if event.gapReason != nil { throw JournalError.nonReplayableGap }
            guard event.beforeRevision == event.afterRevision else { throw JournalError.invalidReplacement }
            return text
        }
        let bytes = Array(text.utf8)
        let removed = Array((reversing ? replacement.newText : replacement.oldText).utf8)
        let inserted = Array((reversing ? replacement.oldText : replacement.newText).utf8)
        let start = replacement.offsetUTF8
        guard start >= 0, start <= bytes.count,
              removed.count <= bytes.count - start,
              bytes[start..<(start + removed.count)].elementsEqual(removed) else {
            throw JournalError.invalidReplacement
        }
        var result = Data(bytes[..<start])
        result.append(contentsOf: inserted)
        result.append(contentsOf: bytes[(start + removed.count)...])
        guard let decoded = String(data: result, encoding: .utf8),
              revision(decoded) == (reversing ? event.beforeRevision : event.afterRevision) else {
            throw JournalError.invalidReplacement
        }
        return decoded
    }

    /// Explicit user-controlled discard after export; never called as automatic recovery.
    public func clear(for key: String) throws {
        let file = url(for: key)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Carries history to a newly saved path. Existing destination history is
    /// authoritative and is never replaced, even if the source contains events.
    @discardableResult
    public func copyIfAbsent(from sourceKey: String, to destinationKey: String) throws -> Bool {
        guard sourceKey != destinationKey else { return false }
        let source = url(for: sourceKey)
        let destination = url(for: destinationKey)
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: destination.path) else { return false }
        _ = try load(for: sourceKey)
        let data = try boundedRead(source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return true
    }

    private func persist(_ journal: Journal, for key: String) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= Self.maximumJournalBytes else { throw JournalError.journalTooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: key), options: .atomic)
    }

    private func boundedRead(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumJournalBytes + 1) ?? Data()
        guard data.count <= Self.maximumJournalBytes else { throw JournalError.journalTooLarge }
        return data
    }

    private func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    private static func isStructurallyValid(_ journal: Journal) -> Bool {
        guard journal.version == 1,
              journal.offsetEncoding == Journal.empty.offsetEncoding,
              journal.revisionEncoding == Journal.empty.revisionEncoding,
              journal.events.count <= maximumEvents,
              journal.initialRevision.map(isHash) ?? journal.events.isEmpty,
              journal.headRevision.map(isHash) ?? journal.events.isEmpty,
              Set(journal.events.map(\.id)).count == journal.events.count else { return false }
        var expected = journal.initialRevision
        var previousSequence = 0
        for event in journal.events {
            guard event.sequence == previousSequence + 1,
                  event.beforeRevision == expected, isHash(event.afterRevision),
                  event.updatedAt >= event.date,
                  (event.replacement != nil ||
                    (event.kind == .save && event.beforeRevision == event.afterRevision && event.gapReason == nil) ||
                    (event.kind == .externalReload && event.beforeRevision != event.afterRevision &&
                     event.gapReason == "source-before-unavailable")) else { return false }
            if let patch = event.replacement {
                guard event.gapReason == nil, patch.offsetUTF8 >= 0,
                      patch.offsetUTF8 <= maximumDocumentBytes,
                      patch.oldText.utf8.count <= maximumDocumentBytes,
                      patch.newText.utf8.count <= maximumDocumentBytes else { return false }
            }
            expected = event.afterRevision
            previousSequence = event.sequence
        }
        return expected == journal.headRevision
    }

    private static func isHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func replacement(from before: String, to after: String) -> Replacement? {
        let old = Array(before.utf8)
        let new = Array(after.utf8)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        if prefix == old.count && prefix == new.count { return nil }
        // A byte prefix can stop within one scalar when two UTF-8 sequences share
        // leading bytes. Retreat until both strings have a scalar boundary.
        while prefix > 0 &&
            ((prefix < old.count && isContinuation(old[prefix])) ||
             (prefix < new.count && isContinuation(new[prefix]))) { prefix -= 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        while suffix > 0 &&
            ((old.count - suffix < old.count && isContinuation(old[old.count - suffix])) ||
             (new.count - suffix < new.count && isContinuation(new[new.count - suffix]))) { suffix -= 1 }
        let oldSlice = Data(old[prefix..<(old.count - suffix)])
        let newSlice = Data(new[prefix..<(new.count - suffix)])
        return Replacement(offsetUTF8: prefix,
            oldText: String(data: oldSlice, encoding: .utf8)!,
            newText: String(data: newSlice, encoding: .utf8)!)
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xc0 == 0x80 }
}
