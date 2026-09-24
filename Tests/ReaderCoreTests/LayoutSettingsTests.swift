import XCTest
@testable import ReaderCore
final class LayoutSettingsTests: XCTestCase {
    func testRoundTripPreservesCustomLayout() throws {
        var settings = LayoutSettings(); settings.paragraphGap = 2.4; settings.accent = "#123456"; settings.bodyFont = "Georgia"
        let restored = try JSONDecoder().decode(LayoutSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(settings, restored); XCTAssertTrue(restored.isValid)
    }
    func testUnsafeOrOutOfRangeValuesAreRejected() {
        var settings = LayoutSettings(); settings.accent = "red; background:url(https://example.com)"; XCTAssertFalse(settings.isValid)
        settings = LayoutSettings(); settings.bodySize = 1000; XCTAssertFalse(settings.isValid)
        settings = LayoutSettings(); settings.bodyFont = "Unknown"; XCTAssertFalse(settings.isValid)
        settings = LayoutSettings(); settings.lineHeight = .nan; XCTAssertFalse(settings.isValid)
    }
    func testEveryPresetIsValid() {
        for name in ["default", "compact", "editorial"] { XCTAssertTrue(LayoutSettings.preset(name).isValid) }
    }
    func testOlderLayoutKeepsCustomSettingsWhenWeightsAreMissing() throws {
        var settings = LayoutSettings(); settings.bodySize = 25; settings.lineHeight = 1.7
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json.removeValue(forKey: "bodyWeight"); json.removeValue(forKey: "headingWeight")
        let restored = try JSONDecoder().decode(LayoutSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, settings)
        settings.bodyWeight = 500; settings.headingWeight = 600
        XCTAssertEqual(try JSONDecoder().decode(LayoutSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.bodyWeight = 1000; XCTAssertFalse(settings.isValid)
    }
}
