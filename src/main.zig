//! Dev CLI — temporary entry point for exercising the core library while
//! the native shells are being built. Later this becomes the `zide`
//! automation CLI that talks to the running app/daemon over its socket.

const std = @import("std");
const zide = @import("zide");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var server = try zide.session.Server.init(alloc);
    defer server.deinit();
    server.handler = .{ .func = logEvent };

    std.debug.print("zide {s} — event-loop demo: two shells, one loop\n", .{zide.version});

    // Two panes alternating output; the event log below shows the loop
    // interleaving them instead of running one to completion first.
    const sid = try server.createSession("demo");
    const a = try server.spawnPane(sid, .{
        .argv = &.{ "/bin/sh", "-c", "for i in 1 2 3; do echo \"A says $i\"; sleep 0.1; done" },
    });
    const b = try server.spawnPane(sid, .{
        .argv = &.{ "/bin/sh", "-c", "for i in 1 2 3; do echo \"B says $i\"; sleep 0.1; done" },
    });

    try server.run();

    for ([_]zide.session.PaneId{ a, b }) |pane| {
        const snap = try server.paneSnapshot(pane, alloc);
        defer alloc.free(snap);
        std.debug.print("--- pane {d} final screen ---\n{s}\n", .{ pane, snap });
    }
}

fn logEvent(ud: ?*anyopaque, server: *zide.session.Server, event: zide.session.Event) void {
    _ = ud;
    _ = server;
    switch (event) {
        .pane_output => |pane| std.debug.print("event: output from pane {d}\n", .{pane}),
        .pane_bell => |pane| std.debug.print("event: BELL from pane {d}\n", .{pane}),
        .pane_exit => |e| std.debug.print("event: pane {d} exited (code {?d})\n", .{ e.pane, e.exit_code }),
    }
}

test {
    std.testing.refAllDecls(@This());
}
