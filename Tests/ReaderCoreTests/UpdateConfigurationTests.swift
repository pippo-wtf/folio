import XCTest
@testable import ReaderCore

final class UpdateConfigurationTests: XCTestCase {
    private var safeInfo: [String: Any] {
        [
            "SUFeedURL": "https://example.com/updates/public.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": true,
            "SUShowReleaseNotes": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUVerifyUpdateBeforeExtraction": true,
            "SUEnableInstallerLauncherService": true,
            "SUAllowsAutomaticUpdates": false,
            "SUAutomaticallyUpdate": false,
        ]
    }

    func testValidManualPolicyEnablesUpdater() {
        XCTAssertTrue(UpdateConfiguration.isSafe(safeInfo))
    }

    func testMissingOrEnabledAutomaticInstallFailsClosed() {
        var info = safeInfo
        info.removeValue(forKey: "SUAllowsAutomaticUpdates")
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
        info["SUAllowsAutomaticUpdates"] = true
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
        info = safeInfo
        info["SUAutomaticallyUpdate"] = true
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
    }

    func testLoopbackExceptionIsTestFlavorOnly() {
        var info = safeInfo
        info["SUFeedURL"] = "http://127.0.0.1:8765/appcast.xml"
        #if FOLIO_UPDATE_TEST
        XCTAssertTrue(UpdateConfiguration.isSafe(info))
        #else
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
        #endif
        info["SUFeedURL"] = "http://localhost:8765/appcast.xml"
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
        info["SUFeedURL"] = "http://example.com/appcast.xml"
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
    }

    func testUnsignedOrInsecureFeedFailsClosed() {
        var info = safeInfo
        info["SURequireSignedFeed"] = false
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
        info = safeInfo
        info["SUSignedFeedFailureExpirationInterval"] = 1728000
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
        info = safeInfo
        info["SUFeedURL"] = "http://example.com/updates/public.xml"
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
        info = safeInfo
        info["SUPublicEDKey"] = "invalid"
        XCTAssertFalse(UpdateConfiguration.isSafe(info))
    }
}
