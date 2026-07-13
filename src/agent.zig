//! Agent task orchestration.
//!
//! Phase 1 model: agents are external CLI tools (Claude Code, Codex,
//! Aider, ...) running in PTYs. An AgentTask ties together the pane the
//! agent runs in, the git worktree it is isolated to, and its attention
//! state (idle / working / needs-attention) that drives notifications.
//! A native in-process agent arrives in a later phase behind this same
//! task model.

const std = @import("std");

pub const Status = enum {
    /// Task created, worktree/pane not yet provisioned.
    pending,
    /// Agent process is running and producing output.
    working,
    /// Agent is waiting for user input — surfaced as a notification ring.
    needs_attention,
    /// Agent process exited; work is ready for review/merge.
    finished,
};

pub const AgentTask = struct {
    /// Short human description, e.g. "fix flaky auth tests".
    description: []const u8,
    status: Status = .pending,
};

test "agent task defaults to pending" {
    const task: AgentTask = .{ .description = "fix flaky auth tests" };
    try std.testing.expectEqual(Status.pending, task.status);
}
