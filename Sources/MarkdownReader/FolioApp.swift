import SwiftUI
import AppKit

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = ReaderModel.shared
    @StateObject private var updater = FolioUpdater()
    var body: some Scene {
        Window(BuildChannel.name, id: "reader") {
            ReaderView(model: model, updater: updater)
                .frame(minWidth: 580, minHeight: 440)
                .onAppear { model.startReading() }
        }
        .defaultSize(width: 960, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                #if !FOLIO_STAGING && !FOLIO_UPDATE_TEST
                Button("Make Folio Default for Markdown…") { DefaultMarkdownApp.ask() }
                #endif
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
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
        #if FOLIO_STAGING
        Window("Layout", id: "layout") {
            LayoutEditor(model: model)
        }
        .defaultSize(width: 390, height: 700)
        #endif
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTrace.record("willFinishLaunching")
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification, object: nil)
    }
    @objc private func windowClosing(_ notification: Notification) { LaunchTrace.record("windowWillClose") }
    func applicationWillTerminate(_ notification: Notification) { LaunchTrace.record("willTerminate") }
    func applicationDidBecomeActive(_ notification: Notification) { LaunchTrace.record("becameActive") }
    func applicationDidResignActive(_ notification: Notification) { LaunchTrace.record("resignedActive") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.record("didFinishLaunching")
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Wait for the application and document window to become active before
        // presenting crash recovery. A modal alert during launch can abort.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) {
            LaunchTrace.record("startupReady")
            ReaderModel.shared.recoveryPromptReady = true
            ReaderModel.shared.startReading()
            DefaultMarkdownApp.offerIfNeeded()
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        LaunchTrace.record("openURLs count=\(urls.count)")
        if let url = urls.first {
            ReaderModel.shared.load(url)
            DispatchQueue.main.async { ReaderWindowPresenter.shared.request() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let allowed = ReaderModel.shared.confirmLeave()
        LaunchTrace.record("shouldTerminate allowed=\(allowed)")
        return allowed ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A Finder open can arrive during window teardown. Keep the application
        // available to present that document; explicit Quit still confirms edits.
        LaunchTrace.record("lastWindowClosed keepRunning")
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { ReaderWindowPresenter.shared.request() }
        return true
    }
}
