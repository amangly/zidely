// zide proto-shell (macOS).
//
// A native window onto a running zide daemon: cmux-style sidebar of
// sessions and panes, live terminal pane view (plain-text snapshots —
// the GPU libghostty renderer arrives with the real shell), an input
// line, and embedded WKWebView browser panes (this app host-registers).
// Throwaway chrome, real protocol. Build with build.sh — needs only
// Command Line Tools.

import AppKit
import WebKit

// MARK: - Socket client

final class SocketClient {
    private let fd: Int32
    private var nextId: UInt64 = 100
    private var pending: [UInt64: ([String: Any]) -> Void] = [:]
    var onEvent: (([String: Any]) -> Void)?

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr, pathCap - 1)
            }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        startReader()
    }

    /// Send a command; the completion runs on the main queue.
    func send(_ obj: [String: Any], _ completion: (([String: Any]) -> Void)? = nil) {
        var obj = obj
        nextId += 1
        obj["id"] = nextId
        if let completion { pending[nextId] = completion }
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    private func startReader() {
        DispatchQueue.global().async { [self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
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
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { continue }
                    DispatchQueue.main.async { self.route(obj) }
                }
            }
        }
    }

    private func route(_ obj: [String: Any]) {
        if obj["event"] is String {
            onEvent?(obj)
        } else if let id = (obj["id"] as? NSNumber)?.uint64Value,
                  let cb = pending.removeValue(forKey: id) {
            cb(obj)
        }
    }
}

// MARK: - Sidebar model

enum Row {
    case session(id: UInt64, title: String)
    case term(pane: UInt64, exited: Bool)
    case browser(pane: UInt64)

    var label: String {
        switch self {
        case let .session(id, title): return "session \(id) — \(title)"
        case let .term(pane, exited): return "    ⌨︎ pane \(pane)\(exited ? "  (exited)" : "")"
        case let .browser(pane): return "    ◉ web \(pane)"
        }
    }
}

// MARK: - Controller

final class Shell: NSObject, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate {
    let client: SocketClient
    let window: NSWindow
    let table = NSTableView()
    let terminalText = NSTextView()
    let terminalScroll = NSScrollView()
    let input = NSTextField()
    let statusLabel = NSTextField(labelWithString: "no pane selected")
    let content = NSView()

    var rows: [Row] = []
    var exited: Set<UInt64> = []
    var webviews: [UInt64: WKWebView] = [:]
    var paneOfWebView: [ObjectIdentifier: UInt64] = [:]
    var selectedPane: UInt64?
    var selectedIsBrowser = false
    var snapshotQueued = false

    init(client: SocketClient) {
        self.client = client
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        buildUI()
        client.onEvent = { [weak self] in self?.handleEvent($0) }
        client.send(["cmd": "host-register"])
        refresh()
    }

    // MARK: UI construction (springs, no constraints — throwaway chrome)

    func buildUI() {
        window.title = "zide"
        let root = window.contentView!
        let W = root.bounds.width
        let H = root.bounds.height
        let sidebarW: CGFloat = 250

        // Sidebar: button row on top, table below.
        let buttons = NSStackView(frame: NSRect(x: 8, y: H - 36, width: sidebarW - 16, height: 28))
        buttons.orientation = .horizontal
        buttons.autoresizingMask = [.minYMargin]
        for (title, action) in [("+ session", #selector(addSession)),
                                ("+ term", #selector(addTerm)),
                                ("+ web", #selector(addWeb))] {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            buttons.addArrangedSubview(b)
        }
        root.addSubview(buttons)

        let sideScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: H - 44))
        sideScroll.autoresizingMask = [.height]
        sideScroll.hasVerticalScroller = true
        let col = NSTableColumn(identifier: .init("main"))
        col.width = sidebarW - 20
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        sideScroll.documentView = table
        root.addSubview(sideScroll)

        // Content area.
        content.frame = NSRect(x: sidebarW + 1, y: 0, width: W - sidebarW - 1, height: H)
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)

        let cW = content.bounds.width
        let cH = content.bounds.height

        statusLabel.frame = NSRect(x: 10, y: cH - 26, width: cW - 20, height: 18)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        terminalScroll.frame = NSRect(x: 0, y: 34, width: cW, height: cH - 66)
        terminalScroll.autoresizingMask = [.width, .height]
        terminalScroll.hasVerticalScroller = true
        terminalText.frame = terminalScroll.bounds
        terminalText.isEditable = false
        terminalText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalText.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.13, alpha: 1)
        terminalText.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        terminalText.autoresizingMask = [.width]
        terminalScroll.documentView = terminalText
        content.addSubview(terminalScroll)

        input.frame = NSRect(x: 8, y: 6, width: cW - 16, height: 24)
        input.autoresizingMask = [.width, .maxYMargin]
        input.placeholderString = "type here, Enter sends to the selected terminal pane"
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.target = self
        input.action = #selector(sendInput)
        content.addSubview(input)

        // Minimal menu so Cmd+Q works.
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit zide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: Data

    func refresh() {
        client.send(["cmd": "list-sessions"]) { [weak self] resp in
            guard let self, let sessions = resp["sessions"] as? [[String: Any]] else { return }
            var new: [Row] = []
            for s in sessions {
                let sid = (s["id"] as? NSNumber)?.uint64Value ?? 0
                new.append(.session(id: sid, title: s["title"] as? String ?? ""))
                for p in s["panes"] as? [NSNumber] ?? [] {
                    new.append(.term(pane: p.uint64Value, exited: self.exited.contains(p.uint64Value)))
                }
                for b in s["browsers"] as? [NSNumber] ?? [] {
                    new.append(.browser(pane: b.uint64Value))
                }
            }
            self.rows = new
            self.table.reloadData()

            // First refresh: focus the first terminal pane so the window
            // shows something immediately.
            if self.selectedPane == nil {
                for (i, r) in new.enumerated() {
                    if case .term = r {
                        self.table.selectRowIndexes([i], byExtendingSelection: false)
                        self.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
                        break
                    }
                }
            }
        }
    }

    func handleEvent(_ obj: [String: Any]) {
        let event = obj["event"] as? String ?? ""
        let pane = (obj["pane"] as? NSNumber)?.uint64Value ?? 0
        switch event {
        case "pane_output":
            if pane == selectedPane, !selectedIsBrowser { queueSnapshot() }
            // A pane we don't know yet (spawned via CLI): refresh sidebar.
            if !rows.contains(where: {
                if case let .term(p, _) = $0 { return p == pane } else { return false }
            }) { refresh() }
        case "pane_exit":
            exited.insert(pane)
            refresh()
            if pane == selectedPane { statusLabel.stringValue = "pane \(pane) — exited" }
        case "browser_open":
            ensureWebView(pane: pane, url: obj["url"] as? String ?? "about:blank")
            refresh()
        case "browser_nav":
            if let web = webviews[pane], let u = URL(string: obj["url"] as? String ?? "") {
                web.load(URLRequest(url: u))
            }
        case "browser_eval":
            if let web = webviews[pane] {
                let seq = (obj["seq"] as? NSNumber)?.uint64Value ?? 0
                web.evaluateJavaScript(obj["js"] as? String ?? "") { value, error in
                    let v = error.map { "error: \($0.localizedDescription)" }
                        ?? String(describing: value ?? "null")
                    self.client.send(["cmd": "browser-eval-result", "pane": pane, "seq": seq, "data": v])
                }
            }
        default:
            break
        }
    }

    func ensureWebView(pane: UInt64, url: String) {
        guard webviews[pane] == nil else { return }
        let web = WKWebView(frame: terminalScroll.frame)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        webviews[pane] = web
        paneOfWebView[ObjectIdentifier(web)] = pane
        if let u = URL(string: url) { web.load(URLRequest(url: u)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pane = paneOfWebView[ObjectIdentifier(webView)] else { return }
        client.send(["cmd": "browser-update", "pane": pane,
                     "url": webView.url?.absoluteString ?? "",
                     "title": webView.title ?? "", "loading": false])
        if pane == selectedPane {
            statusLabel.stringValue = "web \(pane) — \(webView.title ?? "") — \(webView.url?.absoluteString ?? "")"
        }
    }

    func queueSnapshot() {
        guard !snapshotQueued, let pane = selectedPane else { return }
        snapshotQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.snapshotQueued = false
            self.client.send(["cmd": "snapshot", "pane": pane]) { resp in
                guard pane == self.selectedPane,
                      let text = resp["snapshot"] as? String else { return }
                self.terminalText.string = text
                self.terminalText.scrollToEndOfDocument(nil)
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        rows[row].label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let idx = table.selectedRow
        guard idx >= 0, idx < rows.count else { return }
        switch rows[idx] {
        case .session:
            break
        case let .term(pane, wasExited):
            selectedPane = pane
            selectedIsBrowser = false
            for w in webviews.values { w.removeFromSuperview() }
            terminalScroll.isHidden = false
            statusLabel.stringValue = "pane \(pane)\(wasExited ? " — exited" : "")"
            snapshotQueued = false
            queueSnapshot()
        case let .browser(pane):
            selectedPane = pane
            selectedIsBrowser = true
            terminalScroll.isHidden = true
            for w in webviews.values { w.removeFromSuperview() }
            if let web = webviews[pane] {
                web.frame = terminalScroll.frame
                content.addSubview(web)
                statusLabel.stringValue = "web \(pane) — \(web.title ?? "") — \(web.url?.absoluteString ?? "")"
            }
        }
    }

    // MARK: Actions

    var currentSession: UInt64 {
        let idx = table.selectedRow
        if idx >= 0, idx < rows.count {
            var i = idx
            while i >= 0 {
                if case let .session(id, _) = rows[i] { return id }
                i -= 1
            }
        }
        for r in rows { if case let .session(id, _) = r { return id } }
        return 1
    }

    @objc func addSession() {
        client.send(["cmd": "create-session", "title": "session"]) { [weak self] _ in self?.refresh() }
    }

    @objc func addTerm() {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        client.send(["cmd": "spawn-pane", "session": currentSession,
                     "argv": [shellPath, "-i"]]) { [weak self] _ in self?.refresh() }
    }

    @objc func addWeb() {
        let alert = NSAlert()
        alert.messageText = "Open browser pane"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = "https://ziglang.org"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        client.send(["cmd": "browser-open", "session": currentSession, "url": field.stringValue])
        // browser_open comes back as an event and builds the webview.
    }

    @objc func sendInput() {
        guard let pane = selectedPane, !selectedIsBrowser else { return }
        client.send(["cmd": "write", "pane": pane, "data": input.stringValue + "\n"])
        input.stringValue = ""
        queueSnapshot()
    }
}

// MARK: - main

let sockPath = ProcessInfo.processInfo.environment["ZIDE_SOCKET"]
    ?? "/tmp/zide-\(getuid()).sock"
guard let client = SocketClient(path: sockPath) else {
    FileHandle.standardError.write(
        "cannot connect to \(sockPath) — start it with `zide daemon`\n".data(using: .utf8)!)
    exit(1)
}

// Windows must be created after the app finishes launching, or they
// never become visible.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client: SocketClient
    var shell: Shell?
    init(client: SocketClient) { self.client = client }
    func applicationDidFinishLaunching(_ notification: Notification) {
        shell = Shell(client: client)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(client: client)
app.delegate = delegate
app.run()
