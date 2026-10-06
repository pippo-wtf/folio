import XCTest
@testable import ReaderCore

final class CollaborationIdentityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testThreeSameNameParticipantsKeepDistinctStableParticipantAndDeviceIDs() throws {
        let root = try temporaryDirectory()
        var profiles: [ParticipantProfile] = []
        for index in 0..<3 {
            let url = root.appendingPathComponent("\(index)/profile.json")
            let first = try ParticipantStore(profileURL: url).loadOrCreate(displayName: "  Philip  ")
            let reopened = try ParticipantStore(profileURL: url).loadOrCreate(displayName: "Christian")
            XCTAssertEqual(first, reopened)
            XCTAssertEqual(first.displayName, "Philip")
            XCTAssertNotEqual(first.participantID, first.deviceID)
            profiles.append(first)
        }
        XCTAssertEqual(Set(profiles.map(\.participantID)).count, 3)
        XCTAssertEqual(Set(profiles.map(\.deviceID)).count, 3)
    }

    func testRenamePreservesIDsAndPreviousValueAttribution() throws {
        let store = ParticipantStore(profileURL: try temporaryDirectory().appendingPathComponent("profile.json"))
        let before = try store.loadOrCreate(displayName: "Philip")
        let after = try store.rename(to: "  Pippo  ")
        XCTAssertEqual(before.displayName, "Philip")
        XCTAssertEqual(after.displayName, "Pippo")
        XCTAssertEqual(before.participantID, after.participantID)
        XCTAssertEqual(before.deviceID, after.deviceID)
        XCTAssertEqual(try store.loadOrCreate(displayName: "Ignored"), after)
    }

    func testInvalidNamesDoNotCreateOrModifyProfile() throws {
        let url = try temporaryDirectory().appendingPathComponent("profile.json")
        let store = ParticipantStore(profileURL: url)
        for name in ["", " \n\t ", "Phi\u{0001}lip", String(repeating: "é", count: 51)] {
            XCTAssertThrowsError(try store.loadOrCreate(displayName: name))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        let profile = try store.loadOrCreate(displayName: String(repeating: "é", count: 50))
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.rename(to: "a\u{0000}b"))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try store.loadOrCreate(displayName: "Valid"), profile)
    }

    func testCorruptIdentityFailsClosedWithoutReplacingBytes() throws {
        let url = try temporaryDirectory().appendingPathComponent("profile.json")
        for bytes in [Data("broken".utf8), Data("{}".utf8), Data(repeating: 65, count: 4097)] {
            try bytes.write(to: url)
            let store = ParticipantStore(profileURL: url)
            XCTAssertThrowsError(try store.loadOrCreate(displayName: "Philip"))
            XCTAssertThrowsError(try store.rename(to: "Pippo"))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
}
