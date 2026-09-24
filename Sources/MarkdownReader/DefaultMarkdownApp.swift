import AppKit
import UniformTypeIdentifiers

@MainActor enum DefaultMarkdownApp {
    static func offerIfNeeded() {
        #if !FOLIO_STAGING && !FOLIO_UPDATE_TEST
        guard !UserDefaults.standard.bool(forKey: "defaultMarkdownPromptV1"),
              !Bundle.main.bundleURL.path.hasPrefix("/Volumes/"),
              !ReaderModel.shared.recoveryDecisionInterrupted else { return }
        ask()
        #endif
    }
    static func ask() {
        #if !FOLIO_STAGING && !FOLIO_UPDATE_TEST
        let alert = NSAlert()
        alert.messageText = "Make Folio your default Markdown app?"
        alert.informativeText = "Open .md and .markdown files in Folio when you double-click them. You can change this later in Finder."
        alert.addButton(withTitle: "Make Default"); alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        UserDefaults.standard.set(true, forKey: "defaultMarkdownPromptV1")
        guard response == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do {
                let types = Set(["md", "markdown"].compactMap { UTType(filenameExtension: $0) })
                guard !types.isEmpty else { throw CocoaError(.featureUnsupported) }
                for type in types {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                }
            } catch {
                let failure = NSAlert(); failure.messageText = "The default app could not be changed"
                failure.informativeText = "You can try again from the Folio menu. " + error.localizedDescription
                failure.runModal()
            }
        }
        #endif
    }
}
