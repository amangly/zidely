// The zide window: native AppKit chrome styled like cmux vertical tabs.
// Sidebar + host are view-model driven; socket wiring fills the model
// (or ZIDE_UI_DEMO=1 serves fixtures). Panes still live in the daemon.

import AppKit
import WebKit
import GhosttyKit

/// Titlebar toolbar aligned to the window's two columns: the icon
/// cluster spreads across what remains of the sidebar column after the
/// traffic lights, and the title starts at the terminal column's edge.
final class TitlebarToolbar: NSView {
    var icons: [NSButton] = []
    let folder = NSImageView()
    var title: NSTextField?

    override func layout() {
        super.layout()
        // Accessories sit right of the traffic lights; absolute column
        // alignment needs this view's window-x offset.
        let originX = convert(NSPoint.zero, to: nil).x
        let iconEnd = ShellTheme.sidebarWidth - 6
        let avail = max(0, iconEnd - originX)
        let step = avail / CGFloat(max(icons.count, 1))
        for (i, b) in icons.enumerated() {
            let cx = step * (CGFloat(i) + 0.5)
            b.frame = NSRect(x: cx - 14, y: (bounds.height - 28) / 2, width: 28, height: 28)
        }
        let titleX = ShellTheme.sidebarWidth - originX + 16
        folder.frame = NSRect(x: titleX, y: (bounds.height - 16) / 2, width: 16, height: 16)
        title?.frame = NSRect(
            x: titleX + 24, y: (bounds.height - 17) / 2,
            width: max(0, bounds.width - titleX - 32), height: 17)
    }
}

final class ShellController: NSObject, SidebarViewDelegate, WorkspaceHostViewDelegate, NotificationPanelDelegate, WorkspaceSwitcherDelegate, CommandPaletteDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let client: SocketClient
    let runtime: GhosttyRuntime
    let zideBin: String
    let socketPath: String
    let demoMode: Bool

    let window: NSWindow
    let sidebar = SidebarView(frame: .zero)
    let rightSidebar = RightSidebarView(frame: .zero)
    let host = WorkspaceHostView(frame: .zero)
    let notifPanel = NotificationPanelView(frame: .zero)
    let switcher = WorkspaceSwitcherView(frame: .zero)
    let palette = CommandPaletteView(frame: .zero)
    let statusLabel = NSTextField(labelWithString: "")
    let viewModel: ShellViewModel
    var notifPanelVisible = false

    var exited: Set<UInt64> = []
    var bells: Set<UInt64> = []
    var surfaces: [UInt64: TerminalSurfaceView] = [:]
    var webviews: [UInt64: WKWebView] = [:]
    /// Live browser page titles for sidebar rows (pane id → title).
    var browserTitles: [UInt64: String] = [:]
    var paneOfWebView: [ObjectIdentifier: UInt64] = [:]
    /// KVO on each webview's url/title/nav state — live browser chrome.
    var webObservations: [UInt64: [NSKeyValueObservation]] = [:]
    /// Failed-navigation URL per pane: the in-page error view loads as
    /// about:blank, but the omnibar must keep showing where the user
    /// was trying to go.
    var browserErrorURL: [UInt64: String] = [:]
    var selectedPane: UInt64?
    /// Last live session list, for spawn-into-current-session.
    var sessionIds: [UInt64] = []
    /// Which session each daemon pane lives in — splits and extra tabs
    /// spawn their pane into the same session as the workspace.
    var paneSession: [UInt64: UInt64] = [:]
    /// Panes we asked the daemon to kill: their pane_exit triggers the
    /// remove-pane that drops them from the session for good.
    var pendingKill: Set<UInt64> = []
    /// Live OSC terminal titles per pane (shell prompts, running
    /// command) — what pane tabs display, cmux-style.
    var paneTitles: [UInt64: String] = [:]
    /// Panes whose title came from OSC 0/2 — authoritative, never
    /// overwritten by the meta-derived fallback.
    var oscTitled: Set<UInt64> = []
    /// Panes whose foreground process is a known AI agent — their rows
    /// light up and their bells read as "agent needs you".
    var agentPanes: Set<UInt64> = []
    /// Live activity line per agent pane (the pane's last screen line),
    /// so every applyLive rebuild keeps the cmux row treatment.
    var agentActivity: [UInt64: String?] = [:]
    static let agentNames: Set<String> = [
        "claude", "codex", "aider", "gemini", "goose", "amp", "opencode", "cursor-agent",
    ]
    var metaTimer: Timer?
    // Titlebar chrome (cmux-style: the titlebar is the toolbar).
    let bellButton = NSButton()
    let titlebarTitle = NSTextField(labelWithString: "")
    /// With terminal transparency on, the titlebar band and status
    /// strip tint with the terminal's own background color + opacity —
    /// otherwise they read as mismatched solid slabs.
    let topBand = NSView()
    let bottomBand = NSView()
    /// The daemon's notice history is seeded into the panel exactly
    /// once per launch, after the first refresh.
    var noticesSeeded = false
    static let noticeSeqKey = "zide.noticeSeq"
    /// Split layouts live in app memory; the daemon stashes them
    /// (shell-state) so a relaunch rebuilds splits over live panes.
    var shellStateRestored = false
    var shellStateTimer: Timer?

    init(client: SocketClient, runtime: GhosttyRuntime, zideBin: String, socketPath: String, demoMode: Bool = false) {
        self.client = client
        self.runtime = runtime
        self.zideBin = zideBin
        self.socketPath = socketPath
        self.demoMode = demoMode
        self.viewModel = demoMode ? .demo() : ShellViewModel()
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        buildUI()
        buildMenu()
        window.delegate = self
        client.onEvent = { [weak self] in self?.handleEvent($0) }
        BrowserDownloadManager.shared.onEvent = { [weak self] filename, message, file in
            guard let self else { return }
            self.statusLabel.stringValue = "\(filename) — \(message)"
            // Only terminal states earn a notification; per-download
            // progress belongs in the status strip.
            if file != nil || message.hasPrefix("download failed") {
                self.pushNotification(
                    workspaceId: self.viewModel.selectedWorkspaceId ?? "",
                    title: "download",
                    subtitle: "\(filename): \(message)",
                    body: file?.path ?? "")
            }
        }
        if !demoMode {
            client.send(["cmd": "host-register"])
            refresh(selectFirst: true)
            // cwd/branch/ports drift without events (cd, servers starting);
            // panes-meta is poll-based by design.
            metaTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                self?.refreshPaneMeta()
            }
        } else {
            reloadChrome()
            statusLabel.stringValue = "UI demo — ZIDE_UI_DEMO=1  ·  chrome only, not wired"
        }
    }

    // MARK: UI

    func buildUI() {
        // Title kept for Mission Control / app switcher but hidden from
        // the titlebar — cmux chrome has no title text.
        window.title = "zide"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        buildTitlebar()
        window.minSize = NSSize(width: 860, height: 520)

        // Terminal transparency follows the user's ghostty config
        // (background-opacity < 1): non-opaque window + the config's
        // background blur, exactly like ghostty's own window setup.
        if runtime.backgroundOpacity < 1 {
            window.isOpaque = false
            // Ghostty uses near-clear white rather than .clear — it
            // matches Terminal.app's transparent look more closely.
            window.backgroundColor = .white.withAlphaComponent(0.001)
            runtime.applyBackgroundBlur(to: window)
            host.transparentBackground = true
            let band = runtime.backgroundColor
                .withAlphaComponent(runtime.backgroundOpacity)
            for v in [topBand, bottomBand] {
                v.wantsLayer = true
                v.layer?.backgroundColor = band.cgColor
            }
            sidebar.applyTint(band)
        } else {
            topBand.isHidden = true
            bottomBand.isHidden = true
        }
        let root = window.contentView!
        let W = root.bounds.width
        let H = root.bounds.height
        let sw = ShellTheme.sidebarWidth

        sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: H)
        sidebar.autoresizingMask = [.height]
        sidebar.delegate = self
        root.addSubview(sidebar)

        let top = ShellTheme.titlebarClearance

        root.addSubview(topBand)

        // No footer strip: content runs to the bottom edge — the
        // sidebar rows and titlebar already carry the context, and
        // transient messages surface in the notification panel.
        host.frame = NSRect(x: sw + 1, y: 0, width: W - sw - 1, height: H - top)
        host.autoresizingMask = [.width, .height]
        host.delegate = self
        root.addSubview(host)

        rightSidebar.frame = NSRect(x: W - ShellTheme.rightSidebarWidth, y: 0, width: ShellTheme.rightSidebarWidth, height: H)
        rightSidebar.autoresizingMask = [.height, .minXMargin]
        rightSidebar.isHidden = true
        root.addSubview(rightSidebar)

        notifPanel.frame = NSRect(
            x: W - ShellTheme.notifPanelWidth - 20,
            y: H - ShellTheme.notifPanelHeight - 40,
            width: ShellTheme.notifPanelWidth,
            height: ShellTheme.notifPanelHeight)
        notifPanel.autoresizingMask = [.minXMargin, .minYMargin]
        notifPanel.delegate = self
        notifPanel.isHidden = true
        root.addSubview(notifPanel)

        switcher.frame = root.bounds
        switcher.autoresizingMask = [.width, .height]
        switcher.delegate = self
        switcher.isHidden = true
        root.addSubview(switcher)

        palette.frame = root.bounds
        palette.autoresizingMask = [.width, .height]
        palette.delegate = self
        palette.isHidden = true
        root.addSubview(palette)

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// cmux-style titlebar toolbar: the traffic lights and the icon
    /// cluster fill the sidebar column (evenly spread, larger glyphs),
    /// and the workspace title starts at the terminal column's left
    /// edge. All default AppKit (titlebar accessory + borderless
    /// template buttons).
    func buildTitlebar() {
        let bar = TitlebarToolbar()

        func glyph(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            img.isTemplate = true
            let b = NSButton(image: img, target: self, action: action)
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            bar.addSubview(b)
            return b
        }

        bellButton.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")
        bellButton.isBordered = false
        bellButton.bezelStyle = .accessoryBarAction
        bellButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        bellButton.contentTintColor = .secondaryLabelColor
        bellButton.target = self
        bellButton.action = #selector(toggleNotifications)
        bellButton.toolTip = "Notifications (⌘⇧I)"
        bar.addSubview(bellButton)

        bar.icons = [
            glyph("sidebar.left", "Toggle sidebar (⌘B)", #selector(toggleSidebar)),
            bellButton,
            glyph("plus", "New terminal · browser", #selector(showNewMenu(_:))),
            glyph("chevron.left", "Previous workspace", #selector(prevWorkspace)),
            glyph("chevron.right", "Next workspace", #selector(nextWorkspace)),
        ]

        bar.folder.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        bar.folder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: ShellTheme.iconSm, weight: .regular)
        bar.folder.contentTintColor = .tertiaryLabelColor
        bar.addSubview(bar.folder)
        titlebarTitle.font = ShellTheme.uiFontBold
        titlebarTitle.textColor = .labelColor
        titlebarTitle.lineBreakMode = .byTruncatingTail
        bar.addSubview(titlebarTitle)
        bar.title = titlebarTitle

        bar.frame = NSRect(x: 0, y: 0, width: 1200, height: 30)
        bar.autoresizingMask = [.width]
        let vc = NSTitlebarAccessoryViewController()
        vc.view = bar
        vc.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(vc)
    }

    @objc func showNewMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Terminal", action: #selector(addTerm), keyEquivalent: "")
        menu.addItem(withTitle: "New Browser Pane…", action: #selector(addWeb), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    /// Titlebar state that follows the view model: bell badge when
    /// anything is unread, selected workspace title next to it.
    func updateTitlebar() {
        let unread = !viewModel.unreadNotifications.isEmpty
        bellButton.image = NSImage(
            systemSymbolName: unread ? "bell.badge" : "bell",
            accessibilityDescription: "Notifications")
        bellButton.contentTintColor = unread ? ShellTheme.accent : .secondaryLabelColor
        titlebarTitle.stringValue = viewModel.selectedWorkspace?.title ?? ""
    }

    func reloadChrome() {
        sidebar.isHidden = !viewModel.sidebarVisible
        sidebar.apply(
            items: viewModel.items,
            selectedWorkspaceId: viewModel.selectedWorkspaceId,
            collapsedGroups: viewModel.collapsedGroups)
        showSelectedWorkspace()
        layoutHost()
        updateTitlebar()
    }

    func showSelectedWorkspace() {
        let ws = viewModel.selectedWorkspace
        layoutHost()
        host.show(workspace: ws, focusedPaneId: viewModel.focusedPaneId)
        if let ws {
            selectedPane = primaryPaneId(of: ws)
            let unread = viewModel.unreadNotifications.count
            var line = statusLine(for: ws)
            if unread > 0 { line += "  ·  \(unread) unread" }
            statusLabel.stringValue = line
        } else {
            selectedPane = nil
            statusLabel.stringValue = demoMode
                ? "UI demo — no workspace selected"
                : "no workspace selected — ⌘T opens a terminal  ·  \(socketPath)"
        }
    }

    func layoutHost() {
        let root = window.contentView!
        let left = viewModel.sidebarVisible ? ShellTheme.sidebarWidth : 0
        let right = viewModel.rightSidebarVisible ? ShellTheme.rightSidebarWidth : 0
        let top = ShellTheme.titlebarClearance
        sidebar.isHidden = !viewModel.sidebarVisible
        rightSidebar.isHidden = !viewModel.rightSidebarVisible
        sidebar.frame = NSRect(x: 0, y: 0, width: ShellTheme.sidebarWidth, height: root.bounds.height)
        rightSidebar.frame = NSRect(
            x: root.bounds.width - ShellTheme.rightSidebarWidth, y: 0,
            width: ShellTheme.rightSidebarWidth, height: root.bounds.height)
        let frame = NSRect(
            x: left + (left > 0 ? 1 : 0), y: 0,
            width: root.bounds.width - left - right - (left > 0 ? 1 : 0) - (right > 0 ? 1 : 0),
            height: root.bounds.height - top)
        host.frame = frame
        topBand.frame = NSRect(
            x: frame.origin.x, y: root.bounds.height - top,
            width: frame.width, height: top)
        notifPanel.frame = NSRect(
            x: root.bounds.width - ShellTheme.notifPanelWidth - 20
                - (viewModel.rightSidebarVisible ? ShellTheme.rightSidebarWidth : 0),
            y: root.bounds.height - ShellTheme.notifPanelHeight - 40,
            width: ShellTheme.notifPanelWidth,
            height: ShellTheme.notifPanelHeight)
        switcher.frame = root.bounds
        palette.frame = root.bounds
    }

    func primaryPaneId(of ws: ShellWorkspace) -> UInt64? {
        let leaves = ws.layout.leaves
        let node = leaves.first { $0.id == viewModel.focusedPaneId } ?? leaves.first
        guard let node else { return nil }
        return (node.surfaces.first { $0.id == node.selectedSurfaceId } ?? node.surfaces.first)?.paneId
    }

    func statusLine(for ws: ShellWorkspace) -> String {
        var parts = [ws.title]
        if let cwd = ws.cwd { parts.append(cwd) }
        if let branch = ws.branch {
            parts.append(ws.branchDirty ? "\(branch)*" : branch)
        }
        if !ws.ports.isEmpty {
            parts.append(":" + ws.ports.map(String.init).joined(separator: ","))
        }
        if demoMode {
            parts.append("demo")
        } else {
            parts.append(socketPath)
        }
        return parts.joined(separator: "  ·  ")
    }

    func sidebarDidSelectWorkspace(_ id: String) {
        viewModel.selectWorkspace(id)
        reloadChrome()
        if let pane = selectedPane, let view = surfaces[pane] {
            window.makeFirstResponder(view)
        }
    }

    func sidebarDidToggleGroup(_ id: String) {
        viewModel.toggleGroup(id)
        reloadChrome()
    }

    func sidebarDidRequestNewInGroup(_ id: String) {
        if demoMode {
            viewModel.addWorkspace(inGroup: id)
            reloadChrome()
            statusLabel.stringValue = "demo — added workspace in \(id)"
            return
        }
        // Live: new terminal in the default session for now.
        addTerm()
    }

    func sidebarDidTogglePin(_ id: String) {
        viewModel.togglePin(id)
        reloadChrome()
    }

    func sidebarDidRename(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Rename workspace"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: ShellTheme.alertFieldHeight))
        field.stringValue = viewModel.workspace(id: id)?.title ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        viewModel.renameWorkspace(id, title: field.stringValue)
        // Workspace titles are session titles — rename daemon-side or
        // the next refresh reverts it.
        if !demoMode, let sid = viewModel.workspace(id: id)?.sessionId {
            client.send(["cmd": "rename-session", "session": sid, "title": field.stringValue])
        }
        reloadChrome()
    }

    func sidebarDidNavigateWorkspaces(delta: Int) {
        viewModel.selectAdjacentWorkspace(delta: delta)
        reloadChrome()
    }

    func workspaceHost(_ host: WorkspaceHostView, installPanel surface: ShellSurface, into slot: NSView) {
        if demoMode || surface.paneId == nil {
            return
        }
        switch surface.kind {
        case .terminal:
            // A pane known to be dead EOFs the attach instantly, which
            // ghostty renders as a scary "failed to launch" banner —
            // the placeholder is the honest UI.
            if exited.contains(surface.paneId!) { return }
            installTerminal(pane: surface.paneId!, into: slot, host: host)
        case .browser:
            if let web = webviews[surface.paneId!] {
                host.setLiveView(web, in: slot)
                // Claim keyboard focus only when this panel is the
                // focused leaf — a workspace holds several panels now,
                // and every chrome rebuild installs all of them.
                if viewModel.focusedSurface?.id == surface.id {
                    window.makeFirstResponder(web)
                }
            }
        case .placeholder:
            break
        }
    }

    func workspaceHost(_ host: WorkspaceHostView, didChangeSplitRatio ratio: CGFloat, path: String) {
        guard let wsId = viewModel.selectedWorkspaceId else { return }
        viewModel.setSplitRatio(workspaceId: wsId, path: path, ratio: ratio)
        if let ws = viewModel.selectedWorkspace { host.updateLayout(ws.layout) }
        pushShellState()
    }

    func workspaceHost(_ host: WorkspaceHostView, didFocusPane paneId: String) {
        // Bookkeeping only: focus changes ride the click itself — the
        // clicked view (terminal, webview, omnibar) becomes first
        // responder naturally. Forcing it here killed omnibar editing.
        viewModel.focusPane(paneId)
        guard let ws = viewModel.selectedWorkspace,
              let node = ws.layout.leaves.first(where: { $0.id == paneId }),
              let surface = node.surfaces.first(where: { $0.id == node.selectedSurfaceId })
                  ?? node.surfaces.first,
              let pane = surface.paneId else { return }
        selectedPane = pane
    }

    func workspaceHost(_ host: WorkspaceHostView, browserURLForPane paneId: UInt64) -> String? {
        webviews[paneId]?.url?.absoluteString
    }

    func workspaceHost(_ host: WorkspaceHostView, navigateBrowser paneId: UInt64, to url: String) {
        guard let u = URL(string: url) else { return }
        // Omnibar navigations are "typed" in history terms — they
        // dominate future suggestion ranking, like a real omnibox.
        BrowserHistoryStore.shared.recordTyped(url: u)
        if let web = webviews[paneId] {
            web.load(URLRequest(url: u))
        } else if !demoMode {
            ensureWebView(pane: paneId, url: url)
            reloadChrome()
        }
        if !demoMode {
            client.send(["cmd": "browser-update", "pane": paneId, "url": url, "title": "", "loading": true])
        }
        statusLabel.stringValue = "web \(paneId) → \(url)"
    }

    func workspaceHost(_ host: WorkspaceHostView, browserWebViewForPane paneId: UInt64) -> WKWebView? {
        webviews[paneId]
    }

    func workspaceHost(_ host: WorkspaceHostView, suggestionsFor query: String) -> [BrowserSuggestion] {
        BrowserHistoryStore.shared.suggestions(for: query)
    }

    func installTerminal(pane: UInt64, into slot: NSView, host: WorkspaceHostView) {
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
                self.refresh()
            }
            view.onTitleChange = { [weak self] title in
                self?.paneTitleChanged(pane, title: title)
            }
            surfaces[pane] = view
        }
        bells.remove(pane)
        host.setLiveView(view, in: slot)
        // installPanel fires while the pane host is still detached (the
        // host view is added to the window after makePaneHost returns),
        // so focusing now silently fails — defer one runloop tick. Only
        // the focused leaf claims keyboard focus: rebuilds install every
        // panel of the workspace.
        let surfaceId = "pane-\(pane)"
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, view.window != nil,
                  self.viewModel.focusedSurface?.id == surfaceId else { return }
            self.window.makeFirstResponder(view)
        }
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
        shellMenu.addItem(withTitle: "New Terminal", action: #selector(addTerm), keyEquivalent: "t")
        shellMenu.addItem(withTitle: "New Session", action: #selector(addSession), keyEquivalent: "n")
        let browserItem = NSMenuItem(title: "New Browser Pane", action: #selector(addWeb), keyEquivalent: "b")
        browserItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(browserItem)
        shellMenu.addItem(NSMenuItem.separator())
        shellMenu.addItem(withTitle: "Split Right", action: #selector(splitRight), keyEquivalent: "d")
        let splitDown = NSMenuItem(title: "Split Down", action: #selector(splitDown), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitDown)
        shellMenu.addItem(NSMenuItem.separator())
        shellMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        let rightSide = NSMenuItem(title: "Toggle Right Sidebar", action: #selector(toggleRightSidebar), keyEquivalent: "b")
        rightSide.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(rightSide)
        shellMenu.addItem(withTitle: "Go to Workspace…", action: #selector(showSwitcher), keyEquivalent: "p")
        let paletteItem = NSMenuItem(title: "Command Palette…", action: #selector(showPalette), keyEquivalent: "p")
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(paletteItem)
        let renameItem = NSMenuItem(title: "Rename Workspace…", action: #selector(renameSelected), keyEquivalent: "r")
        renameItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(renameItem)
        let closeWs = NSMenuItem(title: "Close Workspace", action: #selector(closeWorkspace), keyEquivalent: "w")
        closeWs.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(closeWs)
        shellMenu.addItem(withTitle: "Close Surface", action: #selector(closeSurface), keyEquivalent: "w")
        shellMenu.addItem(withTitle: "Open Location", action: #selector(openLocation), keyEquivalent: "l")
        // Browser page zoom; in terminal panes ghostty keeps these
        // keys (font size) since they're not in shellShortcuts.
        shellMenu.addItem(withTitle: "Zoom In", action: #selector(zoomInBrowser), keyEquivalent: "+")
        shellMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOutBrowser), keyEquivalent: "-")
        shellMenu.addItem(withTitle: "Actual Size", action: #selector(zoomActualBrowser), keyEquivalent: "0")
        let focusNext = NSMenuItem(title: "Focus Next Pane", action: #selector(focusNextPane), keyEquivalent: "]")
        focusNext.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(focusNext)
        let focusPrev = NSMenuItem(title: "Focus Previous Pane", action: #selector(focusPrevPane), keyEquivalent: "[")
        focusPrev.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(focusPrev)
        let newGroup = NSMenuItem(title: "New Empty Group", action: #selector(newEmptyGroup), keyEquivalent: "g")
        newGroup.keyEquivalentModifierMask = [.command, .control]
        shellMenu.addItem(newGroup)
        let collapse = NSMenuItem(title: "Collapse Focused Group", action: #selector(collapseFocusedGroup), keyEquivalent: ".")
        collapse.keyEquivalentModifierMask = [.command, .control]
        shellMenu.addItem(collapse)
        let notifItem = NSMenuItem(title: "Show Notifications", action: #selector(toggleNotifications), keyEquivalent: "i")
        notifItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(notifItem)
        let unreadItem = NSMenuItem(title: "Jump to Unread", action: #selector(jumpUnread), keyEquivalent: "u")
        unreadItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(unreadItem)
        shellMenu.addItem(NSMenuItem.separator())
        let prev = NSMenuItem(title: "Previous Workspace", action: #selector(prevWorkspace), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .control]
        shellMenu.addItem(prev)
        let next = NSMenuItem(title: "Next Workspace", action: #selector(nextWorkspace), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .control]
        shellMenu.addItem(next)
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Workspace \(i)",
                action: #selector(jumpWorkspace(_:)),
                keyEquivalent: "\(i)")
            item.tag = i - 1
            shellMenu.addItem(item)
        }
        shellMenu.items.forEach { $0.target = self }
        shellItem.submenu = shellMenu

        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = menu
    }

    @objc func toggleSidebar() {
        viewModel.sidebarVisible.toggle()
        reloadChrome()
    }

    @objc func toggleRightSidebar() {
        viewModel.rightSidebarVisible.toggle()
        layoutHost()
    }

    @objc func showSwitcher() {
        let list = viewModel.workspaces(matching: "")
        switcher.present(workspaces: list)
        window.contentView?.addSubview(switcher, positioned: .above, relativeTo: nil)
    }

    @objc func showPalette() {
        palette.present([
            .init(id: "toggle-sidebar", title: "Toggle Sidebar", shortcut: "⌘B"),
            .init(id: "toggle-right", title: "Toggle Right Sidebar", shortcut: "⌘⌥B"),
            .init(id: "goto", title: "Go to Workspace…", shortcut: "⌘P"),
            .init(id: "split-right", title: "Split Right", shortcut: "⌘D"),
            .init(id: "split-down", title: "Split Down", shortcut: "⌘⇧D"),
            .init(id: "close-surface", title: "Close Surface", shortcut: "⌘W"),
            .init(id: "close-workspace", title: "Close Workspace", shortcut: "⌘⇧W"),
            .init(id: "notifications", title: "Show Notifications", shortcut: "⌘⇧I"),
            .init(id: "jump-unread", title: "Jump to Unread", shortcut: "⌘⇧U"),
            .init(id: "new-group", title: "New Empty Group", shortcut: "⌃⌘G"),
            .init(id: "rename", title: "Rename Workspace…", shortcut: "⌘⇧R"),
            .init(id: "new-term", title: "New Terminal", shortcut: "⌘T"),
        ])
        window.contentView?.addSubview(palette, positioned: .above, relativeTo: nil)
    }

    @objc func closeWorkspace() {
        if closeAuxiliaryKeyWindow() { return }
        if !demoMode, let ws = viewModel.selectedWorkspace {
            // Close daemon-side or the workspace resurrects as a row on
            // the next refresh: terminals get their child killed,
            // browser panels are core state removed, and the session
            // itself goes once its panes have drained (remove-session).
            for surf in ws.layout.leaves.flatMap(\.surfaces) {
                guard let pane = surf.paneId else { continue }
                switch surf.kind {
                case .terminal: killPane(pane)
                case .browser: closeBrowserPane(pane)
                case .placeholder: break
                }
            }
            if let sid = ws.sessionId {
                pendingSessionRemove.insert(sid)
                maybeRemoveEmptySessions()
            }
        }
        if viewModel.closeSelectedWorkspace() {
            reloadChrome()
            pushShellState()
        } else {
            statusLabel.stringValue = "no workspace to close"
        }
    }

    @objc func closeSurface() {
        if closeAuxiliaryKeyWindow() { return }
        guard let ws = viewModel.selectedWorkspace else {
            statusLabel.stringValue = "no surface to close"
            return
        }
        // Closing the workspace's last panel closes the workspace —
        // cmux semantics; no empty husk rows.
        if ws.layout.leaves.flatMap(\.surfaces).count <= 1 {
            closeWorkspace()
            return
        }
        if !demoMode {
            let leaves = ws.layout.leaves
            let node = leaves.first { $0.id == viewModel.focusedPaneId } ?? leaves.first
            if let node,
               let surf = node.surfaces.first(where: { $0.id == node.selectedSurfaceId })
                   ?? node.surfaces.first,
               let pane = surf.paneId {
                switch surf.kind {
                case .terminal: killPane(pane)
                case .browser: closeBrowserPane(pane)
                case .placeholder: break
                }
            }
        }
        if viewModel.closeFocusedPanel() {
            reloadChrome()
            pushShellState()
        } else {
            statusLabel.stringValue = "no surface to close"
        }
    }

    /// Sessions queued for removal once their terminal panes drain —
    /// remove-session refuses while panes are still alive.
    var pendingSessionRemove: Set<UInt64> = []
    func maybeRemoveEmptySessions() {
        guard !demoMode, !pendingSessionRemove.isEmpty else { return }
        client.send(["cmd": "list-sessions"]) { [weak self] resp in
            guard let self, let sessions = resp["sessions"] as? [[String: Any]] else { return }
            for s in sessions {
                let sid = (s["id"] as? NSNumber)?.uint64Value ?? 0
                guard self.pendingSessionRemove.contains(sid),
                      (s["panes"] as? [NSNumber] ?? []).isEmpty else { continue }
                self.pendingSessionRemove.remove(sid)
                self.client.send(["cmd": "remove-session", "session": sid]) { _ in
                    self.refresh()
                }
            }
        }
    }

    /// ⌘W (and ⌘⇧W) pressed while a popup or other auxiliary window is
    /// key must close THAT window — never reach into the main window
    /// and kill its selected pane. (An OAuth popup's ⌘W once killed
    /// the user's terminal.)
    private func closeAuxiliaryKeyWindow() -> Bool {
        guard let key = NSApp.keyWindow, key !== window else { return false }
        key.performClose(nil)
        return true
    }

    @objc func focusNextPane() {
        viewModel.focusAdjacentPane(delta: 1)
        reloadChrome()
    }

    @objc func focusPrevPane() {
        viewModel.focusAdjacentPane(delta: -1)
        reloadChrome()
    }

    @objc func renameSelected() {
        guard let id = viewModel.selectedWorkspaceId else { return }
        sidebarDidRename(id)
    }

    @objc func newEmptyGroup() {
        viewModel.createEmptyGroup()
        reloadChrome()
    }

    @objc func collapseFocusedGroup() {
        viewModel.collapseFocusedGroup()
        reloadChrome()
    }

    @objc func splitRight() { spawnIntoSelected { self.viewModel.graftSplit(workspaceId: $0, orientation: .horizontal, paneId: $1) } }

    @objc func splitDown() { spawnIntoSelected { self.viewModel.graftSplit(workspaceId: $0, orientation: .vertical, paneId: $1) } }

    /// Splits and extra tabs are real daemon panes: spawn one into the
    /// selected workspace's session, then graft it into the layout.
    /// applyLive excludes grafted panes from standalone rows.
    private func spawnIntoSelected(graft: @escaping (String, UInt64) -> Void) {
        if demoMode {
            viewModel.splitSelected(orientation: .horizontal)
            reloadChrome()
            return
        }
        guard let ws = viewModel.selectedWorkspace else {
            statusLabel.stringValue = "no workspace selected"
            return
        }
        let wsId = ws.id
        let sid = ws.sessionId
            ?? viewModel.daemonPaneIds(of: ws.layout).first.flatMap { paneSession[$0] }
            ?? currentSession
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        client.send(["cmd": "spawn-pane", "session": sid,
                     "argv": [shellPath, "-i"], "cwd": NSHomeDirectory()]) { [weak self] resp in
            guard let self, let pane = (resp["pane"] as? NSNumber)?.uint64Value else { return }
            self.paneSession[pane] = sid
            graft(wsId, pane)
            self.reloadChrome()
            self.pushShellState()
        }
    }

    @objc func toggleNotifications() {
        if notifPanelVisible {
            notifPanel.isHidden = true
            notifPanelVisible = false
            return
        }
        notifPanel.show(viewModel.notifications)
        notifPanelVisible = true
        window.contentView?.addSubview(notifPanel, positioned: .above, relativeTo: nil)
    }

    @objc func jumpUnread() {
        if viewModel.jumpToLatestUnread() != nil {
            reloadChrome()
        } else {
            statusLabel.stringValue = "no unread notifications"
        }
    }

    @objc func prevWorkspace() {
        viewModel.selectAdjacentWorkspace(delta: -1)
        reloadChrome()
    }

    @objc func nextWorkspace() {
        viewModel.selectAdjacentWorkspace(delta: 1)
        reloadChrome()
    }

    @objc func jumpWorkspace(_ sender: NSMenuItem) {
        viewModel.selectWorkspaceIndex(sender.tag)
        reloadChrome()
    }

    // MARK: Notification panel

    func notificationPanelDidSelect(_ notification: ShellNotification) {
        viewModel.markNotificationRead(notification.id)
        viewModel.selectWorkspace(notification.workspaceId)
        notifPanel.isHidden = true
        notifPanelVisible = false
        reloadChrome()
    }

    func notificationPanelDidClose() {
        notifPanelVisible = false
    }

    // MARK: Workspace switcher

    func workspaceSwitcherDidPick(_ id: String) {
        viewModel.selectWorkspace(id)
        reloadChrome()
    }

    func workspaceSwitcherDidCancel() {}

    // MARK: Command palette

    func commandPaletteDidRun(_ id: String) {
        switch id {
        case "toggle-sidebar": toggleSidebar()
        case "toggle-right": toggleRightSidebar()
        case "goto": showSwitcher()
        case "split-right": splitRight()
        case "split-down": splitDown()
        case "close-surface": closeSurface()
        case "close-workspace": closeWorkspace()
        case "notifications": toggleNotifications()
        case "jump-unread": jumpUnread()
        case "new-group": newEmptyGroup()
        case "rename": renameSelected()
        case "new-term": addTerm()
        default: break
        }
    }

    func commandPaletteDidCancel() {}

    // MARK: Live data

    func refresh(selectFirst: Bool = false) {
        if demoMode { return }
        refreshSessions(selectFirst: selectFirst)
    }

    private func refreshSessions(selectFirst: Bool) {
        client.send(["cmd": "list-sessions"]) { [weak self] resp in
            guard let self, let sessions = resp["sessions"] as? [[String: Any]] else { return }
            var parsed: [(id: UInt64, title: String, panes: [UInt64], browsers: [UInt64], exited: [UInt64])] = []
            self.sessionIds = []
            self.paneSession.removeAll()
            for s in sessions {
                let sid = (s["id"] as? NSNumber)?.uint64Value ?? 0
                self.sessionIds.append(sid)
                let panes = (s["panes"] as? [NSNumber] ?? []).map(\.uint64Value)
                let browsers = (s["browsers"] as? [NSNumber] ?? []).map(\.uint64Value)
                let ex = (s["exited"] as? [NSNumber] ?? []).map(\.uint64Value)
                for e in ex { self.exited.insert(e) }
                for p in panes + browsers { self.paneSession[p] = sid }
                parsed.append((sid, s["title"] as? String ?? "", panes, browsers, ex))
            }
            // Sweep panes that exited while nobody was watching (their
            // pane_exit predates this client) — close-on-exit semantics.
            for s in parsed {
                for e in s.exited {
                    self.client.send(["cmd": "remove-pane", "pane": e])
                }
            }
            self.viewModel.applyLive(
                sessions: parsed, bells: self.bells, exited: self.exited,
                browserTitles: self.browserTitles, paneTitles: self.paneTitles,
                agentActivity: self.agentActivity)
            // Viewing is reading: the selected workspace never shows an
            // unread badge for events that happened in front of you.
            if let sid = self.viewModel.selectedWorkspaceId {
                self.viewModel.markWorkspaceRead(sid)
            }
            if selectFirst, self.viewModel.selectedWorkspaceId == nil {
                self.viewModel.selectedWorkspaceId = self.viewModel.items.compactMap {
                    if case let .workspace(w) = $0 { return w.id }
                    return nil
                }.first
            }
            self.reloadChrome()
            self.refreshPaneMeta()
            if !self.noticesSeeded {
                self.noticesSeeded = true
                self.fetchNoticeHistory()
            }
            if !self.shellStateRestored {
                self.restoreShellState()
            }
            // zide is a terminal first: when the last shell dies (exit,
            // crash, ⌘W), the app must not strand the user in a
            // browser-only shell — keep at least one live terminal.
            let liveTerminals = parsed.flatMap(\.panes).filter { !self.exited.contains($0) }
            if liveTerminals.isEmpty {
                self.ensureTerminalPane()
            } else {
                self.terminalEnsureAttempts = 0
            }
        }
    }

    /// Spawn a fresh default shell without touching the selection.
    /// Bounded: a shell that dies instantly must not spawn-loop.
    private var ensuringTerminal = false
    private var terminalEnsureAttempts = 0
    private func ensureTerminalPane() {
        guard !demoMode, !ensuringTerminal, terminalEnsureAttempts < 3 else { return }
        ensuringTerminal = true
        terminalEnsureAttempts += 1
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let spawn: (UInt64) -> Void = { [weak self] sid in
            guard let self else { return }
            self.client.send(["cmd": "spawn-pane", "session": sid,
                              "argv": [shellPath, "-i"], "cwd": NSHomeDirectory()]) { _ in
                self.ensuringTerminal = false
                self.refresh()
            }
        }
        if let sid = sessionIds.first {
            spawn(sid)
        } else {
            client.send(["cmd": "create-session", "title": "main"]) { resp in
                spawn((resp["session"] as? NSNumber)?.uint64Value ?? 1)
            }
        }
    }

    // MARK: Notice history

    /// Rebuild the notification panel from the daemon's notice history
    /// (`notices` command) so a relaunch shows what happened while the
    /// app was closed. Entries newer than the persisted watermark come
    /// in unread; everything shown moves the watermark forward. Mirrors
    /// the live rules: bells notify, exits stay silent.
    private func fetchNoticeHistory() {
        let seen = UInt64(max(0, UserDefaults.standard.integer(forKey: Self.noticeSeqKey)))
        client.send(["cmd": "notices", "seq": 0]) { [weak self] resp in
            guard let self, let notices = resp["notices"] as? [[String: Any]] else { return }
            let timeFmt = DateFormatter()
            timeFmt.dateStyle = .short
            timeFmt.timeStyle = .short
            timeFmt.doesRelativeDateFormatting = true
            var maxSeq = seen
            for n in notices {
                let seq = (n["seq"] as? NSNumber)?.uint64Value ?? 0
                maxSeq = max(maxSeq, seq)
                let isRead = seq <= seen
                let ts = (n["ts"] as? NSNumber)?.doubleValue ?? 0
                let when = ts > 0
                    ? timeFmt.string(from: Date(timeIntervalSince1970: ts / 1000)) : ""
                switch n["kind"] as? String ?? "" {
                case "pane_bell":
                    guard let pane = (n["pane"] as? NSNumber)?.uint64Value
                    else { break }
                    self.appendHistoryNotification(
                        seq: seq,
                        workspaceId: paneSession[pane].map { "sess-\($0)" } ?? "",
                        title: "pane \(pane)",
                        subtitle: "bell",
                        body: "the terminal rang the bell · \(when)", isRead: isRead)
                default:
                    // pane_exit is history-only context; the live path
                    // never notifies for it either.
                    break
                }
            }
            if maxSeq > seen {
                UserDefaults.standard.set(Int(maxSeq), forKey: Self.noticeSeqKey)
            }
            if self.viewModel.notifications.count > 50 {
                self.viewModel.notifications.removeFirst(self.viewModel.notifications.count - 50)
            }
            if self.notifPanelVisible { self.notifPanel.show(self.viewModel.notifications) }
            // Rows carry the newest notification as their snippet line;
            // they were built before history existed, so rebuild once.
            self.refresh()
        }
    }

    /// History entries take deterministic zero-padded ids so the panel's
    /// id-descending sort keeps them chronological (live "n-…" ids sort
    /// above "h-…" within the same read group).
    private func appendHistoryNotification(
        seq: UInt64, workspaceId: String, title: String,
        subtitle: String, body: String, isRead: Bool
    ) {
        // Same collapse rule as pushNotification: consecutive identical
        // states for one workspace (bells especially) are one entry.
        if let last = viewModel.notifications.last(where: { $0.workspaceId == workspaceId }),
           last.subtitle == subtitle { return }
        viewModel.notifications.append(ShellNotification(
            id: String(format: "h-%010llu", seq),
            workspaceId: workspaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            isRead: isRead))
    }

    /// A live notification just displayed means everything the daemon
    /// has recorded so far has been seen in this run — advance the
    /// watermark so the next launch only re-flags what fires after quit.
    private func bumpNoticeWatermark() {
        let seen = UInt64(max(0, UserDefaults.standard.integer(forKey: Self.noticeSeqKey)))
        client.send(["cmd": "notices", "seq": seen]) { resp in
            let maxSeq = (resp["notices"] as? [[String: Any]] ?? [])
                .compactMap { ($0["seq"] as? NSNumber)?.uint64Value }
                .max()
            if let maxSeq, maxSeq > seen {
                UserDefaults.standard.set(Int(maxSeq), forKey: Self.noticeSeqKey)
            }
        }
    }

    private func refreshPaneMeta() {
        client.send(["cmd": "panes-meta"]) { [weak self] resp in
            guard let self else { return }
            var metas: [UInt64: (cwd: String?, branch: String?, dirty: Bool, ports: [Int],
                                 agent: String?, activity: String?)] = [:]
            var fgTitles: [UInt64: String?] = [:]
            self.agentPanes.removeAll()
            self.agentActivity.removeAll()
            for p in resp["panes"] as? [[String: Any]] ?? [] {
                let id = (p["pane"] as? NSNumber)?.uint64Value ?? 0
                guard id != 0 else { continue }
                let ports = (p["ports"] as? [NSNumber] ?? []).map(\.intValue)
                let fg = p["title"] as? String
                let agent = fg.flatMap { Self.agentNames.contains($0) ? $0 : nil }
                if agent != nil {
                    self.agentPanes.insert(id)
                    self.agentActivity[id] = p["last_line"] as? String
                }
                metas[id] = (
                    cwd: p["cwd"] as? String,
                    branch: p["branch"] as? String,
                    dirty: p["dirty"] as? Bool ?? false,
                    ports: ports,
                    agent: agent,
                    activity: p["last_line"] as? String)
                fgTitles[id] = fg
            }
            guard !metas.isEmpty else { return }
            self.viewModel.applyPaneMeta(metas)
            // Fallback tab titles for shells that never set one: the
            // foreground command, or cwd when the shell is idle. OSC
            // titles stay authoritative.
            for (pane, m) in metas where !self.oscTitled.contains(pane) {
                if let t = self.metaDerivedTitle(command: fgTitles[pane] ?? nil, cwd: m.cwd) {
                    self.paneTitleChanged(pane, title: t, fromOSC: false)
                }
            }
            // Sidebar + status only: reloadChrome() rebuilds the host's
            // panel slots, which yanks keyboard focus out of the
            // terminal — unacceptable on a 4s timer.
            self.sidebar.apply(
                items: self.viewModel.items,
                selectedWorkspaceId: self.viewModel.selectedWorkspaceId,
                collapsedGroups: self.viewModel.collapsedGroups)
            if let ws = self.viewModel.selectedWorkspace {
                self.statusLabel.stringValue = self.statusLine(for: ws)
            }
            self.updateTitlebar()
        }
    }

    // MARK: Events

    /// Append a live notification (cmux-style feed). Skipped when the
    /// workspace's latest entry already says the same thing: agents flap
    /// between working and needs_attention (quiescence detection), and
    /// only working/finished transitions reset the sequence.
    func pushNotification(workspaceId: String, title: String, subtitle: String, body: String) {
        if let last = viewModel.notifications.last(where: { $0.workspaceId == workspaceId }),
           last.subtitle == subtitle { return }
        viewModel.notifications.append(ShellNotification(
            id: "n-\(UUID().uuidString.prefix(8))",
            workspaceId: workspaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            isRead: workspaceId == viewModel.selectedWorkspaceId))
        if viewModel.notifications.count > 50 {
            viewModel.notifications.removeFirst(viewModel.notifications.count - 50)
        }
        if notifPanelVisible { notifPanel.show(viewModel.notifications) }
        bumpNoticeWatermark()
    }

    func handleEvent(_ obj: [String: Any]) {
        if demoMode { return }
        let event = obj["event"] as? String ?? ""
        let pane = (obj["pane"] as? NSNumber)?.uint64Value ?? 0
        switch event {
        case "pane_output":
            // Output renders through attached surfaces; a full refresh
            // per chunk would hammer the daemon (task-list +
            // list-sessions + panes-meta with its ps/lsof/git). Only a
            // pane nobody knows yet — spawned from the CLI or by an
            // agent — needs the sidebar rebuilt.
            if !knowsPane(pane) { refresh() }
        case "pane_bell":
            if pane != selectedPane {
                bells.insert(pane)
                refresh()
                // A bell from a pane running an AI agent is that agent
                // asking for you. Rows are sessions now — notify the
                // pane's workspace.
                let wsId = paneSession[pane].map { "sess-\($0)" } ?? ""
                let title = paneTitles[pane] ?? "pane \(pane)"
                if agentPanes.contains(pane) {
                    pushNotification(
                        workspaceId: wsId, title: title,
                        subtitle: "needs attention", body: "the agent is waiting for you")
                    NSApp.requestUserAttention(.informationalRequest)
                } else {
                    pushNotification(
                        workspaceId: wsId, title: title,
                        subtitle: "bell", body: "the terminal rang the bell")
                }
            }
        case "pane_exit":
            exited.insert(pane)
            pendingKill.remove(pane)
            // Terminal semantics: a pane whose child exited closes,
            // like Terminal.app/ghostty — no grey placeholder ghosts.
            client.send(["cmd": "remove-pane", "pane": pane]) { [weak self] _ in
                self?.refresh()
            }
            refresh()
        case "pane_removed":
            exited.remove(pane)
            pendingKill.remove(pane)
            surfaces.removeValue(forKey: pane)
            viewModel.removePaneEverywhere(pane)
            refresh()
            pushShellState()
            // A workspace close waits for its panes to drain before the
            // session itself can go.
            maybeRemoveEmptySessions()
        case "browser_removed":
            webObservations.removeValue(forKey: pane)
            if let web = webviews.removeValue(forKey: pane) {
                paneOfWebView.removeValue(forKey: ObjectIdentifier(web))
            }
            browserTitles.removeValue(forKey: pane)
            browserErrorURL.removeValue(forKey: pane)
            viewModel.removePaneEverywhere(pane)
            refresh()
        case "browser_open":
            // The browser docks into its session's workspace — the
            // refresh grafts it into the tree in place.
            ensureWebView(pane: pane, url: obj["url"] as? String ?? "about:blank")
            refresh()
        case "session_removed", "session_renamed":
            if let sid = (obj["session"] as? NSNumber)?.uint64Value {
                pendingSessionRemove.remove(sid)
            }
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

    /// A pane's title changed — OSC 0/2 from the surface, or the
    /// meta-derived fallback. Update tabs and sidebar in place — never
    /// reloadChrome here, it rebuilds panel slots and steals keyboard
    /// focus on every prompt.
    func paneTitleChanged(_ pane: UInt64, title: String, fromOSC: Bool = true) {
        if fromOSC { oscTitled.insert(pane) }
        let t = title.isEmpty ? "pane \(pane)" : title
        guard paneTitles[pane] != t else { return }
        paneTitles[pane] = t
        viewModel.setSurfaceTitle(paneId: pane, title: t)
        sidebar.apply(
            items: viewModel.items,
            selectedWorkspaceId: viewModel.selectedWorkspaceId,
            collapsedGroups: viewModel.collapsedGroups)
    }

    /// Tab title when the shell never sets one, cmux/tmux-style: the
    /// foreground command ("vim", "sleep"), or the cwd for an idle
    /// shell ("~", "zide").
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "nu", "ksh", "tcsh"]
    func metaDerivedTitle(command: String?, cwd: String?) -> String? {
        if let command, !command.isEmpty, !Self.shellNames.contains(command) {
            return command
        }
        guard let cwd, !cwd.isEmpty else { return command }
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    /// Kill a daemon pane behind a closed surface: HUP the live child
    /// and remove the pane once its exit lands (already-dead panes are
    /// removed immediately). Without this, closing a terminal is purely
    /// local and the pane resurrects as a row on the next refresh.
    /// Children that trap HUP (TUIs, agents) get SIGKILL after a grace
    /// period — closed means closed.
    func killPane(_ pane: UInt64) {
        if exited.contains(pane) {
            client.send(["cmd": "remove-pane", "pane": pane]) { [weak self] _ in
                self?.refresh()
            }
        } else {
            pendingKill.insert(pane)
            client.send(["cmd": "kill-pane", "pane": pane])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.pendingKill.contains(pane) else { return }
                self.client.send(["cmd": "kill-pane", "pane": pane, "force": true])
            }
        }
    }

    /// Close a browser pane daemon-side — browser panes are core state,
    /// so a local-only close resurrects on the next refresh.
    func closeBrowserPane(_ pane: UInt64) {
        client.send(["cmd": "browser-close", "pane": pane]) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Shell state (split layouts survive app relaunches)

    /// Debounced: stash the current split layouts in the daemon.
    /// Serialize a workspace tree for the daemon's shell-state stash:
    /// {"t":pane} terminal leaf, {"w":pane} browser leaf,
    /// {"h":bool,"r":ratio,"a":…,"b":…} split.
    private func encodeTree(_ layout: ShellLayout) -> [String: Any]? {
        switch layout {
        case let .leaf(node):
            guard let surf = node.surfaces.first, let pane = surf.paneId else { return nil }
            return surf.kind == .browser ? ["w": pane] : ["t": pane]
        case let .split(o, a, b, r):
            guard let ea = encodeTree(a) else { return encodeTree(b) }
            guard let eb = encodeTree(b) else { return ea }
            return ["h": o == ShellLayout.Orientation.horizontal, "r": Double(r), "a": ea, "b": eb]
        }
    }

    private func decodeTree(_ obj: [String: Any]) -> ShellLayout? {
        if let pane = (obj["t"] as? NSNumber)?.uint64Value {
            let surface = ShellSurface(
                id: "pane-\(pane)", title: paneTitles[pane] ?? "pane \(pane)",
                kind: .terminal, paneId: pane)
            return .leaf(ShellPaneNode(id: "p-\(pane)", surfaces: [surface], selectedSurfaceId: surface.id))
        }
        if let pane = (obj["w"] as? NSNumber)?.uint64Value {
            let surface = ShellSurface(
                id: "web-\(pane)", title: browserTitles[pane] ?? "browser",
                kind: .browser, paneId: pane)
            return .leaf(ShellPaneNode(id: "w-\(pane)", surfaces: [surface], selectedSurfaceId: surface.id))
        }
        guard let a = obj["a"] as? [String: Any], let b = obj["b"] as? [String: Any],
              let first = decodeTree(a), let second = decodeTree(b) else { return nil }
        let horizontal = (obj["h"] as? Bool) ?? true
        let ratio = CGFloat((obj["r"] as? NSNumber)?.doubleValue ?? 0.5)
        return .split(
            orientation: horizontal ? .horizontal : .vertical,
            first: first, second: second, ratio: ratio)
    }

    func pushShellState() {
        guard !demoMode, shellStateRestored else { return }
        shellStateTimer?.invalidate()
        shellStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            var trees: [String: Any] = [:]
            for item in self.viewModel.items {
                guard case let .workspace(w) = item, let sid = w.sessionId,
                      let tree = self.encodeTree(w.layout) else { continue }
                trees["\(sid)"] = tree
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["trees": trees]),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.client.send(["cmd": "set-shell-state", "data": json])
        }
    }

    /// Re-adopt stashed workspace arrangements whose panes all still
    /// exist. Runs once, after the first refresh has populated rows.
    func restoreShellState() {
        client.send(["cmd": "get-shell-state"]) { [weak self] resp in
            guard let self else { return }
            defer { self.shellStateRestored = true }
            guard let json = resp["data"] as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let trees = obj["trees"] as? [String: Any]
            else { return }
            var changed = false
            for (key, raw) in trees {
                guard let sid = UInt64(key),
                      let treeObj = raw as? [String: Any],
                      let tree = self.decodeTree(treeObj),
                      let ws = self.viewModel.workspace(id: "sess-\(sid)"),
                      Set(tree.daemonPaneIds) == Set(ws.layout.daemonPaneIds),
                      !tree.daemonPaneIds.isEmpty
                else { continue }
                self.viewModel.setLayout(workspaceId: "sess-\(sid)", layout: tree)
                changed = true
            }
            if changed { self.reloadChrome() }
        }
    }

    /// Whether any workspace already shows this daemon pane.
    func knowsPane(_ pane: UInt64) -> Bool {
        for item in viewModel.items {
            guard case let .workspace(w) = item else { continue }
            if w.layout.daemonPaneIds.contains(pane) { return true }
        }
        return false
    }

    func ensureWebView(pane: UInt64, url: String) {
        guard webviews[pane] == nil else { return }
        let web = BrowserEngine.makeWebView(
            underPageColor: runtime.backgroundColor.withAlphaComponent(runtime.backgroundOpacity))
        web.navigationDelegate = self
        web.uiDelegate = self
        webviews[pane] = web
        paneOfWebView[ObjectIdentifier(web)] = pane
        // Live browser chrome: the address bar, nav buttons, loading
        // progress, and the daemon's stored URL/title follow every
        // navigation — not just page-load completion.
        webObservations[pane] = [
            web.observe(\.url) { [weak self] w, _ in
                self?.browserStateChanged(w)
            },
            web.observe(\.title) { [weak self] w, _ in
                self?.browserStateChanged(w)
            },
            web.observe(\.canGoBack) { [weak self] w, _ in
                self?.browserStateChanged(w)
            },
            web.observe(\.canGoForward) { [weak self] w, _ in
                self?.browserStateChanged(w)
            },
            web.observe(\.isLoading) { [weak self] w, _ in
                self?.browserStateChanged(w)
            },
            web.observe(\.estimatedProgress) { [weak self] w, _ in
                self?.browserStateChanged(w)
            },
        ]
        if let u = URL(string: url) { web.load(URLRequest(url: u)) }
    }

    func browserStateChanged(_ web: WKWebView) {
        guard let pane = paneOfWebView[ObjectIdentifier(web)] else { return }
        if let title = web.title, !title.isEmpty, browserTitles[pane] != title {
            browserTitles[pane] = title
            viewModel.setBrowserTitle(pane: pane, title: title)
            sidebar.apply(
                items: viewModel.items,
                selectedWorkspaceId: viewModel.selectedWorkspaceId,
                collapsedGroups: viewModel.collapsedGroups)
            if let url = web.url { BrowserHistoryStore.shared.updateTitle(url: url, title: title) }
        }
        // The error page itself is about:blank — keep showing the URL
        // that failed instead.
        var displayURL = web.url?.absoluteString
        if displayURL == nil || displayURL == "about:blank" {
            displayURL = browserErrorURL[pane] ?? displayURL
        }
        host.updateBrowserChrome(
            pane: pane,
            url: displayURL,
            canGoBack: web.canGoBack,
            canGoForward: web.canGoForward,
            isLoading: web.isLoading,
            progress: web.estimatedProgress)
    }

    /// New browsing contexts, cmux's split: scripted window.open with
    /// explicit window features becomes a real popup window sharing
    /// WebKit's configuration (window.opener stays alive — OAuth);
    /// everything else (target=_blank, cmd-click fallbacks) opens a
    /// new browser pane, zide's tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, !BrowserEngine.isWebScheme(url) {
            presentExternalOpenPrompt(url)
            return nil
        }
        let featuresSpecified = windowFeatures.x != nil || windowFeatures.y != nil
            || windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.menuBarVisibility != nil
            || windowFeatures.statusBarVisibility != nil
            || windowFeatures.toolbarsVisibility != nil
            || windowFeatures.allowsResizing != nil
        if navigationAction.navigationType == .other, featuresSpecified {
            return BrowserPopupWindow.open(
                configuration: configuration, features: windowFeatures,
                parent: window, underPageColor: webView.underPageBackgroundColor)
        }
        if let url = navigationAction.request.url, !demoMode {
            openBrowserInWorkspace(url.absoluteString, from: webView)
        }
        return nil
    }

    /// target=_blank / cmd-click from a browser panel: the new browser
    /// docks into the SAME workspace (cmux's dock.newSurface) — it
    /// appears beside the page you clicked in, never as a new row.
    func openBrowserInWorkspace(_ url: String, from webView: WKWebView?) {
        let sid = webView.flatMap { paneOfWebView[ObjectIdentifier($0)] }.flatMap { paneSession[$0] }
            ?? viewModel.selectedWorkspace?.sessionId
            ?? currentSession
        client.send(["cmd": "browser-open", "session": sid, "url": url])
    }

    /// window.close() on a pane-hosted browser closes the pane.
    func webViewDidClose(_ webView: WKWebView) {
        guard let pane = paneOfWebView[ObjectIdentifier(webView)] else { return }
        closeBrowserPane(pane)
    }

    @objc func openLocation() {
        if !host.focusOmnibar() {
            statusLabel.stringValue = "no browser pane selected — ⌘⇧B opens one"
        }
    }

    /// The selected pane's webview, when the selection is a browser.
    var selectedWebView: WKWebView? {
        selectedPane.flatMap { webviews[$0] }
    }

    @objc func zoomInBrowser() { adjustBrowserZoom(BrowserEngine.pageZoomStep) }
    @objc func zoomOutBrowser() { adjustBrowserZoom(-BrowserEngine.pageZoomStep) }
    @objc func zoomActualBrowser() { selectedWebView?.pageZoom = 1.0 }

    func adjustBrowserZoom(_ delta: CGFloat) {
        guard let web = selectedWebView else { return }
        web.pageZoom = min(BrowserEngine.maxPageZoom, max(BrowserEngine.minPageZoom, web.pageZoom + delta))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pane = paneOfWebView[ObjectIdentifier(webView)] else { return }
        let url = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        if !title.isEmpty {
            browserTitles[pane] = title
            viewModel.setBrowserTitle(pane: pane, title: title)
        }
        client.send(["cmd": "browser-update", "pane": pane,
                     "url": url, "title": title, "loading": false])
        if pane == selectedPane {
            statusLabel.stringValue = "web \(pane) — \(title.isEmpty ? url : title)  ·  \(url)"
        }
        reloadChrome()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let pane = paneOfWebView[ObjectIdentifier(webView)],
              let url = webView.url, url.absoluteString != "about:blank" else { return }
        browserErrorURL.removeValue(forKey: pane)
        BrowserHistoryStore.shared.recordVisit(url: url, title: webView.title)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        // Cancelled navigations (rapid typing) are not errors, and
        // "frame load interrupted" (102) is a navigation that became a
        // download — both must not paint an error page.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? nsError.userInfo["NSErrorFailingURLStringKey"] as? String
            ?? webView.url?.absoluteString ?? ""
        if let pane = paneOfWebView[ObjectIdentifier(webView)] {
            browserErrorURL[pane] = failedURL
        }
        BrowserErrorPage(failedURL: failedURL, error: nsError).load(in: webView)
    }

    /// The engine's content process crashed — reload rather than leave
    /// a white void.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // Non-web schemes (mailto:, app links) belong to macOS.
        if !BrowserEngine.isWebScheme(url) {
            decisionHandler(.cancel)
            presentExternalOpenPrompt(url)
            return
        }
        // Anchors with the download attribute, Alt-click, etc.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Cmd-click / middle-click docks a new browser panel into the
        // same workspace (cmux: new tab in the dock).
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2 {
            decisionHandler(.cancel)
            if !demoMode { openBrowserInWorkspace(url.absoluteString, from: webView) }
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let scheme = navigationResponse.response.url?.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            decisionHandler(.allow)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        if BrowserDownloadPolicy.shouldDownload(
            mimeType: navigationResponse.response.mimeType,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            contentDisposition: disposition,
            isForMainFrame: navigationResponse.isForMainFrame
        ) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = BrowserDownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = BrowserDownloadManager.shared
    }

    /// HTTP Basic/Digest auth: the standard sign-in sheet. The user
    /// types their own credentials; they go straight into WebKit's
    /// session credential and nowhere else.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 3 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Authentication Required"
        var message = "\(challenge.protectionSpace.host) requires a username and password."
        if let realm = challenge.protectionSpace.realm, !realm.isEmpty {
            message = "\(challenge.protectionSpace.host) requires a username and password for \u{201C}\(realm)\u{201D}."
        }
        if challenge.previousFailureCount > 0 {
            message += "\nThe username or password you entered is incorrect."
        }
        alert.informativeText = message
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        let user = NSTextField(frame: NSRect(x: 0, y: 32, width: 280, height: 24))
        user.placeholderString = "Username"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        pass.placeholderString = "Password"
        box.addSubview(user)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = user
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(.useCredential, URLCredential(
                    user: user.stringValue, password: pass.stringValue, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    /// cmux prompts before handing a link to another app — silent
    /// scheme handoffs are how pages steal focus.
    func presentExternalOpenPrompt(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Open in another app?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(url)
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

    func windowDidResize(_ notification: Notification) {
        layoutHost()
    }

    // MARK: Actions

    var currentSession: UInt64 {
        sessionIds.first ?? 1
    }

    @objc func addSession() {
        if demoMode {
            statusLabel.stringValue = "demo — create-session not wired"
            return
        }
        client.send(["cmd": "create-session", "title": "session"]) { [weak self] _ in self?.refresh() }
    }

    /// ⌘T, cmux-style: a new WORKSPACE — its own daemon session with a
    /// fresh shell — not another pane in the current one.
    @objc func addTerm() {
        if demoMode {
            statusLabel.stringValue = "demo — spawn-pane not wired"
            return
        }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        client.send(["cmd": "create-session", "title": "~"]) { [weak self] resp in
            guard let self, let sid = (resp["session"] as? NSNumber)?.uint64Value else { return }
            self.client.send(["cmd": "spawn-pane", "session": sid,
                              "argv": [shellPath, "-i"], "cwd": NSHomeDirectory()]) { _ in
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.viewModel.selectWorkspace("sess-\(sid)")
                    self.reloadChrome()
                }
            }
        }
    }

    /// ⌘⇧B: dock a browser into the CURRENT workspace (cmux's dock
    /// column) — browsers are panels inside a workspace, never rows.
    @objc func addWeb() {
        if demoMode {
            statusLabel.stringValue = "demo — browser-open not wired"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open browser panel"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: ShellTheme.alertFieldHeight))
        field.stringValue = "https://google.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let sid = viewModel.selectedWorkspace?.sessionId ?? currentSession
        client.send(["cmd": "browser-open", "session": sid, "url": field.stringValue])
    }
}
