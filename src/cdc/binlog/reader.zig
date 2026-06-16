//! Binlog dump 读取器 — 封装 zfinal.DB 的 binlog API.
//! The caller owns the `zfinal.DB` instance and must keep it alive for the reader's lifetime.

const std = @import("std");
const zfinal = @import("zfinal");
const position_mod = @import("position.zig");

/// Raw binlog event. `buffer` is valid only until the next call to
/// `nextEvent()`, `close()`, or `deinit()` (which calls `close()`).
pub const RawEvent = struct {
    buffer: [*c]const u8,
    size: c_ulong,
};

pub const BinlogReader = struct {
    allocator: std.mem.Allocator,
    db: *zfinal.DB,
    current_file: ?[]const u8 = null,
    current_pos: u64 = 0,
    opened: bool = false,

    pub fn init(allocator: std.mem.Allocator, db: *zfinal.DB) BinlogReader {
        return .{ .allocator = allocator, .db = db };
    }

    pub fn deinit(self: *BinlogReader) void {
        self.close();
        if (self.current_file) |f| self.allocator.free(f);
        self.current_file = null;
    }

    pub fn open(self: *BinlogReader, file: []const u8, pos: u64) !void {
        self.close();
        const file_z = try self.allocator.dupeZ(u8, file);
        defer self.allocator.free(file_z);
        try self.db.binlogOpen(file_z, pos);
        errdefer self.db.binlogClose();
        const new_file = try self.allocator.dupe(u8, file);
        if (self.current_file) |f| self.allocator.free(f);
        self.current_file = new_file;
        self.current_pos = pos;
        self.opened = true;
    }

    pub fn close(self: *BinlogReader) void {
        if (self.opened) {
            self.db.binlogClose();
            self.opened = false;
        }
    }

    pub fn nextEvent(self: *BinlogReader) !?RawEvent {
        if (!self.opened) return error.NotOpened;
        const ev = try self.db.binlogFetch() orelse return null;
        self.current_pos += @intCast(ev.size);
        return RawEvent{ .buffer = ev.buffer, .size = ev.size };
    }

    /// Update current file/position when parser sees a ROTATE_EVENT.
    pub fn rotate(self: *BinlogReader, file: []const u8, pos: u64) !void {
        const new_file = try self.allocator.dupe(u8, file);
        if (self.current_file) |f| self.allocator.free(f);
        self.current_file = new_file;
        self.current_pos = pos;
    }

    /// Returns a heap-owned copy of the current position. Caller must deinit.
    pub fn currentPosition(self: *const BinlogReader) !position_mod.Position {
        return .{
            .file = if (self.current_file) |f| try self.allocator.dupe(u8, f) else null,
            .pos = self.current_pos,
        };
    }
};
