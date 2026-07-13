// Command palette (cmux ⌘⇧P): filterable action runner for shell chrome.

import AppKit

struct ShellCommand: Equatable {
    var id: String
    var title: String
    var shortcut: String
}

protocol CommandPaletteDelegate: AnyObject {
    func commandPaletteDidRun(_ id: String)
    func commandPaletteDidCancel()
}

final class CommandPaletteView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: CommandPaletteDelegate?

    private var all: [ShellCommand] = []
    private var filtered: [ShellCommand] = []
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

        field.placeholderString = "Run a command…"
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
        table.rowHeight = 44
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        chrome.addSubview(scroll)

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(backdropClick)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = ShellTheme.switcherWidth
        let h = ShellTheme.switcherHeight
        chrome.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        field.frame = NSRect(x: 16, y: h - 50, width: w - 32, height: 32)
        scroll.frame = NSRect(x: 10, y: 10, width: w - 20, height: h - 68)
    }

    func present(_ commands: [ShellCommand]) {
        all = commands
        filtered = commands
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
            $0.title.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
        table.reloadData()
        if !filtered.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = filtered[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: c.title)
        title.font = ShellTheme.uiFont
        title.frame = NSRect(x: 10, y: 10, width: 300, height: 18)
        let hint = NSTextField(labelWithString: c.shortcut)
        hint.font = ShellTheme.metaFont
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        hint.frame = NSRect(x: 320, y: 10, width: 120, height: 18)
        cell.addSubview(title)
        cell.addSubview(hint)
        return cell
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: hideAndCancel()
        case 125: moveSelection(1)
        case 126: moveSelection(-1)
        case 36: acceptSelection()
        default: super.keyDown(with: event)
        }
    }

    @objc private func acceptFirst() { acceptSelection() }
    @objc private func rowClicked() { acceptSelection() }

    @objc private func backdropClick(_ gr: NSClickGestureRecognizer) {
        if !chrome.frame.contains(gr.location(in: self)) { hideAndCancel() }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let next = min(filtered.count - 1, max(0, max(0, table.selectedRow) + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func acceptSelection() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let id = filtered[row].id
        isHidden = true
        delegate?.commandPaletteDidRun(id)
    }

    private func hideAndCancel() {
        isHidden = true
        delegate?.commandPaletteDidCancel()
    }
}
