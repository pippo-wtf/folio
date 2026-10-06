import XCTest

@testable import TransportProbe

final class ProtocolTests: XCTestCase {
  let w = UUID(), d = UUID(), p = UUID(), v = UUID()
  func event(text: String = "hi", parents: [UUID] = []) -> ProbeEvent {
    ProbeEvent(
      workspaceID: w, documentID: d, participantID: p, deviceID: v, parents: parents,
      payload: .comment(id: UUID(), text: text, sourceRevision: String(repeating: "a", count: 64)))
  }
  func testSchemaReferencesCommentAndHashValidation() throws {
    var e = event()
    e.schemaVersion = 2
    XCTAssertThrowsError(try e.validate())
    XCTAssertThrowsError(try event(text: String(repeating: "x", count: 8001)).validate())
    XCTAssertNoThrow(try event(text: String(repeating: "x", count: 8000)).validate())
    XCTAssertNoThrow(try event(parents: (0..<32).map { _ in UUID() }).validate())
    XCTAssertThrowsError(try event(parents: (0..<33).map { _ in UUID() }).validate())
    e = event()
    e.parents = [e.id]
    XCTAssertThrowsError(try e.validate())
    e = event()
    e.payload = .sourceProposal(
      baseRevision: "bad", proposedRevision: String(repeating: "A", count: 64))
    XCTAssertThrowsError(try e.validate())
    let encoded = try ProbeIO.encode(event())
    let badUUID = String(data: encoded, encoding: .utf8)!.replacingOccurrences(
      of: w.uuidString, with: "not-a-uuid")
    XCTAssertThrowsError(try ProbeIO.decodeEvent(Data(badUUID.utf8)))
  }
  func testCanonicalUUIDsAndOversizedExistingImmutableIdentity() throws {
    var e = event()
    e.workspaceID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001")!
    let encoded = try ProbeIO.encode(e)
    let lower = String(data: encoded, encoding: .utf8)!.replacingOccurrences(
      of: e.workspaceID.uuidString, with: e.workspaceID.uuidString.lowercased())
    XCTAssertThrowsError(try ProbeIO.decodeEvent(Data(lower.utf8)))
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("immutable")
    try Data("longer".utf8).write(to: path)
    XCTAssertThrowsError(try ProbeIO.immutable(Data("x".utf8), at: path)) {
      XCTAssertEqual($0 as? ProbeError, .identityConflict)
    }
  }
  func testBoundedReadsAndEventBoundary() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("event.json")
    let bytes = try ProbeIO.encode(event())
    let boundary = bytes + Data(repeating: 32, count: 65536 - bytes.count)
    try boundary.write(to: file)
    XCTAssertEqual(try ProbeIO.read(file, limit: 65536), boundary)
    XCTAssertNoThrow(try ProbeIO.decodeEvent(boundary))
    try (boundary + Data([32])).write(to: file)
    XCTAssertThrowsError(try ProbeIO.read(file, limit: 65536))
    XCTAssertThrowsError(try ProbeIO.decodeEvent(boundary + Data([32])))
  }
  func testSnapshotLimitsAndRawRoundTrip() throws {
    let large = Data(repeating: 0, count: 8 * 1024 * 1024)
    XCTAssertNoThrow(try ProbeIO.snapshot(large, hash: SnapshotID.hash(large)))
    XCTAssertThrowsError(
      try ProbeIO.snapshot(large + Data([0]), hash: SnapshotID.hash(large + Data([0]))))
    XCTAssertThrowsError(try ProbeIO.snapshot(Data([0]), hash: String(repeating: "a", count: 64)))
    let variants = [
      Data("x\n".utf8), Data([0xef, 0xbb, 0xbf]) + Data("x\n".utf8),
      Data([0xff, 0xfe, 0x78, 0, 0x0a, 0]), Data("x\r\n".utf8),
    ]
    XCTAssertEqual(Set(variants.map(SnapshotID.hash)).count, 4)
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    for data in variants {
      let file = root.appendingPathComponent(SnapshotID.hash(data))
      try ProbeIO.immutable(data, at: file)
      XCTAssertEqual(try Data(contentsOf: file), data)
      XCTAssertNoThrow(try ProbeIO.immutable(data, at: file))
      XCTAssertThrowsError(try ProbeIO.immutable(Data([9]), at: file))
      XCTAssertEqual(try Data(contentsOf: file), data)
    }
  }
  func testRootEscapeAndSymlinkRejected() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try ProbeIO.safe(root.appendingPathComponent("../escape"), root: root))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"),
      withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
    XCTAssertThrowsError(try ProbeIO.safe(root.appendingPathComponent("link/data"), root: root))
  }
}
func temporary() -> URL {
  let u = FileManager.default.temporaryDirectory.appendingPathComponent(
    "folio-probe-" + UUID().uuidString)
  try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u
}
