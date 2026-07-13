//! Control socket: JSON-lines over a Unix domain socket.
//!
//! This is the session server's message-passing seam made external —
//! the same surface the `zide` CLI, the platform shells, and eventually
//! detached daemon clients speak. One line = one JSON object:
//!
//!   request  {"id":1,"cmd":"spawn-pane","session":1,"argv":["sh"]}
//!   response {"id":1,"ok":true,"pane":2}
//!   event    {"event":"pane_exit","pane":2,"exit_code":0}
//!
//! Every connected client receives every event. Commands: ping,
//! create-session, list-sessions, spawn-pane, write, snapshot, save,
//! shutdown.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const xev = @import("xev").Dynamic;
const session = @import("session.zig");
const persist = @import("persist.zig");

/// Wire format of a request. Unknown fields are ignored; every command
/// validates the fields it needs.
const Request = struct {
    id: u32 = 0,
    cmd: []const u8 = "",
    title: ?[]const u8 = null,
    session: ?session.SessionId = null,
    pane: ?session.PaneId = null,
    argv: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    rows: ?u16 = null,
    cols: ?u16 = null,
    data: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

const Connection = struct {
    server: *Server,
    conn: xev.TCP,
    fd: posix.socket_t,
    c_read: xev.Completion = .{},
    read_buf: [4096]u8 = undefined,
    /// Partial-line accumulator; requests may arrive split or batched.
    line: std.ArrayListUnmanaged(u8) = .empty,
    closing: bool = false,

    fn onRead(
        ud: ?*Connection,
        loop: *xev.Loop,
        c: *xev.Completion,
        conn: xev.TCP,
        buf: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        _ = loop;
        _ = c;
        _ = conn;
        _ = buf;
        const self = ud.?;
        const server = self.server;

        const n = r catch 0;
        if (n == 0) {
            server.removeClient(self);
            return .disarm;
        }

        self.line.appendSlice(server.alloc, self.read_buf[0..n]) catch {
            server.removeClient(self);
            return .disarm;
        };

        while (std.mem.indexOfScalar(u8, self.line.items, '\n')) |nl| {
            server.handleLine(self, self.line.items[0..nl]);
            const rest = self.line.items[nl + 1 ..];
            std.mem.copyForwards(u8, self.line.items[0..rest.len], rest);
            self.line.shrinkRetainingCapacity(rest.len);
            if (self.closing) break;
        }

        if (self.closing) {
            server.removeClient(self);
            return .disarm;
        }
        return .rearm;
    }
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    session_server: *session.Server,
    socket_path: []const u8,
    listener: xev.TCP,
    listen_fd: posix.socket_t,
    c_accept: xev.Completion = .{},
    clients: std.ArrayListUnmanaged(*Connection) = .empty,
    downstream: ?session.EventHandler,
    shutting_down: bool = false,
    listener_closed: bool = false,

    /// Create the socket at `socket_path` (an existing file there is
    /// replaced) and start accepting on the session server's loop.
    /// Events flow to every client; the previously installed session
    /// handler keeps receiving them too.
    pub fn create(
        alloc: std.mem.Allocator,
        session_server: *session.Server,
        socket_path: []const u8,
    ) !*Server {
        std.fs.cwd().deleteFile(socket_path) catch {};
        const addr = try std.net.Address.initUnix(socket_path);

        // Mirror xev.TCP.init's flag choice: io_uring wants blocking
        // sockets (EAGAIN would spin), everything else non-blocking.
        var sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
        if (xev.backend != .io_uring) sock_flags |= posix.SOCK.NONBLOCK;
        const fd = try posix.socket(posix.AF.UNIX, sock_flags, 0);
        errdefer posix.close(fd);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 16);

        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .session_server = session_server,
            .socket_path = try alloc.dupe(u8, socket_path),
            .listener = xev.TCP.initFd(fd),
            .listen_fd = fd,
            .downstream = session_server.handler,
        };
        session_server.handler = .{ .userdata = self, .func = onSessionEvent };
        self.listener.accept(&session_server.loop, &self.c_accept, Server, self, onAccept);
        return self;
    }

    /// Tear down bookkeeping. Only call once the event loop is drained
    /// (after `shutdown` ran, or when the loop will never run again).
    pub fn destroy(self: *Server) void {
        self.session_server.handler = self.downstream;
        for (self.clients.items) |client| {
            posix.close(client.fd);
            client.line.deinit(self.alloc);
            self.alloc.destroy(client);
        }
        self.clients.deinit(self.alloc);
        if (!self.listener_closed) posix.close(self.listen_fd);
        std.fs.cwd().deleteFile(self.socket_path) catch {};
        self.alloc.free(self.socket_path);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    fn onAccept(
        ud: ?*Server,
        loop: *xev.Loop,
        c: *xev.Completion,
        r: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        _ = c;
        const self = ud.?;
        const conn = r catch return .disarm;
        const fd = tcpFd(conn);

        if (self.shutting_down) {
            // This is (usually) our own shutdown poke. Drain and close
            // the listener now that its completion is free.
            posix.close(fd);
            posix.close(self.listen_fd);
            self.listener_closed = true;
            std.fs.cwd().deleteFile(self.socket_path) catch {};
            return .disarm;
        }

        // Writes to a vanished client must error, not raise SIGPIPE.
        if (comptime builtin.os.tag.isDarwin()) {
            const one: c_int = 1;
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&one)) catch {};
        }

        const client = self.alloc.create(Connection) catch {
            posix.close(fd);
            return .rearm;
        };
        client.* = .{ .server = self, .conn = conn, .fd = fd };
        self.clients.append(self.alloc, client) catch {
            posix.close(fd);
            self.alloc.destroy(client);
            return .rearm;
        };

        client.conn.read(loop, &client.c_read, .{ .slice = &client.read_buf }, Connection, client, Connection.onRead);
        return .rearm;
    }

    /// Only safe from the client's own read callback (single-threaded
    /// loop; the caller disarms the read completion).
    fn removeClient(self: *Server, client: *Connection) void {
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        posix.close(client.fd);
        client.line.deinit(self.alloc);
        self.alloc.destroy(client);
    }

    fn handleLine(self: *Server, client: *Connection, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;

        const parsed = std.json.parseFromSlice(Request, self.alloc, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.reply(client, .{ .id = @as(u32, 0), .ok = false, .@"error" = "invalid json" });
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;

        self.dispatch(client, req) catch |err| {
            self.reply(client, .{ .id = req.id, .ok = false, .@"error" = @errorName(err) });
        };
    }

    fn dispatch(self: *Server, client: *Connection, req: Request) !void {
        const ss = self.session_server;
        const eql = std.mem.eql;

        if (eql(u8, req.cmd, "ping")) {
            self.reply(client, .{ .id = req.id, .ok = true });
        } else if (eql(u8, req.cmd, "create-session")) {
            const title = req.title orelse return error.MissingTitle;
            const sid = try ss.createSession(title);
            self.reply(client, .{ .id = req.id, .ok = true, .session = sid });
        } else if (eql(u8, req.cmd, "list-sessions")) {
            var arena_state = std.heap.ArenaAllocator.init(self.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const Info = struct {
                id: session.SessionId,
                title: []const u8,
                panes: []const session.PaneId,
            };
            const infos = try arena.alloc(Info, ss.sessions.count());
            var it = ss.sessions.valueIterator();
            var i: usize = 0;
            while (it.next()) |s| : (i += 1) {
                infos[i] = .{ .id = s.id, .title = s.title, .panes = s.panes.items };
            }
            self.reply(client, .{ .id = req.id, .ok = true, .sessions = infos });
        } else if (eql(u8, req.cmd, "spawn-pane")) {
            const sid = req.session orelse return error.MissingSession;
            const argv = req.argv orelse return error.MissingArgv;
            if (argv.len == 0) return error.MissingArgv;
            const pane = try ss.spawnPane(sid, .{
                .argv = argv,
                .cwd = req.cwd,
                .rows = req.rows orelse 24,
                .cols = req.cols orelse 80,
            });
            self.reply(client, .{ .id = req.id, .ok = true, .pane = pane });
        } else if (eql(u8, req.cmd, "write")) {
            const pane = req.pane orelse return error.MissingPane;
            const data = req.data orelse return error.MissingData;
            try ss.paneWrite(pane, data);
            self.reply(client, .{ .id = req.id, .ok = true });
        } else if (eql(u8, req.cmd, "snapshot")) {
            const pane = req.pane orelse return error.MissingPane;
            const snap = try ss.paneSnapshot(pane, self.alloc);
            defer self.alloc.free(snap);
            self.reply(client, .{ .id = req.id, .ok = true, .snapshot = snap });
        } else if (eql(u8, req.cmd, "save")) {
            const path = req.path orelse return error.MissingPath;
            try persist.save(self.alloc, ss, path);
            self.reply(client, .{ .id = req.id, .ok = true });
        } else if (eql(u8, req.cmd, "shutdown")) {
            self.reply(client, .{ .id = req.id, .ok = true });
            self.beginShutdown(client);
        } else {
            return error.UnknownCommand;
        }
    }

    /// Close the socket surface so the loop can drain: other clients
    /// get a socket shutdown (their reads EOF out and clean up), the
    /// requesting client is closed after its callback returns, and a
    /// self-connect pokes the pending accept so its completion fires
    /// and can release the listener (closing an fd out from under a
    /// kqueue/io_uring completion would strand it forever).
    fn beginShutdown(self: *Server, requester: *Connection) void {
        self.shutting_down = true;
        requester.closing = true;
        for (self.clients.items) |client| {
            if (client != requester) posix.shutdown(client.fd, .both) catch {};
        }

        // Hang up pane children so their completions drain and the loop
        // can actually finish; layout state survives for a final save.
        var it = self.session_server.panes.valueIterator();
        while (it.next()) |h| posix.kill(h.*.pane.pid, posix.SIG.HUP) catch {};

        const addr = std.net.Address.initUnix(self.socket_path) catch return;
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return;
        defer posix.close(fd);
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {};
    }

    fn onSessionEvent(ud: ?*anyopaque, server: *session.Server, event: session.Event) void {
        const self: *Server = @ptrCast(@alignCast(ud.?));
        switch (event) {
            .pane_output => |p| self.broadcast(.{ .event = "pane_output", .pane = p }),
            .pane_bell => |p| self.broadcast(.{ .event = "pane_bell", .pane = p }),
            .pane_exit => |e| self.broadcast(.{
                .event = "pane_exit",
                .pane = e.pane,
                .exit_code = e.exit_code,
            }),
        }
        if (self.downstream) |d| d.func(d.userdata, server, event);
    }

    fn broadcast(self: *Server, payload: anytype) void {
        if (self.clients.items.len == 0) return;
        const json = std.fmt.allocPrint(self.alloc, "{f}\n", .{std.json.fmt(payload, .{})}) catch return;
        defer self.alloc.free(json);
        for (self.clients.items) |client| {
            writeAllSocket(client.fd, json) catch {
                client.closing = true;
            };
        }
    }

    fn reply(self: *Server, client: *Connection, payload: anytype) void {
        const json = std.fmt.allocPrint(self.alloc, "{f}\n", .{std.json.fmt(payload, .{})}) catch return;
        defer self.alloc.free(json);
        writeAllSocket(client.fd, json) catch {
            client.closing = true;
        };
    }
};

/// Synchronous client for the control socket: the CLI and tests speak
/// the protocol through this. One request in flight at a time; event
/// lines interleave with responses and are surfaced by readLine too.
pub const Client = struct {
    fd: posix.socket_t,
    buf: [65536]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn connect(path: []const u8) !Client {
        const stream = try std.net.connectUnixSocket(path);
        return .{ .fd = stream.handle };
    }

    pub fn close(self: *Client) void {
        posix.close(self.fd);
        self.* = undefined;
    }

    pub fn sendLine(self: *Client, line: []const u8) !void {
        try writeAllSocket(self.fd, line);
        try writeAllSocket(self.fd, "\n");
    }

    /// Next protocol line (response or event). The slice is valid until
    /// the next readLine call.
    pub fn readLine(self: *Client) ![]u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf[self.start..self.end], '\n')) |i| {
                const line = self.buf[self.start..][0..i];
                self.start += i + 1;
                return line;
            }
            if (self.start > 0) {
                std.mem.copyForwards(u8, self.buf[0 .. self.end - self.start], self.buf[self.start..self.end]);
                self.end -= self.start;
                self.start = 0;
            }
            if (self.end == self.buf.len) return error.LineTooLong;
            const n = try posix.read(self.fd, self.buf[self.end..]);
            if (n == 0) return error.Disconnected;
            self.end += n;
        }
    }

    /// Skip event lines and return the next response, parsed as T.
    pub fn readResponse(
        self: *Client,
        comptime T: type,
        alloc: std.mem.Allocator,
    ) !std.json.Parsed(T) {
        while (true) {
            const line = self.readLine() catch |err| return err;
            if (std.mem.indexOf(u8, line, "\"event\":") != null) continue;
            return try std.json.parseFromSlice(T, alloc, line, .{
                .ignore_unknown_fields = true,
            });
        }
    }
};

fn tcpFd(tcp: xev.TCP) posix.socket_t {
    if (comptime @hasField(xev.TCP, "fd")) return tcp.fd;
    // Dynamic xev: `backend` is an untagged union; pick the variant the
    // runtime-detected backend says is active.
    return switch (xev.backend) {
        inline else => |tag| @field(tcp.backend, @tagName(tag)).fd,
    };
}

/// Write everything, suppressing SIGPIPE (NOSIGPIPE sockopt on Darwin,
/// MSG_NOSIGNAL on Linux) and riding out short/blocked writes.
fn writeAllSocket(fd: posix.socket_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const result = if (comptime builtin.os.tag == .linux)
            posix.send(fd, bytes[off..], posix.MSG.NOSIGNAL)
        else
            posix.write(fd, bytes[off..]);
        const n = result catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = posix.poll(&fds, 1000) catch {};
                continue;
            },
            else => return err,
        };
        off += n;
    }
}

// --- tests ---------------------------------------------------------------

fn waitFor(client: *Client, needle: []const u8) ![]u8 {
    while (true) {
        const line = try client.readLine();
        if (std.mem.indexOf(u8, line, needle) != null) return line;
    }
}

const TestClient = struct {
    socket_path: []const u8,
    state_path: []const u8,
    err: ?anyerror = null,
    saw_exit_event: bool = false,
    snapshot_ok: bool = false,

    fn run(self: *TestClient) void {
        self.runInner() catch |err| {
            self.err = err;
        };
    }

    fn runInner(self: *TestClient) !void {
        var client = try Client.connect(self.socket_path);
        defer client.close();

        try client.sendLine("{\"id\":1,\"cmd\":\"create-session\",\"title\":\"remote\"}");
        const r1 = try waitFor(&client, "\"id\":1");
        if (std.mem.indexOf(u8, r1, "\"ok\":true") == null) return error.CreateFailed;

        try client.sendLine("{\"id\":2,\"cmd\":\"spawn-pane\",\"session\":1," ++
            "\"argv\":[\"/bin/sh\",\"-c\",\"echo hello-socket\"]}");
        const r2 = try waitFor(&client, "\"id\":2");
        if (std.mem.indexOf(u8, r2, "\"pane\":1") == null) return error.SpawnFailed;

        // The exit event proves the event stream reaches clients.
        _ = try waitFor(&client, "\"event\":\"pane_exit\"");
        self.saw_exit_event = true;

        try client.sendLine("{\"id\":3,\"cmd\":\"snapshot\",\"pane\":1}");
        const r3 = try waitFor(&client, "\"id\":3");
        self.snapshot_ok = std.mem.indexOf(u8, r3, "hello-socket") != null;

        var save_buf: [512]u8 = undefined;
        const save_req = try std.fmt.bufPrint(&save_buf, "{{\"id\":4,\"cmd\":\"save\",\"path\":\"{s}\"}}", .{self.state_path});
        try client.sendLine(save_req);
        _ = try waitFor(&client, "\"id\":4");

        try client.sendLine("{\"id\":5,\"cmd\":\"shutdown\"}");
        _ = try waitFor(&client, "\"id\":5");
    }
};

test "socket api: commands, events, save, shutdown" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const socket_path = try std.fs.path.join(alloc, &.{ dir, "zide.sock" });
    defer alloc.free(socket_path);
    const state_path = try std.fs.path.join(alloc, &.{ dir, "state.json" });
    defer alloc.free(state_path);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    var ipc_server = try Server.create(alloc, &server, socket_path);
    defer ipc_server.destroy();

    var client: TestClient = .{ .socket_path = socket_path, .state_path = state_path };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});

    // Runs until the pane finished AND shutdown drained the socket.
    try server.run();
    thread.join();

    try std.testing.expectEqual(@as(?anyerror, null), client.err);
    try std.testing.expect(client.saw_exit_event);
    try std.testing.expect(client.snapshot_ok);

    // The save command persisted a restorable layout.
    var restored = try session.Server.init(alloc);
    defer restored.deinit();
    const result = try persist.restore(alloc, &restored, state_path);
    try std.testing.expectEqual(@as(usize, 1), result.sessions);
    try std.testing.expectEqual(@as(usize, 1), result.panes);
}
