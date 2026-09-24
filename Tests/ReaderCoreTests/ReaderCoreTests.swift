import XCTest
@testable import ReaderCore
final class ReaderCoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testReadPreservesCRLFAndBytes() throws {
        let url=root.appendingPathComponent("note.md")
        let data=Data("# Title\r\n\r\n\tcode  \r\n".utf8)
        try data.write(to:url)
        XCTAssertEqual(try DocumentReader.read(url), String(data:data,encoding:.utf8))
        XCTAssertEqual(try Data(contentsOf:url),data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["note.md"])
    }
    func testEmptyAndBOM() throws {
        let url=root.appendingPathComponent("note.md")
        try Data().write(to:url); XCTAssertEqual(try DocumentReader.read(url),"")
        try (Data([0xef,0xbb,0xbf])+Data("# Text".utf8)).write(to:url)
        XCTAssertEqual(try DocumentReader.read(url),"# Text")
    }
    func testRejectsInvalidEncodingAndSize() throws {
        let url=root.appendingPathComponent("note.md")
        try Data([0xff,0x00,0xff]).write(to:url); XCTAssertThrowsError(try DocumentReader.read(url))
        try Data(repeating:65,count:DocumentReader.maximumBytes+1).write(to:url); XCTAssertThrowsError(try DocumentReader.read(url))
    }
    func testImageRequiresExplicitRoot() {
        let doc=root.appendingPathComponent("doc.md")
        XCTAssertNil(AssetPolicy.resolve("image.png",document:doc,grantedRoot:nil))
        XCTAssertEqual(AssetPolicy.resolve("image.png",document:doc,grantedRoot:root)?.lastPathComponent,"image.png")
    }
    func testTraversalAndUnsafeSchemesRejected() {
        let doc=root.appendingPathComponent("doc.md")
        for path in ["../outside.png","%2e%2e/outside.png","/tmp/image.png","file:///tmp/image.png","https://example.com/image.png","//example.com/image.png","..\\outside.png","script.svg","secret.txt"] {
            XCTAssertNil(AssetPolicy.resolve(path,document:doc,grantedRoot:root),path)
        }
    }
    func testSymlinkEscapeRejected() throws {
        let external=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        try Data([1]).write(to:external); defer { try? FileManager.default.removeItem(at:external) }
        let link=root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:external)
        XCTAssertNil(AssetPolicy.resolve("link.png",document:root.appendingPathComponent("doc.md"),grantedRoot:root))
    }
    func testExternalLinksAllowOnlyWeb() {
        for input in ["javascript:alert(1)","file:///etc/passwd","data:text/html,hello","x-apple.systempreferences:test"] {
            XCTAssertFalse(AssetPolicy.externalLink(URL(string:input)!))
        }
        XCTAssertTrue(AssetPolicy.externalLink(URL(string:"https://example.com")!))
    }
}
