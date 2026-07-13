// Workspace switcher (cmux ⌘P): filterable jump list.

import AppKit

protocol WorkspaceSwitcherDelegate: AnyObject {
    func workspaceSwitcherDidPick(_ id: String)
    func workspaceSwitcherDidCancel()
}

final class WorkspaceSwitcherView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: WorkspaceSwitcherDelegate?

    private var all: [ShellWorkspace] = []
    private var filtered: [ShellWorkspace] = []
    private let field = NSTextField(string: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let chrome = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.35).cgColor

        // Native popover material — standard AppKit overlay look.
        chrome.material = .popover
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 12
        chrome.layer?.masksToBounds = true
        addSubview(chrome)

        field.placeholderString = "Go to workspace…"
        field.font = ShellTheme.overlayFieldFont
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(acceptFirst)
        chrome.addSubview(field)

        let col = NSTableColumn(identifier: .init("main"))
        col.width = 480
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 46
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.action = #selector(rowClicked)
        table.target = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        chrome.addSubview(scroll)

        let click = NSClickGestureRecognizer(target: self, action: #selector(backdropClick))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = ShellTheme.switcherWidth
        let h = ShellTheme.switcherHeight
        chrome.frame = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w, height: h)
        field.frame = NSRect(x: 16, y: h - 50, width: w - 32, height: 32)
        scroll.frame = NSRect(x: 10, y: 10, width: w - 20, height: h - 68)
    }

    func present(workspaces: [ShellWorkspace]) {
        all = workspaces
        filtered = workspaces
        field.stringValue = ""
        table.reloadData()
        isHidden = false
        window?.makeFirstResponder(field)
        if !filtered.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = field.stringValue.lowercased()
        filtered = q.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(q)
                || ($0.cwd?.lowercased().contains(q) ?? false)
                || ($0.branch?.lowercased().contains(q) ?? false)
        }
        table.reloadData()
        if !filtered.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let w = filtered[row]
        let cell = NSTableCellView()
        var meta = w.title
        if let cwd = w.cwd { meta += "  ·  \(cwd)" }
        if let branch = w.branch { meta += "  ·  \(branch)" }
        let label = NSTextField(labelWithString: meta)
        label.font = ShellTheme.uiFont
        label.frame = NSRect(x: 10, y: 10, width: 420, height: 20)
        cell.addSubview(label)
        return cell
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // escape
            hideAndCancel()
        case 125: // down
            moveSelection(1)
        case 126: // up
            moveSelection(-1)
        case 36: // return
            acceptSelection()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func acceptFirst() { acceptSelection() }

    @objc private func rowClicked() { acceptSelection() }

    @objc private func backdropClick(_ gr: NSClickGestureRecognizer) {
        let p = gr.location(in: self)
        if !chrome.frame.contains(p) { hideAndCancel() }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let cur = max(0, table.selectedRow)
        let next = min(filtered.count - 1, max(0, cur + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func acceptSelection() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let id = filtered[row].id
        isHidden = true
        delegate?.workspaceSwitcherDidPick(id)
    }

    private func hideAndCancel() {
        isHidden = true
        delegate?.workspaceSwitcherDidCancel()
    }
}
