// Omnibar suggestions dropdown, cmux-style: as you type, history
// matches ranked by frecency appear under the address bar; ↑/↓
// selects, Enter opens, Esc dismisses, click opens.

import AppKit

final class BrowserSuggestionsView: NSView {
    static let rowHeight: CGFloat = 34

    private(set) var suggestions: [BrowserSuggestion] = []
    private(set) var selectedIndex: Int = -1
    var onPick: ((BrowserSuggestion) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        layer?.zPosition = 50
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        // A dropdown floats over web content; it must stay opaque even
        // in transparency mode or the page bleeds through the text.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    var desiredHeight: CGFloat {
        CGFloat(suggestions.count) * Self.rowHeight + 8
    }

    func show(_ suggestions: [BrowserSuggestion]) {
        self.suggestions = suggestions
        if selectedIndex >= suggestions.count { selectedIndex = suggestions.isEmpty ? -1 : 0 }
        rebuildRows()
    }

    func clearSelection() {
        selectedIndex = -1
        applySelection()
    }

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        if selectedIndex < 0 {
            selectedIndex = delta > 0 ? 0 : suggestions.count - 1
        } else {
            selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
        }
        applySelection()
    }

    var selectedSuggestion: BrowserSuggestion? {
        guard selectedIndex >= 0, selectedIndex < suggestions.count else { return nil }
        return suggestions[selectedIndex]
    }

    private func rebuildRows() {
        subviews.forEach { $0.removeFromSuperview() }
        for (i, s) in suggestions.enumerated() {
            let row = NSView()
            row.wantsLayer = true
            row.identifier = NSUserInterfaceItemIdentifier("row:\(i)")
            row.layer?.cornerRadius = 5

            let title = NSTextField(labelWithString: s.title.isEmpty ? s.url : s.title)
            title.font = ShellTheme.uiFont
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingTail
            title.identifier = NSUserInterfaceItemIdentifier("title")
            row.addSubview(title)

            let url = NSTextField(labelWithString: s.url)
            url.font = ShellTheme.metaFont
            url.textColor = .secondaryLabelColor
            url.lineBreakMode = .byTruncatingMiddle
            url.identifier = NSUserInterfaceItemIdentifier("url")
            row.addSubview(url)

            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            row.addGestureRecognizer(click)
            addSubview(row)
        }
        needsLayout = true
        applySelection()
    }

    private func applySelection() {
        for sub in subviews {
            guard let raw = sub.identifier?.rawValue, raw.hasPrefix("row:"),
                  let i = Int(raw.dropFirst(4)) else { continue }
            sub.layer?.backgroundColor = i == selectedIndex
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
                : NSColor.clear.cgColor
        }
    }

    override func layout() {
        super.layout()
        let rows = subviews.compactMap { sub -> (Int, NSView)? in
            guard let raw = sub.identifier?.rawValue, raw.hasPrefix("row:"),
                  let i = Int(raw.dropFirst(4)) else { return nil }
            return (i, sub)
        }
        for (i, row) in rows {
            // Top row first: flipped index against AppKit's bottom-up y.
            let y = bounds.height - 4 - CGFloat(i + 1) * Self.rowHeight
            row.frame = NSRect(x: 4, y: y, width: bounds.width - 8, height: Self.rowHeight)
            let half = (Self.rowHeight - 4) / 2
            if let title = row.subviews.first(where: { $0.identifier?.rawValue == "title" }) {
                title.frame = NSRect(x: 8, y: half, width: row.bounds.width - 16, height: half)
            }
            if let url = row.subviews.first(where: { $0.identifier?.rawValue == "url" }) {
                url.frame = NSRect(x: 8, y: 2, width: row.bounds.width - 16, height: half)
            }
        }
    }

    @objc private func rowClicked(_ gr: NSClickGestureRecognizer) {
        guard let raw = gr.view?.identifier?.rawValue, raw.hasPrefix("row:"),
              let i = Int(raw.dropFirst(4)), i < suggestions.count else { return }
        onPick?(suggestions[i])
    }
}
