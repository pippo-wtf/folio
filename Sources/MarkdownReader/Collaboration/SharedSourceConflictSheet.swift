import AppKit
import SwiftUI
import ReaderCore

struct SharedSourceVersion: Identifiable {
    let event: CollaborationEvent
    let bytes: Data?
    let isHead: Bool
    let receipt: String
    var id: UUID { event.id }
    var preview: String {
        guard let bytes else { return "Snapshot not delivered. Retry after OneDrive delivers it." }
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { return String(data: bytes, encoding: .utf16) ?? "This version cannot be decoded for display; exact bytes can be exported." }
        return String(data: bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(bytes.dropFirst(3)) : bytes, encoding: .utf8) ?? "Exact bytes can be exported."
    }
}
struct SharedSourceComparison {
    let document: SharedDocumentRef
    let versions: [SharedSourceVersion]
    let heads: [UUID]
    let pending: [UUID]
    let complete: Bool
}

struct SharedSourceConflictSheet: View {
    @ObservedObject var coordinator: CollaborationCoordinator
    @ObservedObject var model: ReaderModel
    let paper: Color, ink: Color, accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var chosenID: UUID?
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Compare shared source").font(.custom(model.layout.headingFont, size: 25)); Spacer(); Button("Done") { dismiss() } }
            Text("Your draft stays in the reader. These are intended saved versions; a local receipt alone proves a write on this Mac. OneDrive may show a different current Markdown file.")
            if let comparison = coordinator.sourceComparison {
                Text(comparison.document.relativePath).fontWeight(.semibold)
                if !comparison.complete || !comparison.pending.isEmpty {
                    Text("Source dependencies are pending. Saving and resolution remain blocked for this document. IDs: \(comparison.pending.map(\.uuidString).joined(separator: ", "))").font(.caption)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Current draft").fontWeight(.semibold)
                        Text(model.text).textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                        Text("Observed file · Author unknown").fontWeight(.semibold)
                        if let observed = coordinator.sourceObservations[comparison.document.documentID] {
                            Text(decode(observed)).textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                        }
                        ForEach(comparison.versions) { version in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(version.event.authorName) · \(version.isHead ? "competing head" : "retained version")").fontWeight(.semibold)
                                Text("\(version.id.uuidString) · \(version.receipt)").font(.caption)
                                Text(version.preview).textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                                if version.isHead { Button(chosenID == version.id ? "Chosen for resolution" : "Choose this version") { chosenID = version.id }.disabled(version.bytes == nil) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(ink.opacity(0.05))
                        }
                    }
                }.frame(maxHeight: 400)
                HStack {
                    Button("Retry") { Task { await coordinator.refresh(); await coordinator.compareSource(document: comparison.document) } }
                    Button("Export all recovery copies…") { export(comparison.document) }
                    Button("Load observed file") { model.reloadSharedSource() }.disabled(model.dirty || model.sharedSaveBusy)
                }
                Button("Resolve all observed heads with chosen version") { resolve(comparison) }
                    .disabled(!coordinator.sourceSavingEnabled || coordinator.busy || model.sharedSaveBusy || chosenID == nil || !comparison.pending.isEmpty || comparison.heads.isEmpty || !comparison.complete)
                Text("Resolution records every currently observed source head. A later delivered branch reopens the conflict. Never-observed external history cannot be recovered.").font(.caption)
            }
            if let issue { Text(issue).font(.caption) }
        }.padding(24).frame(width: 680).font(.custom(model.layout.bodyFont, size: 14))
            .foregroundStyle(ink).background(paper).tint(accent)
    }
    private func decode(_ data: Data) -> String {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16) ?? "Exact bytes available in export." }
        return String(data: data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data, encoding: .utf8) ?? "Exact bytes available in export."
    }
    private func export(_ document: SharedDocumentRef) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Folio-source-recovery-\(UUID().uuidString)"; panel.message = "Choose a new absent directory. Existing files will never be replaced."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { try await coordinator.exportSourceRecovery(document: document, to: url); issue = "Recovery copies exported." } catch { issue = error.localizedDescription } }
    }
    private func resolve(_ comparison: SharedSourceComparison) {
        guard let bytes = comparison.versions.first(where: { $0.id == chosenID })?.bytes,
              let expected = coordinator.sourceObservations[comparison.document.documentID] else { return }
        // Explicit selection confirms resolution, while the unsaved reader draft remains unchanged.
        Task { do {
            let result = try await coordinator.resolveSource(document: comparison.document, expectedCurrent: expected, chosen: bytes, superseding: comparison.heads)
            issue = result.localApply == .applied || result.localApply == .unchanged ? "Chosen version saved on this Mac. Your reader draft is retained." : "The current file changed again. Retry and compare before resolving."
        } catch { issue = "Resolution did not complete. Your source and draft are retained. \(error.localizedDescription)" } }
    }
}
