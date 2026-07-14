// The libghostty app runtime: one ghostty_app_t for the process, the
// runtime callbacks it needs (wakeup -> tick, clipboard, close), and the
// user's own Ghostty configuration (fonts, theme) loaded so zide
// terminals look like their ghostty.

import AppKit
import GhosttyKit

final class GhosttyRuntime {
    static var shared: GhosttyRuntime?

    private(set) var app: ghostty_app_t?
    // ghostty_app_new borrows the config; keep it alive for the app's
    // lifetime (which is the process lifetime).
    private var config: ghostty_config_t?

    init?() {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async { GhosttyRuntime.shared?.tick() }
        }
        runtime.action_cb = { _, target, action in
            // Window/tab/split management actions are the shell's job in
            // ghostty proper; zide's layout is daemon state. The one we
            // consume is the terminal title (OSC 0/2) — it names pane
            // tabs, cmux-style.
            if action.tag == GHOSTTY_ACTION_SET_TITLE,
               target.tag == GHOSTTY_TARGET_SURFACE,
               let surface = target.target.surface,
               let ctitle = action.action.set_title.title {
                let title = String(cString: ctitle)
                if let ud = ghostty_surface_userdata(surface) {
                    let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
                    DispatchQueue.main.async { view.onTitleChange?(title) }
                }
                return true
            }
            return false
        }
        runtime.read_clipboard_cb = { userdata, location, state in
            GhosttyRuntime.readClipboard(userdata, location: location, state: state)
        }
        runtime.confirm_read_clipboard_cb = { userdata, string, state, _ in
            GhosttyRuntime.confirmReadClipboard(userdata, string: string, state: state)
        }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            GhosttyRuntime.writeClipboard(content: content, count: count)
        }
        runtime.close_surface_cb = { userdata, _ in
            GhosttyRuntime.closeSurface(userdata)
        }

        guard let app = ghostty_app_new(&runtime, config) else { return nil }
        self.app = app
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// background-opacity from the user's ghostty config (1.0 = opaque).
    var backgroundOpacity: Double {
        guard let config else { return 1 }
        var v: Double = 1
        let key = "background-opacity"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    /// The terminal background color from the user's ghostty config —
    /// chrome bands tint with it so the window reads as one surface.
    var backgroundColor: NSColor {
        guard let config else { return .black }
        var c = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &c, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return .black
        }
        return NSColor(
            srgbRed: CGFloat(c.r) / 255,
            green: CGFloat(c.g) / 255,
            blue: CGFloat(c.b) / 255,
            alpha: 1)
    }

    /// Apply the config's background blur to a window (no-op when the
    /// config doesn't enable blur).
    func applyBackgroundBlur(to window: NSWindow) {
        guard let app else { return }
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: Surface-scoped callbacks (userdata is a TerminalSurfaceView)

    private static func surfaceView(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = surfaceView(userdata),
              let surface = view.surface
        else { return false }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?
    ) {
        // No confirmation dialog in v1: complete the request as-is.
        guard let view = surfaceView(userdata), let surface = view.surface else { return }
        ghostty_surface_complete_clipboard_request(surface, string, state, true)
    }

    private static func writeClipboard(
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) {
        guard let content else { return }
        for i in 0..<count {
            let entry = content[i]
            guard let mimePtr = entry.mime, let dataPtr = entry.data else { continue }
            guard String(cString: mimePtr) == "text/plain" else { continue }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(String(cString: dataPtr), forType: .string)
            return
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?) {
        guard let view = surfaceView(userdata) else { return }
        DispatchQueue.main.async { view.onClose?() }
    }
}
