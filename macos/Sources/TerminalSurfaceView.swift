// A libghostty terminal surface bound to one zide pane.
//
// The surface's child process is `zide attach <pane>` — the raw
// passthrough transport — so the pane's PTY and state live in the
// daemon while all rendering and input encoding are ghostty's.
// Input handling is a deliberately minimal port of Ghostty's own
// SurfaceView: keys (no IME preedit yet), mouse, scroll, focus, resize.

import AppKit
import GhosttyKit

final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    /// Called on the main queue when ghostty asks to close the surface
    /// (child exited and was dismissed).
    var onClose: (() -> Void)?

    init(app: ghostty_app_t, command: String) {
        super.init(frame: .zero)

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // 0 = the user's configured ghostty font size
        // Keep the surface (and its final screen / error output) visible
        // after the attach client exits instead of vanishing mid-glance.
        cfg.wait_after_command = true
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        command.withCString { cmd in
            cfg.command = cmd
            self.surface = ghostty_surface_new(app, &cfg)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: Geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        updateSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
        updateSize()
    }

    private func updateScale() {
        guard let surface, let window else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func updateSize() {
        guard let surface else { return }
        // ghostty wants the framebuffer size in pixels, not points.
        let backing = convertToBacking(bounds.size)
        guard backing.width > 0, backing.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        _ = keyAction(action, event: event, text: ghosttyText(of: event))
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event, text: nil)
    }

    /// Command-modified keys arrive here, not keyDown. Ghostty reports
    /// whether the key matched one of its bindings (copy/paste/etc.);
    /// unhandled ones fall through to the menu / responder chain.
    ///
    /// Shortcuts the shell owns are refused outright: ghostty binds some
    /// of them itself (cmd+t is its new_tab) and would swallow them —
    /// but zide's layout is daemon state, so the menu must win.
    static let shellShortcuts: Set<String> = ["t", "n", "b", "k", "q", "h"]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command,
           let chars = event.charactersIgnoringModifiers,
           Self.shellShortcuts.contains(chars) {
            return false
        }
        return keyAction(GHOSTTY_ACTION_PRESS, event: event, text: ghosttyText(of: event))
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String?
    ) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        // Heuristic from Ghostty: control and command never contribute
        // to text translation; assume everything else did.
        key.consumed_mods = Self.mods(event.modifierFlags.subtracting([.control, .command]))
        key.composing = false
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            key.unshifted_codepoint = cp.value
        }
        if let text, !text.isEmpty {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    /// Ghostty's ghosttyCharacters: strip control characters (ghostty
    /// encodes those itself) and PUA function-key codepoints.
    private func ghosttyText(of event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: Mouse

    private func report(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        report(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }
    override func mouseUp(with event: NSEvent) { report(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    override func rightMouseDown(with event: NSEvent) { report(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    override func rightMouseUp(with event: NSEvent) { report(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    override func otherMouseDown(with event: NSEvent) { report(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event) }
    override func otherMouseUp(with event: NSEvent) { report(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // ghostty's origin is top-left; AppKit's is bottom-left.
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.mods(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // Ghostty's own 2x trackpad multiplier — matches upstream feel.
            x *= 2
            y *= 2
        }
        // ghostty_input_scroll_mods_t packed struct: bit 0 precision,
        // bits 1-3 momentum phase.
        var mods: Int32 = precision ? 1 : 0
        mods |= Int32(Self.momentum(event.momentumPhase).rawValue) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: return GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: return GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: return GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: return GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: return GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: return GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }
}
