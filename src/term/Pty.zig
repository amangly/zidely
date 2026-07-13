//! POSIX pseudo-terminal (macOS + Linux).
//!
//! Low-level patterns (macOS ioctl constants, IUTF8, CLOEXEC discipline,
//! child pre-exec setup) follow Ghostty's `src/pty.zig` (MIT).

const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Matches the C `struct winsize` layout that openpty/ioctl expect.
pub const Winsize = extern struct {
    ws_row: u16 = 24,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

// Zig cannot translate these macOS ioctl request macros (ziglang/zig#13277).
const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
const TIOCSWINSZ = if (builtin.os.tag == .macos) 2148037735 else c.TIOCSWINSZ;
const TIOCGWINSZ = if (builtin.os.tag == .macos) 1074295912 else c.TIOCGWINSZ;

extern "c" fn setsid() std.c.pid_t;

const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("util.h"); // openpty()
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("pty.h"); // openpty()
    }),
};

/// Read/write end held by us. Never inherited by the child (CLOEXEC).
master: posix.fd_t,
/// The child's end. The spawner closes this in the parent after fork.
slave: posix.fd_t,

pub fn open(size: Winsize) !Pty {
    var size_copy = size;
    var master_fd: posix.fd_t = undefined;
    var slave_fd: posix.fd_t = undefined;
    if (c.openpty(&master_fd, &slave_fd, null, null, @ptrCast(&size_copy)) < 0)
        return error.OpenptyFailed;
    errdefer {
        _ = posix.system.close(master_fd);
        _ = posix.system.close(slave_fd);
    }

    // Only the slave end may be inherited by child processes.
    const flags = try posix.fcntl(master_fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(master_fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);

    // UTF-8 mode is not on by default on macOS.
    var attrs: c.termios = undefined;
    if (c.tcgetattr(master_fd, &attrs) != 0) return error.OpenptyFailed;
    attrs.c_iflag |= c.IUTF8;
    if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0) return error.OpenptyFailed;

    return .{ .master = master_fd, .slave = slave_fd };
}

/// Closes the master end. The slave end is the spawner's responsibility
/// (closed in the parent after fork, or by errdefer on spawn failure).
pub fn deinit(self: *Pty) void {
    _ = posix.system.close(self.master);
    self.* = undefined;
}

pub fn getSize(self: Pty) !Winsize {
    var ws: Winsize = undefined;
    if (c.ioctl(self.master, TIOCGWINSZ, @intFromPtr(&ws)) < 0)
        return error.IoctlFailed;
    return ws;
}

pub fn setSize(self: *Pty, size: Winsize) !void {
    if (c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size)) < 0)
        return error.IoctlFailed;
}

/// Window size of an arbitrary tty fd — e.g. the CLI's own stdout, for
/// sizing an attached pane to the local terminal.
pub fn ttySize(fd: posix.fd_t) !Winsize {
    var ws: Winsize = undefined;
    if (c.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws)) < 0)
        return error.IoctlFailed;
    return ws;
}

/// Called in the forked child, before exec: reset signal handlers,
/// start a new session, and make the slave our controlling terminal.
/// Only async-signal-safe operations allowed here.
pub fn childPreExec(self: Pty) !void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    inline for (.{
        "ABRT", "ALRM", "BUS",  "CHLD", "FPE",  "HUP",  "ILL",
        "INT",  "PIPE", "SEGV", "TRAP", "TERM", "QUIT",
    }) |name| posix.sigaction(@field(posix.SIG, name), &sa, null);

    if (setsid() < 0) return error.ProcessGroupFailed;

    if (c.ioctl(self.slave, TIOCSCTTY, @as(c_ulong, 0)) < 0)
        return error.SetControllingTerminalFailed;
}

test "open, query and change size" {
    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80 });
    defer {
        _ = posix.system.close(pty.slave);
        pty.deinit();
    }

    const initial = try pty.getSize();
    try std.testing.expectEqual(24, initial.ws_row);
    try std.testing.expectEqual(80, initial.ws_col);

    try pty.setSize(.{ .ws_row = 31, .ws_col = 113 });
    const changed = try pty.getSize();
    try std.testing.expectEqual(31, changed.ws_row);
    try std.testing.expectEqual(113, changed.ws_col);
}
