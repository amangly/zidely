//! Terminal surfaces.
//!
//! Terminal emulation and rendering are provided by embedding libghostty
//! (pinned to Ghostty v1.3.1, which is why this repo pins Zig 0.15.2).
//! This module owns the PTY lifecycle and wraps libghostty surfaces
//! behind a core-owned Pane type; the platform shells only ever see our
//! API, never libghostty's.
//!
//! Integration lands in the first real milestone; nothing to see yet.

const std = @import("std");

pub const PaneId = u64;

test {
    std.testing.refAllDecls(@This());
}
