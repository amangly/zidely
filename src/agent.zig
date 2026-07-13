//! Agent task orchestration.
//!
//! Phase 1 model: agents are external CLI tools (Claude Code, Codex,
//! Aider, ...) running in PTY panes. An AgentTask ties together the
//! description, the git worktree it is isolated to, the pane the agent
//! runs in, and its status. A native in-process agent arrives in a later
//! phase behind this same task model.

const std = @import("std");
const xev = @import("xev").Dynamic;
const session = @import("session.zig");
const gitx = @import("gitx.zig");

pub const TaskId = u64;

pub const Status = enum {
    /// Agent process is running and producing output.
    working,
    /// Agent likely waits for user input: it rang the bell, or went
    /// quiet while running (TUI agents animate while they work).
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
    /// Wall clock (ms) of the last PTY output, for quiescence detection.
    last_output_ms: i64 = 0,
};

/// A task changed status. Shells subscribe to drive notification rings.
pub const TaskEvent = struct { task: TaskId, status: Status };

pub const TaskEventHandler = struct {
    userdata: ?*anyopaque = null,
    /// Called from inside the event loop; keep it quick and non-blocking.
    func: *const fn (userdata: ?*anyopaque, manager: *Manager, event: TaskEvent) void,
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
    /// Subscriber for task status changes.
    task_handler: ?TaskEventHandler = null,
    attention_after_ms: u32,
    timer: xev.Timer,
    timer_c: xev.Completion = .{},
    timer_armed: bool = false,

    pub const Options = struct {
        /// Repository agent tasks operate on (its root).
        repo: []const u8,
        /// Directory task worktrees are created under.
        worktrees_dir: []const u8,
        /// A working task with no output for this long is assumed to be
        /// waiting for input and flips to needs_attention.
        attention_after_ms: u32 = 2000,
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
            .attention_after_ms = opts.attention_after_ms,
            .timer = try xev.Timer.init(),
        };
        server.handler = .{ .userdata = self, .func = onEvent };
        return self;
    }

    /// Releases task bookkeeping; does NOT remove worktrees (they may
    /// hold unreviewed agent work). Restores the previous event handler.
    /// Only call once the event loop is drained: an armed quiescence
    /// timer still references this manager.
    pub fn destroy(self: *Manager) void {
        self.timer.deinit();
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
            .last_output_ms = std.time.milliTimestamp(),
        };
        errdefer self.alloc.free(task.description);

        try self.tasks.put(self.alloc, id, task);
        errdefer _ = self.tasks.remove(id);
        try self.by_pane.put(self.alloc, pane, id);
        self.next_task_id += 1;
        self.ensureTimer();
        return id;
    }

    /// Current task state, by value.
    pub fn get(self: *Manager, id: TaskId) ?Task {
        const task = self.tasks.get(id) orelse return null;
        return task.*;
    }

    /// What the task changed so far: full diff vs its base plus commit
    /// count and dirtiness. Works mid-run too (peeking at a working
    /// agent is legitimate review).
    pub fn reviewTask(self: *Manager, id: TaskId, alloc: std.mem.Allocator) !gitx.Review {
        const task = self.tasks.get(id) orelse return error.NoSuchTask;
        return gitx.reviewTaskWorktree(alloc, task.worktree);
    }

    /// Merge a finished task's branch into the repo's current branch,
    /// then remove its worktree and branch. Refuses while the agent is
    /// running or the worktree has uncommitted work.
    pub fn mergeTask(self: *Manager, id: TaskId) !void {
        const task = self.tasks.get(id) orelse return error.NoSuchTask;
        if (task.status != .finished) return error.TaskStillRunning;
        try gitx.mergeTaskBranch(self.alloc, self.repo, task.worktree);
        try self.cleanupTask(id, .{ .delete_branch = true });
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

        // The agent's pane is exited (status is finished); drop it from
        // its session rather than leaving a dead pane behind. Best
        // effort: a still-draining PTY keeps the pane until later.
        self.server.removePane(task.pane) catch {};

        _ = self.tasks.remove(id);
        _ = self.by_pane.remove(task.pane);
        self.destroyTask(task);
    }

    fn setStatus(self: *Manager, task: *Task, status: Status) void {
        if (task.status == status) return;
        task.status = status;
        if (self.task_handler) |h|
            h.func(h.userdata, self, .{ .task = task.id, .status = status });
    }

    fn taskForPane(self: *Manager, pane: session.PaneId) ?*Task {
        const task_id = self.by_pane.get(pane) orelse return null;
        return self.tasks.get(task_id);
    }

    fn onEvent(ud: ?*anyopaque, server: *session.Server, event: session.Event) void {
        const self: *Manager = @ptrCast(@alignCast(ud.?));
        switch (event) {
            .pane_output => |p| if (self.taskForPane(p.pane)) |task| {
                task.last_output_ms = std.time.milliTimestamp();
                if (task.status == .needs_attention) self.setStatus(task, .working);
                self.ensureTimer();
            },
            .pane_bell => |pane| if (self.taskForPane(pane)) |task| {
                if (task.status != .finished) self.setStatus(task, .needs_attention);
            },
            .pane_exit => |e| if (self.taskForPane(e.pane)) |task| {
                task.exit_code = e.exit_code;
                self.setStatus(task, .finished);
            },
        }
        if (self.downstream) |d| d.func(d.userdata, server, event);
    }

    fn anyWorking(self: *Manager) bool {
        var it = self.tasks.valueIterator();
        while (it.next()) |task| if (task.*.status == .working) return true;
        return false;
    }

    /// Arm the quiescence timer if any task needs watching. The timer
    /// disarms itself when nothing is working so that a drained loop
    /// can finish (`Server.run` runs until no work remains).
    fn ensureTimer(self: *Manager) void {
        if (self.timer_armed or !self.anyWorking()) return;
        self.timer_armed = true;
        const interval = @max(self.attention_after_ms / 2, 25);
        self.timer.run(&self.server.loop, &self.timer_c, interval, Manager, self, onTimer);
    }

    fn onTimer(
        ud: ?*Manager,
        loop: *xev.Loop,
        c: *xev.Completion,
        r: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = loop;
        _ = c;
        const self = ud.?;
        r catch {
            self.timer_armed = false;
            return .disarm;
        };

        const now = std.time.milliTimestamp();
        var it = self.tasks.valueIterator();
        while (it.next()) |task_ptr| {
            const task = task_ptr.*;
            if (task.status != .working) continue;
            if (now - task.last_output_ms >= self.attention_after_ms)
                self.setStatus(task, .needs_attention);
        }

        if (self.anyWorking()) return .rearm;
        self.timer_armed = false;
        return .disarm;
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
    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zide-worktrees" });
    defer alloc.free(wt_dir);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const sid = try server.createSession("agents");

    var manager = try Manager.create(alloc, &server, sid, .{
        .repo = repo,
        .worktrees_dir = wt_dir,
        .attention_after_ms = 300,
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
        try std.testing.expectEqualStrings("zide/add-feature-x", task.worktree.branch);
    }

    try server.run();

    const task = manager.get(task_id).?;
    try std.testing.expectEqual(Status.finished, task.status);
    try std.testing.expectEqual(@as(?u8, 0), task.exit_code);

    const snap = try server.paneSnapshot(task.pane, alloc);
    defer alloc.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "zide/add-feature-x") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "agent-finished") != null);

    // Review sees the agent's committed work.
    {
        var review = try manager.reviewTask(task_id, alloc);
        defer review.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 1), review.commits);
        try std.testing.expect(!review.dirty);
        try std.testing.expect(std.mem.indexOf(u8, review.diff, "done.txt") != null);
    }

    // The agent's commit landed on the task branch, not on main.
    try manager.cleanupTask(task_id, .{ .delete_branch = false });
    var count_out = std.ArrayList(u8).empty;
    defer count_out.deinit(alloc);
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "-C", repo, "rev-list", "--count", "zide/add-feature-x" },
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try std.testing.expectEqualStrings("2", std.mem.trim(u8, res.stdout, " \n"));
}

test "merge lands agent work on the base branch and forgets the task" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try gitx.setupTestRepo(alloc, repo);
    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zide-worktrees" });
    defer alloc.free(wt_dir);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const sid = try server.createSession("agents");
    var manager = try Manager.create(alloc, &server, sid, .{
        .repo = repo,
        .worktrees_dir = wt_dir,
        .attention_after_ms = 60_000,
    });
    defer manager.destroy();

    const task_id = try manager.startTask(.{
        .description = "merge me",
        .argv = &.{ "/bin/sh", "-c", "echo merged-content > merged.txt && git add . && " ++
            "git -c user.name=t -c user.email=t@t.invalid commit -qm work" },
    });

    try std.testing.expectError(error.TaskStillRunning, manager.mergeTask(task_id));
    try server.run();
    try manager.mergeTask(task_id);

    try std.testing.expectEqual(@as(?Task, null), manager.get(task_id));
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "-C", repo, "show", "main:merged.txt" },
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try std.testing.expectEqualStrings("merged-content\n", res.stdout);
}

test "cleanup refuses while the agent is still running" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try gitx.setupTestRepo(alloc, repo);
    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zide-worktrees" });
    defer alloc.free(wt_dir);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const sid = try server.createSession("agents");
    var manager = try Manager.create(alloc, &server, sid, .{
        .repo = repo,
        .worktrees_dir = wt_dir,
        .attention_after_ms = 300,
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

const StatusRecorder = struct {
    events: [16]TaskEvent = undefined,
    len: usize = 0,

    fn on(ud: ?*anyopaque, manager: *Manager, event: TaskEvent) void {
        _ = manager;
        const self: *StatusRecorder = @ptrCast(@alignCast(ud.?));
        if (self.len < self.events.len) {
            self.events[self.len] = event;
            self.len += 1;
        }
    }

    fn statuses(self: *const StatusRecorder) []const TaskEvent {
        return self.events[0..self.len];
    }
};

test "quiet task flips to needs_attention and back on output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try gitx.setupTestRepo(alloc, repo);
    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zide-worktrees" });
    defer alloc.free(wt_dir);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const sid = try server.createSession("agents");
    var manager = try Manager.create(alloc, &server, sid, .{
        .repo = repo,
        .worktrees_dir = wt_dir,
        .attention_after_ms = 150,
    });
    defer manager.destroy();

    var recorder: StatusRecorder = .{};
    manager.task_handler = .{ .userdata = &recorder, .func = StatusRecorder.on };

    // Outputs, goes quiet well past the threshold, outputs again, exits.
    _ = try manager.startTask(.{
        .description = "quiet spell",
        .argv = &.{ "/bin/sh", "-c", "echo start; sleep 0.7; echo resumed" },
    });
    try server.run();

    const events = recorder.statuses();
    try std.testing.expect(events.len >= 2);
    try std.testing.expectEqual(Status.finished, events[events.len - 1].status);

    // Quiescence must have fired, and output must have recovered it.
    var first_attention: ?usize = null;
    for (events, 0..) |e, i| {
        if (e.status == .needs_attention) {
            first_attention = i;
            break;
        }
    }
    try std.testing.expect(first_attention != null);
    var recovered = false;
    for (events[first_attention.?..]) |e| {
        if (e.status == .working) recovered = true;
    }
    try std.testing.expect(recovered);
}

test "bell flips to needs_attention immediately" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    try gitx.setupTestRepo(alloc, repo);
    const wt_dir = try std.fs.path.join(alloc, &.{ repo, ".zide-worktrees" });
    defer alloc.free(wt_dir);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const sid = try server.createSession("agents");
    // Huge quiescence threshold: any needs_attention here is bell-driven.
    var manager = try Manager.create(alloc, &server, sid, .{
        .repo = repo,
        .worktrees_dir = wt_dir,
        .attention_after_ms = 60_000,
    });
    defer manager.destroy();

    var recorder: StatusRecorder = .{};
    manager.task_handler = .{ .userdata = &recorder, .func = StatusRecorder.on };

    const task_id = try manager.startTask(.{
        .description = "asks a question",
        .argv = &.{ "/bin/sh", "-c", "printf '\\aproceed? '; read _; echo ok" },
    });
    try server.paneWrite(manager.get(task_id).?.pane, "y\n");
    try server.run();

    const events = recorder.statuses();
    try std.testing.expect(events.len >= 2);
    try std.testing.expectEqual(Status.needs_attention, events[0].status);
    try std.testing.expectEqual(Status.finished, events[events.len - 1].status);
}
