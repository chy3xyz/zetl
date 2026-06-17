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
        0x0a => decodeDate(allocator, body, pos),
        0x0d => decodeYear(allocator, body, pos),
        0xf6 => decodeDecimal(allocator, metadata, body, pos),
        0xfc, 0xfd, 0xf5 => decodeBlobLike(allocator, metadata, body, pos),
        0x07 => decodeTimestamp(allocator, body, pos),
        0x11 => decodeTimestamp2(allocator, metadata, body, pos),
        0x0b => decodeTime(allocator, body, pos),
        0x13 => decodeTime2(allocator, metadata, body, pos),
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

fn decodeDate(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 3) return error.BufferTooShort;
    const v: u32 = (@as(u32, body[pos.*]) << 16) |
        (@as(u32, body[pos.* + 1]) << 8) |
        @as(u32, body[pos.* + 2]);
    pos.* += 3;
    const year: u32 = v >> 9;
    const month: u32 = (v >> 5) & 0x0f;
    const day: u32 = v & 0x1f;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch return error.OutOfMemory;
}

fn decodeYear(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 1) return error.BufferTooShort;
    const v: u32 = body[pos.*];
    pos.* += 1;
    const year: u32 = 1900 + v;
    return std.fmt.allocPrint(allocator, "{d}", .{year}) catch return error.OutOfMemory;
}

// NEWDECIMAL (0xf6) — MySQL `decimal2bin` wire format.
//
// Each 9-digit "limb" is stored as a 4-byte big-endian unsigned integer.
// Layout (per MySQL `strings/decimal.cc::decimal2bin`):
//   * intg_size  = intg_limbs * 4 + dig2bytes[intg0_size]
//   * frac_size  = frac_limbs * 4 + dig2bytes[frac0_size]
//   * intg_limbs = intg_digits / 9,  intg0_size = intg_digits % 9
//   * frac_limbs = scale / 9,        frac0_size = scale % 9
//   * The compressed intg/frac limbs hold the leftover digit count as a
//     big-endian unsigned integer in 1..4 bytes (dig2bytes).
//   * Sign bit lives in byte 0 (positive → high bit set; negative → high bit
//     clear + each limb's bytes XORed with 0xFF before the high-bit twiddle).
//   * MySQL forces intg=1 even when precision == scale, so a "0." value still
//     consumes 1 intg byte (value 0 + sign bit).
const DIG_PER_DEC: usize = 9;
const DIG_TO_BYTES = [10]u8{ 0, 1, 1, 2, 2, 3, 3, 4, 4, 4 };

fn decodeDecimal(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 2) return error.InvalidValue;
    const precision: usize = metadata[0];
    const scale: usize = metadata[1];
    if (precision == 0 or scale > precision) return error.InvalidValue;
    const intg_digits = precision - scale;

    // MySQL always emits at least 1 intg byte (value 0 + sign bit), even when
    // the user-facing integer part is empty (precision == scale).
    const effective_intg_digits: usize = if (intg_digits == 0) 1 else intg_digits;
    const intg_limbs = effective_intg_digits / DIG_PER_DEC;
    const intg0_size: usize = effective_intg_digits - intg_limbs * DIG_PER_DEC;
    const intg_size: usize = intg_limbs * 4 + DIG_TO_BYTES[intg0_size];

    const frac_limbs = scale / DIG_PER_DEC;
    const frac0_size: usize = scale - frac_limbs * DIG_PER_DEC;
    const frac_size: usize = frac_limbs * 4 + DIG_TO_BYTES[frac0_size];

    const total_bytes = intg_size + frac_size;
    if (body.len < pos.* + total_bytes) return error.BufferTooShort;

    const is_negative = (body[pos.*] & 0x80) == 0;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    if (is_negative) try out.append(allocator, '-');

    var read_pos: usize = pos.*;

    // Integer part: optional compressed intg0 limb, then intg_limbs full limbs.
    // The compressed intg0 limb holds intg0_size digits as a 1..4-byte BE int.
    // For full limbs each holds 9 digits. The sign bit is in byte 0 of the
    // whole binary (which is the intg0 byte if intg0_size > 0, otherwise the
    // first full intg limb's byte 0).
    if (intg0_size > 0) {
        var limb: u32 = 0;
        const n_bytes: usize = DIG_TO_BYTES[intg0_size];
        var i: usize = 0;
        while (i < n_bytes) : (i += 1) {
            var b = body[read_pos + i];
            if (i == 0) b ^= 0x80; // strip sign bit
            if (is_negative) b ^= 0xff;
            limb = (limb << 8) | b;
        }
        try appendLimbDigits(&out, allocator, limb, intg0_size);
        read_pos += n_bytes;
    }
    var limb_idx: usize = 0;
    while (limb_idx < intg_limbs) : (limb_idx += 1) {
        var limb: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var b = body[read_pos + i];
            // Sign bit only lives in byte 0 of the whole binary representation.
            if (i == 0 and intg0_size == 0) b ^= 0x80;
            if (is_negative) b ^= 0xff;
            limb = (limb << 8) | b;
        }
        try appendLimbDigits(&out, allocator, limb, 9);
        read_pos += 4;
    }

    // Decimal point between integer and fractional parts.
    if (scale > 0) try out.append(allocator, '.');

    // Fractional part: optional compressed frac0 limb, then frac_limbs full limbs.
    // The sign bit never lives in frac bytes (it was already consumed above).
    if (frac0_size > 0) {
        var limb: u32 = 0;
        const n_bytes: usize = DIG_TO_BYTES[frac0_size];
        var i: usize = 0;
        while (i < n_bytes) : (i += 1) {
            var b = body[read_pos + i];
            if (is_negative) b ^= 0xff;
            limb = (limb << 8) | b;
        }
        try appendLimbDigits(&out, allocator, limb, frac0_size);
        read_pos += n_bytes;
    }
    limb_idx = 0;
    while (limb_idx < frac_limbs) : (limb_idx += 1) {
        var limb: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var b = body[read_pos + i];
            if (is_negative) b ^= 0xff;
            limb = (limb << 8) | b;
        }
        try appendLimbDigits(&out, allocator, limb, 9);
        read_pos += 4;
    }

    pos.* = read_pos;
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// BLOB (0xfc) / VAR_STRING used as TEXT (0xfd) / JSON (0xf5).
///
/// MySQL encodes these as a `pack_length`-byte little-endian length prefix
/// followed by that many raw bytes. `pack_length` lives in `metadata[0]`
/// and is 1/2/3/4 depending on the column's maximum size.
fn decodeBlobLike(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 1) return error.InvalidValue;
    const pack_length: usize = metadata[0];
    if (pack_length < 1 or pack_length > 4) return error.InvalidValue;
    if (body.len < pos.* + pack_length) return error.BufferTooShort;
    var len: usize = 0;
    var i: usize = 0;
    while (i < pack_length) : (i += 1) {
        len |= @as(usize, body[pos.* + i]) << @intCast(i * 8);
    }
    pos.* += pack_length;
    if (body.len < pos.* + len) return error.BufferTooShort;
    const value = allocator.dupe(u8, body[pos.*..][0..len]) catch return error.OutOfMemory;
    pos.* += len;
    return value;
}

/// Append `n_digits` decimal digits of `value` to `out`, zero-padded on the
/// left. Assumes `value < 10^n_digits` (caller's responsibility).
fn appendLimbDigits(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32, n_digits: usize) !void {
    var buf: [10]u8 = undefined; // u32 fits in 10 decimal digits
    var v = value;
    var n: usize = 0;
    if (v == 0) {
        buf[0] = 0;
        n = 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[n] = @intCast(v % 10);
            n += 1;
        }
    }
    // Pad with leading zeros so we always emit exactly n_digits characters.
    while (n < n_digits) : (n += 1) {
        buf[n] = 0;
    }
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        try out.append(allocator, '0' + buf[i - 1]);
    }
}

const SECONDS_PER_DAY: i64 = 86400;

// Howard Hinnant's date algorithm: days_from_civil / civil_from_days.
// Computes days since 1970-01-01 from a (year, month, day) triple.
// Reference: http://howardhinnant.github.io/date_algorithms.html
fn daysFromCivil(y: i64, m: u32, d: u32) i64 {
    const y_adj = if (m <= 2) y - 1 else y;
    const era: i64 = if (y_adj >= 0) @divFloor(y_adj, 400) else -@divFloor(-y_adj - 399, 400);
    const yoe: i64 = y_adj - era * 400;
    const m_adj: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * m_adj + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// Inverse of daysFromCivil: returns (year, month, day) for a given days-since-Unix-epoch.
fn civilFromDays(z: i64) struct { y: i64, m: u32, d: u32 } {
    const z_adj = z + 719468;
    const era: i64 = if (z_adj >= 0) @divFloor(z_adj, 146097) else -@divFloor(-z_adj - 146096, 146097);
    const doe: i64 = z_adj - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe + 1524, 1461), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year: i64 = if (m <= 2) y + 1 else y;
    return .{ .y = year, .m = m, .d = d };
}

fn decodeTime(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 3) return error.BufferTooShort;
    const raw: u32 = (@as(u32, body[pos.*]) << 16) |
        (@as(u32, body[pos.* + 1]) << 8) |
        @as(u32, body[pos.* + 2]);
    pos.* += 3;
    const is_negative = (raw & 0x800000) != 0;
    const abs: u32 = if (is_negative) ((~raw + 1) & 0x7fffff) else raw;
    const hour: u32 = (abs >> 12) & 0x3ff;
    const minute: u32 = (abs >> 6) & 0x3f;
    const second: u32 = abs & 0x3f;
    if (is_negative) {
        return std.fmt.allocPrint(allocator, "-{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
}

fn decodeTime2(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 1) return error.InvalidValue;
    const fsp: u8 = metadata[0];
    if (fsp > 6) return error.InvalidValue;
    const frac_bytes: usize = @intCast(@divFloor(fsp + 1, 2));
    if (body.len < pos.* + 3 + frac_bytes) return error.BufferTooShort;

    const raw: u32 = (@as(u32, body[pos.*]) << 16) |
        (@as(u32, body[pos.* + 1]) << 8) |
        @as(u32, body[pos.* + 2]);
    pos.* += 3;

    var frac_int: u64 = 0;
    var i: usize = 0;
    while (i < frac_bytes) : (i += 1) {
        frac_int = (frac_int << 8) | body[pos.* + i];
    }
    pos.* += frac_bytes;
    const shift: u6 = @intCast((3 - frac_bytes) * 8);
    const microseconds: u64 = frac_int << shift;

    const is_negative = (raw & 0x800000) != 0;
    const abs: u32 = if (is_negative) ((~raw + 1) & 0x7fffff) else raw;
    const hour: u32 = (abs >> 12) & 0x3ff;
    const minute: u32 = (abs >> 6) & 0x3f;
    const second: u32 = abs & 0x3f;

    if (fsp == 0) {
        if (is_negative) {
            return std.fmt.allocPrint(allocator, "-{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
        }
        return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
    }
    if (is_negative) {
        return std.fmt.allocPrint(allocator, "-{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hour, minute, second, microseconds }) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hour, minute, second, microseconds }) catch return error.OutOfMemory;
}

fn decodeTimestamp(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 4) return error.BufferTooShort;
    const v = std.mem.readInt(u32, body[pos.*..][0..4], .big);
    pos.* += 4;
    const secs: i64 = @intCast(v);
    return formatUnix(allocator, secs, 0);
}

fn decodeTimestamp2(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 1) return error.InvalidValue;
    const fsp: u8 = metadata[0];
    if (fsp > 6) return error.InvalidValue;
    const frac_bytes: usize = @intCast(@divFloor(fsp + 1, 2));
    if (body.len < pos.* + 5 + frac_bytes) return error.BufferTooShort;

    var packed_val: u64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        packed_val = (packed_val << 8) | body[pos.* + i];
    }
    pos.* += 5;

    const ymd: u64 = packed_val >> 17;
    const ym: u64 = ymd >> 5;
    const year: i64 = @intCast(ym / 13);
    const month: u32 = @intCast(ym % 13);
    const day: u32 = @intCast(ymd & 0x1f);
    const hms: u64 = packed_val & ((@as(u64, 1) << 17) - 1);
    const hour: u32 = @intCast(hms >> 12);
    const minute: u32 = @intCast((hms >> 6) & 0x3f);
    const second: u32 = @intCast(hms & 0x3f);

    var frac_int: u64 = 0;
    i = 0;
    while (i < frac_bytes) : (i += 1) {
        frac_int = (frac_int << 8) | body[pos.* + i];
    }
    pos.* += frac_bytes;
    const shift: u6 = @intCast((3 - frac_bytes) * 8);
    const microseconds: u64 = frac_int << shift;

    // Compute Unix epoch seconds from civil (y, m, d, h, m, s).
    const days = daysFromCivil(year, month, day);
    const secs: i64 = days * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second;
    // Year is non-negative for all MySQL TIMESTAMP2 values; cast to u64 to
    // avoid the leading '+' sign that {d} emits for positive signed integers.
    const year_u: u64 = @intCast(year);

    if (fsp == 0) {
        return formatUnix(allocator, secs, 0);
    }
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}",
        .{ year_u, month, day, hour, minute, second, microseconds },
    ) catch return error.OutOfMemory;
}

fn formatUnix(allocator: std.mem.Allocator, secs: i64, microseconds: u64) DecodeError![]const u8 {
    const days: i64 = @divFloor(secs, SECONDS_PER_DAY);
    const secs_of_day: i64 = @rem(secs, SECONDS_PER_DAY);
    const civil = civilFromDays(days);
    // Year is non-negative for any positive Unix epoch; cast to u64 to avoid
    // the leading '+' sign that {d} emits for positive signed integers.
    const year_u: u64 = @intCast(civil.y);
    const hh: u32 = @intCast(@divFloor(secs_of_day, 3600));
    const mm: u32 = @intCast(@divFloor(@rem(secs_of_day, 3600), 60));
    const ss: u32 = @intCast(@rem(secs_of_day, 60));
    if (microseconds == 0) {
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
            .{ year_u, civil.m, civil.d, hh, mm, ss },
        ) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}",
        .{ year_u, civil.m, civil.d, hh, mm, ss, microseconds },
    ) catch return error.OutOfMemory;
}

test "decodeColumn for TINY returns decimal" {
    var pos: usize = 0;
    const buf = [_]u8{42};
    const out = try decodeColumn(std.testing.allocator, 0x01, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "decodeColumn for TINY returns negative signed value" {
    var pos: usize = 0;
    const buf = [_]u8{0xff};
    const out = try decodeColumn(std.testing.allocator, 0x01, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("-1", out);
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

test "decodeColumn for NEWDECIMAL(3,2) decodes 1.00 from real wire bytes" {
    var pos: usize = 0;
    // MySQL wire bytes for DECIMAL(3,2) = 1.00: 0x81, 0x00
    //   intg0 limb: 1 digit, stored as uint8 = 0x01, sign bit set -> 0x81
    //   frac0 limb: 2 digits, stored as uint8 = 0x00
    const buf = [_]u8{ 0x81, 0x00 };
    const meta = [_]u8{ 3, 2 };
    const out = try decodeColumn(std.testing.allocator, 0xf6, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1.00", out);
    try std.testing.expectEqual(@as(usize, 2), pos);
}

test "decodeColumn for NEWDECIMAL(5,2) decodes 123.45 from real wire bytes" {
    var pos: usize = 0;
    // MySQL wire bytes for DECIMAL(5,2) = 123.45: 0x80, 0x7B, 0x2D
    //   intg0 limb: 3 digits, stored as uint16 BE = 0x007B, sign bit set -> 0x80 0x7B
    //   frac0 limb: 2 digits, stored as uint8 = 0x2D (=45)
    const buf = [_]u8{ 0x80, 0x7B, 0x2D };
    const meta = [_]u8{ 5, 2 };
    const out = try decodeColumn(std.testing.allocator, 0xf6, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("123.45", out);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "decodeColumn for BLOB with 1-byte length reads N bytes" {
    var pos: usize = 0;
    const buf = [_]u8{ 5, 'h', 'e', 'l', 'l', 'o' };
    const meta = [_]u8{1}; // pack_length=1
    const out = try decodeColumn(std.testing.allocator, 0xfc, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
    try std.testing.expectEqual(@as(usize, 6), pos);
}

test "decodeColumn for TEXT with 2-byte length reads N bytes" {
    var pos: usize = 0;
    const buf = [_]u8{ 5, 0, 'w', 'o', 'r', 'l', 'd' };
    const meta = [_]u8{2}; // pack_length=2
    const out = try decodeColumn(std.testing.allocator, 0xfd, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("world", out);
    try std.testing.expectEqual(@as(usize, 7), pos);
}

test "decodeColumn for JSON with 4-byte length reads N bytes" {
    var pos: usize = 0;
    const buf = [_]u8{ 1, 0, 0, 0, '{' };
    const meta = [_]u8{4}; // pack_length=4
    const out = try decodeColumn(std.testing.allocator, 0xf5, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{", out);
    try std.testing.expectEqual(@as(usize, 5), pos);
}

test "decodeColumn for DATE reads 3-byte packed date" {
    var pos: usize = 0;
    // 2026-06-15 in MySQL DATE wire format:
    // val = (year << 9) | (month << 5) | day
    const val: u32 = (2026 << 9) | (6 << 5) | 15;
    var buf: [3]u8 = undefined;
    buf[0] = @intCast((val >> 16) & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast(val & 0xff);
    const out = try decodeColumn(std.testing.allocator, 0x0a, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15", out);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "decodeColumn for YEAR reads 1-byte year" {
    var pos: usize = 0;
    const buf = [_]u8{122}; // 122 + 1900 = 2022
    const out = try decodeColumn(std.testing.allocator, 0x0d, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2022", out);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "decodeColumn for TIMESTAMP reads 4-byte Unix epoch" {
    var pos: usize = 0;
    // 2026-06-15 12:34:56 UTC -> 1781526896
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 1781526896, .big);
    const out = try decodeColumn(std.testing.allocator, 0x07, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56", out);
    try std.testing.expectEqual(@as(usize, 4), pos);
}

test "decodeColumn for TIMESTAMP2(6) reads 5-byte packed datetime with microseconds" {
    var pos: usize = 0;
    // 2026-06-15 12:34:56.123456 in MySQL TIMESTAMP2 wire format:
    // packed = (year*13+month) << 17 | (day << 12) | (hour << 12) | (minute << 6) | second
    const ymd: u64 = (2026 * 13 + 6) * 32 + 15;
    const hms: u64 = (12 << 12) | (34 << 6) | 56;
    const packed_val: u64 = ymd << 17 | hms;
    var buf: [8]u8 = undefined;
    buf[0] = @intCast((packed_val >> 32) & 0xff);
    buf[1] = @intCast((packed_val >> 24) & 0xff);
    buf[2] = @intCast((packed_val >> 16) & 0xff);
    buf[3] = @intCast((packed_val >> 8) & 0xff);
    buf[4] = @intCast(packed_val & 0xff);
    buf[5] = 0x01;
    buf[6] = 0xe2;
    buf[7] = 0x40;
    const meta = [_]u8{6};
    const out = try decodeColumn(std.testing.allocator, 0x11, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56.123456", out);
    try std.testing.expectEqual(@as(usize, 8), pos);
}

test "decodeColumn for TIME reads 3-byte packed duration" {
    var pos: usize = 0;
    // 12:34:56 -> 0x12 bf f0
    // packed = (hour << 12) | (minute << 6) | second
    const val: u32 = (12 << 12) | (34 << 6) | 56;
    var buf: [3]u8 = undefined;
    buf[0] = @intCast((val >> 16) & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast(val & 0xff);
    const out = try decodeColumn(std.testing.allocator, 0x0b, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("12:34:56", out);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "decodeColumn for TIME2(6) reads 3+3-byte packed duration with microseconds" {
    var pos: usize = 0;
    // 12:34:56.123456
    const val: u32 = (12 << 12) | (34 << 6) | 56;
    var buf: [6]u8 = undefined;
    buf[0] = @intCast((val >> 16) & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast(val & 0xff);
    buf[3] = 0x01;
    buf[4] = 0xe2;
    buf[5] = 0x40;
    const meta = [_]u8{6};
    const out = try decodeColumn(std.testing.allocator, 0x13, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("12:34:56.123456", out);
    try std.testing.expectEqual(@as(usize, 6), pos);
}
