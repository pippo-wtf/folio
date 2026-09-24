import SwiftUI
import WebKit
import AppKit
import ImageIO
import ReaderCore

final class LocalAssets: NSObject, WKURLSchemeHandler {
    var document: URL?
    var root: URL?
    var token = UUID().uuidString.lowercased()
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == token, let document,
              let reference = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.dropFirst().description,
              let file = AssetPolicy.resolve(reference, document: document, grantedRoot: root),
              let handle = try? FileHandle(forReadingFrom: file) else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024 * 1024 + 1), data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 10000, height <= 10000, width * height <= 20_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { task.didFailWithError(URLError(.cannotDecodeContentData)); return }
        task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: png.count, textEncodingName: nil))
        task.didReceive(png); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
final class FolioWebView: WKWebView {
    var editHistory: ((Bool) -> Void)?
    var complexEditorActive = false
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            editHistory?(event.modifierFlags.contains(.shift)); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
struct ReaderWebView: NSViewRepresentable {
    @ObservedObject var model: ReaderModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(model.assetHandler, forURLScheme: "folio-asset")
        config.userContentController.add(context.coordinator, name: "folio")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = FolioWebView(frame: .zero, configuration: config)
        view.editHistory = { [weak model] redo in if redo { model?.redoEdit() } else { model?.undoEdit() } }
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        model.ready = false
        model.webView = view
        let nonce = UUID().uuidString
        let js = resource("reader", "js").replacingOccurrences(of: "</script", with: #"<\/script"#)
        let css = bundledFontsCSS() + resource("math", "css") + resource("reader", "css")
        let csp = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src folio-asset:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        let html = "<!doctype html><html lang='en'><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"\(csp)\"><meta name='viewport' content='width=device-width,initial-scale=1'><style>\(css)</style></head><body><main id='document' aria-label='Document'></main><script nonce='\(nonce)'>\(js)</script></body></html>"
        view.loadHTMLString(html, baseURL: nil)
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    // Only app-bundled font data is embedded; document content cannot supply fonts.
    private func bundledFontsCSS() -> String {
        let faces = [("Oswald", "Oswald", "normal", "200 700"),
                     ("SourceSerif4", "Source Serif 4", "normal", "200 900"),
                     ("SourceSerif4-Italic", "Source Serif 4", "italic", "200 900")]
        return faces.compactMap { file, family, style, weight -> String? in
            guard let url = Bundle.module.url(forResource: file, withExtension: "ttf", subdirectory: "Resources/Fonts"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return "@font-face{font-family:'\(family)';src:url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype');font-style:\(style);font-weight:\(weight);font-display:swap;}"
        }.joined(separator: "\n")
    }
    private func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: ReaderModel
        init(_ model: ReaderModel) { self.model = model }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready": model.ready = true; model.render()
            case "complexEditorState":
                if let token = body["token"] as? String, let active = body["active"] as? Bool {
                    model.acceptComplexEditorState(token: token, active: active)
                }
            case "editDocument":
                if let before = body["before"] as? String, let updated = body["text"] as? String, let token = body["token"] as? String {
                    model.acceptRenderedEdit(before: before, text: updated, token: token, passage: body["passage"] as? String ?? "")
                }
            case "editingRejected":
                model.error = "That edit would remove a complex block. The current draft has been restored; use Source for that change."
                model.render()
            case "undoEdit": model.undoEdit()
            case "redoEdit": model.redoEdit()
            case "outline":
                if let array = body["headings"], let data = try? JSONSerialization.data(withJSONObject: array), let headings = try? JSONDecoder().decode([Heading].self, from: data) { model.headings = headings }
            case "readingPosition":
                if let token = body["token"] as? String, let value = body["position"],
                   let data = try? JSONSerialization.data(withJSONObject: value), let position = try? JSONDecoder().decode(ReadingPosition.self, from: data) {
                    model.saveReadingPosition(position, token: token)
                }
            case "saveHighlights":
                if let token = body["token"] as? String, let array = body["highlights"],
                   let data = try? JSONSerialization.data(withJSONObject: array), data.count <= 2_000_000,
                   let records = try? JSONDecoder().decode([SavedHighlight].self, from: data) {
                    model.saveHighlights(records, token: token)
                }
            case "printReady":
                if let token = body["token"] as? String { model.finishPrint(token: token) }
            case "copyNotice":
                if let text = body["text"] as? String { model.error = String(text.prefix(300)) }
            case "copyFormatted":
                if let text = body["text"] as? String, let html = body["html"] as? String, text.utf8.count <= 400000, html.utf8.count <= 2000000 {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    NSPasteboard.general.setString(html, forType: .html)
                }
            case "copyCode":
                if let text = body["text"] as? String, text.utf8.count <= DocumentReader.maximumBytes { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            case "noteLink":
                if let target = body["target"] as? String { model.openNote(target) }
            case "link":
                if let value = body["url"] as? String, let url = URL(string: value), AssetPolicy.externalLink(url) { NSWorkspace.shared.open(url) }
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other && action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow) } else { decisionHandler(.cancel) }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            model.ready = false
            (webView as? FolioWebView)?.complexEditorActive = false
            model.error = "The reading view stopped. Close this window and reopen Folio to recover. Your file is unchanged."
        }
    }
}
