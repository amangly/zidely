// Shared chrome tokens for the cmux-look AppKit shell.
// Near-black surfaces + electric blue accent. Readable density throughout.

import AppKit

enum ShellTheme {
    static let sidebarWidth: CGFloat = 260
    static let rowHeight: CGFloat = 74
    static let groupHeaderHeight: CGFloat = 28
    static let footerHeight: CGFloat = 48
    static let titlebarClearance: CGFloat = 32
    static let surfaceTabHeight: CGFloat = 32
    static let browserChromeHeight: CGFloat = 36
    static let splitDivider: CGFloat = 1
    static let reviewBarHeight: CGFloat = 40
    static let statusHeight: CGFloat = 28
    static let attentionRing: CGFloat = 11
    static let attentionFlash: CGFloat = 2
    static let focusBorder: CGFloat = 2
    static let rightSidebarWidth: CGFloat = 300
    static let switcherWidth: CGFloat = 520
    static let switcherHeight: CGFloat = 420
    static let notifPanelWidth: CGFloat = 420
    static let notifPanelHeight: CGFloat = 420
    static let tabChipHeight: CGFloat = 28
    static let tabChipRadius: CGFloat = 6
    static let tabActiveBg = NSColor.unemphasizedSelectedContentBackgroundColor
    static let tabHoverBg = NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.55)
    static let tabMaxWidth: CGFloat = 220
    static let tabMinWidth: CGFloat = 96
    static let headerActionWidth: CGFloat = 120
    static let iconSm: CGFloat = 14
    static let iconMd: CGFloat = 16
    static let iconLg: CGFloat = 18
    static let alertFieldHeight: CGFloat = 28

    // Native AppKit surfaces throughout: system semantic colors and
    // vibrancy materials, so the chrome adapts to appearance and accent
    // changes like a stock macOS app. cmux row anatomy on top of that.
    static let contentBg = NSColor.underPageBackgroundColor
    static let panelBg = NSColor.underPageBackgroundColor
    static let paneHeaderBg = NSColor.windowBackgroundColor
    static let splitLine = NSColor.separatorColor
    static let selection = NSColor.controlAccentColor
    static let accent = NSColor.controlAccentColor
    static let unreadBadge: CGFloat = 17
    static let statusDot: CGFloat = 9
    static let attention = NSColor.systemOrange
    static let working = NSColor.systemGreen
    static let idle = NSColor.systemGray
    static let browser = NSColor.systemBlue

    // Browser omnibar: a flat rounded pill on the pane header, like
    // the rest of the chrome — never a stock bezeled field.
    static let urlFieldBg = NSColor.textBackgroundColor
    static let urlFieldRadius: CGFloat = 6
    static let urlFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let snippetFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let metaFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let groupFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let tabFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let statusFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let uiFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let uiFontBold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let overlayFieldFont = NSFont.systemFont(ofSize: 16, weight: .regular)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}
