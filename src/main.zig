//! The `zide` CLI.
//!
//! `zide serve` hosts the session server and its control socket in the
//! foreground; `zide daemon` detaches the same thing so sessions survive
//! the terminal. Every other subcommand is a client speaking the
//! JSON-lines protocol from ipc.zig, auto-starting the daemon on demand.

const std = @import("std");
const posix = std.posix;
const zide = @import("zide");

const usage =
    \\zide {s} — AI-agent multitasking terminal core
    \\
    \\usage: zide <command> [args] [--socket PATH]
    \\
    \\server:
    \\  serve [--state PATH]     host the session server in the foreground;
    \\                           restores state on start, saves on shutdown
    \\  daemon [--state PATH]    same, detached — sessions survive your
    \\                           terminal (state/log/pid in ~/.zide)
    \\
    \\client (auto-starts the daemon, except ping/shutdown):
    \\  ping                     check the server is up
    \\  ls                       list sessions and their panes
    \\  new <title>              create a session, print its id
    \\  spawn <session> <cmd..>  spawn a pane in a session, print its id
    \\  send <pane> <text>       send text + newline to a pane
    \\  snapshot <pane>          print a pane's screen contents
    \\  save <path>              persist the layout to a state file
    \\  events                   follow the event stream (until shutdown)
    \\  shutdown                 stop the server (panes get SIGHUP)
    \\
    \\the socket defaults to $ZIDE_SOCKET, then /tmp/zide-<uid>.sock
    \\
;

/// Response envelope every command cares about; command-specific fields
/// are read separately.
const BaseResponse = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
    session: ?u64 = null,
    pane: ?u64 = null,
    snapshot: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 2) return fail(usage, .{zide.version});
    const cmd = args[1];

    // Split trailing args into options and positionals.
    var socket_opt: ?[]const u8 = null;
    var state_opt: ?[]const u8 = null;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--socket")) {
            i += 1;
            if (i == args.len) return fail("--socket needs a path\n", .{});
            socket_opt = args[i];
        } else if (std.mem.eql(u8, args[i], "--state")) {
            i += 1;
            if (i == args.len) return fail("--state needs a path\n", .{});
            state_opt = args[i];
        } else {
            try pos.append(arena, args[i]);
        }
    }

    const socket_path = socket_opt orelse
        std.process.getEnvVarOwned(arena, "ZIDE_SOCKET") catch
        try std.fmt.allocPrint(arena, "/tmp/zide-{d}.sock", .{posix.getuid()});

    if (std.mem.eql(u8, cmd, "serve"))
        return cmdServe(gpa.allocator(), socket_path, state_opt);
    if (std.mem.eql(u8, cmd, "daemon"))
        return cmdDaemon(arena, gpa.allocator(), socket_path, state_opt);

    // Everything else talks to a running server, auto-starting the
    // daemon for commands that imply one should exist.
    const autostart = !(std.mem.eql(u8, cmd, "ping") or std.mem.eql(u8, cmd, "shutdown"));
    var client = try connectOrStart(arena, socket_path, autostart);
    defer client.close();

    if (std.mem.eql(u8, cmd, "ping")) {
        _ = try roundtrip(arena, &client, .{ .id = 1, .cmd = "ping" });
        try stdout("ok\n", .{});
    } else if (std.mem.eql(u8, cmd, "ls")) {
        try client.sendLine("{\"id\":1,\"cmd\":\"list-sessions\"}");
        const Sessions = struct {
            ok: bool = false,
            @"error": ?[]const u8 = null,
            sessions: []const struct {
                id: u64,
                title: []const u8,
                panes: []const u64 = &.{},
            } = &.{},
        };
        const parsed = try client.readResponse(Sessions, arena);
        if (!parsed.value.ok) return fail("error: {s}\n", .{parsed.value.@"error" orelse "unknown"});
        for (parsed.value.sessions) |s| {
            try stdout("{d}  {s}  ({d} pane{s})\n", .{
                s.id, s.title, s.panes.len, if (s.panes.len == 1) "" else "s",
            });
        }
    } else if (std.mem.eql(u8, cmd, "new")) {
        if (pos.items.len != 1) return fail("usage: zide new <title>\n", .{});
        const resp = try roundtrip(arena, &client, .{
            .id = 1,
            .cmd = "create-session",
            .title = pos.items[0],
        });
        try stdout("{d}\n", .{resp.session.?});
    } else if (std.mem.eql(u8, cmd, "spawn")) {
        if (pos.items.len < 2) return fail("usage: zide spawn <session> <cmd> [args...]\n", .{});
        const sid = try std.fmt.parseInt(u64, pos.items[0], 10);
        const resp = try roundtrip(arena, &client, .{
            .id = 1,
            .cmd = "spawn-pane",
            .session = sid,
            .argv = pos.items[1..],
        });
        try stdout("{d}\n", .{resp.pane.?});
    } else if (std.mem.eql(u8, cmd, "send")) {
        if (pos.items.len != 2) return fail("usage: zide send <pane> <text>\n", .{});
        const pane = try std.fmt.parseInt(u64, pos.items[0], 10);
        const data = try std.fmt.allocPrint(arena, "{s}\n", .{pos.items[1]});
        _ = try roundtrip(arena, &client, .{ .id = 1, .cmd = "write", .pane = pane, .data = data });
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        if (pos.items.len != 1) return fail("usage: zide snapshot <pane>\n", .{});
        const pane = try std.fmt.parseInt(u64, pos.items[0], 10);
        const resp = try roundtrip(arena, &client, .{ .id = 1, .cmd = "snapshot", .pane = pane });
        try stdout("{s}\n", .{resp.snapshot orelse ""});
    } else if (std.mem.eql(u8, cmd, "save")) {
        if (pos.items.len != 1) return fail("usage: zide save <path>\n", .{});
        _ = try roundtrip(arena, &client, .{ .id = 1, .cmd = "save", .path = pos.items[0] });
        try stdout("saved to {s}\n", .{pos.items[0]});
    } else if (std.mem.eql(u8, cmd, "events")) {
        while (true) {
            const line = client.readLine() catch |err| switch (err) {
                error.Disconnected => break,
                else => return err,
            };
            try stdout("{s}\n", .{line});
        }
    } else if (std.mem.eql(u8, cmd, "shutdown")) {
        _ = try roundtrip(arena, &client, .{ .id = 1, .cmd = "shutdown" });
        try stdout("server shutting down\n", .{});
    } else {
        return fail(usage, .{zide.version});
    }
}

extern "c" fn setsid() std.c.pid_t;

/// Start the server detached: double-fork + setsid, stdio to the log
/// file, pidfile written, then the ordinary serve loop. Runs before any
/// event loop exists — kqueue descriptors do not survive fork. The
/// launching process waits until the socket accepts, so a zero exit
/// really means "ready".
fn cmdDaemon(
    arena: std.mem.Allocator,
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    state_opt: ?[]const u8,
) !void {
    const home = std.process.getEnvVarOwned(arena, "HOME") catch
        return fail("daemon needs $HOME for ~/.zide\n", .{});
    const dir = try std.fs.path.join(arena, &.{ home, ".zide" });
    try std.fs.cwd().makePath(dir);

    // The daemon chdirs to /; everything must be absolute before then.
    const cwd = try std.process.getCwdAlloc(arena);
    const state_path = if (state_opt) |sp|
        try std.fs.path.resolve(arena, &.{ cwd, sp })
    else
        try std.fs.path.join(arena, &.{ dir, "state.json" });
    const abs_socket = try std.fs.path.resolve(arena, &.{ cwd, socket_path });
    const log_path = try std.fs.path.join(arena, &.{ dir, "daemon.log" });
    const pid_path = try std.fs.path.join(arena, &.{ dir, "daemon.pid" });

    const pid = try posix.fork();
    if (pid != 0) {
        // Launcher: report ready only once the socket accepts.
        var attempts: usize = 0;
        while (attempts < 60) : (attempts += 1) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            var probe = zide.ipc.Client.connect(abs_socket) catch continue;
            probe.close();
            return stdout("daemon ready on {s} (log: {s})\n", .{ abs_socket, log_path });
        }
        return fail("daemon did not become ready; check {s}\n", .{log_path});
    }

    // Child: fully detach before any event-loop state exists.
    if (setsid() < 0) posix.exit(1);
    const pid2 = posix.fork() catch posix.exit(1);
    if (pid2 != 0) posix.exit(0);
    posix.chdir("/") catch {};

    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
    posix.dup2(devnull, 0) catch posix.exit(1);
    const log_fd = posix.open(log_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644) catch posix.exit(1);
    posix.dup2(log_fd, 1) catch posix.exit(1);
    posix.dup2(log_fd, 2) catch posix.exit(1);
    if (devnull > 2) posix.close(devnull);
    if (log_fd > 2) posix.close(log_fd);

    if (std.fs.createFileAbsolute(pid_path, .{})) |pf| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\n", .{std.c.getpid()}) catch unreachable;
        pf.writeAll(s) catch {};
        pf.close();
    } else |_| {}

    cmdServe(alloc, abs_socket, state_path) catch |err| {
        std.debug.print("daemon error: {}\n", .{err});
        posix.exit(1);
    };
    std.fs.deleteFileAbsolute(pid_path) catch {};
    posix.exit(0);
}

/// Connect, optionally auto-starting the daemon tmux-style.
fn connectOrStart(
    arena: std.mem.Allocator,
    socket_path: []const u8,
    autostart: bool,
) !zide.ipc.Client {
    return zide.ipc.Client.connect(socket_path) catch {
        if (!autostart)
            return fail("cannot connect to {s} — is the zide daemon running?\n", .{socket_path});

        const self_exe = try std.fs.selfExePathAlloc(arena);
        var child = std.process.Child.init(&.{ self_exe, "daemon", "--socket", socket_path }, arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        // The launcher only exits 0 once the socket accepts.
        const term = try child.wait();
        if (term != .Exited or term.Exited != 0)
            return fail("failed to auto-start the daemon on {s}\n", .{socket_path});
        return zide.ipc.Client.connect(socket_path) catch
            fail("daemon started but {s} is not accepting\n", .{socket_path});
    };
}

fn cmdServe(alloc: std.mem.Allocator, socket_path: []const u8, state_path: ?[]const u8) !void {
    var server = try zide.session.Server.init(alloc);
    defer server.deinit();
    var ipc_server = try zide.ipc.Server.create(alloc, &server, socket_path);
    defer ipc_server.destroy();

    if (state_path) |sp| {
        if (zide.persist.restore(alloc, &server, sp)) |restored| {
            try stdout("restored {d} session(s), {d} pane(s) from {s}\n", .{
                restored.sessions, restored.panes, sp,
            });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    try stdout("zide {s} listening on {s}\n", .{ zide.version, socket_path });
    try server.run();

    if (state_path) |sp| {
        try zide.persist.save(alloc, &server, sp);
        try stdout("state saved to {s}\n", .{sp});
    }
}

/// Send one request, await its response, fail loudly on protocol errors.
fn roundtrip(
    arena: std.mem.Allocator,
    client: *zide.ipc.Client,
    payload: anytype,
) !BaseResponse {
    const json = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(payload, .{})});
    try client.sendLine(json);
    const parsed = try client.readResponse(BaseResponse, arena);
    if (!parsed.value.ok) return fail("error: {s}\n", .{parsed.value.@"error" orelse "unknown"});
    return parsed.value;
}

fn stdout(comptime fmt: []const u8, fmt_args: anytype) !void {
    // Not File.writer(): its default positional mode restarts every new
    // writer at offset 0, overwriting earlier output on redirected fds.
    var buf: [65536]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, fmt_args);
    try std.fs.File.stdout().writeAll(s);
}

fn fail(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    std.debug.print(fmt, fmt_args);
    std.process.exit(1);
}

test {
    std.testing.refAllDecls(@This());
}
