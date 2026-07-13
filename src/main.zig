//! Dev CLI — temporary entry point for exercising the core library while
//! the native shells are being built. Later this becomes the `zidely`
//! automation CLI that talks to the running app/daemon over its socket.

const std = @import("std");
const zidely = @import("zidely");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var server = zidely.session.Server.init(alloc);
    defer server.deinit();

    const id = try server.createSession("scratch");
    std.debug.print("zidely {s} — core scaffold\n", .{zidely.version});
    std.debug.print("created session #{d} ({d} total)\n", .{ id, server.count() });

    // Demo: run a real shell command through a PTY, parse its output with
    // the ghostty-vt engine, and print the resulting screen state.
    var pane = try zidely.term.Pane.create(alloc, .{
        .argv = &.{ "/bin/sh", "-c", "echo \"pane $(tty) says hello\"; uname -sm" },
    });
    defer pane.destroy();
    try pane.pumpUntilEof();
    const exit_code = pane.wait();

    const snap = try pane.snapshot(alloc);
    defer alloc.free(snap);
    std.debug.print("--- pane screen (exit code {?d}) ---\n{s}\n", .{ exit_code, snap });
}

test {
    std.testing.refAllDecls(@This());
}
