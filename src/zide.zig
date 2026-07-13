//! zide core — UI-agnostic session server.
//!
//! Everything that is not pixels lives here: sessions, panes, PTYs, agent
//! task orchestration, git worktree management, and (later) the editor
//! engine. Platform shells (macOS Swift app, Linux GTK app, the dev CLI)
//! talk to this library through a message-passing API so that the same
//! core can later run as a detached daemon.

pub const session = @import("session.zig");
pub const agent = @import("agent.zig");
pub const gitx = @import("gitx.zig");
pub const term = @import("term.zig");
pub const ipc = @import("ipc.zig");
pub const persist = @import("persist.zig");
pub const editor = @import("editor.zig");

pub const version = "0.0.1";

test {
    @import("std").testing.refAllDecls(@This());
}
