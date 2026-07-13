// Content chrome: cmux-style pane headers (icon tabs + actions),
// in-pane browser bar, hairline splits, electric focus ring.

import AppKit
import WebKit

protocol WorkspaceHostViewDelegate: AnyObject {
    func workspaceHost(_ host: WorkspaceHostView, installPanel surface: ShellSurface, into slot: NSView)
    func workspaceHost(_ host: WorkspaceHostView, didChangeSplitRatio ratio: CGFloat)
    func workspaceHost(_ host: WorkspaceHostView, didFocusPane paneId: String)
    func workspaceHost(_ host: WorkspaceHostView, browserURLForPane paneId: UInt64) -> String?
    func workspaceHost(_ host: WorkspaceHostView, navigateBrowser paneId: UInt64, to url: String)
    func workspaceHost(_ host: WorkspaceHostView, browserWebViewForPane paneId: UInt64) -> WKWebView?
}

final class WorkspaceHostView: NSView {
    weak var delegate: WorkspaceHostViewDelegate?

    private var workspace: ShellWorkspace?
    private var focusedPaneId: String?
    private let emptyLabel = NSTextField(labelWithString: "no workspace — ⌘T terminal · ⌘⇧P commands · j/k in sidebar")
    private let attentionRing = NSView()
    private var dragOrientation: ShellLayout.Orientation?
    private var dragStartRatio: CGFloat = 0.5
    private var dragStartPoint: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellTheme.contentBg.cgColor
        emptyLabel.font = ShellTheme.uiFont
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.autoresizingMask = [.width, .height]
        addSubview(emptyLabel)

        attentionRing.wantsLayer = true
        attentionRing.layer?.borderWidth = ShellTheme.attentionFlash
        attentionRing.layer?.borderColor = ShellTheme.attention.cgColor
        attentionRing.layer?.cornerRadius = 3
        attentionRing.isHidden = true
        attentionRing.identifier = NSUserInterfaceItemIdentifier("attention-ring")
        attentionRing.layer?.zPosition = 10
        addSubview(attentionRing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        emptyLabel.frame = bounds
        if let workspace { applyFrames(for: workspace) }
    }

    func show(workspace: ShellWorkspace?, focusedPaneId: String? = nil) {
        self.workspace = workspace
        self.focusedPaneId = focusedPaneId ?? {
            guard let workspace else { return nil }
            switch workspace.layout {
            case let .single(p): return p.id
            case let .split(_, first, _, _): return first.id
            }
        }()
        subviews.filter { $0 !== emptyLabel && $0 !== attentionRing }
            .forEach { $0.removeFromSuperview() }
        guard let workspace else {
            emptyLabel.isHidden = false
            attentionRing.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        switch workspace.layout {
        case let .single(pane):
            addSubview(makePaneHost(pane), positioned: .below, relativeTo: attentionRing)
        case let .split(orientation, first, second, ratio):
            let a = makePaneHost(first)
            let b = makePaneHost(second)
            let divider = SplitDividerView()
            divider.orientation = orientation
            divider.target = self
            divider.action = #selector(dividerDrag(_:))
            divider.identifier = NSUserInterfaceItemIdentifier("split-divider")
            addSubview(a, positioned: .below, relativeTo: attentionRing)
            addSubview(divider, positioned: .below, relativeTo: attentionRing)
            addSubview(b, positioned: .below, relativeTo: attentionRing)
            _ = ratio
        }
        attentionRing.isHidden = workspace.attention != .needsAttention && workspace.unreadCount == 0
        applyFrames(for: workspace)
    }

    func updateSplitRatio(_ ratio: CGFloat) {
        guard var workspace, case let .split(o, a, b, _) = workspace.layout else { return }
        workspace.layout = .split(orientation: o, first: a, second: b, ratio: ratio)
        self.workspace = workspace
        applyFrames(for: workspace)
    }

    private func applyFrames(for workspace: ShellWorkspace) {
        attentionRing.frame = bounds.insetBy(dx: 1, dy: 1)

        let kids = subviews.filter { $0 !== emptyLabel && $0 !== attentionRing }
        let area = bounds
        switch workspace.layout {
        case .single:
            kids.first?.frame = area
        case let .split(orientation, _, _, ratio):
            guard kids.count >= 3 else { return }
            let a = kids[0]
            let div = kids[1]
            let b = kids[2]
            let t = max(ShellTheme.splitDivider, 1)
            let r = min(0.85, max(0.15, ratio))
            switch orientation {
            case .horizontal:
                let w1 = floor((area.width - t) * r)
                a.frame = NSRect(x: area.minX, y: area.minY, width: w1, height: area.height)
                div.frame = NSRect(x: area.minX + w1, y: area.minY, width: t, height: area.height)
                b.frame = NSRect(
                    x: area.minX + w1 + t, y: area.minY,
                    width: area.width - w1 - t, height: area.height)
            case .vertical:
                let h1 = floor((area.height - t) * r)
                b.frame = NSRect(
                    x: area.minX, y: area.minY,
                    width: area.width, height: area.height - h1 - t)
                div.frame = NSRect(
                    x: area.minX, y: area.minY + area.height - h1 - t,
                    width: area.width, height: t)
                a.frame = NSRect(
                    x: area.minX, y: area.minY + area.height - h1,
                    width: area.width, height: h1)
            }
        }
        for host in kids where host.identifier?.rawValue.hasPrefix("pane:") == true {
            layoutPaneHost(host)
        }
    }

    private func makePaneHost(_ pane: ShellPaneNode) -> NSView {
        let host = NSView(frame: .zero)
        host.identifier = NSUserInterfaceItemIdentifier("pane:\(pane.id)")
        host.wantsLayer = true
        host.layer?.backgroundColor = ShellTheme.panelBg.cgColor
        host.autoresizingMask = [.width, .height]
        applyFocusBorder(host, focused: focusedPaneId == pane.id)

        let selected = pane.surfaces.first { $0.id == pane.selectedSurfaceId } ?? pane.surfaces.first
        let isBrowser = selected?.kind == .browser

        // No tab strip, no action icons: the sidebar is the tab bar and
        // shortcuts do the rest (ghostty-style minimal chrome). Only
        // browser panes get a header — their URL bar.
        if isBrowser {
            let header = NSView()
            header.wantsLayer = true
            header.layer?.backgroundColor = ShellTheme.paneHeaderBg.cgColor
            header.identifier = NSUserInterfaceItemIdentifier("header")
            host.addSubview(header)
            let browserBar = makeBrowserBar(pane: pane, surface: selected!)
            browserBar.identifier = NSUserInterfaceItemIdentifier("browserBar")
            header.addSubview(browserBar)
        }

        let slot = NSView()
        slot.wantsLayer = true
        slot.layer?.backgroundColor = ShellTheme.contentBg.cgColor
        slot.identifier = NSUserInterfaceItemIdentifier("slot")
        host.addSubview(slot)

        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked(_:)))
        host.addGestureRecognizer(click)

        if let selected {
            installPlaceholder(selected, into: slot)
            delegate?.workspaceHost(self, installPanel: selected, into: slot)
        }
        return host
    }

    private func makeHeaderIconButton(symbol: String, tip: String, id: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.bezelStyle = .inline
        btn.isBordered = false
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        img?.isTemplate = true
        btn.image = img
        btn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: ShellTheme.iconLg, weight: .medium)
        btn.contentTintColor = .secondaryLabelColor
        btn.toolTip = tip
        btn.identifier = NSUserInterfaceItemIdentifier(id)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setFrameSize(NSSize(width: 28, height: 28))
        return btn
    }

    private func makeBrowserBar(pane: ShellPaneNode, surface: ShellSurface) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true

        let back = makeHeaderIconButton(
            symbol: "chevron.backward", tip: "Back",
            id: "navBack:\(pane.id)", action: #selector(browserBack(_:)))
        let fwd = makeHeaderIconButton(
            symbol: "chevron.forward", tip: "Forward",
            id: "navFwd:\(pane.id)", action: #selector(browserForward(_:)))
        let reload = makeHeaderIconButton(
            symbol: "arrow.clockwise", tip: "Reload",
            id: "navReload:\(pane.id)", action: #selector(browserReload(_:)))

        let omnibar = NSTextField(string: "")
        omnibar.isEditable = true
        omnibar.isBordered = true
        omnibar.bezelStyle = .roundedBezel
        omnibar.font = ShellTheme.metaFont
        omnibar.placeholderString = "https://"
        omnibar.identifier = NSUserInterfaceItemIdentifier("omnibar:\(pane.id)")
        omnibar.target = self
        omnibar.action = #selector(omnibarSubmit(_:))
        if let paneId = surface.paneId,
           let live = delegate?.workspaceHost(self, browserURLForPane: paneId),
           !live.isEmpty {
            omnibar.stringValue = live
        } else if surface.title.hasPrefix("http") {
            omnibar.stringValue = surface.title
        } else {
            omnibar.stringValue = "https://"
        }

        for v in [back, fwd, reload, omnibar] as [NSView] { bar.addSubview(v) }
        bar.identifier = NSUserInterfaceItemIdentifier("browserBar")
        // Stash action button frames in layoutPaneHost via tags on subviews order.
        back.tag = 1; fwd.tag = 2; reload.tag = 3; omnibar.tag = 4
        return bar
    }

    private func applyFocusBorder(_ host: NSView, focused: Bool) {
        if focused {
            host.layer?.borderWidth = ShellTheme.focusBorder
            host.layer?.borderColor = ShellTheme.accent.cgColor
        } else {
            host.layer?.borderWidth = 0
            host.layer?.borderColor = nil
        }
    }

    @objc private func paneClicked(_ gr: NSClickGestureRecognizer) {
        guard let view = gr.view,
              let raw = view.identifier?.rawValue,
              raw.hasPrefix("pane:") else { return }
        let paneId = String(raw.dropFirst("pane:".count))
        focusedPaneId = paneId
        delegate?.workspaceHost(self, didFocusPane: paneId)
        for sub in subviews where sub.identifier?.rawValue.hasPrefix("pane:") == true {
            let id = String(sub.identifier!.rawValue.dropFirst("pane:".count))
            applyFocusBorder(sub, focused: id == paneId)
        }
    }

    @objc private func omnibarSubmit(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("omnibar:") else { return }
        let paneNodeId = String(raw.dropFirst("omnibar:".count))
        guard let surface = selectedSurface(paneId: paneNodeId), let paneId = surface.paneId else { return }
        var url = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        if !url.contains("://") { url = "https://" + url }
        delegate?.workspaceHost(self, navigateBrowser: paneId, to: url)
    }

    @objc private func browserBack(_ sender: NSButton) {
        browserNavigate(sender, direction: .back)
    }

    @objc private func browserForward(_ sender: NSButton) {
        browserNavigate(sender, direction: .forward)
    }

    @objc private func browserReload(_ sender: NSButton) {
        browserNavigate(sender, direction: .reload)
    }

    private enum BrowserNav { case back, forward, reload }

    private func browserNavigate(_ sender: NSButton, direction: BrowserNav) {
        guard let raw = sender.identifier?.rawValue else { return }
        let prefix: String
        switch direction {
        case .back: prefix = "navBack:"
        case .forward: prefix = "navFwd:"
        case .reload: prefix = "navReload:"
        }
        guard raw.hasPrefix(prefix) else { return }
        let paneNodeId = String(raw.dropFirst(prefix.count))
        guard let surface = selectedSurface(paneId: paneNodeId),
              let paneId = surface.paneId,
              let web = delegate?.workspaceHost(self, browserWebViewForPane: paneId)
        else { return }
        switch direction {
        case .back: if web.canGoBack { web.goBack() }
        case .forward: if web.canGoForward { web.goForward() }
        case .reload: web.reload()
        }
    }

    private func selectedSurface(paneId: String) -> ShellSurface? {
        guard let workspace else { return nil }
        let nodes: [ShellPaneNode]
        switch workspace.layout {
        case let .single(p): nodes = [p]
        case let .split(_, a, b, _): nodes = [a, b]
        }
        guard let node = nodes.first(where: { $0.id == paneId }) else { return nil }
        return node.surfaces.first { $0.id == node.selectedSurfaceId } ?? node.surfaces.first
    }

    private func layoutPaneHost(_ host: NSView) {
        guard let slot = host.subviews.first(where: { $0.identifier?.rawValue == "slot" })
        else { return }
        // Terminals fill edge-to-edge; only browser panes carry a
        // header (their URL bar).
        let header = host.subviews.first { $0.identifier?.rawValue == "header" }
        let headerH: CGFloat = header != nil ? ShellTheme.browserChromeHeight : 0
        header?.frame = NSRect(
            x: 0, y: host.bounds.height - headerH,
            width: host.bounds.width, height: headerH)
        slot.frame = NSRect(x: 0, y: 0, width: host.bounds.width, height: max(0, host.bounds.height - headerH))

        if let header, let browserBar = header.subviews.first(where: { $0.identifier?.rawValue == "browserBar" }) {
            browserBar.frame = header.bounds
            layoutBrowserBar(browserBar)
        }

        for sub in slot.subviews {
            sub.frame = slot.bounds
            sub.autoresizingMask = [.width, .height]
        }
    }

    private func layoutBrowserBar(_ bar: NSView) {
        let btn: CGFloat = 28
        var x: CGFloat = 6
        for tag in 1...3 {
            if let v = bar.subviews.first(where: { $0.tag == tag }) {
                v.frame = NSRect(x: x, y: (bar.bounds.height - btn) / 2, width: btn, height: btn)
                x += btn
            }
        }
        if let omnibar = bar.subviews.first(where: { $0.tag == 4 }) {
            omnibar.frame = NSRect(
                x: x + 6, y: 5,
                width: max(56, bar.bounds.width - x - 14), height: bar.bounds.height - 10)
        }
    }

    private func installPlaceholder(_ surface: ShellSurface, into slot: NSView) {
        slot.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: placeholderText(for: surface))
        label.font = ShellTheme.uiFont
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.frame = slot.bounds
        label.autoresizingMask = [.width, .height]
        slot.addSubview(label)
    }

    private func placeholderText(for surface: ShellSurface) -> String {
        switch surface.kind {
        case .terminal:
            if let pane = surface.paneId { return "terminal pane \(pane)" }
            return "terminal — \(surface.title)"
        case .browser:
            return "browser — \(surface.title)"
        case .placeholder:
            return surface.title
        }
    }

    func setLiveView(_ view: NSView, in slot: NSView) {
        slot.subviews.forEach { $0.removeFromSuperview() }
        view.frame = slot.bounds
        view.autoresizingMask = [.width, .height]
        slot.addSubview(view)
    }

    @objc private func dividerDrag(_ gesture: NSPanGestureRecognizer) {
        guard let workspace, case let .split(orientation, _, _, ratio) = workspace.layout else { return }
        switch gesture.state {
        case .began:
            dragOrientation = orientation
            dragStartRatio = ratio
            dragStartPoint = orientation == .horizontal ? gesture.location(in: self).x : gesture.location(in: self).y
        case .changed:
            guard let dragOrientation else { return }
            let loc = gesture.location(in: self)
            let span = dragOrientation == .horizontal ? bounds.width : bounds.height
            guard span > 1 else { return }
            let delta: CGFloat
            if dragOrientation == .horizontal {
                delta = (loc.x - dragStartPoint) / span
            } else {
                delta = (loc.y - dragStartPoint) / span
            }
            delegate?.workspaceHost(self, didChangeSplitRatio: dragStartRatio + delta)
        default:
            dragOrientation = nil
        }
    }
}

private final class SplitDividerView: NSView {
    var orientation: ShellLayout.Orientation = .horizontal
    weak var target: AnyObject?
    var action: Selector?

    private let pan = NSPanGestureRecognizer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellTheme.splitLine.cgColor
        pan.target = self
        pan.action = #selector(panned(_:))
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: orientation == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    @objc private func panned(_ g: NSPanGestureRecognizer) {
        guard let target, let action else { return }
        _ = target.perform(action, with: g)
    }
}
