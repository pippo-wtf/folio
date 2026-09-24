import Foundation

/// A release bundle must explicitly opt into checks and explicitly opt out of
/// background downloads and installs before Folio starts Sparkle.
public enum UpdateConfiguration {
    public static func isSafe(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), isAllowedFeedURL(url),
              let key = info["SUPublicEDKey"] as? String,
              let decodedKey = Data(base64Encoded: key), decodedKey.count == 32 else { return false }
        for name in ["SUEnableAutomaticChecks", "SUShowReleaseNotes",
                     "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction",
                     "SUEnableInstallerLauncherService"] {
            guard info[name] as? Bool == true else { return false }
        }
        for name in ["SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate"] {
            guard info[name] as? Bool == false else { return false }
        }
        guard info["SUSignedFeedFailureExpirationInterval"] as? Int == 0 else { return false }
        return true
    }

    private static func isAllowedFeedURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.host != nil else { return false }
        if url.scheme == "https" { return true }
        #if FOLIO_UPDATE_TEST
        // Loopback HTTP is compiled only into the disposable update fixture.
        return url.scheme == "http" && url.host == "127.0.0.1"
        #else
        return false
        #endif
    }
}
