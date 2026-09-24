import XCTest
@testable import ReaderCore
final class DocumentSnapshotTests: XCTestCase {
    func withFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    func testEncodingBOMAndLineEndingsSurviveEditAndNoOp() throws {
        for (encoding, prefix) in [(String.Encoding.utf8, Data()), (.utf8, Data([0xef,0xbb,0xbf])), (.utf16LittleEndian, Data([0xff,0xfe])), (.utf16BigEndian, Data([0xfe,0xff]))] {
            let original = "# Héllo\r\n\r\nText 😀\r\n"
            let data = prefix + original.data(using: encoding)!
            try withFile(data) { url in
                let snapshot = try DocumentSnapshot(url: url)
                XCTAssertEqual(snapshot.text, original)
                try snapshot.save(original, to: url)
                XCTAssertEqual(try Data(contentsOf: url), data)
                let draft = original.replacingOccurrences(of: "Text", with: "New text")
                try snapshot.save(draft, to: url)
                XCTAssertEqual(try Data(contentsOf: url), prefix + draft.data(using: encoding)!)
            }
        }
    }
    func testExternalChangesAreNeverOverwritten() throws {
        try withFile(Data("original".utf8)) { url in
            let snapshot = try DocumentSnapshot(url: url)
            try Data("external".utf8).write(to: url)
            XCTAssertThrowsError(try snapshot.save("draft", to: url))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        }
    }
    func testDeletedOriginalIsNotRecreated() throws {
        try withFile(Data("original".utf8)) { url in
            let snapshot = try DocumentSnapshot(url: url)
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try snapshot.save("draft", to: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
