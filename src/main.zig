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
    \\  attach <pane>            take over the terminal: raw passthrough
    \\                           to the pane (detach: ctrl-\)
    \\  task <description..>     start an agent task: worktree + branch +
    \\                           agent pane in this repo, then attach
    \\                           (--repo PATH, --agent CMD; default: claude)
    \\  tasks                    list agent tasks and their status
    \\  task-diff <id>           show everything a task changed (works
    \\                           mid-run; pipe it to a pager)
    \\  task-merge <id>          merge a finished task into the repo's
    \\                           current branch, then clean it up
    \\  task-rm <id>             discard a finished task's worktree
    \\                           (--branch deletes its branch, --force)
    \\  send <pane> <text>       send text + newline to a pane
    \\  snapshot <pane>          print a pane's screen contents
    \\  browse <session> <url>   open a browser pane, print its id
    \\  nav <pane> <url>         navigate a browser pane
    \\  eval <pane> <js>         run JS in a browser pane (needs a host)
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
    task: ?u64 = null,
    branch: ?[]const u8 = null,
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
    var repo_opt: ?[]const u8 = null;
    var agent_opt: ?[]const u8 = null;
    var branch_flag = false;
    var force_flag = false;
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
        } else if (std.mem.eql(u8, args[i], "--repo")) {
            i += 1;
            if (i == args.len) return fail("--repo needs a path\n", .{});
            repo_opt = args[i];
        } else if (std.mem.eql(u8, args[i], "--agent")) {
            i += 1;
            if (i == args.len) return fail("--agent needs a command\n", .{});
            agent_opt = args[i];
        } else if (std.mem.eql(u8, args[i], "--branch")) {
            branch_flag = true;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            force_flag = true;
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
    } else if (std.mem.eql(u8, cmd, "attach")) {
        if (pos.items.len != 1) return fail("usage: zide attach <pane>\n", .{});
        const pane = try std.fmt.parseInt(u64, pos.items[0], 10);
        try cmdAttach(arena, &client, socket_path, pane);
    } else if (std.mem.eql(u8, cmd, "task")) {
        if (pos.items.len == 0)
            return fail("usage: zide task <description..> [--repo PATH] [--agent CMD]\n", .{});
        const desc = try std.mem.join(arena, " ", pos.items);

        const repo = repo_opt orelse blk: {
            const res = std.process.Child.run(.{
                .allocator = arena,
                .argv = &.{ "git", "rev-parse", "--show-toplevel" },
            }) catch return fail("cannot run git; use --repo PATH\n", .{});
            if (res.term != .Exited or res.term.Exited != 0)
                return fail("not inside a git repository; use --repo PATH\n", .{});
            break :blk std.mem.trim(u8, res.stdout, " \n");
        };

        // --agent overrides the server's default (claude). Split on
        // spaces so "--agent 'codex --yolo'" works; the description is
        // always the final argument.
        var argv_override: ?[]const []const u8 = null;
        if (agent_opt) |a| {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, a, ' ');
            while (it.next()) |tok| try list.append(arena, tok);
            if (list.items.len == 0) return fail("--agent needs a command\n", .{});
            try list.append(arena, desc);
            argv_override = list.items;
        }

        const resp = try roundtrip(arena, &client, .{
            .id = 1,
            .cmd = "task-create",
            .repo = repo,
            .description = desc,
            .argv = argv_override,
        });
        try stdout("task {d} — {s} (pane {d})\n", .{
            resp.task.?, resp.branch orelse "?", resp.pane.?,
        });
        if (posix.isatty(posix.STDOUT_FILENO)) {
            try cmdAttach(arena, &client, socket_path, resp.pane.?);
        }
    } else if (std.mem.eql(u8, cmd, "tasks")) {
        try client.sendLine("{\"id\":1,\"cmd\":\"task-list\"}");
        const Tasks = struct {
            ok: bool = false,
            @"error": ?[]const u8 = null,
            tasks: []const struct {
                id: u64,
                description: []const u8,
                status: []const u8,
                pane: ?u64 = null,
                repo: []const u8,
                branch: []const u8,
                exit_code: ?u8 = null,
            } = &.{},
        };
        const parsed = try client.readResponse(Tasks, arena);
        if (!parsed.value.ok) return fail("error: {s}\n", .{parsed.value.@"error" orelse "unknown"});
        if (parsed.value.tasks.len == 0) {
            try stdout("no agent tasks\n", .{});
        }
        for (parsed.value.tasks) |t| {
            var pane_buf: [32]u8 = undefined;
            const pane_str = if (t.pane) |p|
                try std.fmt.bufPrint(&pane_buf, "pane {d}", .{p})
            else
                "no pane (restored)";
            try stdout("{d}  [{s}]  {s}  —  {s}, {s}, {s}\n", .{
                t.id, t.status, t.description, pane_str, t.branch, t.repo,
            });
        }
    } else if (std.mem.eql(u8, cmd, "task-diff")) {
        if (pos.items.len != 1) return fail("usage: zide task-diff <id>\n", .{});
        const tid = try std.fmt.parseInt(u64, pos.items[0], 10);
        try client.sendLine(try std.fmt.allocPrint(
            arena,
            "{{\"id\":1,\"cmd\":\"task-diff\",\"task\":{d}}}",
            .{tid},
        ));
        const Diff = struct {
            ok: bool = false,
            @"error": ?[]const u8 = null,
            diff: []const u8 = "",
            commits: u32 = 0,
            dirty: bool = false,
            truncated: bool = false,
        };
        const parsed = try client.readResponse(Diff, arena);
        if (!parsed.value.ok) return fail("error: {s}\n", .{parsed.value.@"error" orelse "unknown"});
        try stdout("# task {d}: {d} commit(s){s}{s}\n", .{
            tid,
            parsed.value.commits,
            if (parsed.value.dirty) ", uncommitted changes" else "",
            if (parsed.value.truncated) ", diff truncated" else "",
        });
        try stdout("{s}\n", .{parsed.value.diff});
    } else if (std.mem.eql(u8, cmd, "task-merge")) {
        if (pos.items.len != 1) return fail("usage: zide task-merge <id>\n", .{});
        const tid = try std.fmt.parseInt(u64, pos.items[0], 10);
        _ = try roundtrip(arena, &client, .{ .id = 1, .cmd = "task-merge", .task = tid });
        try stdout("task {d} merged and cleaned up\n", .{tid});
    } else if (std.mem.eql(u8, cmd, "task-rm")) {
        if (pos.items.len != 1)
            return fail("usage: zide task-rm <id> [--branch] [--force]\n", .{});
        const tid = try std.fmt.parseInt(u64, pos.items[0], 10);
        _ = try roundtrip(arena, &client, .{
            .id = 1,
            .cmd = "task-cleanup",
            .task = tid,
            .delete_branch = branch_flag,
            .force = force_flag,
        });
        try stdout("task {d} cleaned up\n", .{tid});
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
    } else if (std.mem.eql(u8, cmd, "browse")) {
        if (pos.items.len != 2) return fail("usage: zide browse <session> <url>\n", .{});
        const sid = try std.fmt.parseInt(u64, pos.items[0], 10);
        const resp = try roundtrip(arena, &client, .{
            .id = 1,
            .cmd = "browser-open",
            .session = sid,
            .url = pos.items[1],
        });
        try stdout("{d}\n", .{resp.pane.?});
    } else if (std.mem.eql(u8, cmd, "nav")) {
        if (pos.items.len != 2) return fail("usage: zide nav <pane> <url>\n", .{});
        const pane = try std.fmt.parseInt(u64, pos.items[0], 10);
        _ = try roundtrip(arena, &client, .{
            .id = 1,
            .cmd = "browser-navigate",
            .pane = pane,
            .url = pos.items[1],
        });
    } else if (std.mem.eql(u8, cmd, "eval")) {
        if (pos.items.len != 2) return fail("usage: zide eval <pane> <js>\n", .{});
        const pane = try std.fmt.parseInt(u64, pos.items[0], 10);
        _ = try roundtrip(arena, &client, .{
            .id = 1,
            .cmd = "browser-eval",
            .pane = pane,
            .data = pos.items[1],
            .seq = @as(u64, 7),
        });
        // The result comes back on the event stream.
        while (true) {
            const line = try client.readLine();
            if (std.mem.indexOf(u8, line, "\"browser_eval_result\"") == null) continue;
            if (std.mem.indexOf(u8, line, "\"seq\":7") == null) continue;
            const Result = struct { value: []const u8 = "" };
            const parsed = try std.json.parseFromSlice(Result, arena, line, .{
                .ignore_unknown_fields = true,
            });
            try stdout("{s}\n", .{parsed.value.value});
            break;
        }
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

/// Ctrl-\ — detaches an interactive attach. Chosen over prefix-key
/// schemes for v1: single byte, no state machine, and rare enough in
/// real terminal input (its usual meaning, SIGQUIT, is disabled by raw
/// mode anyway).
const detach_byte: u8 = 0x1c;

var winch_flag = std.atomic.Value(bool).init(false);

fn onWinch(_: c_int) callconv(.c) void {
    winch_flag.store(true, .release);
}

/// Raw passthrough to a pane, tmux-attach style: this terminal becomes
/// the pane until ctrl-\ or pane exit. Two connections: `control` stays
/// on the JSON protocol (resize on SIGWINCH, and drained so broadcasts
/// never block the server on us); a second connection issues `attach`
/// and becomes the byte pipe.
fn cmdAttach(
    arena: std.mem.Allocator,
    control: *zide.ipc.Client,
    socket_path: []const u8,
    pane: u64,
) !void {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_file = std.fs.File.stdout();
    const is_tty = posix.isatty(stdin_fd);

    // Size the pane to this terminal before painting the backlog.
    if (posix.isatty(posix.STDOUT_FILENO)) {
        if (zide.term.Pty.ttySize(posix.STDOUT_FILENO)) |ws| {
            _ = try roundtrip(arena, control, .{
                .id = 1,
                .cmd = "resize",
                .pane = pane,
                .rows = ws.ws_row,
                .cols = ws.ws_col,
            });
        } else |_| {}
    }

    // Current screen contents as context. Output arriving between this
    // snapshot and the attach below is lost to this client — a small
    // window, acceptable until state replay exists.
    const snap = try roundtrip(arena, control, .{ .id = 2, .cmd = "snapshot", .pane = pane });
    if (snap.snapshot) |s| if (s.len > 0) try stdout_file.writeAll(s);

    var raw = try zide.ipc.Client.connect(socket_path);
    defer raw.close();
    _ = try roundtrip(arena, &raw, .{ .id = 1, .cmd = "attach", .pane = pane });
    // Bytes that raced the ok reply into the client buffer are already
    // raw pane output.
    if (raw.end > raw.start) {
        try stdout_file.writeAll(raw.buf[raw.start..raw.end]);
        raw.start = 0;
        raw.end = 0;
    }

    var orig_termios: ?posix.termios = null;
    if (is_tty) {
        const orig = try posix.tcgetattr(stdin_fd);
        var t = orig;
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        t.iflag.BRKINT = false;
        t.iflag.ISTRIP = false;
        t.oflag.OPOST = false;
        t.cc[@intFromEnum(posix.V.MIN)] = 1;
        t.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(stdin_fd, .FLUSH, t);
        orig_termios = orig;

        var sa: posix.Sigaction = .{
            .handler = .{ .handler = onWinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &sa, null);
    }
    defer if (orig_termios) |orig| posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};

    var out_buf: [4096]u8 = undefined;
    var in_buf: [1024]u8 = undefined;
    var stdin_open = true;
    var detached = false;

    while (true) {
        if (winch_flag.swap(false, .acq_rel)) {
            if (zide.term.Pty.ttySize(posix.STDOUT_FILENO)) |ws| {
                // Fire-and-forget: the ok lands in the control drain. A
                // failure here must not exit while the tty is raw.
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &msg_buf,
                    "{{\"cmd\":\"resize\",\"pane\":{d},\"rows\":{d},\"cols\":{d}}}",
                    .{ pane, ws.ws_row, ws.ws_col },
                ) catch unreachable;
                control.sendLine(msg) catch {};
            } else |_| {}
        }

        var fds = [3]posix.pollfd{
            .{ .fd = raw.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = control.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (stdin_open) stdin_fd else -1, .events = posix.POLL.IN, .revents = 0 },
        };
        // Timeout paces the winch check; EINTR (the signal itself)
        // just means poll again.
        _ = posix.poll(&fds, 200) catch 0;

        const ready = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;

        if (fds[0].revents & ready != 0) {
            const n = posix.read(raw.fd, &out_buf) catch 0;
            if (n == 0) break; // pane exited (server half-closed us)
            try stdout_file.writeAll(out_buf[0..n]);
        }

        if (fds[1].revents & ready != 0) {
            const n = posix.read(control.fd, &out_buf) catch 0;
            if (n == 0) break; // server went away entirely
        }

        if (stdin_open and fds[2].revents & ready != 0) {
            const n = posix.read(stdin_fd, &in_buf) catch 0;
            if (n == 0) {
                // Piped stdin ended; stay attached for output.
                stdin_open = false;
                continue;
            }
            const chunk = in_buf[0..n];
            if (is_tty) {
                if (std.mem.indexOfScalar(u8, chunk, detach_byte)) |i| {
                    try writeAllFd(raw.fd, chunk[0..i]);
                    detached = true;
                    break;
                }
            }
            try writeAllFd(raw.fd, chunk);
        }
    }

    if (orig_termios) |orig| {
        posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};
        orig_termios = null;
    }
    try stdout("\r\n[zide: {s}]\n", .{if (detached) "detached" else "pane closed"});
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try posix.write(fd, bytes[off..]);
}

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
        if (ipc_server.restoreState(sp)) |restored| {
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
        try ipc_server.saveState(sp);
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
