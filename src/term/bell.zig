//! BEL-based attention detection on raw terminal output.
//!
//! A naive scan for 0x07 would false-positive constantly: BEL is also
//! the conventional terminator for OSC sequences (window-title updates,
//! clipboard writes, ...). This scanner tracks just enough VT state to
//! tell them apart: inside an ESC-initiated string sequence
//! (OSC/DCS/APC/PM/SOS) a BEL terminates the string; outside, it is an
//! attention signal.

const std = @import("std");

pub const BellScanner = struct {
    state: enum { ground, esc, string, string_esc } = .ground,

    /// Count attention bells in a chunk. Chunk boundaries may fall
    /// anywhere, including mid-sequence; state carries across calls.
    pub fn scan(self: *BellScanner, bytes: []const u8) usize {
        var bells: usize = 0;
        for (bytes) |byte| switch (self.state) {
            .ground => switch (byte) {
                0x07 => bells += 1,
                0x1b => self.state = .esc,
                else => {},
            },
            .esc => switch (byte) {
                // OSC, DCS, APC, PM, SOS respectively.
                ']', 'P', '_', '^', 'X' => self.state = .string,
                0x1b => {},
                else => self.state = .ground,
            },
            .string => switch (byte) {
                0x07 => self.state = .ground, // string terminator, not attention
                0x1b => self.state = .string_esc,
                else => {},
            },
            .string_esc => switch (byte) {
                '\\' => self.state = .ground, // ST
                0x1b => {},
                else => self.state = .string,
            },
        };
        return bells;
    }
};

test "bare bell is attention" {
    var s: BellScanner = .{};
    try std.testing.expectEqual(@as(usize, 1), s.scan("before\x07after"));
}

test "OSC terminators are not attention" {
    var s: BellScanner = .{};
    // Title update terminated by BEL, then one terminated by ST.
    try std.testing.expectEqual(@as(usize, 0), s.scan("\x1b]0;my title\x07"));
    try std.testing.expectEqual(@as(usize, 0), s.scan("\x1b]0;other\x1b\\"));
    // Ground state must be restored: a real bell still counts.
    try std.testing.expectEqual(@as(usize, 1), s.scan("\x07"));
}

test "state carries across chunk boundaries" {
    var s: BellScanner = .{};
    try std.testing.expectEqual(@as(usize, 0), s.scan("\x1b]0;spl"));
    try std.testing.expectEqual(@as(usize, 0), s.scan("it title\x07"));
    try std.testing.expectEqual(@as(usize, 1), s.scan("ding\x07"));
}

test "DCS payload bells are not attention" {
    var s: BellScanner = .{};
    try std.testing.expectEqual(@as(usize, 0), s.scan("\x1bPpayload\x07with bel\x1b\\"));
}
