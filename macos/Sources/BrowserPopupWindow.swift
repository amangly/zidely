// Scripted window.open popups (OAuth sign-in windows, payment flows)
// get a real window whose webview is built from the configuration
// WebKit supplies — the shared configuration is what keeps
// window.opener/postMessage working across the popup. Minimal port of
// cmux's BrowserPopupWindowController.

import AppKit
import WebKit

final class BrowserPopupWindow: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    /// Popups own no pane; something must retain them while open.
    private static var active: [BrowserPopupWindow] = []

    let window: NSWindow
    let webView: WKWebView

    static func open(
        configuration: WKWebViewConfiguration,
        features: WKWindowFeatures,
        parent: NSWindow?,
        underPageColor: NSColor?
    ) -> WKWebView {
        let popup = BrowserPopupWindow(
            configuration: configuration, features: features,
            parent: parent, underPageColor: underPageColor)
        active.append(popup)
        return popup.webView
    }

    private init(
        configuration: WKWebViewConfiguration,
        features: WKWindowFeatures,
        parent: NSWindow?,
        underPageColor: NSColor?
    ) {
        webView = BrowserEngine.makePopupWebView(
            configuration: configuration, underPageColor: underPageColor)
        let width = features.width.map { CGFloat(truncating: $0) } ?? 900
        let height = features.height.map { CGFloat(truncating: $0) } ?? 700
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(320, width), height: max(240, height)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "zide"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        webView.uiDelegate = self
        webView.navigationDelegate = self
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: WKUIDelegate

    /// window.close() from the page — how OAuth popups end themselves.
    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    /// A popup opening another popup chains through the same path.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        Self.open(
            configuration: configuration, features: windowFeatures,
            parent: window, underPageColor: webView.underPageBackgroundColor)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // The URL is the popup's identity while pages set no title.
        if let host = webView.url?.host { window.title = host }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let title = webView.title, !title.isEmpty { window.title = title }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? nsError.userInfo["NSErrorFailingURLStringKey"] as? String ?? ""
        BrowserErrorPage(failedURL: failedURL, error: nsError).load(in: webView)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        Self.active.removeAll { $0 === self }
    }
}
