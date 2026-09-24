import Foundation

public struct LayoutSettings: Codable, Equatable {
    public var bodyFont = "Source Serif 4"
    public var headingFont = "Oswald"
    public var bodyWeight = 400.0
    public var headingWeight = 700.0
    public var codeFont = "Menlo"
    public var bodySize = 24.0
    public var lineHeight = 1.55
    public var columnWidth = 60.0
    public var pageInset = 48.0
    public var topInset = 82.0
    public var bottomInset = 132.0
    public var paragraphGap = 1.6
    public var blockGap = 2.1
    public var headingScale = 1.0
    public var headingGap = 2.1
    public var listGap = 0.5
    public var codeSize = 18.0
    public var radius = 2.0
    public var ruleWidth = 3.0
    public var scrollbarWidth = 3.0
    public var lightPaper = "#FFFFFF"
    public var lightInk = "#191919"
    public var darkPaper = "#171717"
    public var darkInk = "#E9E9E9"
    public var accent = "#2CFF05"
    public var darkAccent = "#FF9B54"
    public var calloutStyle = "rule"
    public init() {}
    private enum CodingKeys: String, CodingKey { case bodyFont, headingFont, codeFont, bodySize, lineHeight, columnWidth, pageInset, topInset, bottomInset, paragraphGap, blockGap, headingScale, headingGap, listGap, codeSize, radius, ruleWidth, scrollbarWidth, lightPaper, lightInk, darkPaper, darkInk, accent, darkAccent, calloutStyle, bodyWeight, headingWeight }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bodyFont = try values.decode(String.self, forKey: .bodyFont)
        headingFont = try values.decode(String.self, forKey: .headingFont)
        codeFont = try values.decode(String.self, forKey: .codeFont)
        bodySize = try values.decode(Double.self, forKey: .bodySize)
        lineHeight = try values.decode(Double.self, forKey: .lineHeight)
        columnWidth = try values.decode(Double.self, forKey: .columnWidth)
        pageInset = try values.decode(Double.self, forKey: .pageInset)
        topInset = try values.decode(Double.self, forKey: .topInset)
        bottomInset = try values.decode(Double.self, forKey: .bottomInset)
        paragraphGap = try values.decode(Double.self, forKey: .paragraphGap)
        blockGap = try values.decode(Double.self, forKey: .blockGap)
        headingScale = try values.decode(Double.self, forKey: .headingScale)
        headingGap = try values.decode(Double.self, forKey: .headingGap)
        listGap = try values.decode(Double.self, forKey: .listGap)
        codeSize = try values.decode(Double.self, forKey: .codeSize)
        radius = try values.decode(Double.self, forKey: .radius)
        ruleWidth = try values.decode(Double.self, forKey: .ruleWidth)
        scrollbarWidth = try values.decode(Double.self, forKey: .scrollbarWidth)
        lightPaper = try values.decode(String.self, forKey: .lightPaper)
        lightInk = try values.decode(String.self, forKey: .lightInk)
        darkPaper = try values.decode(String.self, forKey: .darkPaper)
        darkInk = try values.decode(String.self, forKey: .darkInk)
        accent = try values.decode(String.self, forKey: .accent)
        darkAccent = try values.decodeIfPresent(String.self, forKey: .darkAccent) ?? "#FF9B54"
        calloutStyle = try values.decode(String.self, forKey: .calloutStyle)
        bodyWeight = try values.decodeIfPresent(Double.self, forKey: .bodyWeight) ?? 400
        headingWeight = try values.decodeIfPresent(Double.self, forKey: .headingWeight) ?? 700
    }
    public var isValid: Bool {
        let fonts = ["Source Serif 4", "Oswald", "Helvetica Neue", "Avenir Next", "Palatino", "Georgia", "Menlo"]
        guard fonts.contains(bodyFont), fonts.contains(headingFont),
              ["Menlo", "Monaco", "Courier"].contains(codeFont),
              ["rule", "plain", "box"].contains(calloutStyle) else { return false }
        let numbers: [(Double, ClosedRange<Double>)] = [
            (bodyWeight,100...900),(headingWeight,100...900),(bodySize,16...36),(lineHeight,1.2...2),(columnWidth,38...90),(pageInset,16...100),(topInset,16...160),(bottomInset,24...200),
            (paragraphGap,0.5...3),(blockGap,0.5...4),(headingScale,0.75...1.5),(headingGap,0.8...3.5),
            (listGap,0.1...1.2),(codeSize,12...26),(radius,0...16),(ruleWidth,0...6),(scrollbarWidth,1...8)
        ]
        return numbers.allSatisfy { $0.0.isFinite && $0.1.contains($0.0) } &&
            [lightPaper,lightInk,darkPaper,darkInk,accent,darkAccent].allSatisfy {
                $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
            }
    }
    public static func preset(_ name: String) -> LayoutSettings {
        var value = LayoutSettings()
        if name == "compact" { value.bodySize = 20; value.paragraphGap = 1; value.blockGap = 1.4; value.headingGap = 1.5; value.listGap = 0.25; value.lineHeight = 1.45 }
        if name == "editorial" { value.bodyFont = "Source Serif 4"; value.headingFont = "Oswald"; value.columnWidth = 54; value.lineHeight = 1.6 }
        return value
    }
}
