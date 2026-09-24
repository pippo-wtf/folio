import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers
import ReaderCore

struct Heading: Identifiable, Decodable { let id: String; let title: String; let level: Int }
@MainActor final class ReaderModel: ObservableObject {
    static let shared = ReaderModel()
    @Published var layout = ReaderModel.savedLayout() {
        didSet {
            guard layout.isValid else { return }
            if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: "readerLayoutV1") }
            if zoom != 1 { zoom = 1 }
            applyAppearance()
        }
    }
    @Published var layoutMessage = ""
    private static func savedLayout() -> LayoutSettings {
        guard let data = UserDefaults.standard.data(forKey: "readerLayoutV1"),
              let value = try? JSONDecoder().decode(LayoutSettings.self, from: data), value.isValid else { return LayoutSettings() }
        return value
    }
    @Published var presets: [ReadingPreset] = []
    @Published var selectedPresetID: UUID?
    private var presetsReadable = true
    init() {
        if let data = UserDefaults.standard.data(forKey: "readingPresetsV1") {
            if let values = try? JSONDecoder().decode([ReadingPreset].self, from: data), ReadingPreset.validLibrary(values) {
                presets = values
            } else { presetsReadable = false; layoutMessage = "Saved presets could not be read. They have not been replaced." }
        } else {
            // One-time snapshot of the user's actual current settings, never a factory approximation.
            let green = ReadingPreset(name: "Green Line", layout: layout, appearance: appearance, zoom: zoom)
            if green.isValid { persistPresets([green]); selectedPresetID = green.id }
        }
        if selectedPresetID == nil { selectedPresetID = presets.first(where: { $0.layout == layout && $0.appearance == appearance && $0.zoom == zoom })?.id }
    }
    var selectedPreset: ReadingPreset? { presets.first { $0.id == selectedPresetID } }
    var presetModified: Bool {
        guard let preset = selectedPreset else { return false }
        return preset.layout != layout || preset.appearance != appearance || preset.zoom != zoom
    }
    @discardableResult private func persistPresets(_ values: [ReadingPreset]) -> Bool {
        guard presetsReadable, ReadingPreset.validLibrary(values), let data = try? JSONEncoder().encode(values) else {
            layoutMessage = "Could not save presets. Use a unique name of 1–60 characters (up to 100 presets)."; return false
        }
        UserDefaults.standard.set(data, forKey: "readingPresetsV1"); presets = values; return true
    }
    func usePreset(_ preset: ReadingPreset) {
        layout = preset.layout; appearance = preset.appearance; zoom = preset.zoom
        selectedPresetID = preset.id; layoutMessage = "\(preset.name) applied."
    }
    private func presetName(title: String, initial: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = "Saves fonts, spacing, colours, element styles, appearance and text zoom on this Mac."
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "Preset name"; alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func savePresetAs() {
        guard let name = presetName(title: "Save current layout as a preset") else { return }
        let value = ReadingPreset(name: name, layout: layout, appearance: appearance, zoom: zoom)
        if persistPresets(presets + [value]) { selectedPresetID = value.id; layoutMessage = "\(name) saved." }
    }
    func updatePreset() {
        guard let old = selectedPreset else { return }
        let alert = NSAlert(); alert.messageText = "Update ‘\(old.name)’?"
        alert.informativeText = "Replace this preset with the current layout settings."
        alert.addButton(withTitle: "Update"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var updated = old; updated.layout = layout; updated.appearance = appearance; updated.zoom = zoom
        if persistPresets(presets.map { $0.id == old.id ? updated : $0 }) { layoutMessage = "\(old.name) updated." }
    }
    func renamePreset() {
        guard var preset = selectedPreset, let name = presetName(title: "Rename preset", initial: preset.name) else { return }
        preset.name = name
        if persistPresets(presets.map { $0.id == preset.id ? preset : $0 }) { layoutMessage = "Preset renamed to \(name)." }
    }
    func deletePreset() {
        guard let preset = selectedPreset else { return }
        let alert = NSAlert(); alert.messageText = "Delete ‘\(preset.name)’?"
        alert.informativeText = "The current reading layout will stay as it is."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if persistPresets(presets.filter { $0.id != preset.id }) { selectedPresetID = nil; layoutMessage = "Preset deleted. Current layout kept." }
    }
    func resetLayout() { selectedPresetID = nil; layout = LayoutSettings(); layoutMessage = "Default layout restored." }
    func applyLayoutPreset(_ name: String) { selectedPresetID = nil; layout = LayoutSettings.preset(name); layoutMessage = "Preset applied." }
    func copyLayout() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        guard let data = try? encoder.encode(layout), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        layoutMessage = "Layout settings copied."
    }
    func pasteLayout() {
        guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 16384,
              let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(LayoutSettings.self, from: data), value.isValid else {
            layoutMessage = "Clipboard does not contain valid Folio layout settings."; return
        }
        layout = value; layoutMessage = "Layout settings applied."
    }
    @Published var recentDocuments: [RecentDocument] = (UserDefaults.standard.data(forKey: "recentDocumentsV1").flatMap { try? JSONDecoder().decode([RecentDocument].self, from: $0) }) ?? []
    var readingPositions: [String: ReadingPosition] = (UserDefaults.standard.data(forKey: "readingPositionsV1").flatMap { try? JSONDecoder().decode([String: ReadingPosition].self, from: $0) }) ?? [:]
    var started = false
    private var pendingPosition: ReadingPosition?
    func saveReadingPosition(_ position: ReadingPosition, token: String) {
        guard token == highlightToken, fileURL != nil, !loading, !writing,
            position.offset.isFinite, position.fraction.isFinite, position.fraction >= 0, position.fraction <= 1, position.heading.count < 512 else { return }
        readingPositions[highlightKey] = position
        if readingPositions.count > 100 { readingPositions = readingPositions.filter { key, _ in recentDocuments.contains { $0.id == key } } }
        if let data = try? JSONEncoder().encode(readingPositions) { UserDefaults.standard.set(data, forKey: "readingPositionsV1") }
    }
    @Published var title = "Folio"
    @Published var subtitle = "A quiet place for your words"
    @Published var text = "" { didSet { scheduleRecovery() } }
    private var recoveryTask: Task<Void, Never>?
    private var recoveryReadable = true
    private let draftStore = DraftStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Recovery/draft.json"))
    private func scheduleRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.flushRecovery()
        }
    }
    func flushRecovery() {
        guard recoveryReadable else { return }
        do {
            if dirty { try draftStore.save(RecoveryDraft(text: text, title: title, originalPath: fileURL?.path)) }
            else { try draftStore.clear() }
        } catch { self.error = "The recovery copy could not be saved. Please save your document now." }
    }
    func restoreRecovery() -> Bool {
        do {
            guard let draft = try draftStore.load() else { return false }
            let alert = NSAlert(); alert.messageText = "Recover unsaved writing?"
            alert.informativeText = "Folio found a local draft of ‘\(draft.title)’. It will open as a recovered copy so the original cannot be overwritten accidentally."
            alert.addButton(withTitle: "Recover Draft"); alert.addButton(withTitle: "Discard Draft")
            if alert.runModal() == .alertFirstButtonReturn {
                isWelcome = false; untitledKey = "folio:draft:" + UUID().uuidString
                baseline = ""; title = draft.title + " — Recovered"; text = draft.text; writing = false; render()
                if let path = draft.originalPath { error = "Recovered from \(path). Use Save As to keep this draft." }
                return true
            }
            try draftStore.clear()
        } catch { recoveryReadable = false; self.error = "The recovery file could not be read. It has not been replaced." }
        return false
    }
    private var sourceEntry: String?
    @Published var writing = false {
        didSet {
            guard oldValue != writing else { return }
            pageEditTime = .distantPast
            if writing { sourceEntry = text }
            else {
                if let before = sourceEntry, before != text { pageUndo.append(before); trimPageHistory(); pageRedo = [] }
                sourceEntry = nil; render()
            }
        }
    }
    @Published var baseline = ""
    @Published var documentID = UUID() { didSet { clearPageHistory() } }
    var snapshot: DocumentSnapshot?
    var dirty: Bool { text != baseline }
    weak var editor: NSTextView?
    func confirmLeave() -> Bool {
        flushRecovery()
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to ‘\(title)’?"
        alert.informativeText = "Your changes have not been saved to the Markdown file."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard Changes"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: baseline = text; flushRecovery(); return true
        default: return false
        }
    }
    func newDocument() {
        guard confirmLeave() else { return }
        baseline = text
        showWelcome()
        isWelcome = false; untitledKey = "folio:draft:" + UUID().uuidString
        marked = []; headings = []
        text = ""; baseline = ""; snapshot = nil; title = "Untitled"; writing = false
        documentID = UUID(); render()
    }
    @discardableResult func save(asCopy: Bool = false) -> Bool {
        guard !loading else { return false }
        let previousHighlightKey = highlightKey
        let previousMarks = marked
        do {
            if !asCopy, let url = fileURL, let snapshot {
                try snapshot.save(text, to: url)
            } else {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
                guard panel.runModal() == .OK, let url = panel.url else { return false }
                // Saving to the original path must still perform the conflict check.
                if url.standardizedFileURL == fileURL?.standardizedFileURL, let snapshot {
                    try snapshot.save(text, to: url)
                } else {
                    let data = try snapshot?.encoded(text) ?? Data(text.utf8)
                    guard data.count <= DocumentReader.maximumBytes else { throw ReaderError.tooLarge }
                    try data.write(to: url, options: .atomic)
                }
                if fileScope { fileURL?.stopAccessingSecurityScopedResource() }
                fileURL = url; fileScope = url.startAccessingSecurityScopedResource()
                assetHandler.document = url
            }
            guard let url = fileURL else { return false }
            let savedSnapshot = try DocumentSnapshot(url: url)
            guard savedSnapshot.text == text else { throw SaveError.conflict }
            snapshot = savedSnapshot; baseline = text
            editor?.breakUndoCoalescing(); rememberDocument(url); flushRecovery()
            title = url.deletingPathExtension().lastPathComponent; error = nil
            if previousHighlightKey != highlightKey, !previousMarks.isEmpty {
                do {
                    if try highlightStore.load(for: highlightKey).isEmpty && highlightStore.events(for: highlightKey).isEmpty {
                        try highlightStore.save(previousMarks, for: highlightKey, revision: HighlightStore.revision(text), draft: false)
                    }
                } catch { self.error = "The document was saved, but its highlights could not be copied. The original review history is still stored locally." }
            }
            recordRevision(); monitor?.invalidate(); startMonitor(); render()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @Published var marked: [SavedHighlight] = []
    @Published var headings: [Heading] = []
    @Published var error: String?
    @Published var loading = false
    @Published var showOutline = false
    @Published var showFind = false
    @Published var search = ""
    @Published var findResult = ""
    @Published var imagesAllowed = false
    @Published var zoom = UserDefaults.standard.object(forKey: "textZoom") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(zoom, forKey: "textZoom"); applyAppearance() }
    }
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); applyAppearance() }
    }
    private(set) var fileURL: URL?
    private var grantedFolder: URL?
    private var fileScope = false
    private var folderScope = false
    private var monitor: Timer?
    private var revision: Date?
    private var revisionSize: Int?
    private var generation = 0
    weak var webView: WKWebView?
    var ready = false
    let assetHandler = LocalAssets()
    private var lastErrorCode = "none"

    private let highlightStore = HighlightStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Highlights"))
    private var highlightToken = ""
    private var highlightsReadable = false
    private var isWelcome = true
    private var untitledKey = "folio:draft:" + UUID().uuidString
    private var highlightKey: String { fileURL?.standardizedFileURL.resolvingSymlinksInPath().path ?? (isWelcome ? "folio:welcome" : untitledKey) }

    func saveHighlights(_ records: [SavedHighlight], token: String) {
        guard token == highlightToken, highlightsReadable, HighlightStore.valid(records) else { return }
        do {
            let saved = records.map { record -> SavedHighlight in
                var value = record
                if let existing = marked.first(where: { $0.id == value.id }) {
                    value.comment = existing.comment; value.revision = existing.revision
                } else { value.revision = HighlightStore.revision(text) }
                return value
            }
            try highlightStore.save(saved, for: highlightKey, revision: HighlightStore.revision(text), draft: dirty)
            marked = saved.sorted { $0.start < $1.start }
            let data = try JSONEncoder().encode(saved)
            let value = try JSONSerialization.jsonObject(with: data)
            script("highlightsSaved", [token, value])
        } catch {
            lastErrorCode = "highlight_save_failed"
            script("highlightSaveFailed", [token])
        }
    }
    func commentOnHighlight(_ id: String) {
        guard let index = marked.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Comment on this passage"
        alert.informativeText = String(marked[index].quote.prefix(220))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 130)); scroll.hasVerticalScroller = true
        let field = NSTextView(frame: scroll.bounds); field.isRichText = false; field.font = .systemFont(ofSize: 14)
        field.string = marked[index].comment ?? ""; field.autoresizingMask = [.width]; field.textContainer?.widthTracksTextView = true
        field.setAccessibilityLabel("Comment"); scroll.documentView = field; alert.accessoryView = scroll
        alert.addButton(withTitle: "Save Comment"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        let key = highlightKey, token = highlightToken
        guard alert.runModal() == .alertFirstButtonReturn, key == highlightKey, token == highlightToken else { return }
        var records = marked
        let comment = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard comment.utf16.count <= 8000 else { error = "Keep comments below 8,000 characters."; return }
        records[index].comment = comment.isEmpty ? nil : comment
        do {
            try highlightStore.save(records, for: key, revision: HighlightStore.revision(text), draft: dirty)
            marked = records; render()
        } catch { self.error = "The comment could not be saved. Please try again." }
    }
    func removeHighlight(_ id: String) {
        saveHighlights(marked.filter { $0.id != id }, token: highlightToken)
    }
    func exportFeedback() {
        guard fileURL != nil else { error = "Save this document before exporting its feedback."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = title + "-feedback.json"
        panel.message = "Contains this document’s highlighted passages, comments and review history. Share this file with an agent when you want it to read your feedback."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try highlightStore.feedback(for: highlightKey, currentText: text, draft: dirty).write(to: url, options: .atomic) }
        catch { self.error = "Feedback could not be exported. Your saved comments are unchanged." }
    }
    func highlightSelection() { script("highlightSelection", []) }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func openNote(_ target: String) {
        let name = String(target.split(separator: "#", maxSplits: 1).first ?? "")
        guard !name.isEmpty, name.utf8.count < 4096 else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.message = "Choose the Markdown file for ‘\(name)’. This grants Folio access to that file."
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func openDropped(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url { Task { @MainActor in self.load(url) } }
        }
        return true
    }
    func load(_ url: URL) {
        guard confirmLeave() else { return }
        isWelcome = false
        baseline = ""; snapshot = nil; writing = false; documentID = UUID()
        generation += 1
        highlightToken = ""; highlightsReadable = false; marked = []
        let current = generation
        monitor?.invalidate()
        if fileScope { fileURL?.stopAccessingSecurityScopedResource() }
        if folderScope { grantedFolder?.stopAccessingSecurityScopedResource() }
        grantedFolder = nil; imagesAllowed = false; folderScope = false
        fileURL = url; fileScope = url.startAccessingSecurityScopedResource()
        assetHandler.document = url; assetHandler.root = nil; assetHandler.token = UUID().uuidString.lowercased()
        title = url.deletingPathExtension().lastPathComponent
        subtitle = url.lastPathComponent + " · Markdown"
        text = ""; headings = []; error = nil; loading = true
        Task {
            do {
                let content = try await Task.detached { try DocumentSnapshot(url: url) }.value
                guard generation == current else { return }
                snapshot = content; text = content.text; baseline = text; loading = false
                pendingPosition = readingPositions[highlightKey] ?? ReadingPosition(heading: "", offset: 0, fraction: 0)
                rememberDocument(url); render()
                recordRevision(); startMonitor()
            } catch {
                guard generation == current else { return }
                loading = false; self.error = (error as? ReaderError)?.localizedDescription ?? "This file is unavailable. Download it locally or choose it again."
                lastErrorCode = "document_open_failed"
            }
        }
    }
    func showWelcome() {
        guard confirmLeave() else { return }
        isWelcome = true
        writing = false; snapshot = nil; documentID = UUID()
        generation += 1; highlightToken = ""; highlightsReadable = false; marked = []; monitor?.invalidate()
        if fileScope { fileURL?.stopAccessingSecurityScopedResource() }; fileScope = false
        if folderScope { grantedFolder?.stopAccessingSecurityScopedResource() }; folderScope = false
        fileURL = nil; grantedFolder = nil; imagesAllowed = false
        assetHandler.document = nil; assetHandler.root = nil
        title = "Folio"; subtitle = "A quiet place for your words"; error = nil; loading = false
        text = (try? String(contentsOf: Bundle.module.url(forResource: "Welcome", withExtension: "md", subdirectory: "Resources")!, encoding: .utf8)) ?? "# Welcome to Folio\n\nOpen a Markdown file to start reading."
        baseline = text
        pendingPosition = ReadingPosition(heading: "", offset: 0, fraction: 0)
        render()
    }
    func chooseImageFolder() {
        guard let fileURL else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.message = "Choose the document’s folder to allow its local images. Folio only reads image files inside this folder."
        if panel.runModal() == .OK, let folder = panel.url {
            if folderScope { grantedFolder?.stopAccessingSecurityScopedResource() }
            grantedFolder = folder; folderScope = folder.startAccessingSecurityScopedResource()
            assetHandler.root = folder; imagesAllowed = true
            assetHandler.token = UUID().uuidString.lowercased(); render()
        }
    }
    func recordRevision() {
        let values = try? fileURL?.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        revision = values?.contentModificationDate; revisionSize = values?.fileSize
    }
    func startMonitor() {
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let url = self.fileURL, !self.loading else { return }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                if values?.contentModificationDate != self.revision || values?.fileSize != self.revisionSize { self.reload() }
            }
        }
    }
    func reload() {
        guard let url = fileURL, !loading else { return }
        let current = generation; loading = true
        Task {
            do {
                let content = try await Task.detached { try DocumentSnapshot(url: url) }.value
                guard current == generation else { return }
                if dirty {
                    if content.bytes != snapshot?.bytes { self.error = SaveError.conflict.localizedDescription }
                    loading = false; recordRevision(); return
                }
                snapshot = content
                if content.text != text { text = content.text; baseline = text; documentID = UUID(); render() }
                error = nil; loading = false; recordRevision()
            } catch {
                guard current == generation else { return }
                loading = false; recordRevision()
                self.error = "The original file is unavailable. You’re seeing the last readable version. Choose the file again to reconnect."
                lastErrorCode = "document_refresh_failed"
            }
        }
    }
    func script(_ method: String, _ arguments: [Any]) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("void window.Folio.\(method).apply(null, \(json))") { [weak self] _, error in
            if error != nil { Task { @MainActor in self?.error = "The reading view couldn’t update. Try opening the document again."; self?.lastErrorCode = "render_failed" } }
        }
    }
    private var pageUndo: [String] = []
    private var pageRedo: [String] = []
    private var pageEditTime = Date.distantPast
    private var pageEditPassage = ""
    func clearPageHistory() { pageUndo = []; pageRedo = []; pageEditTime = .distantPast }
    private func trimPageHistory() {
        while pageUndo.count > 100 || pageUndo.reduce(0, { $0 + $1.utf8.count }) > 16_000_000 { pageUndo.removeFirst() }
    }
    func undoEdit() {
        if writing { editor?.undoManager?.undo(); return }
        guard !loading, let previous = pageUndo.popLast() else { return }
        pageEditTime = .distantPast; pageRedo.append(text); text = previous; render()
    }
    func redoEdit() {
        if writing { editor?.undoManager?.redo(); return }
        guard !loading, let next = pageRedo.popLast() else { return }
        pageEditTime = .distantPast; pageUndo.append(text); trimPageHistory(); text = next; render()
    }
    func acceptRenderedEdit(before: String, text updated: String, token: String, passage: String) {
        guard token == highlightToken, !loading, !writing else { return }
        guard before == text, updated.utf8.count <= DocumentReader.maximumBytes else {
            error = "The page changed before this edit could be applied. Your current draft has been kept. Please retry."
            render(); return
        }
        if updated != text {
            let now = Date()
            if now.timeIntervalSince(pageEditTime) > 0.7 || pageEditPassage != passage { pageUndo.append(text); trimPageHistory() }
            pageEditTime = now; pageEditPassage = passage; pageRedo = []; text = updated
        }
    }
    func render() {
        highlightToken = UUID().uuidString
        var records: [SavedHighlight] = []
        do { records = try highlightStore.load(for: highlightKey); highlightsReadable = true }
        catch {
            highlightsReadable = false
            self.error = "Saved highlights could not be loaded. Your saved marks have not been changed. Reopen the document to retry."
            lastErrorCode = "highlight_load_failed"
        }
        marked = records.sorted { $0.start < $1.start }
        let value = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(records))) ?? []
        let position: Any = pendingPosition.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
        if ready { pendingPosition = nil }
        script("render", [text, "folio-asset://\(assetHandler.token)/", highlightToken, value, highlightsReadable, position, !loading])
        applyAppearance()
    }
    func applyAppearance() {
        guard let data = try? JSONEncoder().encode(layout), let value = try? JSONSerialization.jsonObject(with: data) else { return }
        script("appearance", [appearance, zoom, value])
    }
    func navigateHighlight(id: String) { writing = false; script("navigateHighlight", [id]) }
    func navigate(id: String) { writing = false; script("navigate", [id]) }
    func changeZoom(_ delta: Double) { zoom = min(2.5, max(0.7, (zoom + delta) * 100 / 100)) }
    func find(backwards: Bool = false) {
        guard !search.isEmpty else { findResult = ""; return }
        if writing, let editor {
            let source = editor.string as NSString
            let selection = editor.selectedRange()
            let options: NSString.CompareOptions = backwards ? [.caseInsensitive, .backwards] : [.caseInsensitive]
            let range = backwards ? NSRange(location: 0, length: selection.location) : NSRange(location: NSMaxRange(selection), length: source.length - NSMaxRange(selection))
            var found = source.range(of: search, options: options, range: range)
            if found.location == NSNotFound { found = source.range(of: search, options: options) }
            if found.location != NSNotFound { editor.setSelectedRange(found); editor.scrollRangeToVisible(found) }
            findResult = found.location == NSNotFound ? "No matches" : "Match found"; return
        }
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true; config.caseSensitive = false
        webView?.find(search, configuration: config) { [weak self] result in
            self?.findResult = result.matchFound ? "Match found" : "No matches"
        }
    }
    @Published var preparingPrint = false
    func copyFormatted() {
        guard !writing else { error = "Close Source and select a passage to copy its formatting."; return }
        script("copyFormatted", [])
    }
    private var pdfDestination: URL?
    private var pdfCompletion: PDFExportCompletion?
    func exportPDF() {
        guard ready, !loading, !preparingPrint else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = title + ".pdf"; panel.title = "Export PDF"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        pdfDestination = destination
        writing = false; preparingPrint = true
        script("preparePrint", [])
        Task { try? await Task.sleep(for: .seconds(20)); if preparingPrint && pdfDestination != nil { preparingPrint = false; pdfDestination = nil; error = "PDF preparation took too long. Please try again." } }
    }
    func finishPrint(token: String) {
        guard preparingPrint, token == highlightToken, let webView, let destination = pdfDestination else { preparingPrint = false; pdfDestination = nil; return }
        pdfDestination = nil
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-Export-" + UUID().uuidString + ".pdf")
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 42; info.bottomMargin = 42; info.leftMargin = 46; info.rightMargin = 46
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        guard let window = webView.window else { preparingPrint = false; error = "Open the document window before exporting."; return }
        let completion = PDFExportCompletion { [weak self] success in
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let self else { return }
            self.preparingPrint = false; self.pdfCompletion = nil
            self.script("finishExport", [])
            do {
                guard success else { throw CocoaError(.fileWriteUnknown) }
                let data = try Data(contentsOf: temporary)
                guard data.starts(with: Data("%PDF-".utf8)), data.count > 100 else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: destination, options: .atomic)
            } catch { self.error = "The PDF could not be saved. Please try Export PDF again." }
        }
        pdfCompletion = completion
        operation.runModal(for: window, delegate: completion, didRun: #selector(PDFExportCompletion.didFinish(_:success:context:)), contextInfo: nil)
    }
    func exportDiagnostics() {
        let report: [String: Any] = ["app":"Folio", "version":"0.12.2", "build":1, "system":ProcessInfo.processInfo.operatingSystemVersionString, "lastErrorCode":lastErrorCode, "rendererReady":ready]
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Folio-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { self.error = "Diagnostics could not be saved. Please try again." }
    }
}

@MainActor private final class PDFExportCompletion: NSObject {
    let completed: (Bool) -> Void
    init(_ completed: @escaping (Bool) -> Void) { self.completed = completed }
    @objc func didFinish(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) { completed(success) }
}
