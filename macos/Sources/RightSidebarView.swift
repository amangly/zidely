// Right sidebar chrome (cmux ⌘⌥B): stub panels for files / agent / notes.

import AppKit

final class RightSidebarView: NSView {
    private let effect = NSVisualEffectView()
    private let title = NSTextField(labelWithString: "SIDEBAR")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        title.font = ShellTheme.groupFont
        title.textColor = .tertiaryLabelColor
        effect.addSubview(title)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        for (heading, body) in [
            ("Files", "Project tree — wire later"),
            ("Agent", "Task timeline / tools — wire later"),
            ("Notes", "Scratch pad — wire later"),
        ] {
            let h = NSTextField(labelWithString: heading)
            h.font = ShellTheme.uiFontBold
            h.textColor = .labelColor
            let b = NSTextField(wrappingLabelWithString: body)
            b.font = ShellTheme.metaFont
            b.textColor = .tertiaryLabelColor
            b.preferredMaxLayoutWidth = ShellTheme.rightSidebarWidth - 32
            stack.addArrangedSubview(h)
            stack.addArrangedSubview(b)
        }
        effect.addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effect.frame = bounds
        let top = ShellTheme.titlebarClearance
        title.frame = NSRect(x: 14, y: bounds.height - top - 26, width: bounds.width - 28, height: 18)
        stack.frame = NSRect(
            x: 0, y: 0,
            width: bounds.width,
            height: max(0, bounds.height - top - 34))
    }
}
