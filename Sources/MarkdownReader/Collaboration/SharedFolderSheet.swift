import AppKit
import SwiftUI
import ReaderCore

/// Shared review workspace controls. Uses the reader's actual palette.
struct SharedFolderSheet: View {
    @ObservedObject var coordinator: CollaborationCoordinator
    @ObservedObject var model: ReaderModel
    let paper: Color, ink: Color, accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var create = false
    @State private var candidate = ""
    @State private var reconnectID: UUID?
    private var validName: Bool { CollaborationIO.validName(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(coordinator.workspaceID == nil ? "Shared folder" : "Shared review")
                    .font(.custom(model.layout.headingFont, size: 25))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Your name identifies your contributions; it is not a verified login.")
            TextField("Your name", text: $name).textFieldStyle(.roundedBorder)
            Text("Use a short name without special control characters.")
                .font(.caption).foregroundStyle(ink.opacity(0.7))
            Text("Review data is shared with everyone who has access to this OneDrive folder.")
            Text("Choosing a folder does not invite people or change its permissions. Existing private highlights and edit history stay private.")
                .font(.caption).foregroundStyle(ink.opacity(0.7))
            if coordinator.workspaceID == nil {
                ReviewTabs(label: "Workspace", selection: $create,
                           options: [(false, "Join existing"), (true, "Create once")], ink: ink, accent: accent)
                Text(create ? "Choose an already shared folder. Folio adds a ‘Folio Review’ folder for comments and task history." : "Join after OneDrive delivers ‘Folio Review/workspace.json’ from the creator.")
                    .font(.caption)
                Button("Choose OneDrive folder…") { chooseFolder(reconnect: false) }
                    .disabled(!validName || coordinator.busy)
            } else {
                HStack {
                    Text(coordinator.folderURL?.lastPathComponent ?? "Folder needs reconnection")
                    Spacer()
                    Button("Rename profile") { Task { await coordinator.rename(to: name) } }.disabled(!validName || coordinator.busy)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(coordinator.documents) { doc in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(doc.reference.relativePath).fontWeight(.semibold)
                                if let issue = doc.issue { Text(issue).font(.caption).foregroundStyle(ink.opacity(0.7)) }
                                HStack {
                                    Button("Open") { Task { let generation = model.documentID; if let url = await coordinator.openDocument(id: doc.id), model.documentID == generation { model.load(url) } } }
                                        .disabled(doc.url == nil || coordinator.busy)
                                    Button("Reconnect…") { reconnectID = doc.id }
                                        .disabled(coordinator.busy)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
                if !coordinator.candidates.isEmpty {
                    Picker(reconnectID == nil ? "Unregistered Markdown" : "Reconnect identity", selection: $candidate) {
                        Text("Choose a document").tag("")
                        ForEach(coordinator.candidates, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        Button(reconnectID == nil ? "Share document" : "Reconnect document") {
                            let path = candidate, id = reconnectID
                            Task {
                                if let id { await coordinator.reconnectDocument(id: id, relativePath: path) }
                                else { await coordinator.registerDocument(relativePath: path) }
                                if coordinator.error == nil { candidate = ""; reconnectID = nil }
                            }
                        }.disabled(candidate.isEmpty || coordinator.busy || (reconnectID == nil && coordinator.documents.count >= 8))
                        if reconnectID != nil { Button("Cancel reconnect") { reconnectID = nil } }
                    }
                }
                Toggle("Allow changes to shared Markdown files", isOn: $coordinator.sourceSavingEnabled)
                    .disabled(coordinator.sourceAccessUnverified || coordinator.busy)
                Text("Up to 8 documents per workspace. Folio keeps recovery copies before saving and asks you to resolve conflicting edits.")
                    .font(.caption).foregroundStyle(ink.opacity(0.7))
                HStack {
                    Button("Retry") { Task { await coordinator.refresh() } }
                    Button("Reconnect folder…") { chooseFolder(reconnect: true) }
                    Button("Export local evidence…") { exportEvidence() }
                }.disabled(coordinator.busy)
                Button("Stop watching") { Task { await coordinator.stopWatching() } }.disabled(coordinator.busy)
                Text("Stops local watching and removes the bookmark. Shared files and local recovery evidence are kept.").font(.caption)
            }
            HStack {
                if coordinator.busy { ProgressView().controlSize(.small) }
                Text(coordinator.statusMessage).font(.caption)
            }.foregroundStyle(accent)
            if let error = coordinator.error { Text(error).font(.caption).foregroundStyle(ink).textSelection(.enabled) }
        }
        .padding(24).frame(width: 560)
        .font(.custom(model.layout.bodyFont, size: 14))
        .foregroundStyle(ink).background(paper).tint(accent).buttonStyle(.plain)
        .onAppear { name = coordinator.profile?.displayName ?? "" }
    }
    private func chooseFolder(reconnect: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = reconnect ? "Reconnect" : "Choose folder"
        panel.message = "Choose the already shared OneDrive folder. Folio does not grant access or invite anyone."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if reconnect { await coordinator.reconnectFolder(url) }
            else { await coordinator.join(folder: url, create: create, displayName: name) }
        }
    }
    private func exportEvidence() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Folio-local-evidence-\(UUID().uuidString)"
        panel.message = "Choose a new directory for collaboration evidence. Contains shared review data only."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await coordinator.exportEvidence(to: url) }
    }
}
