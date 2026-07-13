//! Session server: owns sessions and their panes.
//!
//! Designed as a server from day one (state behind an API, no UI types)
//! even though it initially runs in-process inside the app. This is the
//! seam that later becomes the daemon boundary and the automation socket.

const std = @import("std");

pub const SessionId = u64;

pub const Session = struct {
    id: SessionId,
    /// Display title, owned by the server's allocator.
    title: []const u8,
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    sessions: std.AutoHashMapUnmanaged(SessionId, Session),
    next_id: SessionId,

    pub fn init(alloc: std.mem.Allocator) Server {
        return .{
            .alloc = alloc,
            .sessions = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |s| self.alloc.free(s.title);
        self.sessions.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn createSession(self: *Server, title: []const u8) !SessionId {
        const id = self.next_id;
        const owned = try self.alloc.dupe(u8, title);
        errdefer self.alloc.free(owned);
        try self.sessions.put(self.alloc, id, .{ .id = id, .title = owned });
        self.next_id += 1;
        return id;
    }

    pub fn getSession(self: *Server, id: SessionId) ?Session {
        return self.sessions.get(id);
    }

    pub fn count(self: *Server) usize {
        return self.sessions.count();
    }
};

test "create and look up a session" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();

    const id = try server.createSession("agent: fix flaky tests");
    const s = server.getSession(id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("agent: fix flaky tests", s.title);
    try std.testing.expectEqual(@as(usize, 1), server.count());
}
