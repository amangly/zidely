//! Session server: owns sessions, panes, and the event loop.
//!
//! Designed as a server from day one (state behind an API, no UI types)
//! even though it initially runs in-process inside the app. This is the
//! seam that later becomes the daemon boundary and the automation socket.
//! Embedders either drive `run()` on a dedicated thread or pump `tick()`
//! from their own loop, and observe the world through `EventHandler`.

const std = @import("std");
const posix = std.posix;
const xev = @import("xev").Dynamic;
const term = @import("term.zig");

pub const SessionId = u64;
pub const PaneId = term.PaneId;

pub const Event = union(enum) {
    /// The pane's terminal state changed; read it via paneSnapshot().
    /// `bytes` is the raw chunk that caused the change (for attached
    /// raw-passthrough clients) — only valid during the callback.
    pane_output: struct { pane: PaneId, bytes: []const u8 },
    /// The child rang the terminal bell — an explicit attention signal.
    pane_bell: PaneId,
    /// The pane's child exited and its PTY output is fully drained.
    /// exit_code is null only when the exit status could not be read.
    pane_exit: struct { pane: PaneId, exit_code: ?u8 },
};

pub const EventHandler = struct {
    userdata: ?*anyopaque = null,
    /// Called from inside the event loop; keep it quick and non-blocking.
    func: *const fn (userdata: ?*anyopaque, server: *Server, event: Event) void,

    fn emit(self: EventHandler, server: *Server, event: Event) void {
        self.func(self.userdata, server, event);
    }
};

pub const Session = struct {
    id: SessionId,
    /// Display title, owned by the server's allocator.
    title: []const u8,
    panes: std.ArrayListUnmanaged(PaneId) = .empty,
    browsers: std.ArrayListUnmanaged(PaneId) = .empty,
};

/// A browser pane: webview state owned by the core, rendered by
/// whichever shell/host is attached (see ipc.zig's host protocol).
/// Headless-first — the state exists and persists with no host running.
pub const BrowserPane = struct {
    id: PaneId,
    session: SessionId,
    /// Current URL; owned by the server's allocator.
    url: []const u8,
    /// Page title as reported by the host; owned, empty until known.
    title: []const u8,
    loading: bool = true,
};

/// Per-pane event-loop state. Heap-pinned: completions and the read
/// buffer are registered with the kernel and must never move.
const PaneHandle = struct {
    server: *Server,
    id: PaneId,
    session: SessionId,
    pane: *term.Pane,
    stream: xev.Stream,
    process: xev.Process,
    c_read: xev.Completion,
    c_proc: xev.Completion,
    read_buf: [4096]u8 = undefined,
    bells: term.BellScanner = .{},

    // The spawn recipe, retained so the layout can be persisted and
    // respawned later (see persist.zig). Deep-owned by the server.
    argv: []const []const u8,
    cwd: ?[]const u8,
    rows: u16,
    cols: u16,

    // pane_exit is emitted only once BOTH the child has exited and the
    // PTY has drained to EOF, so no trailing output is ever lost.
    eof: bool = false,
    exited: bool = false,
    exit_code: ?u8 = null,
    reported: bool = false,

    fn onRead(
        ud: ?*PaneHandle,
        loop: *xev.Loop,
        c: *xev.Completion,
        stream: xev.Stream,
        buf: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        _ = loop;
        _ = c;
        _ = stream;
        _ = buf;
        const h = ud.?;

        const n = r catch {
            // EOF, or EIO — how Linux reports a closed PTY master.
            h.eof = true;
            h.maybeFinish();
            return .disarm;
        };
        if (n == 0) {
            h.eof = true;
            h.maybeFinish();
            return .disarm;
        }

        const bell_count = h.bells.scan(h.read_buf[0..n]);
        h.pane.feed(h.read_buf[0..n]) catch |err| {
            std.log.warn("pane {d}: dropped {d} bytes of output: {}", .{ h.id, n, err });
        };
        if (h.server.handler) |handler| {
            handler.emit(h.server, .{ .pane_output = .{ .pane = h.id, .bytes = h.read_buf[0..n] } });
            if (bell_count > 0) handler.emit(h.server, .{ .pane_bell = h.id });
        }
        return .rearm;
    }

    fn onExit(
        ud: ?*PaneHandle,
        loop: *xev.Loop,
        c: *xev.Completion,
        r: xev.Process.WaitError!u32,
    ) xev.CallbackAction {
        _ = loop;
        _ = c;
        const h = ud.?;
        h.exited = true;
        h.exit_code = if (r) |status| exitCodeFromStatus(status) else |_| null;
        h.maybeFinish();
        return .disarm;
    }

    fn maybeFinish(self: *PaneHandle) void {
        if (!(self.eof and self.exited) or self.reported) return;
        self.reported = true;
        if (self.server.handler) |handler| handler.emit(self.server, .{
            .pane_exit = .{ .pane = self.id, .exit_code = self.exit_code },
        });
    }
};

fn dupeArgv(alloc: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, argv.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |arg| alloc.free(arg);
        alloc.free(out);
    }
    while (i < argv.len) : (i += 1) out[i] = try alloc.dupe(u8, argv[i]);
    return out;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

/// Both libxev backends deliver a plain exit code (kqueue decodes the
/// wait status itself; the Linux pidfd path reads siginfo). Caveat, to
/// fix by reaping ourselves later: signal deaths surface as 0 on macOS
/// and as the signal number on Linux.
fn exitCodeFromStatus(status: u32) ?u8 {
    return @intCast(status & 0xff);
}

pub const Server = struct {
    alloc: std.mem.Allocator,
    loop: xev.Loop,
    sessions: std.AutoHashMapUnmanaged(SessionId, Session),
    panes: std.AutoHashMapUnmanaged(PaneId, *PaneHandle),
    browser_panes: std.AutoHashMapUnmanaged(PaneId, *BrowserPane),
    next_session_id: SessionId = 1,
    /// Shared by terminal and browser panes so ids never collide.
    next_pane_id: PaneId = 1,
    handler: ?EventHandler = null,

    pub fn init(alloc: std.mem.Allocator) !Server {
        // With a single candidate backend (macOS: kqueue), Dynamic
        // collapses to the static API which has no detect().
        if (comptime @hasDecl(xev, "detect")) try xev.detect();
        return .{
            .alloc = alloc,
            .loop = try xev.Loop.init(.{}),
            .sessions = .empty,
            .panes = .empty,
            .browser_panes = .empty,
        };
    }

    pub fn deinit(self: *Server) void {
        var pane_it = self.panes.valueIterator();
        while (pane_it.next()) |handle_ptr| {
            const h = handle_ptr.*;
            h.process.deinit();
            // Closing the master hangs up the PTY; a still-running child
            // gets SIGHUP from the kernel.
            h.pane.destroy();
            freeArgv(self.alloc, h.argv);
            if (h.cwd) |c| self.alloc.free(c);
            self.alloc.destroy(h);
        }
        self.panes.deinit(self.alloc);

        var browser_it = self.browser_panes.valueIterator();
        while (browser_it.next()) |bp| {
            const b = bp.*;
            self.alloc.free(b.url);
            self.alloc.free(b.title);
            self.alloc.destroy(b);
        }
        self.browser_panes.deinit(self.alloc);

        var session_it = self.sessions.valueIterator();
        while (session_it.next()) |s| {
            s.panes.deinit(self.alloc);
            s.browsers.deinit(self.alloc);
            self.alloc.free(s.title);
        }
        self.sessions.deinit(self.alloc);

        self.loop.deinit();
        self.* = undefined;
    }

    pub fn createSession(self: *Server, title: []const u8) !SessionId {
        const id = self.next_session_id;
        const owned = try self.alloc.dupe(u8, title);
        errdefer self.alloc.free(owned);
        try self.sessions.put(self.alloc, id, .{ .id = id, .title = owned });
        self.next_session_id += 1;
        return id;
    }

    /// Retitle a session (shells rename their workspace rows).
    pub fn renameSession(self: *Server, id: SessionId, title: []const u8) !void {
        const sess = self.sessions.getPtr(id) orelse return error.NoSuchSession;
        const owned = try self.alloc.dupe(u8, title);
        self.alloc.free(sess.title);
        sess.title = owned;
    }

    /// Remove a session whose terminal panes are all gone — kill and
    /// remove them first (their kernel completions must drain from
    /// request context, same rule as removePane). Browser panes are
    /// pure state and close with the session; callers broadcast their
    /// removal.
    pub fn removeSession(self: *Server, id: SessionId) !void {
        const sess = self.sessions.getPtr(id) orelse return error.NoSuchSession;
        if (sess.panes.items.len != 0) return error.SessionNotEmpty;
        while (sess.browsers.items.len > 0) {
            const bid = sess.browsers.items[sess.browsers.items.len - 1];
            self.closeBrowserPane(bid) catch {
                _ = sess.browsers.pop();
            };
        }
        var removed = self.sessions.fetchRemove(id).?.value;
        removed.panes.deinit(self.alloc);
        removed.browsers.deinit(self.alloc);
        self.alloc.free(removed.title);
    }

    pub fn getSession(self: *Server, id: SessionId) ?Session {
        return self.sessions.get(id);
    }

    pub fn count(self: *Server) usize {
        return self.sessions.count();
    }

    pub const SpawnOptions = struct {
        rows: u16 = 24,
        cols: u16 = 80,
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
    };

    /// Spawn a child on a new PTY pane inside a session and register it
    /// with the event loop. Output and exit are reported via `handler`.
    pub fn spawnPane(self: *Server, session_id: SessionId, opts: SpawnOptions) !PaneId {
        const sess = self.sessions.getPtr(session_id) orelse return error.NoSuchSession;

        const pane = try term.Pane.create(self.alloc, .{
            .rows = opts.rows,
            .cols = opts.cols,
            .argv = opts.argv,
            .cwd = opts.cwd,
        });
        errdefer pane.destroy();

        // The loop only reads the master when it's ready, but a PTY can
        // still block on odd conditions; make it explicitly non-blocking.
        const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        const fl = try posix.fcntl(pane.masterFd(), posix.F.GETFL, 0);
        _ = try posix.fcntl(pane.masterFd(), posix.F.SETFL, fl | nonblock);

        const argv_copy = try dupeArgv(self.alloc, opts.argv);
        errdefer freeArgv(self.alloc, argv_copy);
        const cwd_copy: ?[]const u8 = if (opts.cwd) |c| try self.alloc.dupe(u8, c) else null;
        errdefer if (cwd_copy) |c| self.alloc.free(c);

        const h = try self.alloc.create(PaneHandle);
        errdefer self.alloc.destroy(h);
        const id = self.next_pane_id;
        h.* = .{
            .server = self,
            .id = id,
            .session = session_id,
            .pane = pane,
            .stream = xev.Stream.initFd(pane.masterFd()),
            .process = try xev.Process.init(pane.pid),
            // Zero-init is the correct completion init for both static
            // and Dynamic xev (Dynamic's init() is broken for io_uring;
            // its watchers ensureTag() on zero-inited completions).
            .c_read = .{},
            .c_proc = .{},
            .argv = argv_copy,
            .cwd = cwd_copy,
            .rows = opts.rows,
            .cols = opts.cols,
        };
        errdefer h.process.deinit();

        try self.panes.put(self.alloc, id, h);
        errdefer _ = self.panes.remove(id);
        try sess.panes.append(self.alloc, id);
        self.next_pane_id += 1;

        h.stream.read(&self.loop, &h.c_read, .{ .slice = &h.read_buf }, PaneHandle, h, PaneHandle.onRead);
        h.process.wait(&self.loop, &h.c_proc, PaneHandle, h, PaneHandle.onExit);
        return id;
    }

    /// Create a browser pane in a session. Pure state: rendering happens
    /// in whatever host attaches via the ipc host protocol.
    pub fn openBrowserPane(self: *Server, session_id: SessionId, url: []const u8) !PaneId {
        const sess = self.sessions.getPtr(session_id) orelse return error.NoSuchSession;

        const b = try self.alloc.create(BrowserPane);
        errdefer self.alloc.destroy(b);
        const id = self.next_pane_id;
        b.* = .{
            .id = id,
            .session = session_id,
            .url = try self.alloc.dupe(u8, url),
            .title = try self.alloc.dupe(u8, ""),
        };
        errdefer {
            self.alloc.free(b.url);
            self.alloc.free(b.title);
        }

        try self.browser_panes.put(self.alloc, id, b);
        errdefer _ = self.browser_panes.remove(id);
        try sess.browsers.append(self.alloc, id);
        self.next_pane_id += 1;
        return id;
    }

    /// Update browser pane state (navigation from a client, or the host
    /// reporting load progress/title). Null fields stay unchanged.
    pub fn updateBrowserPane(
        self: *Server,
        id: PaneId,
        url: ?[]const u8,
        title: ?[]const u8,
        loading: ?bool,
    ) !void {
        const b = self.browser_panes.get(id) orelse return error.NoSuchPane;
        if (url) |u| {
            const owned = try self.alloc.dupe(u8, u);
            self.alloc.free(b.url);
            b.url = owned;
        }
        if (title) |t| {
            const owned = try self.alloc.dupe(u8, t);
            self.alloc.free(b.title);
            b.title = owned;
        }
        if (loading) |l| b.loading = l;
    }

    /// Browser pane state by value; string fields are borrowed from the
    /// server and valid until the next update.
    pub fn getBrowserPane(self: *Server, id: PaneId) ?BrowserPane {
        const b = self.browser_panes.get(id) orelse return null;
        return b.*;
    }

    /// Close a browser pane: pure state removal (rendering hosts drop
    /// their webview on the broadcast). Without this, a "closed"
    /// browser resurrects from the daemon on every refresh.
    pub fn closeBrowserPane(self: *Server, id: PaneId) !void {
        const b = self.browser_panes.get(id) orelse return error.NoSuchPane;
        if (self.sessions.getPtr(b.session)) |sess| {
            for (sess.browsers.items, 0..) |p, i| {
                if (p == id) {
                    _ = sess.browsers.orderedRemove(i);
                    break;
                }
            }
        }
        _ = self.browser_panes.remove(id);
        self.alloc.free(b.url);
        self.alloc.free(b.title);
        self.alloc.destroy(b);
    }

    /// Send input bytes to a pane's child (keyboard input, agent control).
    pub fn paneWrite(self: *Server, id: PaneId, bytes: []const u8) !void {
        const h = self.panes.get(id) orelse return error.NoSuchPane;
        try h.pane.writeInput(bytes);
    }

    /// Plain-text screen contents of a pane. Caller owns the memory.
    pub fn paneSnapshot(self: *Server, id: PaneId, alloc: std.mem.Allocator) ![]const u8 {
        const h = self.panes.get(id) orelse return error.NoSuchPane;
        return h.pane.snapshot(alloc);
    }

    /// VT byte stream that repaints the pane's full state (content,
    /// colors, cursor) on the attaching renderer's terminal. Caller
    /// owns the memory.
    pub fn paneReplay(self: *Server, id: PaneId, alloc: std.mem.Allocator) ![]const u8 {
        const h = self.panes.get(id) orelse return error.NoSuchPane;
        return h.pane.replayBytes(alloc);
    }

    /// Whether a pane's child has exited. Clients that connect after the
    /// fact (a shell restarting onto a live daemon) have missed the
    /// pane_exit event, so this state must be queryable, not just
    /// broadcast.
    pub fn paneExited(self: *Server, id: PaneId) bool {
        const h = self.panes.get(id) orelse return false;
        return h.exited;
    }

    /// Exited AND drained — i.e. the pane_exit event already fired and
    /// no more output will ever arrive.
    pub fn paneFinished(self: *Server, id: PaneId) bool {
        const h = self.panes.get(id) orelse return false;
        return h.exited and h.eof;
    }

    /// Resize a pane's PTY and terminal grid (an attached client's
    /// window changed). The new size joins the persisted spawn recipe.
    pub fn paneResize(self: *Server, id: PaneId, rows: u16, cols: u16) !void {
        const h = self.panes.get(id) orelse return error.NoSuchPane;
        try h.pane.resize(rows, cols);
        h.rows = rows;
        h.cols = cols;
    }

    /// Remove an exited-and-drained pane: destroy its handle and forget
    /// it (agent-task cleanup, closing dead panes). Refuses on a live
    /// child — its kernel completions may still be armed.
    pub fn removePane(self: *Server, id: PaneId) !void {
        const h = self.panes.get(id) orelse return error.NoSuchPane;
        if (!(h.exited and h.eof)) return error.PaneStillRunning;

        if (self.sessions.getPtr(h.session)) |sess| {
            for (sess.panes.items, 0..) |p, i| {
                if (p == id) {
                    _ = sess.panes.orderedRemove(i);
                    break;
                }
            }
        }
        _ = self.panes.remove(id);

        h.process.deinit();
        h.pane.destroy();
        freeArgv(self.alloc, h.argv);
        if (h.cwd) |c| self.alloc.free(c);
        self.alloc.destroy(h);
    }

    /// Run the event loop until no registered work remains (i.e. every
    /// spawned pane has exited and drained).
    pub fn run(self: *Server) !void {
        try self.loop.run(.until_done);
    }

    /// Single non-blocking pass — for embedding in a host UI loop.
    pub fn tick(self: *Server) !void {
        try self.loop.run(.no_wait);
    }
};

test "create and look up a session" {
    var server = try Server.init(std.testing.allocator);
    defer server.deinit();

    const id = try server.createSession("agent: fix flaky tests");
    const s = server.getSession(id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("agent: fix flaky tests", s.title);
    try std.testing.expectEqual(@as(usize, 1), server.count());
}

const TestCollector = struct {
    outputs: usize = 0,
    exits: [8]struct { pane: PaneId, code: ?u8 } = undefined,
    exit_count: usize = 0,

    fn on(ud: ?*anyopaque, server: *Server, event: Event) void {
        _ = server;
        const self: *TestCollector = @ptrCast(@alignCast(ud.?));
        switch (event) {
            .pane_output => self.outputs += 1,
            .pane_bell => {},
            .pane_exit => |e| {
                self.exits[self.exit_count] = .{ .pane = e.pane, .code = e.exit_code };
                self.exit_count += 1;
            },
        }
    }
};

test "panes run concurrently under the event loop and report exits" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc);
    defer server.deinit();

    var collector: TestCollector = .{};
    server.handler = .{ .userdata = &collector, .func = TestCollector.on };

    const sid = try server.createSession("test");
    const p1 = try server.spawnPane(sid, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'pane-one-done\\n'" },
    });
    const p2 = try server.spawnPane(sid, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'pane-two-done\\n'; exit 3" },
    });

    try server.run();

    try std.testing.expect(collector.outputs >= 2);
    try std.testing.expectEqual(@as(usize, 2), collector.exit_count);
    for (collector.exits[0..collector.exit_count]) |e| {
        const expected: ?u8 = if (e.pane == p1) 0 else 3;
        try std.testing.expectEqual(expected, e.code);
    }

    const snap1 = try server.paneSnapshot(p1, alloc);
    defer alloc.free(snap1);
    try std.testing.expect(std.mem.indexOf(u8, snap1, "pane-one-done") != null);

    const snap2 = try server.paneSnapshot(p2, alloc);
    defer alloc.free(snap2);
    try std.testing.expect(std.mem.indexOf(u8, snap2, "pane-two-done") != null);
}

test "writing input drives an interactive child" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc);
    defer server.deinit();

    const sid = try server.createSession("interactive");
    const pane = try server.spawnPane(sid, .{
        .argv = &.{ "/bin/sh", "-c", "read line; echo \"got: $line\"" },
    });

    try server.paneWrite(pane, "hello-interactive\n");
    try server.run();

    const snap = try server.paneSnapshot(pane, alloc);
    defer alloc.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "got: hello-interactive") != null);
}
