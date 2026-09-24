import AppKit
import CoreText
import Sparkle
import SwiftUI

/// Presentation only: Sparkle owns downloads, signature validation and installation.
@MainActor final class FolioUpdateDriver: NSObject, ObservableObject, SPUUserDriver, NSWindowDelegate {
    @Published private(set) var updateAvailable = false
    var hasPendingDialog: Bool { primary != nil || secondary != nil }

    @Published var heading = "Folio updates"
    @Published var message = ""
    @Published var version = ""
    @Published var notes = ""
    @Published var progress: Double?
    @Published var busy = false
    @Published var primaryTitle: String?
    @Published var secondaryTitle: String?
    private var primary: (() -> Void)?
    private var secondary: (() -> Void)?
    private var window: NSWindow?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var acceptingNotes = false

    let icon: NSImage
    override init() {
        icon = NSApplication.shared.applicationIconImage
        super.init()
            for name in ["Oswald", "SourceSerif4", "SourceSerif4-Italic"] {
                if let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Resources/Fonts") {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
    }

    private func present(_ title: String, _ detail: String, busy: Bool = false, showWindow: Bool = true,
                         primaryTitle: String? = nil, primary: (() -> Void)? = nil,
                         secondaryTitle: String? = nil, secondary: (() -> Void)? = nil) {
        self.heading = title; self.message = detail; self.busy = busy; self.progress = nil
        self.primaryTitle = primaryTitle; self.primary = primary
        self.secondaryTitle = secondaryTitle; self.secondary = secondary
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 590),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Folio Updates"; panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true; panel.backgroundColor = .white
            panel.appearance = NSAppearance(named: .aqua)
            panel.contentMinSize = NSSize(width: 480, height: 420)
            panel.isReleasedWhenClosed = false; panel.delegate = self
            let content = NSHostingView(rootView: FolioUpdateView(driver: self))
            content.sizingOptions = []
            panel.contentView = content
            panel.setContentSize(NSSize(width: 580, height: 590))
            panel.center(); window = panel
        }
        window?.standardWindowButton(.closeButton)?.isEnabled = secondary != nil
        if showWindow { window?.makeKeyAndOrderFront(nil) }
    }
    func choosePrimary() {
        guard let action = primary else { return }
        primary = nil; secondary = nil; primaryTitle = nil; secondaryTitle = nil
        action()
    }
    func chooseSecondary() {
        guard let action = secondary else { return }
        primary = nil; secondary = nil; primaryTitle = nil; secondaryTitle = nil
        window?.orderOut(nil)
        action()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { chooseSecondary(); return false }
    func showUpdateInFocus() { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    private func clearDetails() { acceptingNotes = false; notes = ""; version = "" }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        clearDetails()
        present("Keep Folio close", "Let Folio check for new versions. You choose when to download and install.",
            primaryTitle: "Check Automatically", primary: { reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: false, sendSystemProfile: false)) },
            secondaryTitle: "Not Now", secondary: { reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false)) })
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        clearDetails()
        present("Looking for updates", "Checking for the latest Folio.", busy: true, secondaryTitle: "Cancel", secondary: cancellation)
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateAvailable = true
        clearDetails(); version = "Folio " + appcastItem.displayVersionString
        acceptingNotes = true
        notes = Self.readableNotes(appcastItem.itemDescription ?? "")
        if notes.isEmpty { notes = appcastItem.releaseNotesURL == nil ? "No release notes were provided for this version." : "Loading release notes…" }
        let installing = state.stage == .installing
        if appcastItem.isInformationOnlyUpdate {
            present("An update to Folio", "This version is not available for in-app installation.", showWindow: state.userInitiated, secondaryTitle: "Done", secondary: { reply(.dismiss) })
        } else {
            present("A little more Folio", "A new version is ready when you are.", showWindow: state.userInitiated,
                primaryTitle: installing ? "Install & Relaunch" : "Update Folio", primary: { [weak self] in self?.acceptingNotes = false; reply(.install) },
                secondaryTitle: installing ? "Cancel Update" : "Later", secondary: { reply(installing ? .skip : .dismiss) })
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard acceptingNotes else { return }
        guard downloadData.data.count <= 128_000, let text = String(data: downloadData.data, encoding: .utf8) else {
            notes = "The release notes could not be displayed."; return
        }
        notes = Self.readableNotes(text)
        if notes.isEmpty { notes = "No release notes were provided for this version." }
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        guard acceptingNotes else { return }
        notes = "Release notes could not be loaded. You can close this window and check again later."
    }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updateAvailable = false
        clearDetails()
        present("No update available", error.localizedDescription, secondaryTitle: "Done", secondary: acknowledgement)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        clearDetails()
        present("The update couldn’t finish", error.localizedDescription + " Try Check for Updates again when you’re ready.", secondaryTitle: "Done", secondary: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        acceptingNotes = false; expected = 0; received = 0
        present("On its way", "Downloading your update.", busy: true, secondaryTitle: "Cancel Download", secondary: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength; updateProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (sum, overflow) = received.addingReportingOverflow(length)
        received = overflow ? UInt64.max : sum; updateProgress()
    }
    private func updateProgress() {
        progress = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }
    func showDownloadDidStartExtractingUpdate() {
        acceptingNotes = false
        present("Getting Folio ready", "Verifying and preparing the update.", busy: true)
    }
    func showExtractionReceivedProgress(_ value: Double) { progress = value.isFinite ? max(0, min(1, value)) : nil }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        acceptingNotes = false
        present("Ready for a fresh start", "Folio will reopen after installing. You’ll be asked to save any unfinished writing.",
            primaryTitle: "Install & Relaunch", primary: { reply(.install) },
            secondaryTitle: "Cancel Update", secondary: { reply(.skip) })
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        present("Finishing up", applicationTerminated ? "Installing Folio. It will reopen shortly." : "Save your writing in Folio to continue. If you cancelled quitting, you can try again.", busy: true,
            primaryTitle: applicationTerminated ? nil : "Continue", primary: applicationTerminated ? nil : retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        updateAvailable = false
        clearDetails()
        present("You’re up to date", "The update is installed.", secondaryTitle: "Done", secondary: acknowledgement)
    }
    func dismissUpdateInstallation() {
        primary = nil; secondary = nil; primaryTitle = nil; secondaryTitle = nil
        clearDetails(); busy = false; progress = nil; window?.orderOut(nil)
    }
    // Release content is rendered as text, never as executable HTML or remote media.
    static func readableNotes(_ text: String) -> String {
        String(text.prefix(32_000))
            .replacingOccurrences(of: "(?i)<(?:br|/p|/li|/h[1-6])[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct FolioUpdateView: View {
    @ObservedObject var driver: FolioUpdateDriver
    private let ink = Color(red: 25/255, green: 25/255, blue: 25/255)
    private let accent = Color(red: 44/255, green: 1, blue: 5/255)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: driver.icon).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                Text("FOLIO").font(.system(size: 12, weight: .semibold)).tracking(2)
                Spacer()
                if !driver.version.isEmpty { Text(driver.version).font(.system(size: 12)).foregroundStyle(.secondary) }
            }.padding(.bottom, 24)
            Text(driver.heading).font(.custom("Oswald-Regular_Bold", size: 38)).fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            Text(driver.message).font(.custom("SourceSerif4Roman-Regular", size: 19)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            if driver.busy {
                Group {
                    if let progress = driver.progress { ProgressView(value: progress) }
                    else { ProgressView().controlSize(.small) }
                }.tint(accent).padding(.top, 24).accessibilityLabel(driver.heading)
            }
            if !driver.notes.isEmpty {
                Rectangle().fill(ink.opacity(0.12)).frame(height: 1).padding(.vertical, 26)
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(Array(driver.notes.components(separatedBy: "\n").prefix(256).enumerated()), id: \.offset) { _, line in
                            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                                noteLine(line)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.scrollIndicators(.hidden)
            } else { Spacer(minLength: 24) }
            HStack(spacing: 12) {
                Spacer()
                if let title = driver.secondaryTitle {
                    Button(title) { driver.chooseSecondary() }.buttonStyle(UpdateButtonStyle(primary: false, accent: accent)).keyboardShortcut(.cancelAction)
                }
                if let title = driver.primaryTitle {
                    Button(title) { driver.choosePrimary() }.buttonStyle(UpdateButtonStyle(primary: true, accent: accent)).keyboardShortcut(.defaultAction)
                }
            }.padding(.top, 28)
        }
        .padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 30)
        .foregroundStyle(ink).background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "https" || url.scheme == "http" else { return .discarded }
            return .systemAction
        })
    }
    @ViewBuilder private func noteLine(_ line: String) -> some View {
        if line.hasPrefix("#") {
            Text(line.drop(while: { $0 == "#" || $0 == " " })).font(.custom("Oswald-Regular_SemiBold", size: 24)).padding(.top, 4)
        } else {
            let clean = line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line
            Text(.init(clean)).font(.custom("SourceSerif4Roman-Regular", size: 18)).lineSpacing(5).tint(ink)
        }
    }
}
private struct UpdateButtonStyle: ButtonStyle {
    let primary: Bool
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(primary ? accent.opacity(configuration.isPressed ? 0.65 : 1) : Color.black.opacity(configuration.isPressed ? 0.08 : 0.035))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
