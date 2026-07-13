// Left chrome: native translucent sidebar (standard AppKit material),
// collapsible groups with +, row context menus.

import AppKit

protocol SidebarViewDelegate: AnyObject {
    func sidebarDidSelectWorkspace(_ id: String)
    func sidebarDidToggleGroup(_ id: String)
    func sidebarDidRequestNewInGroup(_ id: String)
    func sidebarDidTogglePin(_ id: String)
    func sidebarDidRename(_ id: String)
    func sidebarDidNavigateWorkspaces(delta: Int)
}

final class SidebarView: NSView {
    weak var delegate: SidebarViewDelegate?

    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No workspaces\n⌘T new terminal · ⌘⇧B browser")
    private var rowViews: [String: WorkspaceRowView] = [:]
    private var selectedId: String?
    private var contextWorkspaceId: String?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        emptyLabel.font = ShellTheme.metaFont
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        effect.addSubview(emptyLabel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: doc.widthAnchor),
        ])

        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effect.frame = bounds
        let top = ShellTheme.titlebarClearance
        scroll.frame = NSRect(
            x: 0, y: 0,
            width: bounds.width,
            height: max(0, bounds.height - top - 6))
        emptyLabel.frame = NSRect(
            x: 16, y: bounds.height / 2 - 28,
            width: bounds.width - 32, height: 56)
        if let doc = scroll.documentView {
            doc.frame.size.width = bounds.width
        }
    }

    func apply(items: [ShellSidebarItem], selectedWorkspaceId: String?, collapsedGroups: Set<String>) {
        selectedId = selectedWorkspaceId
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowViews.removeAll()

        let hasWorkspace = items.contains {
            if case .workspace = $0 { return true }
            return false
        }
        emptyLabel.isHidden = hasWorkspace
        scroll.isHidden = !hasWorkspace

        var hideMembers = false
        for item in items {
            switch item {
            case let .group(id, title):
                hideMembers = collapsedGroups.contains(id)
                let wrap = NSView()
                wrap.translatesAutoresizingMaskIntoConstraints = false

                let chevron = hideMembers ? "▶" : "▼"
                let header = NSButton(title: "\(chevron)  \(title)", target: self, action: #selector(groupClicked(_:)))
                header.bezelStyle = .inline
                header.isBordered = false
                header.font = ShellTheme.groupFont
                header.contentTintColor = .tertiaryLabelColor
                header.alignment = .left
                header.identifier = NSUserInterfaceItemIdentifier(id)
                header.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(header)

                let plus = NSButton(
                    image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New in group")!,
                    target: self, action: #selector(groupPlusClicked(_:)))
                plus.bezelStyle = .inline
                plus.isBordered = false
                plus.controlSize = .regular
                plus.identifier = NSUserInterfaceItemIdentifier(id)
                plus.toolTip = "New workspace in group"
                plus.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(plus)

                NSLayoutConstraint.activate([
                    wrap.heightAnchor.constraint(equalToConstant: ShellTheme.groupHeaderHeight),
                    wrap.widthAnchor.constraint(equalToConstant: ShellTheme.sidebarWidth),
                    header.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 8),
                    header.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                    plus.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -8),
                    plus.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                    header.trailingAnchor.constraint(lessThanOrEqualTo: plus.leadingAnchor, constant: -4),
                ])
                stack.addArrangedSubview(wrap)
            case let .workspace(w):
                if hideMembers { continue }
                let row = WorkspaceRowView(workspace: w)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.isSelected = w.id == selectedWorkspaceId
                NSLayoutConstraint.activate([
                    row.heightAnchor.constraint(equalToConstant: ShellTheme.rowHeight),
                    row.widthAnchor.constraint(equalToConstant: ShellTheme.sidebarWidth),
                ])
                let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
                row.addGestureRecognizer(click)
                let right = NSClickGestureRecognizer(target: self, action: #selector(rowRightClicked(_:)))
                right.buttonMask = 0x2
                row.addGestureRecognizer(right)
                row.identifier = NSUserInterfaceItemIdentifier(w.id)
                stack.addArrangedSubview(row)
                rowViews[w.id] = row
            }
        }
        stack.layoutSubtreeIfNeeded()
        if let doc = scroll.documentView {
            let h = max(stack.fittingSize.height, scroll.contentView.bounds.height)
            doc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        }
        needsLayout = true
    }

    @objc private func rowClicked(_ gr: NSClickGestureRecognizer) {
        guard let view = gr.view, let id = view.identifier?.rawValue else { return }
        delegate?.sidebarDidSelectWorkspace(id)
    }

    @objc private func rowRightClicked(_ gr: NSClickGestureRecognizer) {
        guard let view = gr.view, let id = view.identifier?.rawValue else { return }
        contextWorkspaceId = id
        let menu = NSMenu()
        let pin = NSMenuItem(title: "Pin / Unpin", action: #selector(ctxPin), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)
        let rename = NSMenuItem(title: "Rename…", action: #selector(ctxRename), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let event = NSApp.currentEvent ?? NSEvent.mouseEvent(
            with: .rightMouseDown, location: gr.location(in: view),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    @objc private func ctxPin() {
        guard let id = contextWorkspaceId else { return }
        delegate?.sidebarDidTogglePin(id)
    }

    @objc private func ctxRename() {
        guard let id = contextWorkspaceId else { return }
        delegate?.sidebarDidRename(id)
    }

    @objc private func groupClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        delegate?.sidebarDidToggleGroup(id)
    }

    @objc private func groupPlusClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        delegate?.sidebarDidRequestNewInGroup(id)
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        switch chars {
        case "j", "J":
            delegate?.sidebarDidNavigateWorkspaces(delta: 1)
        case "k", "K":
            delegate?.sidebarDidNavigateWorkspaces(delta: -1)
        case "n" where event.modifierFlags.contains(.control):
            delegate?.sidebarDidNavigateWorkspaces(delta: 1)
        case "p" where event.modifierFlags.contains(.control):
            delegate?.sidebarDidNavigateWorkspaces(delta: -1)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
