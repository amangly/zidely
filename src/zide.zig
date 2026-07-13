//! zide core — UI-agnostic session server.
//!
//! Everything that is not pixels lives here: sessions, panes, PTYs, git
//! introspection, and (later) the editor engine. Platform shells (macOS
//! Swift app, Linux GTK app, the dev CLI) talk to this library through
//! a message-passing API so that the same core can later run as a
//! detached daemon. AI agents (claude, codex, ...) run as ordinary
//! processes in ordinary panes — the shell detects and surfaces them.

pub const session = @import("session.zig");
pub const gitx = @import("gitx.zig");
pub const term = @import("term.zig");
pub const ipc = @import("ipc.zig");
pub const persist = @import("persist.zig");
pub const procinfo = @import("procinfo.zig");
pub const editor = @import("editor.zig");

pub const version = "0.0.1";

test {
    @import("std").testing.refAllDecls(@This());
}
