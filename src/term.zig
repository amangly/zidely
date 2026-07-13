//! Terminal surfaces.
//!
//! The core owns the PTY lifecycle (Pty) and terminal state (Pane wraps
//! a ghostty-vt Terminal fed by the PTY). Ghostty v1.3.1 exports its VT
//! engine as the `ghostty-vt` Zig module — that is what lives here, in
//! the core. GPU rendering via full libghostty (GhosttyKit) happens in
//! the platform shells; they read terminal state through our API and
//! never see libghostty types directly.

const std = @import("std");

pub const Pty = @import("term/Pty.zig");
pub const Pane = @import("term/Pane.zig");

pub const PaneId = u64;

test {
    std.testing.refAllDecls(@This());
}
