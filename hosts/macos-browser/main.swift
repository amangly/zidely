// zide browser host (macOS prototype).
//
// Connects to the zide control socket, registers as the browser host,
// and renders each browser pane as a WKWebView window. This is the
// stand-in for the real shell's embedded browser panes: same protocol,
// throwaway chrome. Build with hosts/macos-browser/build.sh — needs
// only Command Line Tools, not Xcode.

import AppKit
import WebKit

let sockPath = ProcessInfo.processInfo.environment["ZIDE_SOCKET"]
    ?? "/tmp/zide-\(getuid()).sock"

// --- control socket -------------------------------------------------------

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fatalError("socket() failed") }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    sockPath.withCString { cstr in
        strncpy(
            UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
            cstr,
            MemoryLayout.size(ofValue: addr.sun_path) - 1
        )
    }
}
let connected = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    FileHandle.standardError.write(
        "cannot connect to \(sockPath) — is the zide daemon running?\n".data(using: .utf8)!)
    exit(1)
}

// Single-write-per-line keeps interleaving harmless for this prototype.
func sendJSON(_ obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0a)
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
}

sendJSON(["id": 1, "cmd": "host-register"])

// --- webview windows ------------------------------------------------------

final class Host: NSObject, WKNavigationDelegate {
    var windows: [UInt64: (NSWindow, WKWebView)] = [:]
    var paneOf: [ObjectIdentifier: UInt64] = [:]

    func open(pane: UInt64, url: String) {
        if windows[pane] != nil { return nav(pane: pane, url: url) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        web.navigationDelegate = self
        let offset = CGFloat(windows.count) * 32
        let win = NSWindow(
            contentRect: NSRect(x: 160 + offset, y: 160 + offset, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "zide pane \(pane)"
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        windows[pane] = (win, web)
        paneOf[ObjectIdentifier(web)] = pane
        nav(pane: pane, url: url)
    }

    func nav(pane: UInt64, url: String) {
        guard let (_, web) = windows[pane], let u = URL(string: url) else { return }
        web.load(URLRequest(url: u))
    }

    func eval(pane: UInt64, seq: UInt64, js: String) {
        guard let (_, web) = windows[pane] else { return }
        web.evaluateJavaScript(js) { value, error in
            let v = error.map { "error: \($0.localizedDescription)" }
                ?? String(describing: value ?? "null")
            sendJSON(["id": 0, "cmd": "browser-eval-result",
                      "pane": pane, "seq": seq, "data": v])
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pane = paneOf[ObjectIdentifier(webView)] else { return }
        sendJSON(["id": 0, "cmd": "browser-update", "pane": pane,
                  "url": webView.url?.absoluteString ?? "",
                  "title": webView.title ?? "", "loading": false])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = Host()

// --- protocol reader ------------------------------------------------------

DispatchQueue.global().async {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer.prefix(upTo: nl))
            buffer.removeSubrange(...nl)
            guard
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let event = obj["event"] as? String
            else { continue }
            let pane = (obj["pane"] as? NSNumber)?.uint64Value ?? 0
            DispatchQueue.main.async {
                switch event {
                case "browser_open":
                    host.open(pane: pane, url: obj["url"] as? String ?? "about:blank")
                case "browser_nav":
                    host.nav(pane: pane, url: obj["url"] as? String ?? "about:blank")
                case "browser_eval":
                    host.eval(pane: pane,
                              seq: (obj["seq"] as? NSNumber)?.uint64Value ?? 0,
                              js: obj["js"] as? String ?? "")
                default:
                    break
                }
            }
        }
    }
}

app.run()
