//! Session persistence: layout + cwd respawn, and agent-task records.
//!
//! Saves every session's title and each pane's spawn recipe (argv, cwd,
//! size) as versioned JSON; restore recreates the sessions and respawns
//! the panes fresh. Processes are not checkpointed. A saved cwd that no
//! longer exists makes that pane's child exit immediately (code 125);
//! the pane still restores.
//!
//! Agent tasks are the exception to respawning: re-running an agent
//! command from scratch could redo (or undo) work, so task panes are
//! excluded from the layout and tasks are saved as records instead —
//! the ipc layer re-adopts them as pane-less, review-only tasks (see
//! agent.Manager.adoptTask).

const std = @import("std");
const session = @import("session.zig");

pub const format_version: u32 = 2;

const SavedPane = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
};

const SavedBrowser = struct {
    url: []const u8,
};

const SavedSession = struct {
    title: []const u8,
    panes: []const SavedPane = &.{},
    browsers: []const SavedBrowser = &.{},
};

/// An agent task's durable identity: enough to re-adopt its worktree
/// for review/merge/discard after a restart.
pub const TaskRecord = struct {
    repo: []const u8,
    description: []const u8,
    branch: []const u8,
    path: []const u8,
    base: []const u8,
};

pub const SavedState = struct {
    version: u32 = format_version,
    sessions: []const SavedSession = &.{},
    tasks: []const TaskRecord = &.{},
};

pub const SaveOptions = struct {
    /// Agent-task records to persist alongside the layout.
    tasks: []const TaskRecord = &.{},
    /// Panes to leave out of the layout (live agent panes).
    exclude_panes: []const session.PaneId = &.{},
    /// Sessions to leave out entirely (agents sessions that would
    /// serialize empty once their task panes are excluded).
    exclude_sessions: []const session.SessionId = &.{},
};

fn contains(comptime T: type, haystack: []const T, needle: T) bool {
    for (haystack) |h| if (h == needle) return true;
    return false;
}

/// Write the server's current layout (and task records) to `path`.
pub fn save(
    alloc: std.mem.Allocator,
    server: *session.Server,
    path: []const u8,
    opts: SaveOptions,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sessions: std.ArrayListUnmanaged(SavedSession) = .empty;
    var it = server.sessions.valueIterator();
    while (it.next()) |s| {
        if (contains(session.SessionId, opts.exclude_sessions, s.id)) continue;

        var panes: std.ArrayListUnmanaged(SavedPane) = .empty;
        for (s.panes.items) |pane_id| {
            if (contains(session.PaneId, opts.exclude_panes, pane_id)) continue;
            const h = server.panes.get(pane_id) orelse continue;
            try panes.append(arena, .{ .argv = h.argv, .cwd = h.cwd, .rows = h.rows, .cols = h.cols });
        }
        var browsers: std.ArrayListUnmanaged(SavedBrowser) = .empty;
        for (s.browsers.items) |pane_id| {
            const b = server.browser_panes.get(pane_id) orelse continue;
            try browsers.append(arena, .{ .url = b.url });
        }
        try sessions.append(arena, .{
            .title = s.title,
            .panes = panes.items,
            .browsers = browsers.items,
        });
    }

    const state: SavedState = .{ .sessions = sessions.items, .tasks = opts.tasks };
    const json = try std.fmt.allocPrint(arena, "{f}\n", .{
        std.json.fmt(state, .{ .whitespace = .indent_2 }),
    });

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(json);
}

pub const RestoreResult = struct { sessions: usize, panes: usize };

/// Parse a state file. Older versions load fine (new fields default);
/// newer ones are refused rather than silently misread.
pub fn load(alloc: std.mem.Allocator, path: []const u8) !std.json.Parsed(SavedState) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(bytes);

    const parsed = try std.json.parseFromSlice(SavedState, alloc, bytes, .{
        .ignore_unknown_fields = true,
        // The returned value outlives `bytes` — escape-free strings must
        // not be served as slices into the input buffer.
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    if (parsed.value.version > format_version) return error.UnsupportedStateVersion;
    return parsed;
}

/// Recreate a loaded layout into `server`: sessions are created and
/// panes respawned with their saved argv/cwd/size. Task records are the
/// caller's to re-adopt (the ipc layer owns agent managers).
pub fn apply(server: *session.Server, state: SavedState) !RestoreResult {
    var result: RestoreResult = .{ .sessions = 0, .panes = 0 };
    for (state.sessions) |s| {
        const sid = try server.createSession(s.title);
        result.sessions += 1;
        for (s.panes) |p| {
            _ = try server.spawnPane(sid, .{
                .argv = p.argv,
                .cwd = p.cwd,
                .rows = p.rows,
                .cols = p.cols,
            });
            result.panes += 1;
        }
        for (s.browsers) |b| {
            _ = try server.openBrowserPane(sid, b.url);
            result.panes += 1;
        }
    }
    return result;
}

/// Load + apply, for callers with no agent managers (tests, embedding).
pub fn restore(alloc: std.mem.Allocator, server: *session.Server, path: []const u8) !RestoreResult {
    const parsed = try load(alloc, path);
    defer parsed.deinit();
    return apply(server, parsed.value);
}

test "save and restore session layout" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const state_path = try std.fs.path.join(alloc, &.{ dir, "state.json" });
    defer alloc.free(state_path);

    {
        var server = try session.Server.init(alloc);
        defer server.deinit();
        const sid = try server.createSession("workbench");
        _ = try server.spawnPane(sid, .{
            .argv = &.{ "/bin/sh", "-c", "echo restore-me" },
            .rows = 30,
            .cols = 90,
        });
        try server.run();
        try save(alloc, &server, state_path, .{});
    }

    var server = try session.Server.init(alloc);
    defer server.deinit();
    const result = try restore(alloc, &server, state_path);
    try std.testing.expectEqual(@as(usize, 1), result.sessions);
    try std.testing.expectEqual(@as(usize, 1), result.panes);

    // The restored pane really respawned its command.
    try server.run();
    const sess = server.getSession(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("workbench", sess.title);
    const snap = try server.paneSnapshot(sess.panes.items[0], alloc);
    defer alloc.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "restore-me") != null);
}
