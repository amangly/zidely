//! Git integration: managed worktree-per-agent-task.
//!
//! Creating an agent task provisions a worktree + branch; finishing one
//! walks a review → merge → clean-up flow. Implementation shells out to
//! `git` (libgit2 FFI only if it ever proves necessary). This module also
//! grows the repo-status queries (branch, dirty state, ahead/behind) that
//! tabs display, and eventually the commit-graph model for the git UI.

const std = @import("std");

pub const branch_prefix = "zide/";

pub const Error = error{
    GitFailed,
    EmptyTaskDescription,
    BranchNamespaceExhausted,
};

/// A provisioned task worktree. Strings are owned by the creating
/// allocator; release with deinit().
pub const Worktree = struct {
    /// Task branch, e.g. "zide/fix-flaky-auth-tests".
    branch: []const u8,
    /// Absolute path of the worktree directory.
    path: []const u8,

    pub fn deinit(self: *Worktree, alloc: std.mem.Allocator) void {
        alloc.free(self.branch);
        alloc.free(self.path);
        self.* = undefined;
    }
};

/// Run git with the given args in `repo` and return trimmed stdout,
/// owned by `alloc`. Non-zero exit becomes error.GitFailed (stderr goes
/// to the debug log).
fn git(alloc: std.mem.Allocator, repo: []const u8, args: []const []const u8) ![]const u8 {
    var argv = try std.ArrayList([]const u8).initCapacity(alloc, args.len + 3);
    defer argv.deinit(alloc);
    argv.appendAssumeCapacity("git");
    argv.appendAssumeCapacity("-C");
    argv.appendAssumeCapacity(repo);
    argv.appendSliceAssumeCapacity(args);

    const res = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return error.GitFailed;
    defer alloc.free(res.stderr);
    errdefer alloc.free(res.stdout);

    switch (res.term) {
        .Exited => |code| if (code != 0) {
            std.log.debug("git {s} failed ({d}): {s}", .{ args[0], code, res.stderr });
            return error.GitFailed;
        },
        else => return error.GitFailed,
    }

    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == res.stdout.len) return res.stdout;
    const out = try alloc.dupe(u8, trimmed);
    alloc.free(res.stdout);
    return out;
}

/// Root of the repository containing `dir`. Caller owns the result.
pub fn repoRoot(alloc: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return git(alloc, dir, &.{ "rev-parse", "--show-toplevel" });
}

fn branchExists(alloc: std.mem.Allocator, repo: []const u8, branch: []const u8) !bool {
    const ref = try std.fmt.allocPrint(alloc, "refs/heads/{s}", .{branch});
    defer alloc.free(ref);
    const out = git(alloc, repo, &.{ "rev-parse", "--verify", "--quiet", ref }) catch return false;
    alloc.free(out);
    return true;
}

pub const CreateOptions = struct {
    /// Directory to create worktrees under (created if missing).
    worktrees_dir: []const u8,
    /// Ref the task branch starts from; HEAD when null.
    base_ref: ?[]const u8 = null,
};

/// Provision an isolated worktree + branch for an agent task described
/// by `description`. Branch and directory names derive from the slugged
/// description, with a numeric suffix on collision.
pub fn createTaskWorktree(
    alloc: std.mem.Allocator,
    repo: []const u8,
    description: []const u8,
    opts: CreateOptions,
) !Worktree {
    var name_buf: [128]u8 = undefined;
    const base = try branchNameForTask(&name_buf, description);

    try std.fs.cwd().makePath(opts.worktrees_dir);

    var attempt: u32 = 0;
    const branch: []const u8 = while (attempt < 100) : (attempt += 1) {
        const candidate = if (attempt == 0)
            try alloc.dupe(u8, base)
        else
            try std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, attempt + 1 });

        if (!(try branchExists(alloc, repo, candidate))) break candidate;
        alloc.free(candidate);
    } else return error.BranchNamespaceExhausted;
    errdefer alloc.free(branch);

    const path = try std.fs.path.join(alloc, &.{
        opts.worktrees_dir,
        branch[branch_prefix.len..],
    });
    errdefer alloc.free(path);

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    try args.appendSlice(alloc, &.{ "worktree", "add", "-b", branch, path });
    if (opts.base_ref) |ref| try args.append(alloc, ref);

    const out = try git(alloc, repo, args.items);
    alloc.free(out);

    return .{ .branch = branch, .path = path };
}

pub const RemoveOptions = struct {
    /// Also delete the task branch (forced — agent branches may be
    /// unmerged when discarded).
    delete_branch: bool = false,
    /// Remove even if the worktree has uncommitted changes.
    force: bool = false,
};

/// Tear down a task worktree created by createTaskWorktree. Does not
/// free `wt` — the caller still owns it.
pub fn removeTaskWorktree(
    alloc: std.mem.Allocator,
    repo: []const u8,
    wt: Worktree,
    opts: RemoveOptions,
) !void {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    try args.appendSlice(alloc, &.{ "worktree", "remove" });
    if (opts.force) try args.append(alloc, "--force");
    try args.append(alloc, wt.path);

    const out = try git(alloc, repo, args.items);
    alloc.free(out);

    if (opts.delete_branch) {
        const bout = try git(alloc, repo, &.{ "branch", "-D", wt.branch });
        alloc.free(bout);
    }
}

/// Derive a branch name from a task description:
/// "Fix flaky auth tests!" -> "zide/fix-flaky-auth-tests".
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
    try std.testing.expectEqualStrings("zide/fix-flaky-auth-tests", name);
}

test "branch name rejects empty descriptions" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.EmptyTaskDescription, branchNameForTask(&buf, "!!!"));
}

/// Create a scratch git repository with one commit. Test helper shared
/// with agent.zig.
pub fn setupTestRepo(alloc: std.mem.Allocator, path: []const u8) !void {
    inline for (.{
        .{ "init", "-q", "-b", "main" },
        .{ "-c", "user.name=zide-test", "-c", "user.email=test@zide.invalid", "commit", "-q", "--allow-empty", "-m", "init" },
    }) |args| {
        const out = try git(alloc, path, &args);
        alloc.free(out);
    }
}

test "worktree lifecycle: create, collide, remove" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try setupTestRepo(alloc, repo);

    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zide-worktrees" });
    defer alloc.free(wt_dir);

    var wt1 = try createTaskWorktree(alloc, repo, "Fix auth bug", .{ .worktrees_dir = wt_dir });
    defer wt1.deinit(alloc);
    try std.testing.expectEqualStrings("zide/fix-auth-bug", wt1.branch);
    try std.fs.accessAbsolute(wt1.path, .{});

    // Same description again: branch and directory must not collide.
    var wt2 = try createTaskWorktree(alloc, repo, "Fix auth bug", .{ .worktrees_dir = wt_dir });
    defer wt2.deinit(alloc);
    try std.testing.expectEqualStrings("zide/fix-auth-bug-2", wt2.branch);
    try std.fs.accessAbsolute(wt2.path, .{});

    // The worktree is a real checkout on the task branch.
    const head = try git(alloc, wt1.path, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer alloc.free(head);
    try std.testing.expectEqualStrings("zide/fix-auth-bug", head);

    try removeTaskWorktree(alloc, repo, wt1, .{ .delete_branch = true });
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(wt1.path, .{}));
    try std.testing.expect(!(try branchExists(alloc, repo, wt1.branch)));
}
