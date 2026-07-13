//! Git introspection: the repo-status queries (branch, dirty state)
//! that pane metadata displays, and eventually the commit-graph model
//! for the git UI. Shells out to `git` (libgit2 FFI only if it ever
//! proves necessary).

const std = @import("std");

pub const Error = error{GitFailed};

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

pub const RepoStatus = struct {
    /// Current branch name, or short SHA when detached. Owned.
    branch: []const u8,
    /// Tracked files modified (untracked ignored: cheap, and noise for
    /// a status glance).
    dirty: bool,

    pub fn deinit(self: *RepoStatus, alloc: std.mem.Allocator) void {
        alloc.free(self.branch);
        self.* = undefined;
    }
};

/// Branch + dirtiness of the repository containing `dir`, or null when
/// it isn't inside one — pane metadata for status displays.
pub fn repoStatus(alloc: std.mem.Allocator, dir: []const u8) ?RepoStatus {
    const branch = git(alloc, dir, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) catch return null;
    errdefer alloc.free(branch);
    const status = git(alloc, dir, &.{ "status", "--porcelain", "--untracked-files=no" }) catch {
        alloc.free(branch);
        return null;
    };
    defer alloc.free(status);
    return .{ .branch = branch, .dirty = status.len != 0 };
}

/// Create a scratch git repository with one commit. Test helper shared
/// with the ipc tests.
pub fn setupTestRepo(alloc: std.mem.Allocator, path: []const u8) !void {
    inline for (.{
        .{ "init", "-q", "-b", "main" },
        .{ "-c", "user.name=zide-test", "-c", "user.email=test@zide.invalid", "commit", "-q", "--allow-empty", "-m", "init" },
    }) |args| {
        const out = try git(alloc, path, &args);
        alloc.free(out);
    }
}

test "repoStatus reports branch and dirtiness" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try setupTestRepo(alloc, repo);

    var status = repoStatus(alloc, repo) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", status.branch);
    try std.testing.expect(!status.dirty);
    status.deinit(alloc);

    // Modified tracked file → dirty; untracked files stay ignored.
    try tmp.dir.writeFile(.{ .sub_path = "repo/tracked.txt", .data = "v1" });
    const add = try git(alloc, repo, &.{ "add", "tracked.txt" });
    alloc.free(add);
    const commit = try git(alloc, repo, &.{
        "-c", "user.name=t", "-c", "user.email=t@t.invalid", "commit", "-qm", "add",
    });
    alloc.free(commit);
    try tmp.dir.writeFile(.{ .sub_path = "repo/tracked.txt", .data = "v2" });

    var dirty = repoStatus(alloc, repo) orelse return error.TestUnexpectedResult;
    try std.testing.expect(dirty.dirty);
    dirty.deinit(alloc);

    // Not a repo → null. (The tmp dir itself lives under .zig-cache,
    // inside this very repository — use the filesystem root instead.)
    try std.testing.expect(repoStatus(alloc, "/") == null);
}
