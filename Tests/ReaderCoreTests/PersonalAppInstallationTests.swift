import XCTest
@testable import ReaderCore

final class PersonalAppInstallationTests: XCTestCase {
    func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("download/Folio.app")
        let home = root.appendingPathComponent("person")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("payload"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, source, home)
    }
    func testInstallAndReplaceInReceivingHome() throws {
        let (_, source, home) = try fixture()
        var verified: [URL] = []
        let installed = try PersonalAppInstallation.install(source: source, home: home, isRunning: { false }, verify: { verified.append($0) })
        XCTAssertEqual(installed, home.appendingPathComponent("Applications/Folio.app"))
        XCTAssertEqual(verified.count, 2)
        try Data("updated".utf8).write(to: source.appendingPathComponent("payload"))
        try PersonalAppInstallation.install(source: source, home: home, isRunning: { false }, verify: { _ in })
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("payload")), "updated")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Applications").path), ["Folio.app"])
    }
    func testFailedCopiedSignaturePreservesInstalledApp() throws {
        let (_, source, home) = try fixture()
        let installed = try PersonalAppInstallation.install(source: source, home: home, isRunning: { false }, verify: { _ in })
        try Data("unverified".utf8).write(to: source.appendingPathComponent("payload"))
        var checks = 0
        XCTAssertThrowsError(try PersonalAppInstallation.install(source: source, home: home, isRunning: { false }, verify: { _ in
            checks += 1; if checks == 2 { throw CocoaError(.fileReadCorruptFile) }
        }))
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("payload")), "new")
    }
    func testRunningAppAndExternalFolderAreRejected() throws {
        let (root, source, home) = try fixture()
        XCTAssertThrowsError(try PersonalAppInstallation.install(source: source, home: home, isRunning: { true }, verify: { _ in }))
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Applications"), withDestinationURL: shared)
        XCTAssertThrowsError(try PersonalAppInstallation.install(source: source, home: home, isRunning: { false }, verify: { _ in }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shared.path), [])
    }
}
