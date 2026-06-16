const std = @import("std");

pub const DecodeError = error{
    BufferTooShort,
    InvalidValue,
    UnsupportedType,
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
