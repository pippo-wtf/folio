import SwiftUI
import AppKit
import ReaderCore

struct LayoutEditor: View {
    @ObservedObject var model: ReaderModel

    private let bodyHeadFonts = ["Source Serif 4", "Oswald", "Helvetica Neue", "Avenir Next", "Palatino", "Georgia", "Menlo"]
    private let codeFonts = ["Menlo", "Monaco", "Courier"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section("Typography") {
                    picker("Body Font", \.bodyFont, options: bodyHeadFonts)
                    slider("Body Weight", \.bodyWeight, range: weightRange(model.layout.bodyFont), step: 100, unit: "")
                    picker("Heading Font", \.headingFont, options: bodyHeadFonts)
                    slider("Heading Weight", \.headingWeight, range: weightRange(model.layout.headingFont), step: 100, unit: "")
                    picker("Code Font", \.codeFont, options: codeFonts)
                    slider("Body Size", \.bodySize, range: 16...36, step: 1, unit: "px")
                    slider("Line Height", \.lineHeight, range: 1.2...2, step: 0.05, unit: "×")
                    slider("Heading Scale", \.headingScale, range: 0.75...1.5, step: 0.05, unit: "×")
                    slider("Code Size", \.codeSize, range: 12...26, step: 1, unit: "px")
                }

                section("Spacing") {
                    slider("Column Width", \.columnWidth, range: 38...90, step: 1, unit: "ch")
                    slider("Page Inset", \.pageInset, range: 16...100, step: 4, unit: "px")
                    slider("Top Margin", \.topInset, range: 16...160, step: 2, unit: "px")
                    slider("Bottom Margin", \.bottomInset, range: 24...200, step: 2, unit: "px")
                    slider("Paragraph Gap", \.paragraphGap, range: 0.5...3, step: 0.1, unit: "em")
                    slider("Block Gap", \.blockGap, range: 0.5...4, step: 0.1, unit: "em")
                    slider("Heading Gap", \.headingGap, range: 0.8...3.5, step: 0.1, unit: "rem")
                    slider("List Gap", \.listGap, range: 0.1...1.2, step: 0.1, unit: "em")
                    slider("Corner Radius", \.radius, range: 0...16, step: 1, unit: "px")
                    slider("Rule Width", \.ruleWidth, range: 0...6, step: 1, unit: "px")
                    slider("Scrollbar Width", \.scrollbarWidth, range: 1...8, step: 1, unit: "px")
                }

                DisclosureGroup("Colors") {
                    VStack(alignment: .leading, spacing: 12) {
                        colorRow("Light Paper", \.lightPaper)
                        colorRow("Light Ink", \.lightInk)
                        colorRow("Dark Paper", \.darkPaper)
                        colorRow("Dark Ink", \.darkInk)
                        colorRow("Accent", \.accent)
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 13, weight: .semibold))

                DisclosureGroup("Elements") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Callout Style", selection: calloutBinding) {
                            Text("Rule").tag("rule")
                            Text("Plain").tag("plain")
                            Text("Box").tag("box")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Callout style")

                        Picker("Appearance", selection: $model.appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Appearance")
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 13, weight: .semibold))

                Text("Layout changes reset reader zoom automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                footer
            }
            .padding(20)
        }
        .frame(width: 380, height: 680)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Layout")
                .font(.system(size: 17, weight: .semibold))
            Text(model.selectedPreset.map { "\($0.name)\(model.presetModified ? " · Modified" : "")" } ?? "Custom layout · Saved on this Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Reset") { model.resetLayout() }
                    .buttonStyle(.bordered)
                PresetMenu(model: model)
                    .menuStyle(.borderlessButton)
                    .frame(width: 90)
                Spacer()
                Button("Copy") { model.copyLayout() }
                    .buttonStyle(.bordered)
                Button("Paste") { model.pasteLayout() }
                    .buttonStyle(.bordered)
            }

            if !model.layoutMessage.isEmpty {
                Text(model.layoutMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Status: \(model.layoutMessage)")
            }
        }
    }

    // MARK: - Section container

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
        }
    }

    // MARK: - Font picker

    private func picker(_ title: String, _ keyPath: WritableKeyPath<LayoutSettings, String>, options: [String]) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 110, alignment: .leading)
            Picker(title, selection: fontBinding(keyPath)) {
                ForEach(options, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func weightRange(_ font: String) -> ClosedRange<Double> {
        if font == "Oswald" { return 200...700 }
        if font == "Source Serif 4" { return 200...900 }
        return 100...900
    }

    private func fontBinding(_ keyPath: WritableKeyPath<LayoutSettings, String>) -> Binding<String> {
        Binding(
            get: { model.layout[keyPath: keyPath] },
            set: { font in
                var layout = model.layout
                layout[keyPath: keyPath] = font
                let range = weightRange(font)
                if keyPath == \LayoutSettings.bodyFont { layout.bodyWeight = min(range.upperBound, max(range.lowerBound, layout.bodyWeight)) }
                if keyPath == \LayoutSettings.headingFont { layout.headingWeight = min(range.upperBound, max(range.lowerBound, layout.headingWeight)) }
                model.layout = layout
            }
        )
    }

    // MARK: - Numeric slider helper

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<LayoutSettings, Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String
    ) -> some View {
        let binding = Binding<Double>(
            get: { model.layout[keyPath: keyPath] },
            set: { model.layout[keyPath: keyPath] = $0 }
        )
        let value = model.layout[keyPath: keyPath]

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)")
        }
    }

    // MARK: - Color row

    private func colorRow(_ title: String, _ keyPath: WritableKeyPath<LayoutSettings, String>) -> some View {
        let hex = model.layout[keyPath: keyPath]
        let colorBinding = Binding<Color>(
            get: { Color(hex: hex) ?? .white },
            set: { newColor in
                if let newHex = newColor.toHex() {
                    model.layout[keyPath: keyPath] = newHex
                }
            }
        )

        return HStack {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 110, alignment: .leading)
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
            Text(hex.uppercased())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) color \(hex)")
    }

    // MARK: - Callout style binding

    private var calloutBinding: Binding<String> {
        Binding(
            get: { model.layout.calloutStyle },
            set: { model.layout.calloutStyle = $0 }
        )
    }
}

// MARK: - Color <-> Hex helpers

private extension Color {
    init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.hasPrefix("#") ? String(sanitized.dropFirst()) : sanitized
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    func toHex() -> String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
