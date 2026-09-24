import Foundation

enum BuildChannel {
    // Seed appearance only once. Each edition owns its subsequent preferences.
    static func prepareDefaults() {
        guard let url = Bundle.module.url(forResource: "InitialAppearance", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for key in ["readerLayoutV1", "readingPresetsV1", "appearance", "textZoom"] {
            guard UserDefaults.standard.object(forKey: key) == nil, let value = values[key] else { continue }
            if key == "readerLayoutV1" || key == "readingPresetsV1" {
                if let encoded = try? JSONSerialization.data(withJSONObject: value) { UserDefaults.standard.set(encoded, forKey: key) }
            } else { UserDefaults.standard.set(value, forKey: key) }
        }
    }
    #if FOLIO_UPDATE_TEST
    static let name = "Folio Update Test"
    static let storage = "Folio Update Test"
    #elseif FOLIO_STAGING
    static let name = "Folio Staging"
    static let storage = "Folio Staging"
    #else
    static let name = "Folio"
    static let storage = "Folio"
    #endif
}
