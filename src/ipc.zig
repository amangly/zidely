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
//! create-session, list-sessions, spawn-pane, write, snapshot, resize,
//! save, shutdown — plus the browser surface: browser-open,
//! browser-navigate, browser-eval work from any client; a shell process
//! that can render webviews registers with host-register and receives
//! browser_open / browser_nav / browser_eval events (existing panes are
//! replayed on registration), reporting state back with browser-update
//! and browser-eval-result. Browser panes are core state: they exist,
//! persist, and restore with no host attached.
//!
//! The `attach` command converts a connection to raw PTY passthrough —
//! permanently leaving the JSON protocol. After the ok reply, bytes the
//! client sends go verbatim into the pane and the pane's output comes
//! back verbatim; the server half-closes the socket when the pane
//! exits. This is the transport terminal renderers sit on (a libghostty
//! surface runs `zide attach <pane>` the way a terminal runs tmux
//! attach), so panes stay daemon-owned while rendering stays native.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const xev = @import("xev").Dynamic;
const session = @import("session.zig");
const persist = @import("persist.zig");
const agent = @import("agent.zig");

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
    url: ?[]const u8 = null,
    seq: ?u64 = null,
    loading: ?bool = null,
    repo: ?[]const u8 = null,
    description: ?[]const u8 = null,
    task: ?agent.TaskId = null,
    delete_branch: ?bool = null,
    force: ?bool = null,
};

const Connection = struct {
    server: *Server,
    conn: xev.TCP,
    fd: posix.socket_t,
    c_read: xev.Completion = .{},
    read_buf: [4096]u8 = undefined,
    /// Partial-line accumulator; requests may arrive split or batched.
    line: std.ArrayListUnmanaged(u8) = .empty,
    /// Raw-passthrough mode: bytes flow verbatim to/from this pane and
    /// the JSON protocol no longer applies (see the attach command).
    attached: ?session.PaneId = null,
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

        if (self.attached) |pane| {
            // A vanished pane EOFs the attachment rather than erroring:
            // the exit path already half-closed this socket.
            server.session_server.paneWrite(pane, self.read_buf[0..n]) catch {};
            return .rearm;
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
            if (self.attached) |pane| {
                // The attach request may arrive batched with the first
                // input bytes; everything after its newline is raw.
                if (self.line.items.len > 0)
                    server.session_server.paneWrite(pane, self.line.items) catch {};
                self.line.clearRetainingCapacity();
                break;
            }
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
    /// The connection that renders webviews, if one registered.
    host: ?*Connection = null,
    downstream: ?session.EventHandler,
    /// One agent manager per repo, created lazily on first task-create.
    /// Ordered: their event handlers chain onto the session server and
    /// must unwind LIFO on destroy.
    managers: std.ArrayListUnmanaged(RepoManager) = .empty,
    /// Task ids are global across repos: handed to each manager before
    /// every startTask so shells never see colliding ids.
    next_task_id: agent.TaskId = 1,
    shutting_down: bool = false,
    listener_closed: bool = false,

    const RepoManager = struct {
        repo: []const u8,
        manager: *agent.Manager,
    };

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
        // Managers chained their handlers after ours: unwind LIFO first.
        while (self.managers.pop()) |rm| {
            rm.manager.destroy();
            self.alloc.free(rm.repo);
        }
        self.managers.deinit(self.alloc);
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
        // Raw libc call: std's setsockopt treats EINVAL as unreachable,
        // but macOS returns EINVAL when the peer already disconnected
        // (e.g. a probe that connects and instantly closes) — a state
        // any client can put us in, which must never panic the server.
        if (comptime builtin.os.tag.isDarwin()) {
            const one: c_int = 1;
            _ = std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &one, @sizeOf(c_int));
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
        if (self.host == client) self.host = null;
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
                browsers: []const session.PaneId,
                /// Subset of `panes` whose child has exited. A client that
                /// connects late never saw those pane_exit events.
                exited: []const session.PaneId,
            };
            const infos = try arena.alloc(Info, ss.sessions.count());
            var it = ss.sessions.valueIterator();
            var i: usize = 0;
            while (it.next()) |s| : (i += 1) {
                var exited: std.ArrayListUnmanaged(session.PaneId) = .empty;
                for (s.panes.items) |p| {
                    if (ss.paneExited(p)) try exited.append(arena, p);
                }
                infos[i] = .{
                    .id = s.id,
                    .title = s.title,
                    .panes = s.panes.items,
                    .browsers = s.browsers.items,
                    .exited = exited.items,
                };
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
        } else if (eql(u8, req.cmd, "resize")) {
            const pane = req.pane orelse return error.MissingPane;
            const rows = req.rows orelse return error.MissingSize;
            const cols = req.cols orelse return error.MissingSize;
            try ss.paneResize(pane, rows, cols);
            self.reply(client, .{ .id = req.id, .ok = true });
        } else if (eql(u8, req.cmd, "attach")) {
            const pane = req.pane orelse return error.MissingPane;
            if (ss.panes.get(pane) == null) return error.NoSuchPane;
            // Mode-switch before replying: the ok line must be the last
            // JSON this connection ever sees (broadcasts skip attached
            // connections), so everything after it is pane bytes.
            client.attached = pane;
            self.reply(client, .{ .id = req.id, .ok = true });
        } else if (eql(u8, req.cmd, "save")) {
            const path = req.path orelse return error.MissingPath;
            try persist.save(self.alloc, ss, path);
            self.reply(client, .{ .id = req.id, .ok = true });
        } else if (eql(u8, req.cmd, "host-register")) {
            self.host = client;
            self.reply(client, .{ .id = req.id, .ok = true });
            // Replay existing browser panes so a late host renders them.
            var it = ss.browser_panes.valueIterator();
            while (it.next()) |bp| {
                const b = bp.*;
                self.sendTo(client, .{
                    .event = "browser_open",
                    .pane = b.id,
                    .session = b.session,
                    .url = b.url,
                });
            }
        } else if (eql(u8, req.cmd, "browser-open")) {
            const sid = req.session orelse return error.MissingSession;
            const url = req.url orelse return error.MissingUrl;
            const pane = try ss.openBrowserPane(sid, url);
            self.reply(client, .{ .id = req.id, .ok = true, .pane = pane });
            self.broadcast(.{ .event = "browser_open", .pane = pane, .session = sid, .url = url });
        } else if (eql(u8, req.cmd, "browser-navigate")) {
            const pane = req.pane orelse return error.MissingPane;
            const url = req.url orelse return error.MissingUrl;
            try ss.updateBrowserPane(pane, url, null, true);
            self.reply(client, .{ .id = req.id, .ok = true });
            self.broadcast(.{ .event = "browser_nav", .pane = pane, .url = url });
        } else if (eql(u8, req.cmd, "browser-update")) {
            // The host reporting navigation state / page title back.
            const pane = req.pane orelse return error.MissingPane;
            try ss.updateBrowserPane(pane, req.url, req.title, req.loading);
            self.reply(client, .{ .id = req.id, .ok = true });
            const b = ss.getBrowserPane(pane).?;
            self.broadcast(.{
                .event = "browser_update",
                .pane = pane,
                .url = b.url,
                .title = b.title,
                .loading = b.loading,
            });
        } else if (eql(u8, req.cmd, "browser-eval")) {
            const pane = req.pane orelse return error.MissingPane;
            const js = req.data orelse return error.MissingData;
            if (ss.getBrowserPane(pane) == null) return error.NoSuchPane;
            const host = self.host orelse return error.NoBrowserHost;
            self.sendTo(host, .{
                .event = "browser_eval",
                .pane = pane,
                .seq = req.seq orelse 0,
                .js = js,
            });
            self.reply(client, .{ .id = req.id, .ok = true });
        } else if (eql(u8, req.cmd, "browser-eval-result")) {
            const pane = req.pane orelse return error.MissingPane;
            self.reply(client, .{ .id = req.id, .ok = true });
            self.broadcast(.{
                .event = "browser_eval_result",
                .pane = pane,
                .seq = req.seq orelse 0,
                .value = req.data orelse "",
            });
        } else if (eql(u8, req.cmd, "task-create")) {
            const repo = req.repo orelse return error.MissingRepo;
            const desc = req.description orelse return error.MissingDescription;
            const mgr = try self.managerFor(repo);

            // Default agent: interactive Claude Code seeded with the task.
            const default_argv = [_][]const u8{ "claude", desc };
            const argv: []const []const u8 = req.argv orelse &default_argv;

            mgr.next_task_id = self.next_task_id;
            const tid = try mgr.startTask(.{
                .description = desc,
                .argv = argv,
                .rows = req.rows orelse 24,
                .cols = req.cols orelse 80,
            });
            self.next_task_id = mgr.next_task_id;

            const task = mgr.get(tid).?;
            self.reply(client, .{
                .id = req.id,
                .ok = true,
                .task = tid,
                .pane = task.pane,
                .branch = task.worktree.branch,
            });
            self.broadcast(.{
                .event = "task_status",
                .task = tid,
                .status = @tagName(task.status),
                .pane = task.pane,
                .description = desc,
            });
        } else if (eql(u8, req.cmd, "task-list")) {
            var arena_state = std.heap.ArenaAllocator.init(self.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const TaskInfo = struct {
                id: agent.TaskId,
                description: []const u8,
                status: []const u8,
                pane: session.PaneId,
                repo: []const u8,
                branch: []const u8,
                exit_code: ?u8,
            };
            var infos: std.ArrayListUnmanaged(TaskInfo) = .empty;
            for (self.managers.items) |rm| {
                var it = rm.manager.tasks.valueIterator();
                while (it.next()) |task_ptr| {
                    const t = task_ptr.*;
                    try infos.append(arena, .{
                        .id = t.id,
                        .description = t.description,
                        .status = @tagName(t.status),
                        .pane = t.pane,
                        .repo = rm.repo,
                        .branch = t.worktree.branch,
                        .exit_code = t.exit_code,
                    });
                }
            }
            self.reply(client, .{ .id = req.id, .ok = true, .tasks = infos.items });
        } else if (eql(u8, req.cmd, "task-cleanup")) {
            const tid = req.task orelse return error.MissingTask;
            const mgr = for (self.managers.items) |rm| {
                if (rm.manager.get(tid) != null) break rm.manager;
            } else return error.NoSuchTask;
            try mgr.cleanupTask(tid, .{
                .delete_branch = req.delete_branch orelse false,
                .force = req.force orelse false,
            });
            self.reply(client, .{ .id = req.id, .ok = true });
            self.broadcast(.{ .event = "task_removed", .task = tid });
        } else if (eql(u8, req.cmd, "task-diff")) {
            const tid = req.task orelse return error.MissingTask;
            const mgr = for (self.managers.items) |rm| {
                if (rm.manager.get(tid) != null) break rm.manager;
            } else return error.NoSuchTask;
            var review = try mgr.reviewTask(tid, self.alloc);
            defer review.deinit(self.alloc);
            // One diff line must fit the synchronous client's buffer
            // (with JSON-escaping overhead on top).
            const cap = 400 * 1024;
            const diff = if (review.diff.len <= cap) review.diff else review.diff[0..cap];
            self.reply(client, .{
                .id = req.id,
                .ok = true,
                .diff = diff,
                .truncated = review.diff.len > cap,
                .commits = review.commits,
                .dirty = review.dirty,
            });
        } else if (eql(u8, req.cmd, "task-merge")) {
            const tid = req.task orelse return error.MissingTask;
            const mgr = for (self.managers.items) |rm| {
                if (rm.manager.get(tid) != null) break rm.manager;
            } else return error.NoSuchTask;
            try mgr.mergeTask(tid);
            self.reply(client, .{ .id = req.id, .ok = true });
            self.broadcast(.{ .event = "task_removed", .task = tid, .merged = true });
        } else if (eql(u8, req.cmd, "shutdown")) {
            self.reply(client, .{ .id = req.id, .ok = true });
            self.beginShutdown(client);
        } else {
            return error.UnknownCommand;
        }
    }

    /// The agent manager for a repo, created on first use along with the
    /// session its task panes live in.
    fn managerFor(self: *Server, repo: []const u8) !*agent.Manager {
        for (self.managers.items) |rm| {
            if (std.mem.eql(u8, rm.repo, repo)) return rm.manager;
        }

        const title = try std.fmt.allocPrint(self.alloc, "agents: {s}", .{std.fs.path.basename(repo)});
        defer self.alloc.free(title);
        const sid = try self.session_server.createSession(title);

        const wt_dir = try std.fs.path.join(self.alloc, &.{ repo, ".zide-worktrees" });
        defer self.alloc.free(wt_dir);
        const mgr = try agent.Manager.create(self.alloc, self.session_server, sid, .{
            .repo = repo,
            .worktrees_dir = wt_dir,
        });
        errdefer mgr.destroy();
        mgr.task_handler = .{ .userdata = self, .func = onTaskEvent };

        const repo_owned = try self.alloc.dupe(u8, repo);
        errdefer self.alloc.free(repo_owned);
        try self.managers.append(self.alloc, .{ .repo = repo_owned, .manager = mgr });
        return mgr;
    }

    fn onTaskEvent(ud: ?*anyopaque, manager: *agent.Manager, event: agent.TaskEvent) void {
        const self: *Server = @ptrCast(@alignCast(ud.?));
        const task = manager.get(event.task) orelse return;
        self.broadcast(.{
            .event = "task_status",
            .task = event.task,
            .status = @tagName(event.status),
            .pane = task.pane,
            .description = task.description,
            .exit_code = task.exit_code,
        });
    }

    /// Send a payload to one specific connection (host routing).
    fn sendTo(self: *Server, client: *Connection, payload: anytype) void {
        const json = std.fmt.allocPrint(self.alloc, "{f}\n", .{std.json.fmt(payload, .{})}) catch return;
        defer self.alloc.free(json);
        writeAllSocket(client.fd, json) catch {
            client.closing = true;
        };
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
            .pane_output => |p| {
                self.broadcast(.{ .event = "pane_output", .pane = p.pane });
                for (self.clients.items) |client| {
                    if (client.attached != p.pane) continue;
                    writeAllSocket(client.fd, p.bytes) catch {
                        client.closing = true;
                    };
                }
            },
            .pane_bell => |p| self.broadcast(.{ .event = "pane_bell", .pane = p }),
            .pane_exit => |e| {
                self.broadcast(.{
                    .event = "pane_exit",
                    .pane = e.pane,
                    .exit_code = e.exit_code,
                });
                // EOF raw attachments; their client loops end on read 0.
                // shutdown(2), not close — the read completion stays live.
                for (self.clients.items) |client| {
                    if (client.attached != e.pane) continue;
                    posix.shutdown(client.fd, .both) catch {};
                }
            },
        }
        if (self.downstream) |d| d.func(d.userdata, server, event);
    }

    /// JSON to every protocol-mode client. Attached connections are raw
    /// byte streams — a JSON line would corrupt them, so they are skipped.
    fn broadcast(self: *Server, payload: anytype) void {
        if (self.clients.items.len == 0) return;
        const json = std.fmt.allocPrint(self.alloc, "{f}\n", .{std.json.fmt(payload, .{})}) catch return;
        defer self.alloc.free(json);
        for (self.clients.items) |client| {
            if (client.attached != null) continue;
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
    /// Sized for a whole task-diff response on one JSON line (the
    /// server caps diffs at 400 KiB before escaping).
    buf: [1024 * 1024]u8 = undefined,
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

/// Plays both sides of the browser protocol on one thread: a mock host
/// connection (pretend WKWebView) and a regular client, interleaved in
/// an order where every read has already been written by the server.
const BrowserTestClient = struct {
    socket_path: []const u8,
    err: ?anyerror = null,
    host_got_open: bool = false,
    host_got_replayed: bool = false,
    client_saw_update: bool = false,
    client_got_eval_result: bool = false,

    fn run(self: *BrowserTestClient) void {
        self.runInner() catch |err| {
            self.err = err;
        };
    }

    fn runInner(self: *BrowserTestClient) !void {
        var client = try Client.connect(self.socket_path);
        defer client.close();

        try client.sendLine("{\"id\":1,\"cmd\":\"create-session\",\"title\":\"web\"}");
        _ = try waitFor(&client, "\"id\":1");
        try client.sendLine("{\"id\":2,\"cmd\":\"browser-open\",\"session\":1,\"url\":\"https://example.com\"}");
        const r2 = try waitFor(&client, "\"id\":2");
        if (std.mem.indexOf(u8, r2, "\"pane\":1") == null) return error.OpenFailed;

        // Eval without a host must fail cleanly.
        try client.sendLine("{\"id\":3,\"cmd\":\"browser-eval\",\"pane\":1,\"data\":\"1+1\",\"seq\":9}");
        const r3 = try waitFor(&client, "\"id\":3");
        if (std.mem.indexOf(u8, r3, "NoBrowserHost") == null) return error.ExpectedNoHost;

        // A host attaches late: it must get the existing pane replayed.
        var host = try Client.connect(self.socket_path);
        defer host.close();
        try host.sendLine("{\"id\":1,\"cmd\":\"host-register\"}");
        _ = try waitFor(&host, "\"id\":1");
        const replay = try waitFor(&host, "\"event\":\"browser_open\"");
        self.host_got_replayed = std.mem.indexOf(u8, replay, "example.com") != null;

        // Host reports the page loaded; the client sees the update.
        try host.sendLine("{\"id\":2,\"cmd\":\"browser-update\",\"pane\":1," ++
            "\"title\":\"Example Domain\",\"loading\":false}");
        _ = try waitFor(&host, "\"id\":2");
        const upd = try waitFor(&client, "\"event\":\"browser_update\"");
        self.client_saw_update = std.mem.indexOf(u8, upd, "Example Domain") != null;

        // Eval round-trip: client → core → host → core → client.
        try client.sendLine("{\"id\":4,\"cmd\":\"browser-eval\",\"pane\":1,\"data\":\"1+1\",\"seq\":42}");
        _ = try waitFor(&client, "\"id\":4");
        const ev = try waitFor(&host, "\"event\":\"browser_eval\"");
        self.host_got_open = std.mem.indexOf(u8, ev, "\"seq\":42") != null;
        try host.sendLine("{\"id\":3,\"cmd\":\"browser-eval-result\",\"pane\":1,\"seq\":42,\"data\":\"2\"}");
        const res = try waitFor(&client, "\"event\":\"browser_eval_result\"");
        self.client_got_eval_result = std.mem.indexOf(u8, res, "\"seq\":42") != null and
            std.mem.indexOf(u8, res, "\"value\":\"2\"") != null;

        try client.sendLine("{\"id\":5,\"cmd\":\"shutdown\"}");
        _ = try waitFor(&client, "\"id\":5");
    }
};

test "browser panes: host protocol round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const socket_path = try std.fs.path.join(alloc, &.{ dir, "zide.sock" });
    defer alloc.free(socket_path);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    var ipc_server = try Server.create(alloc, &server, socket_path);
    defer ipc_server.destroy();

    var tc: BrowserTestClient = .{ .socket_path = socket_path };
    const thread = try std.Thread.spawn(.{}, BrowserTestClient.run, .{&tc});
    try server.run();
    thread.join();

    try std.testing.expectEqual(@as(?anyerror, null), tc.err);
    try std.testing.expect(tc.host_got_replayed);
    try std.testing.expect(tc.client_saw_update);
    try std.testing.expect(tc.host_got_open);
    try std.testing.expect(tc.client_got_eval_result);

    // Browser pane state survived in the core.
    const b = server.getBrowserPane(1).?;
    try std.testing.expectEqualStrings("Example Domain", b.title);
    try std.testing.expect(!b.loading);
}

/// Drives the attach transport end to end: spawn an interactive child,
/// resize its pane, attach raw, type into it, read its raw output, and
/// observe the EOF the server sends when the pane exits.
const AttachTestClient = struct {
    socket_path: []const u8,
    err: ?anyerror = null,
    resized_output_ok: bool = false,
    saw_eof: bool = false,

    fn run(self: *AttachTestClient) void {
        self.runInner() catch |err| {
            self.err = err;
        };
    }

    fn runInner(self: *AttachTestClient) !void {
        var control = try Client.connect(self.socket_path);
        defer control.close();

        try control.sendLine("{\"id\":1,\"cmd\":\"create-session\",\"title\":\"attach\"}");
        _ = try waitFor(&control, "\"id\":1");

        // An interactive child: waits for one line, reports its tty size.
        try control.sendLine("{\"id\":2,\"cmd\":\"spawn-pane\",\"session\":1," ++
            "\"argv\":[\"/bin/sh\",\"-c\",\"read line; stty size\"]}");
        const r2 = try waitFor(&control, "\"id\":2");
        if (std.mem.indexOf(u8, r2, "\"pane\":1") == null) return error.SpawnFailed;

        // Live resize: what an attached client sends on SIGWINCH.
        try control.sendLine("{\"id\":3,\"cmd\":\"resize\",\"pane\":1,\"rows\":33,\"cols\":111}");
        const r3 = try waitFor(&control, "\"id\":3");
        if (std.mem.indexOf(u8, r3, "\"ok\":true") == null) return error.ResizeFailed;

        // Second connection becomes the raw byte pipe.
        var raw = try Client.connect(self.socket_path);
        defer raw.close();
        try raw.sendLine("{\"id\":1,\"cmd\":\"attach\",\"pane\":1}");
        _ = try waitFor(&raw, "\"id\":1");

        // Raw input: unblocks `read line`; the child then prints the
        // size the resize command set.
        try writeAllSocket(raw.fd, "\n");

        var collected: [4096]u8 = undefined;
        var len: usize = 0;
        // Bytes that raced the ok reply are already pane output.
        if (raw.end > raw.start) {
            const pending = raw.buf[raw.start..raw.end];
            @memcpy(collected[0..pending.len], pending);
            len = pending.len;
        }
        while (len < collected.len) {
            const n = posix.read(raw.fd, collected[len..]) catch 0;
            if (n == 0) break; // pane exit half-closed the attachment
            len += n;
        }
        self.saw_eof = true;
        self.resized_output_ok = std.mem.indexOf(u8, collected[0..len], "33 111") != null;

        try control.sendLine("{\"id\":9,\"cmd\":\"shutdown\"}");
        _ = try waitFor(&control, "\"id\":9");
    }
};

test "attach: raw passthrough, live resize, exit EOF" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const socket_path = try std.fs.path.join(alloc, &.{ dir, "zide.sock" });
    defer alloc.free(socket_path);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    var ipc_server = try Server.create(alloc, &server, socket_path);
    defer ipc_server.destroy();

    var tc: AttachTestClient = .{ .socket_path = socket_path };
    const thread = try std.Thread.spawn(.{}, AttachTestClient.run, .{&tc});
    try server.run();
    thread.join();

    try std.testing.expectEqual(@as(?anyerror, null), tc.err);
    try std.testing.expect(tc.saw_eof);
    try std.testing.expect(tc.resized_output_ok);
}

/// Drives the agent-task protocol end to end: create a task (fake
/// agent in a real scratch repo), see it in task-list, watch the
/// task_status stream to finished, clean it up, see task_removed.
const TaskTestClient = struct {
    socket_path: []const u8,
    repo: []const u8,
    err: ?anyerror = null,
    listed_ok: bool = false,
    finished_ok: bool = false,
    removed_ok: bool = false,
    diff_ok: bool = false,
    merged_ok: bool = false,
    panes_gone: bool = false,

    fn run(self: *TaskTestClient) void {
        self.runInner() catch |err| {
            self.err = err;
        };
    }

    fn runInner(self: *TaskTestClient) !void {
        var client = try Client.connect(self.socket_path);
        defer client.close();

        var buf: [1024]u8 = undefined;
        const create = try std.fmt.bufPrint(&buf, "{{\"id\":1,\"cmd\":\"task-create\"," ++
            "\"repo\":\"{s}\",\"description\":\"prove the harness\"," ++
            "\"argv\":[\"/bin/sh\",\"-c\",\"git rev-parse --abbrev-ref HEAD; echo task-done\"]}}", .{self.repo});
        try client.sendLine(create);
        const r1 = try waitFor(&client, "\"id\":1");
        if (std.mem.indexOf(u8, r1, "\"ok\":true") == null) return error.CreateFailed;
        if (std.mem.indexOf(u8, r1, "zide/prove-the-harness") == null) return error.NoBranch;

        try client.sendLine("{\"id\":2,\"cmd\":\"task-list\"}");
        const r2 = try waitFor(&client, "\"id\":2");
        self.listed_ok = std.mem.indexOf(u8, r2, "prove the harness") != null and
            std.mem.indexOf(u8, r2, self.repo) != null;

        // The agent exits on its own; status must reach finished.
        while (true) {
            const line = try client.readLine();
            if (std.mem.indexOf(u8, line, "\"task_status\"") == null) continue;
            if (std.mem.indexOf(u8, line, "\"finished\"") == null) continue;
            self.finished_ok = true;
            break;
        }

        try client.sendLine("{\"id\":3,\"cmd\":\"task-cleanup\",\"task\":1," ++
            "\"delete_branch\":true,\"force\":true}");
        _ = try waitFor(&client, "\"id\":3");
        _ = try waitFor(&client, "\"task_removed\"");
        try client.sendLine("{\"id\":4,\"cmd\":\"task-list\"}");
        const r4 = try waitFor(&client, "\"id\":4");
        self.removed_ok = std.mem.indexOf(u8, r4, "prove the harness") == null;

        // Second task commits work; review it and merge it over the socket.
        const create2 = try std.fmt.bufPrint(&buf, "{{\"id\":5,\"cmd\":\"task-create\"," ++
            "\"repo\":\"{s}\",\"description\":\"commit some work\"," ++
            "\"argv\":[\"/bin/sh\",\"-c\",\"echo diffable-content > agent.txt && git add . && " ++
            "git -c user.name=t -c user.email=t@t.invalid commit -qm work\"]}}", .{self.repo});
        try client.sendLine(create2);
        _ = try waitFor(&client, "\"id\":5");
        while (true) {
            const line = try client.readLine();
            if (std.mem.indexOf(u8, line, "\"task_status\"") == null) continue;
            if (std.mem.indexOf(u8, line, "\"finished\"") != null) break;
        }

        try client.sendLine("{\"id\":6,\"cmd\":\"task-diff\",\"task\":2}");
        const r6 = try waitFor(&client, "\"id\":6");
        self.diff_ok = std.mem.indexOf(u8, r6, "diffable-content") != null and
            std.mem.indexOf(u8, r6, "\"commits\":1") != null and
            std.mem.indexOf(u8, r6, "\"dirty\":false") != null;

        try client.sendLine("{\"id\":7,\"cmd\":\"task-merge\",\"task\":2}");
        const r7 = try waitFor(&client, "\"id\":7");
        self.merged_ok = std.mem.indexOf(u8, r7, "\"ok\":true") != null;
        _ = try waitFor(&client, "\"task_removed\"");

        // Cleanup removed the dead agent panes from their session too.
        try client.sendLine("{\"id\":8,\"cmd\":\"list-sessions\"}");
        const r8 = try waitFor(&client, "\"id\":8");
        self.panes_gone = std.mem.indexOf(u8, r8, "\"panes\":[]") != null;

        try client.sendLine("{\"id\":9,\"cmd\":\"shutdown\"}");
        _ = try waitFor(&client, "\"id\":9");
    }
};

test "agent tasks over the socket: create, list, status stream, cleanup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const socket_path = try std.fs.path.join(alloc, &.{ dir, "zide.sock" });
    defer alloc.free(socket_path);

    try tmp.dir.makeDir("repo");
    const repo = try tmp.dir.realpathAlloc(alloc, "repo");
    defer alloc.free(repo);
    const gitx = @import("gitx.zig");
    try gitx.setupTestRepo(alloc, repo);

    var server = try session.Server.init(alloc);
    defer server.deinit();
    var ipc_server = try Server.create(alloc, &server, socket_path);
    defer ipc_server.destroy();

    var tc: TaskTestClient = .{ .socket_path = socket_path, .repo = repo };
    const thread = try std.Thread.spawn(.{}, TaskTestClient.run, .{&tc});
    try server.run();
    thread.join();

    try std.testing.expectEqual(@as(?anyerror, null), tc.err);
    try std.testing.expect(tc.listed_ok);
    try std.testing.expect(tc.finished_ok);
    try std.testing.expect(tc.removed_ok);
    try std.testing.expect(tc.diff_ok);
    try std.testing.expect(tc.merged_ok);
    try std.testing.expect(tc.panes_gone);

    // The merged task's work is on the repo's branch.
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "-C", repo, "show", "main:agent.txt" },
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try std.testing.expectEqualStrings("diffable-content\n", res.stdout);
}

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
