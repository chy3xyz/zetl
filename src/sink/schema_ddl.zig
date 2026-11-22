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
    /// 源表主键列名 (默认 "id" 由 caller 传入). 非空且存在于 columns 时,
    /// 自动建表追加 UNIQUE KEY (mall_id, pk) — 没有唯一键时 sink 的
    /// INSERT ... ON DUPLICATE KEY UPDATE 无法去重, 源行 UPDATE 后
    /// re-sync 会重复插入 (2026-11-21 E2E 发现). pk 不在源列中则跳过, 幂等降级.
    pk_column: []const u8 = "",
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

    // 治理列 — TransformEngine.process 会注入这些列 (mall_id/source_type/sync_type/
    // is_delete + 条件性 source_create_time/source_update_time), sync_time 依赖
    // DEFAULT CURRENT_TIMESTAMP 自动填充. DDL 与 flush 的 INSERT 列集必须一致,
    // 否则首次增量 flush 即报 Unknown column (2026-11-21 E2E 实测踩坑).
    const governance_cols = [_][]const u8{
        "    `mall_id` VARCHAR(64) NULL",
        "    `source_type` VARCHAR(16) NULL",
        "    `sync_type` VARCHAR(8) NULL",
        "    `sync_time` DATETIME NULL DEFAULT CURRENT_TIMESTAMP",
        "    `is_delete` TINYINT NULL DEFAULT 0",
        "    `source_create_time` DATETIME NULL",
        "    `source_update_time` DATETIME NULL",
    };
    for (governance_cols) |g| {
        try col_parts.append(allocator, try allocator.dupe(u8, g));
    }

    // 幂等唯一键: (mall_id, pk_column). mall_id 由 TransformEngine 注入, pk 从源表主键透传.
    const has_pk = options.pk_column.len > 0 and blk: {
        for (columns) |c| {
            if (std.mem.eql(u8, c.name, options.pk_column)) break :blk true;
        }
        break :blk false;
    };
    if (has_pk) {
        const pk_quoted = try quoteIdentifier(allocator, options.pk_column);
        defer allocator.free(pk_quoted);
        // 所有权移交 col_parts (cleanup loop 统一 free)
        const uk = try std.fmt.allocPrint(allocator, "    UNIQUE KEY uk_zetl_mall_pk (`mall_id`, {s})", .{pk_quoted});
        try col_parts.append(allocator, uk);
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

test "buildCreateTable appends unique key when pk_column present" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "id", .type = 0x08 },
        .{ .name = "amount", .type = 0xf6, .precision = 10, .scale = 2 },
    };
    const ddl = try buildCreateTable(a, "orders", &cols, .{ .pk_column = "id" });
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "UNIQUE KEY uk_zetl_mall_pk (`mall_id`, `id`)") != null);
    // 治理列也在
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`sync_type` VARCHAR(8)") != null);
}

test "buildCreateTable skips unique key when pk_column missing from columns" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{.{ .name = "code", .type = 0x0f }};
    const ddl = try buildCreateTable(a, "t", &cols, .{ .pk_column = "id" });
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "UNIQUE KEY") == null);
}

test "buildCreateTable skips unique key when pk_column empty" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{.{ .name = "id", .type = 0x08 }};
    const ddl = try buildCreateTable(a, "t", &cols, .{});
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "UNIQUE KEY") == null);
}
