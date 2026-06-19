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
/// 简化映射: 命中常用类型, 未命中回落 TEXT.
fn mySqlTypeName(col_type: u8) []const u8 {
    return switch (col_type) {
        0x01 => "TINYINT",
        0x02 => "SMALLINT",
        0x03 => "INT",
        0x09 => "MEDIUMINT",
        0x08 => "BIGINT",
        0x04 => "FLOAT",
        0x05 => "DOUBLE",
        0x00 => "DECIMAL",
        0xf6 => "DECIMAL(18,4)",
        0x0a => "DATE",
        0x0b => "TIME",
        0x0c => "DATETIME",
        0x12 => "DATETIME(6)",
        0x07 => "TIMESTAMP",
        0x11 => "TIMESTAMP(6)",
        0x0d => "YEAR",
        0x0f => "VARCHAR(255)",
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
        const type_name = mySqlTypeName(col.type);
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
