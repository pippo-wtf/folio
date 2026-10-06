import Foundation

/// Task positions refer to Markdown source UTF-16, never rendered highlight positions.
public enum SharedTaskMatcher {
    private static let task = try! NSRegularExpression(pattern: "^[\\t ]*(?:[-+*]|[0-9]{1,9}[.)])[\\t ]+\\[([ xX])\\](?:[\\t ]|$)", options: .anchorsMatchLines)

    /// `rawSourceRevision` must come from the exact saved bytes, including encoding/BOM.
    public static func anchor(atUTF16 offset: Int, in source: String, rawSourceRevision: String) -> SharedTaskAnchor? {
        let text = source as NSString
        guard CollaborationIO.validHash(rawSourceRevision), offset >= 0, offset < text.length,
              text.length <= 32_000_000 else { return nil }
        let allCandidates = candidates(in: text)
        guard let candidate = allCandidates.first(where: { $0.offset == offset }),
              candidate.line.utf16.count <= 20_000 else { return nil }
        let normalizedText = normalized(source) as NSString
        let prefix = context(normalizedText, before: candidate.start)
        let suffix = context(normalizedText, after: candidate.end)
        // Reject anchors whose retained evidence cannot distinguish a surviving duplicate
        // after another identical task is deleted from a future revision.
        let equivalent = allCandidates.filter {
            normalized($0.line) == normalized(candidate.line)
                && context(normalizedText, before: $0.start, limit: prefix.utf16.count) == prefix
                && context(normalizedText, after: $0.end, limit: suffix.utf16.count) == suffix
        }
        guard equivalent.count == 1 else { return nil }
        return SharedTaskAnchor(sourceOffsetUTF16: offset, line: candidate.line,
                                prefix: prefix, suffix: suffix, rawSourceRevision: rawSourceRevision,
                                decodedSourceRevision: HighlightStore.revision(source))
    }

    /// A saved revision may use its validated original position. Changed source must have
    /// exactly one line/context match; proximity to the old offset is never evidence.
    public static func locate(_ anchor: SharedTaskAnchor, in source: String) -> Int? {
        guard (try? anchor.validate()) != nil, anchor.sourceOffsetUTF16 <= 32_000_000 else { return nil }
        let text = source as NSString
        guard text.length <= 32_000_000 else { return nil }
        let exactRevision = HighlightStore.revision(source) == anchor.decodedSourceRevision
        let normalizedText = normalized(source) as NSString
        var matches: [Int] = []
        for candidate in candidates(in: text) {
            guard normalized(candidate.line) == normalized(anchor.line),
                  context(normalizedText, before: candidate.start, limit: anchor.prefix.utf16.count) == normalized(anchor.prefix),
                  context(normalizedText, after: candidate.end, limit: anchor.suffix.utf16.count) == normalized(anchor.suffix) else { continue }
            if exactRevision {
                if candidate.offset == anchor.sourceOffsetUTF16 { return candidate.offset }
            } else {
                matches.append(candidate.offset)
                if matches.count > 1 { return nil }
            }
        }
        return exactRevision ? nil : matches.first
    }

    private struct Candidate {
        let start, end, offset: Int
        let line: String
    }

    private static func candidates(in text: NSString) -> [Candidate] {
        var result: [Candidate] = []
        var cursor = 0
        while cursor < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
            let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
            if let match = task.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                result.append(Candidate(start: start, end: contentsEnd,
                                        offset: start + match.range(at: 1).location, line: line))
            }
            cursor = end
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        let result = NSMutableString(string: value)
        for match in task.matches(in: value, range: NSRange(location: 0, length: value.utf16.count)).reversed() {
            result.replaceCharacters(in: match.range(at: 1), with: " ")
        }
        return result as String
    }

    private static func context(_ text: NSString, before end: Int, limit: Int = 64) -> String {
        var start = max(0, end - limit)
        // Context may be shorter than the limit rather than introduce a replacement character.
        if start < end, (0xDC00...0xDFFF).contains(Int(text.character(at: start))) { start += 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private static func context(_ text: NSString, after start: Int, limit: Int = 64) -> String {
        var end = min(text.length, start + limit)
        if end > start, (0xD800...0xDBFF).contains(Int(text.character(at: end - 1))) { end -= 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}
