//! Session persistence: layout + cwd respawn.
//!
//! Saves every session's title and each pane's spawn recipe (argv, cwd,
//! size) as versioned JSON; restore recreates the sessions and respawns
//! the panes fresh. Processes are not checkpointed — that's daemon-mode
//! territory (phase 2). A saved cwd that no longer exists makes that
//! pane's child exit immediately (code 125); the pane still restores.

const std = @import("std");
const session = @import("session.zig");

pub const format_version: u32 = 1;

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

const SavedState = struct {
    version: u32 = format_version,
    sessions: []const SavedSession = &.{},
};

/// Write the server's current layout to `path` as JSON.
pub fn save(alloc: std.mem.Allocator, server: *session.Server, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sessions = try arena.alloc(SavedSession, server.sessions.count());
    var it = server.sessions.valueIterator();
    var i: usize = 0;
    while (it.next()) |s| : (i += 1) {
        const panes = try arena.alloc(SavedPane, s.panes.items.len);
        for (s.panes.items, 0..) |pane_id, j| {
            const h = server.panes.get(pane_id) orelse continue;
            panes[j] = .{ .argv = h.argv, .cwd = h.cwd, .rows = h.rows, .cols = h.cols };
        }
        const browsers = try arena.alloc(SavedBrowser, s.browsers.items.len);
        for (s.browsers.items, 0..) |pane_id, j| {
            const b = server.browser_panes.get(pane_id) orelse continue;
            browsers[j] = .{ .url = b.url };
        }
        sessions[i] = .{ .title = s.title, .panes = panes, .browsers = browsers };
    }

    const state: SavedState = .{ .sessions = sessions };
    const json = try std.fmt.allocPrint(arena, "{f}\n", .{
        std.json.fmt(state, .{ .whitespace = .indent_2 }),
    });

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(json);
}

pub const RestoreResult = struct { sessions: usize, panes: usize };

/// Recreate the layout saved at `path` into `server`: sessions are
/// created and panes respawned with their saved argv/cwd/size.
pub fn restore(alloc: std.mem.Allocator, server: *session.Server, path: []const u8) !RestoreResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(bytes);

    const parsed = try std.json.parseFromSlice(SavedState, alloc, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.version != format_version) return error.UnsupportedStateVersion;

    var result: RestoreResult = .{ .sessions = 0, .panes = 0 };
    for (parsed.value.sessions) |s| {
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
        try save(alloc, &server, state_path);
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
