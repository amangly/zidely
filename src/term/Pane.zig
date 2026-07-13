//! A terminal pane: a child process attached to a PTY, whose output
//! feeds a ghostty-vt Terminal so the core always has queryable screen
//! state — regardless of whether any UI is rendering it. This is the
//! foundation both for rendering (shells read the terminal state) and
//! for agent orchestration (the core watches agent panes for attention
//! cues without a UI in the loop).

const Pane = @This();

const std = @import("std");
const posix = std.posix;
const ghostty = @import("ghostty-vt");
const Pty = @import("Pty.zig");

alloc: std.mem.Allocator,
pty: Pty,
pid: posix.pid_t,
/// Heap-pinned: the stream handler keeps a pointer to it.
terminal: *ghostty.Terminal,
/// Long-lived so escape sequences split across PTY reads parse correctly.
stream: ghostty.ReadonlyStream,

pub const Options = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    /// Program and arguments, resolved via PATH.
    argv: []const []const u8,
};

pub fn create(alloc: std.mem.Allocator, opts: Options) !*Pane {
    const terminal = try alloc.create(ghostty.Terminal);
    errdefer alloc.destroy(terminal);
    terminal.* = try .init(alloc, .{ .cols = opts.cols, .rows = opts.rows });
    errdefer terminal.deinit(alloc);

    var pty = try Pty.open(.{ .ws_row = opts.rows, .ws_col = opts.cols });
    errdefer {
        _ = posix.system.close(pty.slave);
        pty.deinit();
    }

    const pid = try spawn(alloc, pty, opts.argv);

    // The child owns the slave end now.
    posix.close(pty.slave);

    const pane = try alloc.create(Pane);
    errdefer alloc.destroy(pane);
    pane.* = .{
        .alloc = alloc,
        .pty = pty,
        .pid = pid,
        .terminal = terminal,
        .stream = terminal.vtStream(),
    };
    return pane;
}

pub fn destroy(self: *Pane) void {
    const alloc = self.alloc;
    self.stream.deinit();
    self.terminal.deinit(alloc);
    alloc.destroy(self.terminal);
    self.pty.deinit();
    self.* = undefined;
    alloc.destroy(self);
}

/// Fork + exec `argv` with the PTY slave as its controlling terminal.
/// Everything the child needs is allocated before fork; the child must
/// not touch the allocator.
fn spawn(alloc: std.mem.Allocator, pty: Pty, argv: []const []const u8) !posix.pid_t {
    std.debug.assert(argv.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_z[i] = (try arena.dupeZ(u8, arg)).ptr;

    var env = try std.process.getEnvMap(arena);
    try env.put("TERM", "xterm-256color");
    const envp = try std.process.createEnvironFromMap(arena, &env, .{});

    const pid = try posix.fork();
    if (pid == 0) {
        // Child. Only async-signal-safe operations from here on.
        pty.childPreExec() catch posix.exit(125);
        posix.dup2(pty.slave, 0) catch posix.exit(125);
        posix.dup2(pty.slave, 1) catch posix.exit(125);
        posix.dup2(pty.slave, 2) catch posix.exit(125);
        if (pty.slave > 2) posix.close(pty.slave);
        _ = posix.execvpeZ(argv_z[0].?, argv_z.ptr, envp.ptr) catch {};
        posix.exit(127);
    }
    return pid;
}

/// Send bytes to the child (keyboard input, once shells exist).
pub fn writeInput(self: *Pane, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try posix.write(self.pty.master, bytes[off..]);
}

/// Drain PTY output into the terminal until the child closes its end
/// (usually: exits). Blocking; the event-loop version replaces this when
/// the daemon core lands.
pub fn pumpUntilEof(self: *Pane) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
            // Linux reports EIO on the master once the child exits.
            error.InputOutput => break,
            else => return err,
        };
        if (n == 0) break;
        try self.stream.nextSlice(buf[0..n]);
    }
}

/// Reap the child. Returns its exit code, or null if it died by signal.
pub fn wait(self: *Pane) ?u8 {
    const res = posix.waitpid(self.pid, 0);
    if (posix.W.IFEXITED(res.status)) return posix.W.EXITSTATUS(res.status);
    return null;
}

pub fn resize(self: *Pane, rows: u16, cols: u16) !void {
    try self.pty.setSize(.{ .ws_row = rows, .ws_col = cols });
    try self.terminal.resize(self.alloc, cols, rows);
}

/// Plain-text contents of the screen. Caller owns the returned memory.
pub fn snapshot(self: *Pane, alloc: std.mem.Allocator) ![]const u8 {
    return self.terminal.plainString(alloc);
}

test "pane captures child output through the vt engine" {
    const alloc = std.testing.allocator;
    var pane = try Pane.create(alloc, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'zidely\\033[1;32m-pty\\033[0m-ok\\n'" },
    });
    defer pane.destroy();

    try pane.pumpUntilEof();
    try std.testing.expectEqual(@as(?u8, 0), pane.wait());

    const snap = try pane.snapshot(alloc);
    defer alloc.free(snap);
    // SGR color sequences must have been consumed as styling, not text.
    try std.testing.expect(std.mem.indexOf(u8, snap, "zidely-pty-ok") != null);
}

test "child sees the requested terminal size" {
    const alloc = std.testing.allocator;
    var pane = try Pane.create(alloc, .{
        .rows = 31,
        .cols = 113,
        .argv = &.{ "/bin/sh", "-c", "stty size" },
    });
    defer pane.destroy();

    try pane.pumpUntilEof();
    try std.testing.expectEqual(@as(?u8, 0), pane.wait());

    const snap = try pane.snapshot(alloc);
    defer alloc.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "31 113") != null);
}
