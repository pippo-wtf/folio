import AppKit
import Security

@MainActor final class Installer: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.install() }
    }
    func install() {
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let destination = folder.appendingPathComponent("Folio.app")
        let source = Bundle.main.resourceURL!.appendingPathComponent("Folio.app")
        let prompt = NSAlert()
        prompt.messageText = "Install Folio for your account?"
        prompt.informativeText = "Folio will be installed in your personal Applications folder:\n\(folder.path)\n\nAn existing Folio in this folder will be replaced. Your documents and settings stay in place."
        prompt.addButton(withTitle: "Install Folio"); prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        do {
            try PersonalAppInstallation.install(source: source, home: fm.homeDirectoryForCurrentUser, isRunning: {
                NSRunningApplication.runningApplications(withBundleIdentifier: "wtf.pippo.markdown-reader").contains { !$0.isTerminated }
            }, verify: { url in
                var code: SecStaticCode?
                var requirement: SecRequirement?
                let rule = "anchor apple generic and identifier \"wtf.pippo.markdown-reader\" and certificate leaf[subject.OU] = \"D683769MKC\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                      SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                      let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
                    throw NSError(domain: "FolioInstaller", code: 2, userInfo: [NSLocalizedDescriptionKey: "Folio’s signature could not be verified. Download a fresh installer from the official Folio GitHub page."])
                }
            })
            NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                Task { @MainActor in
                    if let error {
                        let alert = NSAlert(); alert.messageText = "Folio was installed"
                        alert.informativeText = "Open Folio from your personal Applications folder. \(error.localizedDescription)"
                        alert.runModal()
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                    NSApp.terminate(nil)
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Folio could not be installed"
            alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }
}
@main enum InstallerMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Installer()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
