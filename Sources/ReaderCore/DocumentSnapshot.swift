import Foundation

public struct DocumentSnapshot: Sendable {
    public let bytes: Data
    public let text: String
    public init(url: URL) throws {
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw ReaderError.unsupported }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        bytes = try handle.read(upToCount: DocumentReader.maximumBytes + 1) ?? Data()
        guard bytes.count <= DocumentReader.maximumBytes else { throw ReaderError.tooLarge }
        guard let decoded = Self.decode(bytes), !decoded.contains("\0") else { throw ReaderError.encoding }
        text = decoded
    }
    private static func decode(_ bytes: Data) -> String? {
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { return String(data: bytes, encoding: .utf16) }
        return String(data: bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(bytes.dropFirst(3)) : bytes, encoding: .utf8)
    }
    public func encoded(_ draft: String) throws -> Data {
        if draft == text { return bytes }
        let encoding: String.Encoding = bytes.starts(with: [0xff, 0xfe]) ? .utf16LittleEndian : bytes.starts(with: [0xfe, 0xff]) ? .utf16BigEndian : .utf8
        var prefix = Data()
        if encoding == .utf16LittleEndian { prefix = Data([0xff, 0xfe]) }
        else if encoding == .utf16BigEndian { prefix = Data([0xfe, 0xff]) }
        else if bytes.starts(with: [0xef, 0xbb, 0xbf]) { prefix = Data([0xef, 0xbb, 0xbf]) }
        guard let data = draft.data(using: encoding) else { throw ReaderError.encoding }
        prefix.append(data)
        guard prefix.count <= DocumentReader.maximumBytes else { throw ReaderError.tooLarge }
        return prefix
    }
    public func save(_ draft: String, to url: URL) throws {
        let data = try encoded(draft)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { target in
            do {
                guard try DocumentSnapshot(url: target).bytes == bytes else { throw SaveError.conflict }
                if data != bytes { try data.write(to: target, options: .atomic) }
            } catch { writeError = error }
        }
        if let error = coordinatorError ?? writeError as NSError? { throw error }
    }
}
public enum SaveError: Error, LocalizedError {
    case conflict
    public var errorDescription: String? { "The file changed outside Folio. Your draft is safe here. Use Save As to keep a separate copy, or reopen the file to review the external version." }
}
