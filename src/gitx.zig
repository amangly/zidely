//! Git integration: managed worktree-per-agent-task.
//!
//! Creating an agent task provisions a worktree + branch; finishing one
//! walks a review → merge → clean-up flow. Implementation shells out to
//! `git` (libgit2 FFI only if it ever proves necessary). This module also
//! grows the repo-status queries (branch, dirty state, ahead/behind) that
//! tabs display, and eventually the commit-graph model for the git UI.

const std = @import("std");

pub const branch_prefix = "zidely/";

/// Derive a branch name from a task description:
/// "Fix flaky auth tests!" -> "zidely/fix-flaky-auth-tests".
pub fn branchNameForTask(buf: []u8, description: []const u8) ![]const u8 {
    if (buf.len < branch_prefix.len) return error.NoSpaceLeft;
    @memcpy(buf[0..branch_prefix.len], branch_prefix);

    var len: usize = branch_prefix.len;
    var pending_dash = false;
    for (description) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            if (pending_dash and len > branch_prefix.len) {
                if (len >= buf.len) return error.NoSpaceLeft;
                buf[len] = '-';
                len += 1;
            }
            pending_dash = false;
            if (len >= buf.len) return error.NoSpaceLeft;
            buf[len] = lower;
            len += 1;
        } else {
            pending_dash = true;
        }
    }
    if (len == branch_prefix.len) return error.EmptyTaskDescription;
    return buf[0..len];
}

test "branch name slugification" {
    var buf: [64]u8 = undefined;
    const name = try branchNameForTask(&buf, "Fix flaky auth tests!");
    try std.testing.expectEqualStrings("zidely/fix-flaky-auth-tests", name);
}

test "branch name rejects empty descriptions" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.EmptyTaskDescription, branchNameForTask(&buf, "!!!"));
}
