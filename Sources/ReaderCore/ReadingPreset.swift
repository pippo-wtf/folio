import Foundation

public struct ReadingPreset: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var layout: LayoutSettings
    public var appearance: String
    public var zoom: Double
    public init(name: String, layout: LayoutSettings, appearance: String, zoom: Double = 1) {
        self.id = UUID(); self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.layout = layout; self.appearance = appearance; self.zoom = zoom
    }
    public var isValid: Bool {
        !name.isEmpty && name.count <= 60 && name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        layout.isValid && ["system", "light", "dark"].contains(appearance) && zoom.isFinite && (0.7...2.5).contains(zoom)
    }
    public static func validLibrary(_ values: [ReadingPreset]) -> Bool {
        values.count <= 100 && values.allSatisfy(\.isValid) && Set(values.map(\.id)).count == values.count &&
        Set(values.map { $0.name.lowercased() }).count == values.count
    }
}
