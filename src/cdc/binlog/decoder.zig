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
        0x0c => decodeDatetime(allocator, body, pos),
        0x12 => decodeDatetime2(allocator, metadata, body, pos),
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

fn decodeDatetime(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 8) return error.BufferTooShort;
    const v = std.mem.readInt(u64, body[pos.*..][0..8], .little);
    pos.* += 8;
    const date_int: u64 = v >> 32;
    const time_int: u64 = v & 0xffffffff;
    const year: u64 = @divFloor(date_int, 16 * 32);
    const rem1: u64 = date_int % (16 * 32);
    const month: u64 = @divFloor(rem1, 32);
    const day: u64 = rem1 % 32;
    const hour: u64 = @divFloor(time_int, 64 * 64);
    const rem2: u64 = time_int % (64 * 64);
    const minute: u64 = @divFloor(rem2, 64);
    const second: u64 = rem2 % 64;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ year, month, day, hour, minute, second }) catch return error.OutOfMemory;
}

fn decodeDatetime2(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 1) return error.InvalidValue;
    const fsp: u8 = metadata[0];
    if (fsp > 6) return error.InvalidValue;

    const int_bytes: usize = 5;
    const frac_bytes: usize = @intCast(@divFloor(fsp + 1, 2));
    if (body.len < pos.* + int_bytes + frac_bytes) return error.BufferTooShort;

    // Read 5-byte big-endian packed datetime via readInt.
    // Zig has no u40 builtin; shift manually.
    var packed_int: u64 = 0;
    var i: usize = 0;
    while (i < int_bytes) : (i += 1) {
        packed_int = (packed_int << 8) | body[pos.* + i];
    }
    pos.* += int_bytes;

    // ymd = (year * 13 + month) * 32 + day, occupies high 22 bits
    const ymd: u64 = packed_int >> 17;
    const ym: u64 = ymd >> 5;
    const year: u64 = ym / 13;
    const month: u64 = ym % 13;
    const day: u64 = ymd & 0x1F;

    // hms occupies low 17 bits
    const hms: u64 = packed_int & ((@as(u64, 1) << 17) - 1);
    const hour: u64 = hms >> 12;
    const minute: u64 = (hms >> 6) & 0x3F;
    const second: u64 = hms & 0x3F;

    // frac part is big-endian
    var frac_int: u64 = 0;
    i = 0;
    while (i < frac_bytes) : (i += 1) {
        frac_int = (frac_int << 8) | body[pos.* + i];
    }
    pos.* += frac_bytes;

    if (fsp == 0) {
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ year, month, day, hour, minute, second }) catch return error.OutOfMemory;
    }

    // fsp 1..5: MySQL stores fractional value already pre-scaled to a 3-byte field,
    // but the scaling depends on fsp. For fsp=6 (3 bytes), the value IS microseconds.
    // For fsp<6, we left-shift the stored value by (3 - frac_bytes) * 8 bits and pad zeros.
    const shift: u6 = @intCast((3 - frac_bytes) * 8);
    const microseconds: u64 = frac_int << shift;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ year, month, day, hour, minute, second, microseconds }) catch return error.OutOfMemory;
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

test "decodeColumn for DATETIME reads 8-byte packed date" {
    var pos: usize = 0;
    // 2026-06-15 12:34:56 in MySQL DATETIME wire format:
    // date_int = day + month*32 + year*16*32
    // time_int = sec + min*64 + hour*64*64
    var buf: [8]u8 = undefined;
    const date_int: u64 = 15 + 6 * 32 + 2026 * 16 * 32;
    const time_int: u64 = 56 + 34 * 64 + 12 * 64 * 64;
    std.mem.writeInt(u64, &buf, date_int << 32 | time_int, .little);
    const out = try decodeColumn(std.testing.allocator, 0x0c, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56", out);
}

test "decodeColumn for DATETIME2(6) reads 5+3-byte packed date" {
    var pos: usize = 0;
    // 2026-06-15 12:34:56.123456 packed per real MySQL formula:
    // packed_int = (year*13 + month)*2^17 | (day << 17) | (hour << 12) | (min << 6) | sec
    const ymd: u64 = (2026 * 13 + 6) * 32 + 15;
    const hms: u64 = (12 << 12) | (34 << 6) | 56;
    const packed_int: u64 = ymd << 17 | hms;
    var buf: [8]u8 = undefined;
    // 5 bytes big-endian
    buf[0] = @intCast((packed_int >> 32) & 0xff);
    buf[1] = @intCast((packed_int >> 24) & 0xff);
    buf[2] = @intCast((packed_int >> 16) & 0xff);
    buf[3] = @intCast((packed_int >> 8) & 0xff);
    buf[4] = @intCast(packed_int & 0xff);
    // 3 bytes big-endian microseconds = 123456 (0x01E240)
    buf[5] = 0x01;
    buf[6] = 0xe2;
    buf[7] = 0x40;
    const meta = [_]u8{6};
    const out = try decodeColumn(std.testing.allocator, 0x12, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56.123456", out);
}

test "decodeColumn for DATETIME2(0) emits no fraction" {
    var pos: usize = 0;
    const ymd: u64 = (2026 * 13 + 6) * 32 + 15;
    const hms: u64 = (12 << 12) | (34 << 6) | 56;
    const packed_int: u64 = ymd << 17 | hms;
    var buf: [5]u8 = undefined;
    buf[0] = @intCast((packed_int >> 32) & 0xff);
    buf[1] = @intCast((packed_int >> 24) & 0xff);
    buf[2] = @intCast((packed_int >> 16) & 0xff);
    buf[3] = @intCast((packed_int >> 8) & 0xff);
    buf[4] = @intCast(packed_int & 0xff);
    const meta = [_]u8{0};
    const out = try decodeColumn(std.testing.allocator, 0x12, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56", out);
}
