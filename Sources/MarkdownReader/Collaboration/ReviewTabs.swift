import SwiftUI

/// Flat text tabs, with the reader palette and an explicit selected-state underline.
struct ReviewTabs<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]
    let ink: Color
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(ink.opacity(selection == value ? 1 : 0.65))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selection == value ? accent : ink.opacity(0.12)).frame(height: selection == value ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
