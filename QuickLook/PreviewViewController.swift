import AppKit
import WebKit
import QuickLookUI

@objc(FolioPreviewController)
final class FolioPreviewController: NSViewController, QLPreviewingController, WKScriptMessageHandler, WKNavigationDelegate {
    private var web: WKWebView!
    private var source = ""
    private var ready = false
    private var completion: ((Error?) -> Void)?
    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "folio")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 800), configuration: config)
        web.navigationDelegate = self
        view = web; preferredContentSize = NSSize(width: 760, height: 800)
        let bundle = Bundle(for: Self.self)
        func resource(_ name: String, _ ext: String) -> String {
            guard let url = bundle.url(forResource: name, withExtension: ext) else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        let nonce = UUID().uuidString
        let js = resource("reader", "js").replacingOccurrences(of: "</script", with: #"<\/script"#)
        var fonts = ""
        for (file, family, style, weights) in [("Oswald", "Oswald", "normal", "200 700"), ("SourceSerif4", "Source Serif 4", "normal", "200 900"), ("SourceSerif4-Italic", "Source Serif 4", "italic", "200 900")] {
            if let url = bundle.url(forResource: file, withExtension: "ttf"), let data = try? Data(contentsOf: url) {
                fonts += "@font-face{font-family:'\(family)';src:url(data:font/ttf;base64,\(data.base64EncodedString()));font-style:\(style);font-weight:\(weights)}"
            }
        }
        let css = fonts + resource("reader", "css") + resource("math", "css")
        let csp = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; font-src data:; img-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        web.loadHTMLString("<!doctype html><html lang='en'><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"\(csp)\"><style>\(css)</style></head><body><main id='document' aria-label='Markdown preview'></main><script nonce='\(nonce)'>\(js)</script></body></html>", baseURL: nil)
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw CocoaError(.fileReadUnsupportedScheme) }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let utf16 = data.starts(with: [0xff,0xfe]) || data.starts(with: [0xfe,0xff])
            let clean = data.starts(with: [0xef,0xbb,0xbf]) ? Data(data.dropFirst(3)) : data
            guard let text = String(data: clean, encoding: utf16 ? .utf16 : .utf8), !text.contains("\0") else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            source = text; completion = handler
            loadViewIfNeeded()
            if ready { render() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(CocoaError(.fileReadUnknown)) }
        } catch { handler(error) }
    }
    private func render() {
        guard let data = try? JSONSerialization.data(withJSONObject: [source, "", UUID().uuidString, [], false]), let json = String(data: data, encoding: .utf8) else { finish(CocoaError(.fileReadUnknown)); return }
        web.evaluateJavaScript("window.Folio.render.apply(null, \(json))") { [weak self] _, error in self?.finish(error) }
    }
    private func finish(_ error: Error?) { let handler = completion; completion = nil; handler?(error) }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], body["type"] as? String == "ready" else { return }
        ready = true; if completion != nil { render() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}
