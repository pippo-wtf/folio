import SwiftUI
import ReaderCore

struct NameOnboarding: View {
    @ObservedObject var coordinator: CollaborationCoordinator
    let headingFont: String
    let paper: Color, ink: Color
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    private var validName: Bool {
        CollaborationIO.validName(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What’s your name?")
                    .font(.custom(headingFont, size: 32))
                Text("Shown beside your shared comments and completed tasks.")
                    .font(.system(size: 15))
                    .foregroundStyle(ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Your name", text: $name)
                .textFieldStyle(.plain).font(.system(size: 18))
                .padding(14).background(ink.opacity(0.05))
                .overlay(Rectangle().stroke(ink.opacity(0.18), lineWidth: 1))
                .focused($nameFocused)
                .accessibilityLabel("Your name")
                .onSubmit { save() }
            if let error = coordinator.onboardingError {
                Text(error).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: save) {
                Text(coordinator.busy ? "Saving…" : "Continue")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(paper).background(ink)
            }
            .buttonStyle(.plain)
            .disabled(!validName || coordinator.busy)
            .opacity(validName && !coordinator.busy ? 1 : 0.45)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32).frame(width: 400)
        .foregroundStyle(ink).background(paper).tint(ink)
        .interactiveDismissDisabled()
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard validName, !coordinator.busy else { return }
        Task { await coordinator.saveOnboardingName(name) }
    }
}
