import SwiftUI
import AppKit

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = ReaderModel.shared
    var body: some Scene {
        Window("Folio", id: "reader") {
            ReaderView(model: model)
                .frame(minWidth: 580, minHeight: 440)
                .onAppear { model.startReading() }
        }
        .defaultSize(width: 960, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") { model.newDocument() }.keyboardShortcut("n")
                Button("Open Markdown…") { model.open() }.keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentDocuments) { item in Button(item.name) { model.openRecent(item) }.help(item.id) }
                    Divider()
                    Button("Clear Recent Files") { model.clearHistory() }
                }
                Button("Welcome to Folio") { model.showWelcome() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undoEdit() }.keyboardShortcut("z")
                Button("Redo") { model.redoEdit() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }.keyboardShortcut("s")
                Button("Save As…") { model.save(asCopy: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("Export PDF…") { model.exportPDF() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.preparingPrint || model.loading)
            }
            CommandGroup(after: .textEditing) {
                Button("Copy Formatted Text") { model.copyFormatted() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.writing)

                Button("Highlight Selection") { model.highlightSelection() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Find…") { model.showFind = true }.keyboardShortcut("f")
                Button("Find Next") { model.find() }.keyboardShortcut("g")
                Button("Find Previous") { model.find(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Contents") { model.showOutline.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Larger Text") { model.changeZoom(0.1) }.keyboardShortcut("+")
                Button("Smaller Text") { model.changeZoom(-0.1) }.keyboardShortcut("-")
                Button("Actual Text Size") { model.zoom = 1 }.keyboardShortcut("0")
            }
            CommandGroup(replacing: .help) {
                Button("Export Private Diagnostics…") { model.exportDiagnostics() }
            }
        }
        Window("Layout", id: "layout") {
            LayoutEditor(model: model)
        }
        .defaultSize(width: 390, height: 700)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { ReaderModel.shared.load(url) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { ReaderModel.shared.confirmLeave() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
