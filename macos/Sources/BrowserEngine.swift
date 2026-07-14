// Browser panes run the same engine cmux runs: WebKit (WKWebView),
// Safari's engine, configured the way cmux's BrowserPanel.makeWebView
// does — presenting as Safari so sites serve their modern UI instead
// of fallback/bot-check flows.

import AppKit
import WebKit

enum BrowserEngine {
    /// cmux forces a Safari UA: some WebKit builds report a minimal UA
    /// without Version/Safari tokens, and Google serves old UIs or
    /// triggers bot checks on those.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"

    static func makeWebView(underPageColor: NSColor?) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Cookies/storage persist across navigations and launches —
        // sign-ins stick, consent walls don't repeat.
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return finishWebView(WKWebView(frame: .zero, configuration: config), underPageColor: underPageColor)
    }

    /// Popup webviews must be built with the exact configuration WebKit
    /// hands createWebViewWith — that shared configuration is what
    /// keeps window.opener/postMessage alive (OAuth popups).
    static func makePopupWebView(
        configuration: WKWebViewConfiguration,
        underPageColor: NSColor?
    ) -> WKWebView {
        finishWebView(
            WKWebView(frame: .zero, configuration: configuration),
            underPageColor: underPageColor)
    }

    private static func finishWebView(_ web: WKWebView, underPageColor: NSColor?) -> WKWebView {
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.customUserAgent = safariUserAgent
        // Match the unpainted/loading background to the terminal theme
        // so new browsers don't flash white before content paints.
        if let underPageColor { web.underPageBackgroundColor = underPageColor }
        return web
    }

    /// cmux's page-zoom bounds and step.
    static let minPageZoom: CGFloat = 0.5
    static let maxPageZoom: CGFloat = 3.0
    static let pageZoomStep: CGFloat = 0.1

    /// External-scheme handoff (mailto:, facetime:, app schemes...):
    /// anything WebKit itself won't render inline belongs to macOS.
    static func isWebScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return ["http", "https", "about", "blob", "data", "javascript", "file"].contains(scheme)
    }
}
