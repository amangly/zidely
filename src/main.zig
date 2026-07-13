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
}

test {
    std.testing.refAllDecls(@This());
}
