const std = @import("std");

pub const DecodeError = error{
    BufferTooShort,
    InvalidValue,
    UnsupportedType,
    OutOfMemory,
};

/// 返回指定 MySQL 类型在 column_metadata 中占用的字节数.
/// 未识别的类型返回 0, 调用方按字节数跳过对应 metadata.
pub fn metadataLengthForType(col_type: u8) usize {
    return switch (col_type) {
        // 整数 / DATE / TIME / YEAR / OLD DECIMAL / ENUM / SET: 无 metadata
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0xf7, 0xf8 => 0,
        // TIMESTAMP2 / DATETIME2 / TIME2: 1 字节 (fsp)
        0x11, 0x12, 0x13 => 1,
        // NEWDECIMAL: 2 字节 (precision + scale)
        0xf6 => 2,
        // VARCHAR / VAR_STRING / STRING / BIT: 2 字节 (max_length / bit_length)
        0x0f, 0x10, 0xfd, 0xfe => 2,
        // BLOB 变种 / JSON: 1 字节 (pack_length)
        0xf5, 0xf9, 0xfa, 0xfb, 0xfc => 1,
        // 其他: 0 字节
        else => 0,
    };
}

test "metadataLengthForType returns correct sizes" {
    try std.testing.expectEqual(@as(usize, 0), metadataLengthForType(0x0c)); // DATETIME
    try std.testing.expectEqual(@as(usize, 1), metadataLengthForType(0x11)); // TIMESTAMP2
    try std.testing.expectEqual(@as(usize, 1), metadataLengthForType(0x12)); // DATETIME2
    try std.testing.expectEqual(@as(usize, 1), metadataLengthForType(0x13)); // TIME2
    try std.testing.expectEqual(@as(usize, 2), metadataLengthForType(0xf6)); // NEWDECIMAL
    try std.testing.expectEqual(@as(usize, 2), metadataLengthForType(0x0f)); // VARCHAR
    try std.testing.expectEqual(@as(usize, 1), metadataLengthForType(0xfc)); // BLOB
    try std.testing.expectEqual(@as(usize, 2), metadataLengthForType(0xfd)); // VAR_STRING
    try std.testing.expectEqual(@as(usize, 1), metadataLengthForType(0xf5)); // JSON (MySQL 8)
    try std.testing.expectEqual(@as(usize, 0), metadataLengthForType(0xff)); // unknown
}

pub fn decodeColumn(
    allocator: std.mem.Allocator,
    col_type: u8,
    metadata: []const u8,
    body: []const u8,
    pos: *usize,
) DecodeError![]const u8 {
    return switch (col_type) {
        0x01 => decodeInt(allocator, 1, body, pos),
        0x02 => decodeInt(allocator, 2, body, pos),
        0x09 => decodeInt(allocator, 3, body, pos),
        0x03 => decodeInt(allocator, 4, body, pos),
        0x08 => decodeInt(allocator, 8, body, pos),
        0x0f => decodeVarchar(allocator, metadata, body, pos),
        else => return error.UnsupportedType,
    };
}

fn decodeInt(allocator: std.mem.Allocator, n: u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + n) return error.BufferTooShort;
    const v: i64 = switch (n) {
        1 => @as(i64, @as(i8, @bitCast(body[pos.*]))),
        2 => std.mem.readInt(i16, body[pos.*..][0..2], .little),
        3 => blk: {
            // Sign-extend a 24-bit value to i64.
            const raw = std.mem.readInt(u24, body[pos.*..][0..3], .little);
            const signed: i24 = @bitCast(raw);
            break :blk @as(i64, signed);
        },
        4 => std.mem.readInt(i32, body[pos.*..][0..4], .little),
        8 => std.mem.readInt(i64, body[pos.*..][0..8], .little),
        else => unreachable,
    };
    pos.* += n;
    return std.fmt.allocPrint(allocator, "{d}", .{v}) catch return error.OutOfMemory;
}

fn decodeVarchar(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 2) return error.InvalidValue;
    const max_length = @as(usize, metadata[0]) | (@as(usize, metadata[1]) << 8);
    if (max_length <= 255) {
        if (body.len < pos.* + 1) return error.BufferTooShort;
        const str_len: usize = body[pos.*];
        pos.* += 1;
        if (body.len < pos.* + str_len) return error.BufferTooShort;
        const value = allocator.dupe(u8, body[pos.*..][0..str_len]) catch return error.OutOfMemory;
        pos.* += str_len;
        return value;
    } else {
        if (body.len < pos.* + 2) return error.BufferTooShort;
        const str_len = @as(usize, body[pos.*]) | (@as(usize, body[pos.* + 1]) << 8);
        pos.* += 2;
        if (body.len < pos.* + str_len) return error.BufferTooShort;
        const value = allocator.dupe(u8, body[pos.*..][0..str_len]) catch return error.OutOfMemory;
        pos.* += str_len;
        return value;
    }
}

test "decodeColumn for TINY returns decimal" {
    var pos: usize = 0;
    const buf = [_]u8{42};
    const out = try decodeColumn(std.testing.allocator, 0x01, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "decodeColumn for SHORT returns decimal" {
    var pos: usize = 0;
    const buf = [_]u8{ 0xff, 0x00 }; // 255
    const out = try decodeColumn(std.testing.allocator, 0x02, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("255", out);
}

test "decodeColumn for VARCHAR(<=255) reads 1-byte length" {
    var pos: usize = 0;
    const buf = [_]u8{ 3, 'a', 'b', 'c' };
    const meta = [_]u8{ 0, 0 }; // max_length=0
    const out = try decodeColumn(std.testing.allocator, 0x0f, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "decodeColumn for VARCHAR(>255) reads 2-byte length" {
    var pos: usize = 0;
    // "hello" len=5
    const buf = [_]u8{ 5, 0, 'h', 'e', 'l', 'l', 'o' };
    const meta = [_]u8{ 0x00, 0x01 }; // max_length=256 -> >255
    const out = try decodeColumn(std.testing.allocator, 0x0f, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "decodeColumn for INT24 returns signed decimal" {
    var pos: usize = 0;
    // INT24 value -1 -> 0xFFFFFF (little-endian)
    const buf = [_]u8{ 0xff, 0xff, 0xff };
    const out = try decodeColumn(std.testing.allocator, 0x09, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("-1", out);
}

test "decodeColumn for LONGLONG returns large signed value" {
    var pos: usize = 0;
    // 2^40 - 1 = 1099511627775
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, 1099511627775, .little);
    const out = try decodeColumn(std.testing.allocator, 0x08, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1099511627775", out);
}
