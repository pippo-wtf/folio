import XCTest
@testable import ReaderCore

final class ReadingPresetTests: XCTestCase {
    func testRoundTripPreservesEverySettingAndIdentity() throws {
        var layout = LayoutSettings(); layout.bodySize = 28; layout.accent = "#00FDFF"; layout.paragraphGap = 2
        let value = ReadingPreset(name: "Green Line", layout: layout, appearance: "dark", zoom: 1.2)
        let restored = try JSONDecoder().decode([ReadingPreset].self, from: JSONEncoder().encode([value]))
        XCTAssertEqual(restored, [value]); XCTAssertTrue(ReadingPreset.validLibrary(restored))
    }
    func testDuplicateNamesIDsAndInvalidValuesAreRejected() {
        let a = ReadingPreset(name: "Green Line", layout: LayoutSettings(), appearance: "light")
        let b = ReadingPreset(name: "green line", layout: LayoutSettings(), appearance: "light")
        XCTAssertFalse(ReadingPreset.validLibrary([a,b])); XCTAssertFalse(ReadingPreset.validLibrary([a,a]))
        var bad = a; bad.zoom = .infinity; XCTAssertFalse(bad.isValid)
        bad = a; bad.name = " "; XCTAssertFalse(bad.isValid)
        bad = a; bad.layout.bodySize = 500; XCTAssertFalse(bad.isValid)
        bad = a; bad.appearance = "unknown"; XCTAssertFalse(bad.isValid)
        XCTAssertTrue(ReadingPreset.validLibrary([]))
    }
    func testSavedSnapshotIsIndependentOfLaterEdits() {
        var layout = LayoutSettings()
        let preset = ReadingPreset(name: "Green Line", layout: layout, appearance: "light")
        layout.bodySize = 32
        XCTAssertEqual(preset.layout.bodySize, 24)
    }
}
