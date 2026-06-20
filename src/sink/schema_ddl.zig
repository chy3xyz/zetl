//! DDL 生成 - 从 ColumnMeta 自动生成 CREATE TABLE 语句
//! 见 docs/superpowers/plans/2026-06-15-zetl-phase7-sink-automation.md (Task 1)
//!
//! 用于 V2 sink 自动化: 当归集表不存在时, 用 source schema 推断列并创建目标表.

const std = @import("std");
const mapper = @import("../transform/mapper.zig");

pub const DdlOptions = struct {
    database: []const u8 = "",
    engine: []const u8 = "InnoDB",
    charset: []const u8 = "utf8mb4",
};

/// MySQL 类型常量 → 字符串. type 来自 mapper.ColumnMeta.type (MySQL 协议类型字节).
/// `length` 用于 VARCHAR(N) / CHAR(N); `precision`+`scale` 用于 DECIMAL(P,S).
/// 不提供时用默认值: VARCHAR(255), CHAR(1), DECIMAL(18,4).
/// 返回的 slice 来自 `type_buf` (栈 buffer, 32 bytes), caller 必须立刻用, 不要长期持有.
fn mySqlTypeName(
    col_type: u8,
    length: ?u16,
    precision: ?u8,
    scale: ?u8,
    type_buf: []u8,
) []const u8 {
    // 动态长度类型优先用 bufPrint 写入 type_buf
    if (col_type == 0xf6 or col_type == 0x00) {
        return std.fmt.bufPrint(type_buf, "DECIMAL({d},{d})", .{ precision orelse 18, scale orelse 4 }) catch unreachable;
    }
    if (col_type == 0x0f) {
        return std.fmt.bufPrint(type_buf, "VARCHAR({d})", .{length orelse 255}) catch unreachable;
    }
    if (col_type == 0xfe) {
        return std.fmt.bufPrint(type_buf, "CHAR({d})", .{length orelse 1}) catch unreachable;
    }
    return switch (col_type) {
        0x01 => "TINYINT",
        0x02 => "SMALLINT",
        0x03 => "INT",
        0x09 => "MEDIUMINT",
        0x08 => "BIGINT",
        0x04 => "FLOAT",
        0x05 => "DOUBLE",
        0x0a => "DATE",
        0x0b => "TIME",
        0x0c => "DATETIME",
        0x12 => "DATETIME(6)",
        0x07 => "TIMESTAMP",
        0x11 => "TIMESTAMP(6)",
        0x0d => "YEAR",
        0xfc => "BLOB",
        0xfd => "TEXT",
        0xf5 => "JSON",
        else => "TEXT",
    };
}

/// 用反引号包裹标识符 (V1 简化: 不处理嵌入反引号, 由调用方保证 name 合法).
fn quoteIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "`{s}`", .{name});
}

/// 生成 CREATE TABLE IF NOT EXISTS DDL.
/// - target_table: 目标表名
/// - columns: 列元数据 (列名 + MySQL 类型字节)
/// - options: 可选 database 前缀, engine, charset
/// - 返回的 DDL 字符串由 caller 负责 free.
pub fn buildCreateTable(
    allocator: std.mem.Allocator,
    target_table: []const u8,
    columns: []const mapper.ColumnMeta,
    options: DdlOptions,
) ![]u8 {
    var col_parts = std.ArrayList([]const u8).empty;
    defer {
        for (col_parts.items) |c| allocator.free(c);
        col_parts.deinit(allocator);
    }
    for (columns) |col| {
        const quoted = try quoteIdentifier(allocator, col.name);
        var type_buf: [32]u8 = undefined;
        const type_name = mySqlTypeName(col.type, col.length, col.precision, col.scale, &type_buf);
        const part = try std.fmt.allocPrint(allocator, "    {s} {s}", .{ quoted, type_name });
        allocator.free(quoted);
        try col_parts.append(allocator, part);
    }

    var cols_buf = std.ArrayList(u8).empty;
    defer cols_buf.deinit(allocator);
    for (col_parts.items, 0..) |part, i| {
        if (i > 0) try cols_buf.append(allocator, ',');
        try cols_buf.appendSlice(allocator, part);
    }

    const target = if (options.database.len > 0)
        try std.fmt.allocPrint(allocator, "`{s}`.`{s}`", .{ options.database, target_table })
    else
        try std.fmt.allocPrint(allocator, "`{s}`", .{target_table});
    defer allocator.free(target);

    return std.fmt.allocPrint(
        allocator,
        "CREATE TABLE IF NOT EXISTS {s} (\n{s}\n) ENGINE={s} DEFAULT CHARSET={s};",
        .{ target, cols_buf.items, options.engine, options.charset },
    );
}

test "buildCreateTable formats basic identity table" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "id", .type = 0x03 },
        .{ .name = "name", .type = 0x0f },
    };
    const ddl = try buildCreateTable(a, "orders", &cols, .{});
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "CREATE TABLE IF NOT EXISTS `orders`") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`id` INT") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`name` VARCHAR(255)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "ENGINE=InnoDB") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "DEFAULT CHARSET=utf8mb4") != null);
}

test "buildCreateTable includes database prefix when provided" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{.{ .name = "id", .type = 0x03 }};
    const ddl = try buildCreateTable(a, "orders", &cols, .{ .database = "analytics" });
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`analytics`.`orders`") != null);
}

test "buildCreateTable uses VARCHAR(N) from ColumnMeta.length" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "id", .type = 0x08 },
        .{ .name = "order_no", .type = 0x0f, .length = 32 },
    };
    const ddl = try buildCreateTable(a, "orders", &cols, .{});
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`order_no` VARCHAR(32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "VARCHAR(255)") == null);
}

test "buildCreateTable uses DECIMAL(P,S) from ColumnMeta" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "amount", .type = 0xf6, .precision = 10, .scale = 2 },
    };
    const ddl = try buildCreateTable(a, "orders", &cols, .{});
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`amount` DECIMAL(10,2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "DECIMAL(18,4)") == null);
}
