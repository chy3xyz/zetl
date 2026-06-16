//! Binlog 位点 (file + position)

const std = @import("std");

pub const Position = struct {
    file: ?[]const u8 = null,
    pos: u64 = 0,

    pub const ParseError = error{InvalidPosition};

    pub fn parse(allocator: std.mem.Allocator, s: []const u8) (ParseError || error{OutOfMemory})!Position {
        const colon = std.mem.indexOfScalar(u8, s, ':');
        if (colon == null or colon.? == 0 or colon.? == s.len - 1) return error.InvalidPosition;
        const file = s[0..colon.?];
        const pos_s = s[colon.? + 1 ..];
        const pos = std.fmt.parseInt(u64, pos_s, 10) catch return error.InvalidPosition;
        return .{ .file = try allocator.dupe(u8, file), .pos = pos };
    }

    pub fn eql(self: Position, other: Position) bool {
        if (self.pos != other.pos) return false;
        const sf = self.file orelse return other.file == null;
        const of = other.file orelse return false;
        return std.mem.eql(u8, sf, of);
    }

    pub fn deinit(self: *Position, allocator: std.mem.Allocator) void {
        if (self.file) |f| allocator.free(f);
        self.* = undefined;
    }

    pub fn dupe(self: *const Position, allocator: std.mem.Allocator) !Position {
        return .{
            .file = if (self.file) |f| try allocator.dupe(u8, f) else null,
            .pos = self.pos,
        };
    }

    /// Use `{f}` format specifier (Zig 0.17 custom-format convention).
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const f = self.file orelse "";
        try writer.print("{s}:{d}", .{ f, self.pos });
    }
};

test "Position dupe and deinit" {
    const a = std.testing.allocator;
    var orig = try Position.parse(a, "mysql-bin.000001:1234");
    defer orig.deinit(a);
    var copy = try orig.dupe(a);
    defer copy.deinit(a);
    try std.testing.expect(orig.eql(copy));
}

test "Position format and parse roundtrip" {
    const a = std.testing.allocator;
    var orig = try Position.parse(a, "mysql-bin.000001:1234");
    defer orig.deinit(a);
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{orig});
    var parsed = try Position.parse(a, s);
    defer parsed.deinit(a);
    try std.testing.expect(orig.eql(parsed));
}

test "Position parse invalid" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidPosition, Position.parse(a, ""));
    try std.testing.expectError(error.InvalidPosition, Position.parse(a, "nofile"));
    try std.testing.expectError(error.InvalidPosition, Position.parse(a, "file:notanumber"));
}

test "Position eql handles null file and pos" {
    const a = Position{ .file = null, .pos = 0 };
    const b = Position{ .file = null, .pos = 100 };
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(a.eql(a));
}

