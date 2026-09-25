import SwiftUI
import AppKit

struct WindowChrome: NSViewRepresentable {
    var dark: Bool
    var paper: String

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.dark = dark
        view.paper = paper
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.dark = dark
        nsView.paper = paper
        nsView.applyIfPossible()
    }

    final class ConfiguratorView: NSView {
        let closeGuard = ReaderCloseGuard()
        var dark: Bool = false
        var paper = "#FFFFFF"

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfPossible()
        }

        func applyIfPossible() {
            if Thread.isMainThread {
                applyNow()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.applyNow()
                }
            }
        }

        private func applyNow() {
            guard let window = self.window else { return }
            if window.delegate !== closeGuard {
                closeGuard.original = window.delegate
                window.delegate = closeGuard
            }
            window.isDocumentEdited = ReaderModel.shared.dirty
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.isOpaque = true

            let lightColor = NSColor.white
            let darkColor = NSColor(
                calibratedRed: 0x17 / 255.0,
                green: 0x17 / 255.0,
                blue: 0x17 / 255.0,
                alpha: 1.0
            )
            if let hex = UInt32(paper.dropFirst(), radix: 16) {
                window.backgroundColor = NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
            } else { window.backgroundColor = dark ? darkColor : lightColor }
            // ReaderView.preferredColorScheme owns native appearance. Setting it
            // here fights SwiftUI during menu transitions and loops toolbar layout.
        }
    }
}

@MainActor final class ReaderCloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        guard ReaderModel.shared.confirmLeave() else { return false }
        ReaderModel.shared.baseline = ReaderModel.shared.text
        return true
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }
}
