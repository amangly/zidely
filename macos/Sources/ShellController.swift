// The zide window: cmux-style chrome. A dark vertical sidebar lists
// sessions and their panes with attention state; the rest of the window
// is the selected pane — a live libghostty terminal surface or a
// WKWebView browser pane. Panes are daemon state; this controller is a
// view onto the socket protocol and nothing more.

import AppKit
import WebKit
import GhosttyKit

enum SidebarRow {
    case tasksHeader
    case task(id: UInt64)
    case session(id: UInt64, title: String)
    case term(pane: UInt64)
    case browser(pane: UInt64)
}

struct TaskInfo {
    var id: UInt64
    var pane: UInt64
    var description: String
    var status: String // working | needs_attention | finished
}

final class ShellController: NSObject, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate, NSWindowDelegate {
    let client: SocketClient
    let runtime: GhosttyRuntime
    let zideBin: String
    let socketPath: String

    let window: NSWindow
    let table = NSTableView()
    let content = NSView()
    let statusLabel = NSTextField(labelWithString: "")
    let placeholder = NSTextField(labelWithString: "no pane selected — ⌘T opens a terminal")

    var rows: [SidebarRow] = []
    var exited: Set<UInt64> = []
    var bells: Set<UInt64> = []
    var tasks: [UInt64: TaskInfo] = [:]
    var surfaces: [UInt64: TerminalSurfaceView] = [:]
    var webviews: [UInt64: WKWebView] = [:]
    var paneOfWebView: [ObjectIdentifier: UInt64] = [:]
    var selectedPane: UInt64?

    static let sidebarWidth: CGFloat = 240

    init(client: SocketClient, runtime: GhosttyRuntime, zideBin: String, socketPath: String) {
        self.client = client
        self.runtime = runtime
        self.zideBin = zideBin
        self.socketPath = socketPath
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        buildUI()
        buildMenu()
        window.delegate = self
        client.onEvent = { [weak self] in self?.handleEvent($0) }
        client.send(["cmd": "host-register"])
        refresh(selectFirst: true)
    }

    // MARK: UI

    func buildUI() {
        window.title = "zide"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 700, height: 400)
        let root = window.contentView!
        let W = root.bounds.width
        let H = root.bounds.height
        let sw = Self.sidebarWidth

        // Sidebar: translucent dark, cmux-style.
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sw, height: H))
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)

        // Below the traffic lights (the titlebar is transparent and the
        // sidebar spans it).
        let titlebar: CGFloat = 28
        let buttons = NSStackView(frame: NSRect(x: 10, y: H - titlebar - 30, width: sw - 20, height: 24))
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.autoresizingMask = [.minYMargin]
        // Icon buttons (new-session lives in the menu, ⌘N).
        for (symbol, tip, action) in [
            ("sparkles", "New agent task (⌘K)", #selector(addTask)),
            ("apple.terminal", "New terminal (⌘T)", #selector(addTerm)),
            ("globe", "New browser pane (⌘B)", #selector(addWeb)),
        ] {
            let b = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                target: self, action: action)
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.isBordered = true
            b.toolTip = tip
            buttons.addArrangedSubview(b)
        }
        sidebar.addSubview(buttons)

        let sideScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sw, height: H - titlebar - 38))
        sideScroll.autoresizingMask = [.height]
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("main"))
        col.width = sw - 16
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .sourceList
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        sideScroll.documentView = table
        sidebar.addSubview(sideScroll)

        // Content area: the selected pane fills it, with a thin status
        // strip at the bottom. It stops BELOW the titlebar: the strip
        // above must stay clickable as a real titlebar (drag,
        // double-click to zoom) and the window title must not overlap
        // pane content.
        content.frame = NSRect(x: sw + 1, y: 22, width: W - sw - 1, height: H - 22 - titlebar)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor
        root.addSubview(content)

        statusLabel.frame = NSRect(x: sw + 11, y: 3, width: W - sw - 20, height: 16)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        root.addSubview(statusLabel)

        placeholder.frame = content.bounds
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        placeholder.autoresizingMask = [.width, .height]
        content.addSubview(placeholder)

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func buildMenu() {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide zide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit zide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let shellItem = NSMenuItem()
        menu.addItem(shellItem)
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(withTitle: "New Agent Task", action: #selector(addTask), keyEquivalent: "k")
        shellMenu.addItem(withTitle: "New Terminal", action: #selector(addTerm), keyEquivalent: "t")
        shellMenu.addItem(withTitle: "New Session", action: #selector(addSession), keyEquivalent: "n")
        shellMenu.addItem(withTitle: "New Browser Pane", action: #selector(addWeb), keyEquivalent: "b")
        shellMenu.items.forEach { $0.target = self }
        shellItem.submenu = shellMenu

        // Edit menu so field editors work; ghostty surfaces handle
        // copy/paste through their own super+c/v bindings.
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu

        NSApp.mainMenu = menu
    }

    // MARK: Sidebar data

    func refresh(selectFirst: Bool = false) {
        // Tasks first: session rendering hides panes that belong to tasks.
        client.send(["cmd": "task-list"]) { [weak self] resp in
            guard let self else { return }
            self.tasks.removeAll()
            for t in resp["tasks"] as? [[String: Any]] ?? [] {
                let info = TaskInfo(
                    id: (t["id"] as? NSNumber)?.uint64Value ?? 0,
                    pane: (t["pane"] as? NSNumber)?.uint64Value ?? 0,
                    description: t["description"] as? String ?? "",
                    status: t["status"] as? String ?? "working")
                self.tasks[info.id] = info
            }
            self.refreshSessions(selectFirst: selectFirst)
        }
    }

    private func refreshSessions(selectFirst: Bool) {
        client.send(["cmd": "list-sessions"]) { [weak self] resp in
            guard let self, let sessions = resp["sessions"] as? [[String: Any]] else { return }
            let taskPanes = Set(self.tasks.values.map(\.pane))

            var new: [SidebarRow] = []
            if !self.tasks.isEmpty {
                new.append(.tasksHeader)
                for t in self.tasks.values.sorted(by: { $0.id < $1.id }) {
                    new.append(.task(id: t.id))
                }
            }
            for s in sessions {
                let sid = (s["id"] as? NSNumber)?.uint64Value ?? 0
                let panes = (s["panes"] as? [NSNumber] ?? []).map(\.uint64Value)
                let browsers = (s["browsers"] as? [NSNumber] ?? []).map(\.uint64Value)
                let visible = panes.filter { !taskPanes.contains($0) }
                // Agent-task host sessions with nothing else to show are
                // pure duplication of the tasks section.
                if visible.isEmpty && browsers.isEmpty { continue }
                new.append(.session(id: sid, title: s["title"] as? String ?? ""))
                for p in visible { new.append(.term(pane: p)) }
                for b in browsers { new.append(.browser(pane: b)) }
                for e in s["exited"] as? [NSNumber] ?? [] {
                    self.exited.insert(e.uint64Value)
                }
            }
            let selected = self.selectedPane
            self.rows = new
            self.table.reloadData()
            if let selected, let idx = self.rowIndex(of: selected) {
                self.table.selectRowIndexes([idx], byExtendingSelection: false)
            } else if selectFirst {
                for (i, r) in new.enumerated() {
                    if case .term = r {
                        self.table.selectRowIndexes([i], byExtendingSelection: false)
                        break
                    }
                }
            }
        }
    }

    func rowIndex(of pane: UInt64) -> Int? {
        for (i, r) in rows.enumerated() {
            switch r {
            case let .term(p) where p == pane: return i
            case let .browser(p) where p == pane: return i
            case let .task(id) where tasks[id]?.pane == pane: return i
            default: continue
            }
        }
        return nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithAttributedString: label(for: rows[row]))
        text.frame = NSRect(x: 4, y: 3, width: Self.sidebarWidth - 24, height: 18)
        text.autoresizingMask = [.width]
        cell.addSubview(text)
        cell.textField = text
        return cell
    }

    func label(for row: SidebarRow) -> NSAttributedString {
        switch row {
        case .tasksHeader:
            return NSAttributedString(
                string: "AGENT TASKS",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
        case let .task(id):
            let t = tasks[id]
            let status = t?.status ?? "working"
            let dotColor: NSColor = switch status {
            case "needs_attention": .systemOrange
            case "finished": .systemGray
            default: .systemGreen
            }
            let s = NSMutableAttributedString(
                string: status == "needs_attention" ? "◉ " : "● ",
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: dotColor])
            s.append(NSAttributedString(
                string: t?.description ?? "task \(id)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: status == "finished"
                        ? NSColor.secondaryLabelColor : NSColor.labelColor,
                ]))
            return s
        case let .session(id, title):
            return NSAttributedString(
                string: "SESSION \(id)  \(title.uppercased())",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
        case let .term(pane):
            let dotColor: NSColor =
                exited.contains(pane) ? .systemGray :
                bells.contains(pane) ? .systemOrange : .systemGreen
            let s = NSMutableAttributedString(
                string: "● ",
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: dotColor])
            s.append(NSAttributedString(
                string: "pane \(pane)\(exited.contains(pane) ? "  exited" : "")",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: exited.contains(pane) ? NSColor.secondaryLabelColor : NSColor.labelColor,
                ]))
            return s
        case let .browser(pane):
            let s = NSMutableAttributedString(
                string: "◉ ",
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemBlue])
            s.append(NSAttributedString(
                string: "web \(pane)",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
            return s
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .session, .tasksHeader: return false
        default: return true
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let idx = table.selectedRow
        guard idx >= 0, idx < rows.count else { return }
        switch rows[idx] {
        case .session, .tasksHeader:
            break
        case let .task(id):
            if let pane = tasks[id]?.pane { select(terminal: pane) }
        case let .term(pane):
            select(terminal: pane)
        case let .browser(pane):
            select(browser: pane)
        }
    }

    // MARK: Pane hosting

    func clearContent() {
        for v in content.subviews where v !== placeholder { v.removeFromSuperview() }
        placeholder.isHidden = true
    }

    func select(terminal pane: UInt64) {
        selectedPane = pane
        bells.remove(pane)
        clearContent()

        let view: TerminalSurfaceView
        if let cached = surfaces[pane] {
            view = cached
        } else {
            guard let app = runtime.app else { return }
            let command = "\(zideBin) attach \(pane) --socket \(socketPath)"
            view = TerminalSurfaceView(app: app, command: command)
            view.onClose = { [weak self, weak view] in
                guard let self else { return }
                self.surfaces[pane] = nil
                view?.removeFromSuperview()
                if self.selectedPane == pane { self.placeholder.isHidden = false }
                self.refresh()
            }
            surfaces[pane] = view
        }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        window.makeFirstResponder(view)
        statusLabel.stringValue = "pane \(pane)\(exited.contains(pane) ? " — exited" : "")  ·  \(socketPath)"
        reloadRow(pane)
    }

    func select(browser pane: UInt64) {
        selectedPane = pane
        clearContent()
        guard let web = webviews[pane] else {
            placeholder.isHidden = false
            return
        }
        web.frame = content.bounds
        web.autoresizingMask = [.width, .height]
        content.addSubview(web)
        window.makeFirstResponder(web)
        statusLabel.stringValue = "web \(pane) — \(web.title ?? "")  ·  \(web.url?.absoluteString ?? "")"
    }

    func reloadRow(_ pane: UInt64) {
        if let idx = rowIndex(of: pane) {
            table.reloadData(forRowIndexes: [idx], columnIndexes: [0])
        }
    }

    // MARK: Events

    func handleEvent(_ obj: [String: Any]) {
        let event = obj["event"] as? String ?? ""
        let pane = (obj["pane"] as? NSNumber)?.uint64Value ?? 0
        switch event {
        case "pane_output":
            // A pane we don't know yet (spawned from the CLI or an agent).
            if rowIndex(of: pane) == nil { refresh() }
        case "pane_bell":
            if pane != selectedPane {
                bells.insert(pane)
                reloadRow(pane)
            }
        case "pane_exit":
            exited.insert(pane)
            reloadRow(pane)
            if pane == selectedPane {
                statusLabel.stringValue = "pane \(pane) — exited"
            }
        case "task_status":
            let id = (obj["task"] as? NSNumber)?.uint64Value ?? 0
            let status = obj["status"] as? String ?? "working"
            if var t = tasks[id] {
                t.status = status
                tasks[id] = t
                if let idx = rowIndex(of: t.pane) {
                    table.reloadData(forRowIndexes: [idx], columnIndexes: [0])
                }
            } else {
                // A task we don't know yet (created from the CLI).
                refresh()
            }
            // The cmux notification ring: an agent needs you.
            if status == "needs_attention", tasks[id]?.pane != selectedPane {
                NSApp.requestUserAttention(.informationalRequest)
            }
        case "task_removed":
            let id = (obj["task"] as? NSNumber)?.uint64Value ?? 0
            tasks.removeValue(forKey: id)
            refresh()
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
        let web = WKWebView(frame: content.bounds)
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
            statusLabel.stringValue = "web \(pane) — \(webView.title ?? "")  ·  \(webView.url?.absoluteString ?? "")"
        }
    }

    // MARK: Window focus

    func windowDidBecomeKey(_ notification: Notification) {
        runtime.setFocus(true)
        if let pane = selectedPane, let view = surfaces[pane] {
            window.makeFirstResponder(view)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        runtime.setFocus(false)
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
        var sid = currentSession
        let spawn: () -> Void = { [weak self] in
            guard let self else { return }
            self.client.send(["cmd": "spawn-pane", "session": sid,
                              "argv": [shellPath, "-i"], "cwd": NSHomeDirectory()]) { resp in
                let pane = (resp["pane"] as? NSNumber)?.uint64Value
                self.refresh()
                if let pane {
                    // Select once the sidebar knows the row.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let idx = self.rowIndex(of: pane) {
                            self.table.selectRowIndexes([idx], byExtendingSelection: false)
                        }
                    }
                }
            }
        }
        if rows.isEmpty {
            client.send(["cmd": "create-session", "title": "main"]) { resp in
                sid = (resp["session"] as? NSNumber)?.uint64Value ?? 1
                spawn()
            }
        } else {
            spawn()
        }
    }

    @objc func addTask() {
        let alert = NSAlert()
        alert.messageText = "New agent task"
        alert.informativeText = "Runs the agent in its own git worktree + branch."

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 56))
        stack.orientation = .vertical
        stack.spacing = 8
        let desc = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        desc.placeholderString = "what should the agent do?"
        let repo = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        repo.placeholderString = "repository path"
        repo.stringValue = UserDefaults.standard.string(forKey: "zide.lastRepo") ?? ""
        stack.addArrangedSubview(desc)
        stack.addArrangedSubview(repo)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = desc

        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              !desc.stringValue.isEmpty, !repo.stringValue.isEmpty else { return }
        UserDefaults.standard.set(repo.stringValue, forKey: "zide.lastRepo")

        client.send(["cmd": "task-create",
                     "repo": repo.stringValue,
                     "description": desc.stringValue]) { [weak self] resp in
            guard let self else { return }
            if resp["ok"] as? Bool != true {
                self.statusLabel.stringValue = "task failed: \(resp["error"] as? String ?? "?")"
                return
            }
            let pane = (resp["pane"] as? NSNumber)?.uint64Value
            self.refresh()
            if let pane {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let idx = self.rowIndex(of: pane) {
                        self.table.selectRowIndexes([idx], byExtendingSelection: false)
                    }
                }
            }
        }
    }

    @objc func addWeb() {
        let alert = NSAlert()
        alert.messageText = "Open browser pane"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = "https://ziglang.org"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        client.send(["cmd": "browser-open", "session": currentSession, "url": field.stringValue])
    }
}
