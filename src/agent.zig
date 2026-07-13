//! Agent task orchestration.
//!
//! Phase 1 model: agents are external CLI tools (Claude Code, Codex,
//! Aider, ...) running in PTY panes. An AgentTask ties together the
//! description, the git worktree it is isolated to, the pane the agent
//! runs in, and its status. A native in-process agent arrives in a later
//! phase behind this same task model.

const std = @import("std");
const session = @import("session.zig");
const gitx = @import("gitx.zig");

pub const TaskId = u64;

pub const Status = enum {
    /// Agent process is running.
    working,
    /// Agent is waiting for user input — surfaced as a notification.
    /// (Detection heuristics land with the shell; unused until then.)
    needs_attention,
    /// Agent process exited; work is ready for review/merge/cleanup.
    finished,
};

pub const Task = struct {
    id: TaskId,
    /// Short human description, e.g. "fix flaky auth tests". Owned.
    description: []const u8,
    worktree: gitx.Worktree,
    pane: session.PaneId,
    status: Status,
    exit_code: ?u8 = null,
};

/// Orchestrates agent tasks on top of a session server: provisions the
/// worktree, spawns the agent pane inside it, and tracks task status by
/// listening to the server's event stream (forwarding every event to
/// whatever handler was installed before — shells keep their view).
pub const Manager = struct {
    alloc: std.mem.Allocator,
    server: *session.Server,
    session_id: session.SessionId,
    repo: []const u8,
    worktrees_dir: []const u8,
    tasks: std.AutoHashMapUnmanaged(TaskId, *Task),
    by_pane: std.AutoHashMapUnmanaged(session.PaneId, TaskId),
    next_task_id: TaskId = 1,
    downstream: ?session.EventHandler,

    pub const Options = struct {
        /// Repository agent tasks operate on (its root).
        repo: []const u8,
        /// Directory task worktrees are created under.
        worktrees_dir: []const u8,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        server: *session.Server,
        session_id: session.SessionId,
        opts: Options,
    ) !*Manager {
        const self = try alloc.create(Manager);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .server = server,
            .session_id = session_id,
            .repo = try alloc.dupe(u8, opts.repo),
            .worktrees_dir = try alloc.dupe(u8, opts.worktrees_dir),
            .tasks = .empty,
            .by_pane = .empty,
            .downstream = server.handler,
        };
        server.handler = .{ .userdata = self, .func = onEvent };
        return self;
    }

    /// Releases task bookkeeping; does NOT remove worktrees (they may
    /// hold unreviewed agent work). Restores the previous event handler.
    pub fn destroy(self: *Manager) void {
        self.server.handler = self.downstream;
        var it = self.tasks.valueIterator();
        while (it.next()) |task_ptr| self.destroyTask(task_ptr.*);
        self.tasks.deinit(self.alloc);
        self.by_pane.deinit(self.alloc);
        self.alloc.free(self.repo);
        self.alloc.free(self.worktrees_dir);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    fn destroyTask(self: *Manager, task: *Task) void {
        self.alloc.free(task.description);
        task.worktree.deinit(self.alloc);
        self.alloc.destroy(task);
    }

    pub const StartOptions = struct {
        /// What the agent should do; becomes the branch/worktree name.
        description: []const u8,
        /// Agent command, e.g. {"claude", "-p", "..."} — any CLI tool.
        argv: []const []const u8,
        rows: u16 = 24,
        cols: u16 = 80,
        /// Ref the task branch starts from; HEAD when null.
        base_ref: ?[]const u8 = null,
    };

    /// Provision a worktree + branch for the task and spawn the agent
    /// in a pane whose working directory is that worktree.
    pub fn startTask(self: *Manager, opts: StartOptions) !TaskId {
        var wt = try gitx.createTaskWorktree(self.alloc, self.repo, opts.description, .{
            .worktrees_dir = self.worktrees_dir,
            .base_ref = opts.base_ref,
        });
        errdefer {
            gitx.removeTaskWorktree(self.alloc, self.repo, wt, .{
                .delete_branch = true,
                .force = true,
            }) catch {};
            wt.deinit(self.alloc);
        }

        const pane = try self.server.spawnPane(self.session_id, .{
            .rows = opts.rows,
            .cols = opts.cols,
            .argv = opts.argv,
            .cwd = wt.path,
        });

        const task = try self.alloc.create(Task);
        errdefer self.alloc.destroy(task);
        const id = self.next_task_id;
        task.* = .{
            .id = id,
            .description = try self.alloc.dupe(u8, opts.description),
            .worktree = wt,
            .pane = pane,
            .status = .working,
        };
        errdefer self.alloc.free(task.description);

        try self.tasks.put(self.alloc, id, task);
        errdefer _ = self.tasks.remove(id);
        try self.by_pane.put(self.alloc, pane, id);
        self.next_task_id += 1;
        return id;
    }

    /// Current task state, by value.
    pub fn get(self: *Manager, id: TaskId) ?Task {
        const task = self.tasks.get(id) orelse return null;
        return task.*;
    }

    pub const CleanupOptions = struct {
        /// Delete the task branch too (forced); keep it for merging
        /// when false.
        delete_branch: bool = false,
        /// Remove the worktree even with uncommitted changes.
        force: bool = false,
    };

    /// Remove a finished task's worktree (and optionally its branch),
    /// then forget the task. The review/merge flow happens before this.
    pub fn cleanupTask(self: *Manager, id: TaskId, opts: CleanupOptions) !void {
        const task = self.tasks.get(id) orelse return error.NoSuchTask;
        if (task.status != .finished) return error.TaskStillRunning;

        try gitx.removeTaskWorktree(self.alloc, self.repo, task.worktree, .{
            .delete_branch = opts.delete_branch,
            .force = opts.force,
        });

        _ = self.tasks.remove(id);
        _ = self.by_pane.remove(task.pane);
        self.destroyTask(task);
    }

    fn onEvent(ud: ?*anyopaque, server: *session.Server, event: session.Event) void {
        const self: *Manager = @ptrCast(@alignCast(ud.?));
        switch (event) {
            .pane_exit => |e| if (self.by_pane.get(e.pane)) |task_id| {
                if (self.tasks.get(task_id)) |task| {
                    task.status = .finished;
                    task.exit_code = e.exit_code;
                }
            },
            // Attention detection (agent waiting for input) hooks in
            // here once the heuristics exist.
            .pane_output => {},
        }
        if (self.downstream) |d| d.func(d.userdata, server, event);
    }
};

test "agent task runs in its own worktree and reports finish" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try gitx.setupTestRepo(alloc, repo);
    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zidely-worktrees" });
    defer alloc.free(wt_dir);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const sid = try server.createSession("agents");

    var manager = try Manager.create(alloc, &server, sid, .{
        .repo = repo,
        .worktrees_dir = wt_dir,
    });
    defer manager.destroy();

    // A stand-in agent: prove we're on the task branch, in the task
    // worktree, then commit something and finish.
    const task_id = try manager.startTask(.{
        .description = "Add feature X",
        .argv = &.{ "/bin/sh", "-c", "git rev-parse --abbrev-ref HEAD && touch done.txt && git add . && " ++
            "git -c user.name=t -c user.email=t@t.invalid commit -qm agent-work && echo agent-finished" },
    });

    {
        const task = manager.get(task_id).?;
        try std.testing.expectEqual(Status.working, task.status);
        try std.testing.expectEqualStrings("zidely/add-feature-x", task.worktree.branch);
    }

    try server.run();

    const task = manager.get(task_id).?;
    try std.testing.expectEqual(Status.finished, task.status);
    try std.testing.expectEqual(@as(?u8, 0), task.exit_code);

    const snap = try server.paneSnapshot(task.pane, alloc);
    defer alloc.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "zidely/add-feature-x") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "agent-finished") != null);

    // The agent's commit landed on the task branch, not on main.
    try manager.cleanupTask(task_id, .{ .delete_branch = false });
    var count_out = std.ArrayList(u8).empty;
    defer count_out.deinit(alloc);
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "-C", repo, "rev-list", "--count", "zidely/add-feature-x" },
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try std.testing.expectEqualStrings("2", std.mem.trim(u8, res.stdout, " \n"));
}

test "cleanup refuses while the agent is still running" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try gitx.setupTestRepo(alloc, repo);
    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zidely-worktrees" });
    defer alloc.free(wt_dir);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const sid = try server.createSession("agents");
    var manager = try Manager.create(alloc, &server, sid, .{
        .repo = repo,
        .worktrees_dir = wt_dir,
    });
    defer manager.destroy();

    const task_id = try manager.startTask(.{
        .description = "long running",
        .argv = &.{ "/bin/sh", "-c", "read _" },
    });
    try std.testing.expectError(error.TaskStillRunning, manager.cleanupTask(task_id, .{}));

    // Unblock the child so the loop can drain and the test can end.
    try server.paneWrite(manager.get(task_id).?.pane, "\n");
    try server.run();
    try std.testing.expectEqual(Status.finished, manager.get(task_id).?.status);
}
