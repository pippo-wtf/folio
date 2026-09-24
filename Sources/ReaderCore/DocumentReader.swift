import Foundation

public enum ReaderError: Error, LocalizedError {
    case unsupported, tooLarge, encoding, denied
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose a Markdown file ending in .md or .markdown."
        case .tooLarge: return "This document is larger than the 8 MB limit. Open a smaller file."
        case .encoding: return "This file is not readable UTF-8 or UTF-16 text. Save a copy as UTF-8 in another app."
        case .denied: return "This file is unavailable. Download it locally or choose it again."
        }
    }
}
public enum DocumentReader {
    public static let maximumBytes = 8 * 1024 * 1024
    public static func read(_ url: URL) throws -> String {
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw ReaderError.unsupported }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ReaderError.tooLarge }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            guard let result = String(data: data, encoding: .utf16) else { throw ReaderError.encoding }
            return result
        }
        let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        guard let result = String(data: bytes, encoding: .utf8), !result.contains("\0") else { throw ReaderError.encoding }
        return result
    }
}
public enum AssetPolicy {
    public static func resolve(_ reference: String, document: URL, grantedRoot: URL?) -> URL? {
        guard let grantedRoot, let decoded = reference.removingPercentEncoding,
              !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.hasPrefix("\\"),
              !decoded.contains("\0"), !decoded.contains("\\"),
              URLComponents(string: decoded)?.scheme == nil,
              !decoded.hasPrefix("//") else { return nil }
        let root = grantedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = document.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"].contains(candidate.pathExtension.lowercased()) else { return nil }
        return candidate
    }
    public static func externalLink(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}
