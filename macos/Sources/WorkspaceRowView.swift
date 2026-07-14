// One vertical-tab row, cmux anatomy: bold title with a leading unread
// badge (or status dot), a grey notification-snippet line, and a dim
// "branch* • cwd • ports" meta line. Selected rows fill with the solid
// system accent and force white text.

import AppKit

final class WorkspaceRowView: NSView {
    var workspace: ShellWorkspace {
        didSet { refresh() }
    }
    var isSelected: Bool = false {
        didSet {
            refresh()
            needsDisplay = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let pinLabel = NSTextField(labelWithString: "")

    init(workspace: ShellWorkspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = ShellTheme.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        snippetLabel.font = ShellTheme.snippetFont
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.drawsBackground = false
        metaLabel.font = ShellTheme.metaFont
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.drawsBackground = false
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.drawsBackground = false
        badgeLabel.isHidden = true
        pinLabel.font = .systemFont(ofSize: 12)
        pinLabel.drawsBackground = false
        pinLabel.isHidden = true
        addSubview(titleLabel)
        addSubview(snippetLabel)
        addSubview(metaLabel)
        addSubview(badgeLabel)
        addSubview(pinLabel)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ShellTheme.rowHeight)
    }

    /// Diameter of the leading indicator: unread badge wins over the
    /// agent-status dot; rows with neither keep the title flush left.
    private var indicatorWidth: CGFloat {
        if workspace.unreadCount > 0 { return ShellTheme.unreadBadge + 7 }
        if hasStatusDot { return ShellTheme.statusDot + 8 }
        return 0
    }

    private var hasStatusDot: Bool {
        workspace.attention != ShellAttention.none || workspace.layoutHasBrowser()
    }

    /// Vertical positions of the row's lines, centered as a block so a
    /// row missing its snippet or meta line doesn't show dead space.
    private func linePositions() -> (title: CGFloat, snippet: CGFloat?, meta: CGFloat?) {
        let hasSnippet = !(workspace.notificationSnippet ?? "").isEmpty
        let hasMeta = !metaText().isEmpty
        let titleH: CGFloat = 18
        let snipH: CGFloat = 18
        let metaH: CGFloat = 17
        let total = titleH + (hasSnippet ? snipH : 0) + (hasMeta ? metaH : 0)
        var y = (bounds.height + total) / 2 - titleH
        let titleY = y
        var snippetY: CGFloat?
        if hasSnippet {
            y -= snipH
            snippetY = y
        }
        var metaY: CGFloat?
        if hasMeta {
            y -= metaH
            metaY = y
        }
        return (titleY, snippetY, metaY)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14
        let lines = linePositions()
        let trailing: CGFloat = workspace.isPinned ? 18 : 0
        titleLabel.frame = NSRect(
            x: inset + indicatorWidth, y: lines.title,
            width: bounds.width - inset - indicatorWidth - 14 - trailing, height: 18)
        let w = bounds.width - inset - 14
        if let sy = lines.snippet {
            snippetLabel.frame = NSRect(x: inset, y: sy, width: w, height: 15)
        }
        snippetLabel.isHidden = lines.snippet == nil
        if let my = lines.meta {
            metaLabel.frame = NSRect(x: inset, y: my, width: w, height: 14)
        }
        metaLabel.isHidden = lines.meta == nil
        if workspace.isPinned {
            pinLabel.frame = NSRect(x: bounds.width - 26, y: lines.title, width: 16, height: 16)
            pinLabel.isHidden = false
        } else {
            pinLabel.isHidden = true
        }
        if workspace.unreadCount > 0 {
            badgeLabel.frame = NSRect(
                x: inset - 1, y: lines.title + 1,
                width: ShellTheme.unreadBadge + 2, height: ShellTheme.unreadBadge - 1)
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            ShellTheme.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 8, yRadius: 8).fill()
        }
        let inset: CGFloat = 14
        let titleLine = linePositions().title
        if workspace.unreadCount > 0 {
            let d = ShellTheme.unreadBadge
            let badge = NSRect(x: inset, y: titleLine + 1, width: d, height: d)
            (isSelected ? NSColor.white : ShellTheme.accent).setFill()
            NSBezierPath(ovalIn: badge).fill()
        } else if hasStatusDot, let color = statusDotColor() {
            let d = ShellTheme.statusDot
            let dot = NSRect(x: inset, y: titleLine + 5, width: d, height: d)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if workspace.attention == .needsAttention {
                color.withAlphaComponent(0.35).setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
        super.draw(dirtyRect)
    }

    private func statusDotColor() -> NSColor? {
        switch workspace.attention {
        case .needsAttention: return ShellTheme.attention
        case .working: return ShellTheme.working
        case .finished: return ShellTheme.idle
        case .none:
            return workspace.layoutHasBrowser() ? ShellTheme.browser : nil
        }
    }

    /// cmux meta order: branch first, then path, then ports.
    private func metaText() -> String {
        var bits: [String] = []
        if let branch = workspace.branch {
            bits.append(workspace.branchDirty ? "\(branch)*" : branch)
        }
        if let cwd = workspace.cwd, !cwd.isEmpty { bits.append(cwd) }
        if !workspace.ports.isEmpty {
            bits.append(workspace.ports.map { ":\($0)" }.joined(separator: " "))
        }
        return bits.joined(separator: " • ")
    }

    private func refresh() {
        titleLabel.stringValue = workspace.title
        snippetLabel.stringValue = workspace.notificationSnippet ?? ""
        metaLabel.stringValue = metaText()

        if isSelected {
            titleLabel.textColor = .white
            snippetLabel.textColor = NSColor.white.withAlphaComponent(0.85)
            metaLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            badgeLabel.textColor = ShellTheme.selection
        } else {
            titleLabel.textColor = workspace.attention == .finished
                ? .secondaryLabelColor : .labelColor
            snippetLabel.textColor = .secondaryLabelColor
            metaLabel.textColor = .tertiaryLabelColor
            badgeLabel.textColor = .white
        }

        badgeLabel.stringValue = workspace.unreadCount > 9 ? "9+" : "\(workspace.unreadCount)"
        if workspace.isPinned {
            pinLabel.stringValue = "★"
            pinLabel.textColor = isSelected ? .white : ShellTheme.accent
        }

        needsLayout = true
        needsDisplay = true
    }

}

private extension ShellWorkspace {
    func layoutHasBrowser() -> Bool {
        layout.leaves.contains { node in
            node.surfaces.contains { $0.kind == .browser }
        }
    }
}
