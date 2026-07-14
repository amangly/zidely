// Notification panel chrome (cmux ⌘⇧I): list unread/read alerts, jump to workspace.

import AppKit

protocol NotificationPanelDelegate: AnyObject {
    func notificationPanelDidSelect(_ notification: ShellNotification)
    func notificationPanelDidClose()
}

final class NotificationPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: NotificationPanelDelegate?

    private var items: [ShellNotification] = []
    private let titleLabel = NSTextField(labelWithString: "Notifications")
    private let closeButton = NSButton(title: "Done", target: nil, action: nil)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No notifications")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Hosted in an NSPopover, which supplies the material, arrow,
        // shadow, and clipping — the content view stays transparent.

        titleLabel.font = ShellTheme.uiFontBold
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.controlSize = .regular
        addSubview(closeButton)

        emptyLabel.font = ShellTheme.uiFont
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        let col = NSTableColumn(identifier: .init("main"))
        col.width = 340
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 60
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .regular

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 16, y: bounds.height - 36, width: 220, height: 20)
        closeButton.frame = NSRect(x: bounds.width - 78, y: bounds.height - 38, width: 64, height: 26)
        let body = NSRect(x: 10, y: 10, width: bounds.width - 20, height: bounds.height - 52)
        scroll.frame = body
        emptyLabel.frame = body
    }

    func show(_ notifications: [ShellNotification]) {
        // Unread first, then read.
        items = notifications.sorted { a, b in
            if a.isRead != b.isRead { return !a.isRead && b.isRead }
            return a.id > b.id
        }
        emptyLabel.isHidden = !items.isEmpty
        table.reloadData()
        isHidden = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let n = items[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: n.title)
        title.font = n.isRead ? ShellTheme.uiFont : ShellTheme.uiFontBold
        title.textColor = n.isRead ? .secondaryLabelColor : .labelColor
        title.frame = NSRect(x: 10, y: 34, width: 360, height: 18)
        let sub = NSTextField(labelWithString: "\(n.subtitle) — \(n.body)")
        sub.font = ShellTheme.metaFont
        sub.textColor = .tertiaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 10, y: 12, width: 360, height: 16)
        cell.addSubview(title)
        cell.addSubview(sub)
        if !n.isRead {
            let dot = NSView(frame: NSRect(x: 0, y: 22, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = ShellTheme.attention.cgColor
            dot.layer?.cornerRadius = 3
            cell.addSubview(dot)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        delegate?.notificationPanelDidSelect(items[row])
        table.deselectAll(nil)
    }

    @objc private func close() {
        isHidden = true
        delegate?.notificationPanelDidClose()
    }
}
