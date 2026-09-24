import SwiftUI

struct PresetMenu: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Menu {
            Section("Your presets") {
                ForEach(model.presets) { preset in
                    Button { model.usePreset(preset) } label: {
                        if model.selectedPresetID == preset.id && !model.presetModified { Label(preset.name, systemImage: "checkmark") }
                        else { Text(preset.name) }
                    }
                }
            }
            Section("Built-in") {
                Button("Default") { model.applyLayoutPreset("default") }
                Button("Compact") { model.applyLayoutPreset("compact") }
                Button("Editorial") { model.applyLayoutPreset("editorial") }
            }
            Divider()
            Button("Customize Layout…") { openWindow(id: "layout") }
            Button("Save Current as Preset…") { model.savePresetAs() }
            if let preset = model.selectedPreset {
                Button("Update ‘\(preset.name)’…") { model.updatePreset() }.disabled(!model.presetModified)
                Button("Rename ‘\(preset.name)’…") { model.renamePreset() }
                Button("Delete ‘\(preset.name)’…") { model.deletePreset() }
            }
        } label: { Label("Presets", systemImage: "swatchpalette") }
        .help(model.selectedPreset.map { "\($0.name)\(model.presetModified ? " · Modified" : "")" } ?? "Choose or save a reading preset")
    }
}
