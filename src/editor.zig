//! Editor engine (phase 3).
//!
//! Our own core: rope/piece-table buffers, tree-sitter (C FFI) for
//! syntax, an LSP client, Vim emulation, and a custom GPU text renderer
//! shared across editor surfaces. Owning the buffer model is what makes
//! AI inline diffs and agent-proposed edits first-class.
//!
//! Deliberately empty until phases 1–2 (multiplexer, agent orchestration,
//! automation API) are solid.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
