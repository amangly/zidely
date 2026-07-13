//! Live process introspection for pane metadata: a child's current
//! working directory, its descendant processes, and their listening TCP
//! ports. macOS uses libproc; Linux uses /proc. Ports go through
//! `lsof` — descendants matter because shells put jobs in their own
//! process groups, so a dev server is not in the pane child's group.

const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.os.tag.isDarwin())
    @cImport({
        @cInclude("libproc.h");
    })
else
    struct {};

/// Current working directory of a live process, or null if it can't be
/// read (process gone, permissions). Caller owns the result.
pub fn cwdOfPid(alloc: std.mem.Allocator, pid: std.posix.pid_t) ?[]const u8 {
    if (comptime builtin.os.tag.isDarwin()) {
        var info: c.proc_vnodepathinfo = undefined;
        const rc = c.proc_pidinfo(pid, c.PROC_PIDVNODEPATHINFO, 0, &info, @sizeOf(c.proc_vnodepathinfo));
        if (rc <= 0) return null;
        const path = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
        if (path.len == 0) return null;
        return alloc.dupe(u8, path) catch null;
    } else {
        var link_buf: [64]u8 = undefined;
        const link = std.fmt.bufPrint(&link_buf, "/proc/{d}/cwd", .{pid}) catch return null;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fs.readLinkAbsolute(link, &path_buf) catch return null;
        return alloc.dupe(u8, path) catch null;
    }
}

// Zig 0.15.2's std.c doesn't declare tcgetpgrp; both libcs have it.
extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;

/// Command name of the PTY's foreground process group leader — what
/// tmux calls pane_current_command ("vim", "sleep", "zsh"). Null when
/// nothing can be reported (dead fd, ps failure). Caller owns the
/// result.
pub fn foregroundCommand(alloc: std.mem.Allocator, master_fd: std.posix.fd_t) ?[]const u8 {
    const pgid = tcgetpgrp(master_fd);
    if (pgid <= 0) return null;
    var buf: [16]u8 = undefined;
    const pid_s = std.fmt.bufPrint(&buf, "{d}", .{pgid}) catch return null;
    const res = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "ps", "-o", "comm=", "-p", pid_s },
    }) catch return null;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.term != .Exited or res.term.Exited != 0) return null;
    // "-zsh" for login shells, "/bin/zsh" when ps reports a path.
    const trimmed = std.mem.trim(u8, res.stdout, " \t\n-");
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, std.fs.path.basename(trimmed)) catch null;
}

/// A point-in-time snapshot of the process table (pid → parent).
pub const ProcessTree = struct {
    entries: []const Entry,

    pub const Entry = struct { pid: i32, ppid: i32 };

    /// One `ps` call captures the whole table; all descendant queries
    /// afterwards are in-memory.
    pub fn snapshot(arena: std.mem.Allocator) !ProcessTree {
        const res = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "ps", "-axo", "pid=,ppid=" },
            .max_output_bytes = 4 * 1024 * 1024,
        }) catch return error.PsFailed;
        if (res.term != .Exited or res.term.Exited != 0) return error.PsFailed;

        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        var lines = std.mem.tokenizeScalar(u8, res.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const pid_s = fields.next() orelse continue;
            const ppid_s = fields.next() orelse continue;
            const pid = std.fmt.parseInt(i32, pid_s, 10) catch continue;
            const ppid = std.fmt.parseInt(i32, ppid_s, 10) catch continue;
            try entries.append(arena, .{ .pid = pid, .ppid = ppid });
        }
        return .{ .entries = entries.items };
    }

    /// The process and everything below it, breadth-first.
    pub fn descendantsOf(self: ProcessTree, arena: std.mem.Allocator, root: i32) ![]const i32 {
        var out: std.ArrayListUnmanaged(i32) = .empty;
        try out.append(arena, root);
        var head: usize = 0;
        while (head < out.items.len) : (head += 1) {
            const parent = out.items[head];
            for (self.entries) |e| {
                if (e.ppid == parent) try out.append(arena, e.pid);
            }
        }
        return out.items;
    }
};

pub const Listener = struct { pid: i32, port: u16 };

/// Listening TCP ports of the given processes, via one `lsof` call.
/// Errors degrade to an empty result: ports are decoration, and lsof
/// exits non-zero for the common "nothing found" case anyway.
pub fn listeningPorts(arena: std.mem.Allocator, pids: []const i32) []const Listener {
    if (pids.len == 0) return &.{};

    var pid_list: std.ArrayListUnmanaged(u8) = .empty;
    for (pids, 0..) |pid, i| {
        if (i != 0) pid_list.append(arena, ',') catch return &.{};
        pid_list.writer(arena).print("{d}", .{pid}) catch return &.{};
    }

    const res = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "lsof", "-a", "-P", "-iTCP", "-sTCP:LISTEN", "-Fpn", "-p", pid_list.items },
        .max_output_bytes = 1024 * 1024,
    }) catch return &.{};
    if (res.term != .Exited) return &.{};

    var out: std.ArrayListUnmanaged(Listener) = .empty;
    var current_pid: i32 = 0;
    var lines = std.mem.tokenizeScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        switch (line[0]) {
            'p' => current_pid = std.fmt.parseInt(i32, line[1..], 10) catch 0,
            'n' => {
                // e.g. "n*:8080", "n127.0.0.1:3000", "n[::1]:8080"
                const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
                const port = std.fmt.parseInt(u16, line[colon + 1 ..], 10) catch continue;
                const dup = for (out.items) |l| {
                    if (l.pid == current_pid and l.port == port) break true;
                } else false;
                if (!dup) out.append(arena, .{ .pid = current_pid, .port = port }) catch return &.{};
            },
            else => {},
        }
    }
    return out.items;
}

test "cwdOfPid sees our own working directory" {
    const alloc = std.testing.allocator;
    const cwd = cwdOfPid(alloc, std.c.getpid()) orelse return error.TestUnexpectedResult;
    defer alloc.free(cwd);
    const expected = try std.process.getCwdAlloc(alloc);
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, cwd);
}

test "process tree finds a spawned child" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var child = std.process.Child.init(&.{ "/bin/sleep", "2" }, arena);
    try child.spawn();
    defer {
        _ = child.kill() catch {};
    }

    const tree = try ProcessTree.snapshot(arena);
    const descendants = try tree.descendantsOf(arena, std.c.getpid());
    const found = for (descendants) |pid| {
        if (pid == child.id) break true;
    } else false;
    try std.testing.expect(found);
}

test "listeningPorts sees our own listener" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();

    const listeners = listeningPorts(arena, &.{std.c.getpid()});
    const found = for (listeners) |l| {
        if (l.port == port) break true;
    } else false;
    try std.testing.expect(found);
}
