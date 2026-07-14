// In-page navigation error UI, ported from cmux's BrowserErrorPage:
// a failed load renders a styled page with the failed URL and a
// retry link instead of leaving a blank webview. (cmux additionally
// offers a certificate-bypass button there; zide doesn't — invalid
// TLS stays an error.)

import Foundation
import WebKit

struct BrowserErrorPageContent {
    let title: String
    let message: String

    init(error: NSError, failedURL: String) {
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorTimedOut):
            title = "Can\u{2019}t reach this page"
            message = failedURL.isEmpty
                ? "The site refused to connect. Check that a server is running on this address."
                : "\(failedURL) refused to connect. Check that a server is running on this address."
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            title = "No internet connection"
            message = "Check your network connection and try again."
        case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorSecureConnectionFailed):
            title = "Connection isn\u{2019}t secure"
            message = "The certificate for this site is invalid."
        default:
            title = "Can\u{2019}t open this page"
            message = "The page could not be opened. Check the address and try again."
        }
    }
}

@MainActor
struct BrowserErrorPage {
    let failedURL: String
    let error: NSError

    func load(in webView: WKWebView) {
        let content = BrowserErrorPageContent(error: error, failedURL: failedURL)
        let reload: String
        if let retryURL = Self.retryURL(from: failedURL) {
            reload = """
                <a class="button reload" href="\(escapeHTML(retryURL.absoluteString))">Reload</a>
            """
        } else {
            reload = ""
        }
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <style>
        :root {
            color-scheme: light dark;
            --background: #f7f7f8;
            --border: rgba(0, 0, 0, 0.12);
            --text: #1d1d1f;
            --secondary: #666a70;
            --tertiary: #80858c;
            --code-background: rgba(0, 0, 0, 0.045);
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex; align-items: center; justify-content: center;
            min-height: 100vh; box-sizing: border-box; margin: 0; padding: 32px;
            background: var(--background); color: var(--text);
            -webkit-font-smoothing: antialiased;
        }
        .container { width: min(520px, 100%); text-align: left; }
        .icon {
            display: inline-flex; align-items: center; justify-content: center;
            width: 28px; height: 28px; margin-bottom: 14px;
            border: 1px solid var(--border); border-radius: 50%;
            color: var(--secondary); font-size: 16px; font-weight: 700;
        }
        h1 { margin: 0; font-size: 22px; font-weight: 650; line-height: 1.2; }
        p { margin: 10px 0 0; font-size: 14px; color: var(--secondary); line-height: 1.5; }
        .url {
            margin-top: 18px; padding: 10px 12px; border-radius: 6px;
            background: var(--code-background); color: var(--tertiary);
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 12px; line-height: 1.45; overflow-wrap: anywhere;
        }
        .actions { display: flex; gap: 10px; margin-top: 24px; }
        .button {
            min-height: 34px; box-sizing: border-box; padding: 7px 16px;
            border-radius: 6px; font: inherit; font-size: 13px; font-weight: 600;
            cursor: pointer; text-decoration: none;
            display: inline-flex; align-items: center; justify-content: center;
        }
        .reload { background: var(--text); color: var(--background); }
        .reload:hover { opacity: 0.86; }
        @media (prefers-color-scheme: dark) {
            :root {
                --background: #1c1c1e;
                --border: rgba(255, 255, 255, 0.14);
                --text: #f5f5f7;
                --secondary: #a1a1a6;
                --tertiary: #8e8e93;
                --code-background: rgba(255, 255, 255, 0.07);
            }
        }
        </style>
        </head>
        <body>
        <div class="container">
            <div class="icon" aria-hidden="true">!</div>
            <h1>\(escapeHTML(content.title))</h1>
            <p>\(escapeHTML(content.message))</p>
            <div class="url">\(escapeHTML(failedURL))</div>
            <div class="actions">\(reload)</div>
        </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func retryURL(from failedURL: String) -> URL? {
        guard let url = URL(string: failedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
