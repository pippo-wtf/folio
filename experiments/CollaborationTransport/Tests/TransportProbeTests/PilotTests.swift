import XCTest

@testable import TransportProbe

final class PilotTests: XCTestCase {
  func run(_ arguments: [String]) throws -> (Int32, [String: Any]) {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let xcode = package.appendingPathComponent(".build/out/Products/Debug/folio-transport-probe")
    let standard = package.appendingPathComponent(".build/debug/folio-transport-probe")
    let task = Process()
    let pipe = Pipe()
    task.executableURL = FileManager.default.fileExists(atPath: xcode.path) ? xcode : standard
    task.arguments = arguments
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try task.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, try JSONSerialization.jsonObject(with: bytes) as! [String: Any])
  }
  func args(_ command: String, _ root: URL) -> [String] {
    [
      command, "--local-root", root.appendingPathComponent("local").path, "--shared-root",
      root.appendingPathComponent("shared").path,
    ]
  }
  func initialize(_ root: URL) throws {
    let result = try run(
      args("init", root) + [
        "--workspace-id", fixed(1).uuidString, "--document-id", fixed(2).uuidString,
      ])
    XCTAssertEqual(result.0, 0)
  }
  func testCommandsPrepareApplyDelayedSnapshotsAndRecovery() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try initialize(root)
    let source = root.appendingPathComponent("shared/fixture.md")
    let base = root.appendingPathComponent("local/base.bin")
    let proposed = root.appendingPathComponent("local/proposed.bin")
    let original = try Data(contentsOf: source)
    try original.write(to: base)
    try Data("proposed 👋\r\n".utf8).write(to: proposed)
    let prepared = try run(
      args("prepare-source", root) + ["--base", base.path, "--proposed", proposed.path])
    XCTAssertEqual(prepared.0, 0)
    let id = prepared.1["proposalID"] as! String
    let applied = try run(args("apply-source", root) + ["--proposal-id", id])
    XCTAssertEqual(applied.0, 0)
    XCTAssertEqual(try Data(contentsOf: source), Data("proposed 👋\r\n".utf8))
    let events = try run(args("publish", root) + ["--only", "events"])
    XCTAssertEqual(events.1["status"] as? String, "pending")
    XCTAssertFalse(events.1.description.contains("remote sync confirmed"))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("shared/Folio Review/events"),
        includingPropertiesForKeys: nil
      ).count, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("shared/Folio Review/snapshots").path))
    let interruption = try run(
      args("publish", root) + ["--only", "snapshots", "--stop-after", "1"])
    XCTAssertEqual(interruption.0, 3)
    XCTAssertEqual(interruption.1["status"] as? String, "injectedInterruption")
    XCTAssertEqual(try run(args("publish", root)).0, 0)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("shared/Folio Review/snapshots"),
        includingPropertiesForKeys: nil
      ).count, 2)
    let output = root.appendingPathComponent("recovery")
    XCTAssertEqual(
      try run(args("recover", root) + ["--proposal-id", id, "--output", output.path]).0, 0)
    let files = try FileManager.default.contentsOfDirectory(
      at: output, includingPropertiesForKeys: nil)
    XCTAssertTrue(files.contains { (try? Data(contentsOf: $0)) == original })
    XCTAssertTrue(files.contains { (try? Data(contentsOf: $0)) == Data("proposed 👋\r\n".utf8) })
  }
  func testFailedApplyPreservesSourceAndExportLedgerRoundTrip() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try initialize(root)
    let source = root.appendingPathComponent("shared/fixture.md")
    let base = root.appendingPathComponent("local/base.bin")
    let proposed = root.appendingPathComponent("local/next.bin")
    try Data(contentsOf: source).write(to: base)
    try Data("next".utf8).write(to: proposed)
    let id =
      try run(args("prepare-source", root) + ["--base", base.path, "--proposed", proposed.path]).1[
        "proposalID"] as! String
    try Data("external".utf8).write(to: source)
    XCTAssertEqual(try run(args("apply-source", root) + ["--proposal-id", id]).0, 2)
    XCTAssertEqual(try Data(contentsOf: source), Data("external".utf8))
    let output = root.appendingPathComponent("evidence")
    XCTAssertEqual(try run(args("export", root) + ["--output", output.path]).0, 0)
    let json =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: output.appendingPathComponent("ledger.json"))) as! [String: Any]
    XCTAssertNotNil(json["monotonicDurationNanoseconds"])
    XCTAssertNotNil(json["snapshotHashes"])
    XCTAssertNotNil(json["limits"])
    let scan = try run(args("scan", root))
    let report = try JSONSerialization.data(withJSONObject: scan.1["reconciliation"]!)
    XCTAssertEqual(
      try JSONDecoder().decode(ReconciliationReport.self, from: report).status, .complete)
  }
  func testValidationJoinGenerateAndUnavailableFolder() throws {
    let root = temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNotEqual(try run(["scan"]).0, 0)
    try initialize(root)
    XCTAssertNotEqual(
      try run(
        args("init", root) + [
          "--workspace-id", fixed(1).uuidString, "--document-id", fixed(2).uuidString,
        ]
      ).0, 0)
    XCTAssertNotEqual(try run(args("publish", root) + ["--only", "wrong"]).0, 0)
    XCTAssertNotEqual(
      try run(
        args("generate", root) + [
          "--participant-id", fixed(3).uuidString, "--device-id", fixed(4).uuidString, "--count",
          "0",
        ]
      ).0, 0)
    XCTAssertEqual(
      try run(
        args("generate", root) + [
          "--participant-id", fixed(3).uuidString, "--device-id", fixed(4).uuidString, "--count",
          "3", "--seed", "1",
        ]
      ).0, 0)
    XCTAssertEqual(try run(args("publish", root) + ["--stop-after", "1"]).0, 3)
    XCTAssertEqual(try run(args("publish", root)).0, 0)
    let second = root.appendingPathComponent("second-local")
    XCTAssertEqual(
      try run([
        "join", "--local-root", second.path, "--shared-root",
        root.appendingPathComponent("shared").path, "--workspace-id", fixed(1).uuidString,
      ]).0, 0)
    let scan = try run([
      "scan", "--local-root", second.path, "--shared-root",
      root.appendingPathComponent("shared").path,
    ])
    let report = scan.1["reconciliation"] as! [String: Any]
    let state = report["state"] as! [String: Any]
    XCTAssertEqual((state["acceptedIDs"] as! [String]).count, 3)
    XCTAssertNotEqual(
      try run(args("prepare-source", root) + ["--base", "/etc/hosts", "--proposed", "/etc/hosts"])
        .0, 0)
    try FileManager.default.moveItem(
      at: root.appendingPathComponent("shared"), to: root.appendingPathComponent("renamed"))
    XCTAssertEqual(try run(args("scan", root)).0, 2)
  }
}
