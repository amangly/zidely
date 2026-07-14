// Content chrome: the selected workspace's cmux-style surface tree —
// recursive splits of terminal panes with the browser dock column,
// in-pane browser bar, hairline dividers, electric focus ring.

import AppKit
import WebKit

protocol WorkspaceHostViewDelegate: AnyObject {
    func workspaceHost(_ host: WorkspaceHostView, installPanel surface: ShellSurface, into slot: NSView)
    func workspaceHost(_ host: WorkspaceHostView, didChangeSplitRatio ratio: CGFloat, path: String)
    func workspaceHost(_ host: WorkspaceHostView, didFocusPane paneId: String)
    func workspaceHost(_ host: WorkspaceHostView, browserURLForPane paneId: UInt64) -> String?
    func workspaceHost(_ host: WorkspaceHostView, navigateBrowser paneId: UInt64, to url: String)
    func workspaceHost(_ host: WorkspaceHostView, browserWebViewForPane paneId: UInt64) -> WKWebView?
    func workspaceHost(_ host: WorkspaceHostView, suggestionsFor query: String) -> [BrowserSuggestion]
}

final class WorkspaceHostView: NSView, NSTextFieldDelegate {
    weak var delegate: WorkspaceHostViewDelegate?

    /// Terminal transparency: with a non-opaque window, the canvas and
    /// pane slots must not paint or they block the see-through
    /// terminal background.
    var transparentBackground = false {
        didSet {
            layer?.backgroundColor = transparentBackground
                ? NSColor.clear.cgColor : ShellTheme.contentBg.cgColor
        }
    }

    private var workspace: ShellWorkspace?
    private var focusedPaneId: String?
    private let emptyLabel = NSTextField(labelWithString: "no workspace — ⌘T new workspace · ⌘⇧P commands · j/k in sidebar")
    private let attentionRing = NSView()
    /// Omnibar history dropdown — one shared overlay, floated above
    /// whichever browser panel's address bar is being typed in.
    private let suggestionsView = BrowserSuggestionsView(frame: .zero)
    private weak var suggestionsField: NSTextField?

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
        hideSuggestions()
        self.workspace = workspace
        self.focusedPaneId = focusedPaneId ?? workspace?.layout.leaves.first?.id
        subviews.filter { $0 !== emptyLabel && $0 !== attentionRing }
            .forEach { $0.removeFromSuperview() }
        guard let workspace, !workspace.layout.isEmpty else {
            emptyLabel.isHidden = false
            emptyLabel.stringValue = workspace == nil
                ? "no workspace — ⌘T new workspace · ⌘⇧P commands · j/k in sidebar"
                : "empty workspace — ⌘D opens a shell here, ⌘⇧W closes it"
            attentionRing.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        buildViews(for: workspace.layout, path: "")
        attentionRing.isHidden = workspace.attention != .needsAttention && workspace.unreadCount == 0
        applyFrames(for: workspace)
    }

    /// The tree changed shape or a divider moved: swap the layout in
    /// and re-frame without rebuilding panel slots.
    func updateLayout(_ layout: ShellLayout) {
        guard var workspace else { return }
        workspace.layout = layout
        self.workspace = workspace
        applyFrames(for: workspace)
    }

    private func buildViews(for layout: ShellLayout, path: String) {
        switch layout {
        case let .leaf(node):
            addSubview(makePaneHost(node), positioned: .below, relativeTo: attentionRing)
        case let .split(orientation, first, second, _):
            buildViews(for: first, path: path.isEmpty ? "0" : "\(path).0")
            let divider = SplitDividerView()
            divider.orientation = orientation
            divider.path = path
            divider.target = self
            divider.action = #selector(dividerDrag(_:))
            divider.identifier = NSUserInterfaceItemIdentifier("divider:\(path)")
            addSubview(divider, positioned: .below, relativeTo: attentionRing)
            buildViews(for: second, path: path.isEmpty ? "1" : "\(path).1")
        }
    }

    private func applyFrames(for workspace: ShellWorkspace) {
        attentionRing.frame = bounds.insetBy(dx: 1, dy: 1)
        placeFrames(for: workspace.layout, in: bounds, path: "")
    }

    private func placeFrames(for layout: ShellLayout, in area: NSRect, path: String) {
        switch layout {
        case let .leaf(node):
            guard let host = subviews.first(where: { $0.identifier?.rawValue == "pane:\(node.id)" })
            else { return }
            host.frame = area
            layoutPaneHost(host)
        case let .split(orientation, first, second, ratio):
            let t = max(ShellTheme.splitDivider, 1)
            let r = min(0.85, max(0.15, ratio))
            let divider = subviews.first { $0.identifier?.rawValue == "divider:\(path)" }
            switch orientation {
            case .horizontal:
                let w1 = floor((area.width - t) * r)
                placeFrames(
                    for: first,
                    in: NSRect(x: area.minX, y: area.minY, width: w1, height: area.height),
                    path: path.isEmpty ? "0" : "\(path).0")
                divider?.frame = NSRect(x: area.minX + w1, y: area.minY, width: t, height: area.height)
                placeFrames(
                    for: second,
                    in: NSRect(
                        x: area.minX + w1 + t, y: area.minY,
                        width: area.width - w1 - t, height: area.height),
                    path: path.isEmpty ? "1" : "\(path).1")
            case .vertical:
                // `first` is the top half; AppKit y grows upward.
                let h1 = floor((area.height - t) * r)
                placeFrames(
                    for: first,
                    in: NSRect(
                        x: area.minX, y: area.minY + area.height - h1,
                        width: area.width, height: h1),
                    path: path.isEmpty ? "0" : "\(path).0")
                divider?.frame = NSRect(
                    x: area.minX, y: area.minY + area.height - h1 - t,
                    width: area.width, height: t)
                placeFrames(
                    for: second,
                    in: NSRect(
                        x: area.minX, y: area.minY,
                        width: area.width, height: area.height - h1 - t),
                    path: path.isEmpty ? "1" : "\(path).1")
            }
        }
    }

    private func makePaneHost(_ pane: ShellPaneNode) -> NSView {
        let host = NSView(frame: .zero)
        host.identifier = NSUserInterfaceItemIdentifier("pane:\(pane.id)")
        host.wantsLayer = true
        host.layer?.backgroundColor = ShellTheme.panelBg.cgColor
        applyFocusBorder(host, focused: focusedPaneId == pane.id)

        let selected = pane.surfaces.first { $0.id == pane.selectedSurfaceId } ?? pane.surfaces.first
        let isBrowser = selected?.kind == .browser

        // No tab strip, no action icons: the sidebar is the tab bar and
        // shortcuts do the rest (ghostty-style minimal chrome). Only
        // browser panels get a header — their URL bar.
        if isBrowser {
            let header = NSView()
            header.wantsLayer = true
            header.layer?.backgroundColor = ShellTheme.paneHeaderBg.cgColor
            header.identifier = NSUserInterfaceItemIdentifier("header")
            host.addSubview(header)
            let browserBar = makeBrowserBar(pane: pane, surface: selected!)
            browserBar.identifier = NSUserInterfaceItemIdentifier("browserBar")
            header.addSubview(browserBar)
            // Page-load progress: a hairline under the address bar,
            // like every browser's loading indicator.
            let progress = NSView()
            progress.wantsLayer = true
            progress.layer?.backgroundColor = ShellTheme.accent.cgColor
            progress.identifier = NSUserInterfaceItemIdentifier("progress")
            progress.isHidden = true
            header.addSubview(progress)
        }

        let slot = NSView()
        slot.wantsLayer = true
        slot.layer?.backgroundColor = transparentBackground
            ? NSColor.clear.cgColor : ShellTheme.contentBg.cgColor
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
        omnibar.delegate = self
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
        back.tag = 1; fwd.tag = 2; reload.tag = 3; omnibar.tag = 4
        return bar
    }

    /// The pane whose focus pulse already played — chrome rebuilds must
    /// not re-fire it; only genuine focus changes do.
    private var lastPulsedPaneId: String?

    private func applyFocusBorder(_ host: NSView, focused: Bool) {
        if focused {
            // cmux-style: the ring pulses in softly to show where focus
            // landed, then fades out — the pane itself is the focus
            // indicator, not a permanent frame.
            host.layer?.borderWidth = ShellTheme.focusBorder
            host.layer?.borderColor = ShellTheme.accent.withAlphaComponent(0).cgColor
            let id = host.identifier?.rawValue
            if id != lastPulsedPaneId {
                lastPulsedPaneId = id
                let pulse = CAKeyframeAnimation(keyPath: "borderColor")
                pulse.values = [
                    ShellTheme.accent.withAlphaComponent(0).cgColor,
                    ShellTheme.accent.withAlphaComponent(0.55).cgColor,
                    ShellTheme.accent.withAlphaComponent(0.55).cgColor,
                    ShellTheme.accent.withAlphaComponent(0).cgColor,
                ]
                pulse.keyTimes = [0, 0.15, 0.55, 1]
                pulse.duration = 1.1
                host.layer?.add(pulse, forKey: "focus-pulse")
            }
        } else {
            host.layer?.removeAnimation(forKey: "focus-pulse")
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
        // A highlighted history suggestion wins over the raw text.
        let input = suggestionsView.selectedSuggestion?.url ?? sender.stringValue
        hideSuggestions()
        // Omnibox semantics: URLs load, host-looking input gets a
        // scheme, free text becomes a web search.
        guard let url = BrowserURLResolver.resolve(input) else { return }
        sender.stringValue = url.absoluteString
        delegate?.workspaceHost(self, navigateBrowser: paneId, to: url.absoluteString)
    }

    // MARK: Omnibar suggestions

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field.identifier?.rawValue.hasPrefix("omnibar:") == true else { return }
        let query = field.stringValue
        let matches = query.isEmpty ? [] : (delegate?.workspaceHost(self, suggestionsFor: query) ?? [])
        guard !matches.isEmpty else {
            hideSuggestions()
            return
        }
        suggestionsField = field
        suggestionsView.clearSelection()
        suggestionsView.show(matches)
        suggestionsView.onPick = { [weak self, weak field] pick in
            guard let self, let field else { return }
            field.stringValue = pick.url
            self.omnibarSubmit(field)
        }
        if suggestionsView.superview !== self { addSubview(suggestionsView) }
        positionSuggestions(under: field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField)?.identifier?.rawValue.hasPrefix("omnibar:") == true
        else { return }
        // Delayed: a click on a suggestion row ends editing on
        // mouse-down, but the row's click gesture fires on mouse-up —
        // tearing the overlay down in between would eat the click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.suggestionsField?.currentEditor() == nil else { return }
            self.hideSuggestions()
        }
    }

    /// ↑/↓ walk the dropdown, Esc dismisses it; everything else keeps
    /// the field editor's normal behavior.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control.identifier?.rawValue.hasPrefix("omnibar:") == true,
              suggestionsView.superview != nil else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            suggestionsView.moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            suggestionsView.moveSelection(-1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideSuggestions()
            return true
        default:
            return false
        }
    }

    private func positionSuggestions(under field: NSTextField) {
        let rect = field.convert(field.bounds, to: self)
        let height = suggestionsView.desiredHeight
        suggestionsView.frame = NSRect(
            x: rect.minX, y: rect.minY - height - 4,
            width: rect.width, height: height)
    }

    private func hideSuggestions() {
        suggestionsView.removeFromSuperview()
        suggestionsView.show([])
        suggestionsField = nil
    }

    /// Live address-bar/nav updates for a browser panel, without
    /// rebuilding the header. The omnibar is left alone while the user
    /// is editing it.
    func updateBrowserChrome(
        pane: UInt64, url: String?, canGoBack: Bool, canGoForward: Bool,
        isLoading: Bool = false, progress: Double = 0
    ) {
        guard let workspace else { return }
        for node in workspace.layout.leaves {
            guard let surface = node.surfaces.first(where: { $0.id == node.selectedSurfaceId })
                ?? node.surfaces.first,
                surface.kind == .browser, surface.paneId == pane
            else { continue }
            guard let host = subviews.first(where: { $0.identifier?.rawValue == "pane:\(node.id)" }),
                  let header = host.subviews.first(where: { $0.identifier?.rawValue == "header" }),
                  let bar = header.subviews.first(where: { $0.identifier?.rawValue == "browserBar" })
            else { continue }
            if let field = bar.subviews.first(where: { $0.tag == 4 }) as? NSTextField,
               field.currentEditor() == nil, let url {
                field.stringValue = url
            }
            (bar.subviews.first { $0.tag == 1 } as? NSButton)?.isEnabled = canGoBack
            (bar.subviews.first { $0.tag == 2 } as? NSButton)?.isEnabled = canGoForward
            // The reload button doubles as stop while loading — real
            // browser behavior.
            if let reload = bar.subviews.first(where: { $0.tag == 3 }) as? NSButton {
                let symbol = isLoading ? "xmark" : "arrow.clockwise"
                let tip = isLoading ? "Stop" : "Reload"
                let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
                img?.isTemplate = true
                reload.image = img
                reload.toolTip = tip
            }
            if let progressBar = header.subviews.first(where: { $0.identifier?.rawValue == "progress" }) {
                progressBar.isHidden = !isLoading || progress <= 0
                progressBar.frame = NSRect(
                    x: 0, y: 0,
                    width: header.bounds.width * CGFloat(min(1, max(0, progress))), height: 2)
            }
        }
    }

    /// Focus the selected browser panel's address bar (⌘L).
    func focusOmnibar() -> Bool {
        func walk(_ v: NSView) -> NSTextField? {
            for sub in v.subviews {
                if let field = sub as? NSTextField,
                   sub.identifier?.rawValue.hasPrefix("omnibar:") == true {
                    return field
                }
                if let found = walk(sub) { return found }
            }
            return nil
        }
        guard let field = walk(self) else { return false }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        return true
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
        case .reload:
            if web.isLoading {
                web.stopLoading()
            } else {
                web.reload()
            }
        }
    }

    private func selectedSurface(paneId: String) -> ShellSurface? {
        guard let workspace,
              let node = workspace.layout.leaves.first(where: { $0.id == paneId })
        else { return nil }
        return node.surfaces.first { $0.id == node.selectedSurfaceId } ?? node.surfaces.first
    }

    private func layoutPaneHost(_ host: NSView) {
        guard let slot = host.subviews.first(where: { $0.identifier?.rawValue == "slot" })
        else { return }
        // Terminals fill edge-to-edge; only browser panels carry a
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
        guard let divider = gesture.view as? SplitDividerView,
              let workspace else { return }
        switch gesture.state {
        case .began:
            divider.dragStartRatio = currentRatio(of: workspace.layout, path: divider.path) ?? 0.5
            divider.dragStartPoint = divider.orientation == .horizontal
                ? gesture.location(in: self).x : gesture.location(in: self).y
            divider.dragSpan = span(of: workspace.layout, path: divider.path, in: bounds, orientation: divider.orientation)
        case .changed:
            let loc = gesture.location(in: self)
            guard divider.dragSpan > 1 else { return }
            let delta: CGFloat
            if divider.orientation == .horizontal {
                delta = (loc.x - divider.dragStartPoint) / divider.dragSpan
            } else {
                // `first` is the top half; dragging down grows it.
                delta = (divider.dragStartPoint - loc.y) / divider.dragSpan
            }
            delegate?.workspaceHost(self, didChangeSplitRatio: divider.dragStartRatio + delta, path: divider.path)
        default:
            break
        }
    }

    private func currentRatio(of layout: ShellLayout, path: String) -> CGFloat? {
        var node = layout
        var remaining = Substring(path)
        while true {
            guard case let .split(_, a, b, r) = node else { return nil }
            if remaining.isEmpty { return r }
            let head = remaining.prefix(1)
            remaining = remaining.dropFirst(remaining.count == 1 ? 1 : 2)
            node = head == "0" ? a : b
        }
    }

    /// Pixel span of the split a path addresses — ratio deltas need it.
    private func span(of layout: ShellLayout, path: String, in area: NSRect, orientation: ShellLayout.Orientation) -> CGFloat {
        var node = layout
        var rect = area
        var remaining = Substring(path)
        while true {
            guard case let .split(o, a, b, r) = node else { break }
            if remaining.isEmpty { break }
            let t = max(ShellTheme.splitDivider, 1)
            let clamped = min(0.85, max(0.15, r))
            let head = remaining.prefix(1)
            remaining = remaining.dropFirst(remaining.count == 1 ? 1 : 2)
            switch o {
            case .horizontal:
                let w1 = floor((rect.width - t) * clamped)
                rect = head == "0"
                    ? NSRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height)
                    : NSRect(x: rect.minX + w1 + t, y: rect.minY, width: rect.width - w1 - t, height: rect.height)
            case .vertical:
                let h1 = floor((rect.height - t) * clamped)
                rect = head == "0"
                    ? NSRect(x: rect.minX, y: rect.minY + rect.height - h1, width: rect.width, height: h1)
                    : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - h1 - t)
            }
            node = head == "0" ? a : b
        }
        return orientation == .horizontal ? rect.width : rect.height
    }
}

private final class SplitDividerView: NSView {
    var orientation: ShellLayout.Orientation = .horizontal
    var path: String = ""
    var dragStartRatio: CGFloat = 0.5
    var dragStartPoint: CGFloat = 0
    var dragSpan: CGFloat = 0
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
