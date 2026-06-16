//! 轻量 binlog 事件解析器
//! 阶段 1: 解析事件头 + ROTATE_EVENT (位点更新) + HEARTBEAT_EVENT.
//! 阶段 2 (Task 9): 解析 TABLE_MAP / WRITE_ROWS / UPDATE_ROWS / DELETE_ROWS.

const std = @import("std");
const event_mod = @import("../event.zig");
const position_mod = @import("position.zig");

pub const EventType = enum(u8) {
    rotate = 0x04,
    heartbeat = 0x1b,
    table_map = 0x13,
    write_rows_v2 = 0x1e,
    update_rows_v2 = 0x1f,
    delete_rows_v2 = 0x20,
    xid = 0x10,
    _,
};

pub const EventHeader = struct {
    timestamp: u32,
    type_code: u8,
    server_id: u32,
    event_size: u32,
    log_pos: u32,
    flags: u16,
};

pub const ParsedEvent = union(enum) {
    rotate: position_mod.Position,
    heartbeat,
    unknown: EventHeader,
    row: event_mod.RowEvent,
};

pub const ParseError = error{ BufferTooShort, InvalidEvent, OutOfMemory };

pub fn parseHeader(buffer: []const u8) ParseError!EventHeader {
    if (buffer.len < 19) return error.BufferTooShort;
    return .{
        .timestamp = std.mem.readInt(u32, buffer[0..4], .little),
        .type_code = buffer[4],
        .server_id = std.mem.readInt(u32, buffer[5..9], .little),
        .event_size = std.mem.readInt(u32, buffer[9..13], .little),
        .log_pos = std.mem.readInt(u32, buffer[13..17], .little),
        .flags = std.mem.readInt(u16, buffer[17..19], .little),
    };
}

pub fn parseEvent(allocator: std.mem.Allocator, buffer: []const u8) ParseError!ParsedEvent {
    const header = try parseHeader(buffer);
    const event_type: EventType = @enumFromInt(header.type_code);
    const body = buffer[19..];

    switch (event_type) {
        .rotate => {
            if (body.len < 8) return error.BufferTooShort;
            const pos = std.mem.readInt(u64, body[0..8], .little);
            const name_len: usize = @intCast(header.event_size - 19 - 8);
            if (body.len < 8 + name_len) return error.BufferTooShort;
            const name = body[8..][0..name_len];
            return ParsedEvent{ .rotate = .{
                .file = try allocator.dupe(u8, name),
                .pos = pos,
            } };
        },
        .heartbeat => return ParsedEvent.heartbeat,
        else => return ParsedEvent{ .unknown = header },
    }
}

test "parse ROTATE_EVENT" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0, .little); // timestamp
    buf[4] = 0x04; // ROTATE_EVENT
    std.mem.writeInt(u32, buf[5..9], 1, .little); // server_id
    // event_size = 19 (header) + 8 (pos) + 10 (name "bin.000001") = 37
    std.mem.writeInt(u32, buf[9..13], 37, .little);
    std.mem.writeInt(u32, buf[13..17], 0, .little); // log_pos
    std.mem.writeInt(u16, buf[17..19], 0, .little); // flags
    std.mem.writeInt(u64, buf[19..27], 12345, .little); // position
    @memcpy(buf[27..][0..10], "bin.000001");

    var ev = try parseEvent(a, &buf);
    defer switch (ev) {
        .rotate => |*pos| pos.deinit(a),
        else => {},
    };
    try std.testing.expect(ev == .rotate);
    try std.testing.expectEqualStrings("bin.000001", ev.rotate.file orelse "");
    try std.testing.expectEqual(@as(u64, 12345), ev.rotate.pos);
}
