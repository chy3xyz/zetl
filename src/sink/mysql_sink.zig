//! MySQL Sink - 幂等批量 INSERT...ON DUPLICATE KEY UPDATE
//! 见 docs/superpowers/specs/2026-06-16-zetl-v1-design.md §3.3
//!
//! 关键设计:
//! 1. 攒批 (append 达 batch_size 自动 flush)
//! 2. 幂等 (基于归集库 UNIQUE 索引 + ON DUPLICATE KEY UPDATE)
//! 3. 脏数据分流 (flush 失败的行 → error_order)

const std = @import("std");
const zfinal = @import("zfinal");
const transform = @import("../transform/mod.zig");

pub const ConflictStrategy = enum {
    ignore, // 冲突则忽略
    update, // 冲突则更新 (推荐, 默认)
    fail, // 冲突则报错
};

pub const MySqlSink = struct {
    allocator: std.mem.Allocator,
    pool: *zfinal.ConnectionPool,
    target_table: []const u8,
    batch_buffer: std.ArrayList(transform.engine.RowData) = .empty,
    batch_size: usize = 1000,
    conflict_strategy: ConflictStrategy = .update,
    /// 唯一键字段名 (V1 假设单字段唯一, 如 order_no; 多字段组合留 V2)
    /// 实际幂等由归集库 UNIQUE INDEX 兜底
    unique_key: []const u8 = "",

    /// 错误行记录 (用于写入 error_order)
    pub const ErrorRecord = struct {
        mall_id: []const u8,
        order_no: []const u8,
        raw_data_json: []const u8,
        error_type: []const u8,
        error_msg: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, pool: *zfinal.ConnectionPool, target_table: []const u8, batch_size: usize, unique_key: []const u8) MySqlSink {
        return .{
            .allocator = allocator,
            .pool = pool,
            .target_table = allocator.dupe(u8, target_table) catch target_table,
            .batch_size = batch_size,
            .unique_key = allocator.dupe(u8, unique_key) catch unique_key,
        };
    }

    pub fn deinit(self: *MySqlSink) void {
        self.flush() catch {};
        for (self.batch_buffer.items) |*row| row.deinit();
        self.batch_buffer.deinit(self.allocator);
    }

    /// 追加单行 (达 batch_size 自动 flush)
    pub fn append(self: *MySqlSink, row: transform.engine.RowData) !void {
        try self.batch_buffer.append(self.allocator, row);
        if (self.batch_buffer.items.len >= self.batch_size) {
            try self.flush();
        }
    }

    /// 强制刷盘
    pub fn flush(self: *MySqlSink) !void {
        if (self.batch_buffer.items.len == 0) return;

        const rows = self.batch_buffer.items;
        const sql = try buildBatchInsertSql(self.allocator, self.target_table, rows, self.conflict_strategy, self.unique_key);
        defer self.allocator.free(sql);

        const conn = self.pool.acquire() catch return error.PoolExhausted;
        defer self.pool.release(conn) catch {};

        // sql: [:0]u8 needed for exec
        const sql_z = try sentinelAlloc(self.allocator, sql);
        defer self.allocator.free(sql_z);

        conn.exec(sql_z) catch |err| {
            std.log.warn("Sink flush failed (size={d}): {s}", .{ rows.len, @errorName(err) });
            return err;
        };

        for (self.batch_buffer.items) |*row| row.deinit();
        self.batch_buffer.clearRetainingCapacity();

        std.log.info("MySqlSink: flushed {d} rows to {s}", .{ rows.len, self.target_table });
    }
};

/// 分配零结尾字符串
fn sentinelAlloc(allocator: std.mem.Allocator, src: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, src.len + 1);
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}

/// 构造 INSERT ... ON DUPLICATE KEY UPDATE 批量 SQL (纯字符串拼接, 上游负责转义)
pub fn buildBatchInsertSql(allocator: std.mem.Allocator, target_table: []const u8, rows: []const transform.engine.RowData, strategy: ConflictStrategy, unique_key: []const u8) ![]u8 {
    if (rows.len == 0) return allocator.dupe(u8, "");

    // 1. 从首行取列序
    const first = rows[0];
    var col_list = std.ArrayList([]const u8).empty;
    defer col_list.deinit(allocator);
    var it = first.iterator();
    while (it.next()) |entry| {
        try col_list.append(allocator, entry.key_ptr.*);
    }
    if (col_list.items.len == 0) return allocator.dupe(u8, "");

    // 2. 构造头部
    var sql_buf = std.ArrayList(u8).empty;
    errdefer sql_buf.deinit(allocator);

    try sql_buf.print(allocator, "INSERT INTO `{s}` (", .{target_table});
    for (col_list.items, 0..) |col, i| {
        if (i > 0) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, "`{s}`", .{col});
    }
    try sql_buf.appendSlice(allocator, ") VALUES ");

    // 3. 批量 VALUES
    for (rows, 0..) |row, row_idx| {
        if (row_idx > 0) try sql_buf.append(allocator, ',');
        try sql_buf.append(allocator, '(');
        for (col_list.items, 0..) |col, col_idx| {
            if (col_idx > 0) try sql_buf.append(allocator, ',');
            const val = row.get(col) orelse "";
            try escapeAndAppend(allocator, &sql_buf, val);
        }
        try sql_buf.append(allocator, ')');
    }

    // 4. ON DUPLICATE KEY UPDATE 子句
    switch (strategy) {
        .ignore => try sql_buf.appendSlice(allocator, " ON DUPLICATE KEY UPDATE `id`=`id`"),
        .update => {
            try sql_buf.appendSlice(allocator, " ON DUPLICATE KEY UPDATE ");
            var update_idx: usize = 0;
            for (col_list.items) |col| {
                if (unique_key.len > 0 and std.mem.eql(u8, col, unique_key)) continue;
                if (std.mem.eql(u8, col, "mall_id")) continue;
                if (update_idx > 0) try sql_buf.append(allocator, ',');
                try sql_buf.print(allocator, "`{s}`=VALUES(`{s}`)", .{ col, col });
                update_idx += 1;
            }
            if (update_idx == 0) try sql_buf.appendSlice(allocator, "`id`=`id`");
        },
        .fail => {},
    }

    return sql_buf.toOwnedSlice(allocator);
}

/// SQL 字符串转义: 单引号、反斜杠、NULL 处理 (直接 append 到 ArrayList)
fn escapeAndAppend(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), val: []const u8) !void {
    if (val.len == 0) {
        try buf.appendSlice(allocator, "NULL");
        return;
    }
    if (isNumericLiteral(val)) {
        try buf.appendSlice(allocator, val);
        return;
    }
    try buf.append(allocator, '\'');
    for (val) |c| {
        switch (c) {
            '\'' => try buf.appendSlice(allocator, "''"),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            0 => try buf.appendSlice(allocator, "\\0"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\x1a' => try buf.appendSlice(allocator, "\\Z"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '\'');
}

fn isNumericLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_dot = false;
    for (s, 0..) |c, i| {
        if (c == '-' and i == 0) continue;
        if (c == '.' and !has_dot) {
            has_dot = true;
            continue;
        }
        if (c < '0' or c > '9') return false;
    }
    return true;
}

test "buildBatchInsertSql: simple batch" {
    const a = std.testing.allocator;

    var row1 = transform.engine.RowData.init(a);
    defer row1.deinit();
    try row1.put("mall_id", "mall_001");
    try row1.put("order_no", "ON001");
    try row1.put("order_total", "100.50");

    var row2 = transform.engine.RowData.init(a);
    defer row2.deinit();
    try row2.put("mall_id", "mall_001");
    try row2.put("order_no", "ON002");
    try row2.put("order_total", "200.00");

    const rows = [_]transform.engine.RowData{ row1, row2 };
    const sql = try buildBatchInsertSql(a, "union_all_order", &rows, .update, "order_no");
    defer a.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO `union_all_order`") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DUPLICATE KEY UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'mall_001'") != null);
    // order_no 唯一键 - 不出现在 ON DUPLICATE 中
    try std.testing.expect(std.mem.indexOf(u8, sql, "VALUES(`order_no`)") == null);
    // order_total 应出现
    try std.testing.expect(std.mem.indexOf(u8, sql, "VALUES(`order_total`)") != null);
}

test "buildBatchInsertSql: ignore strategy" {
    const a = std.testing.allocator;
    var row = transform.engine.RowData.init(a);
    defer row.deinit();
    try row.put("a", "1");
    const rows = [_]transform.engine.RowData{row};
    const sql = try buildBatchInsertSql(a, "t", &rows, .ignore, "");
    defer a.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DUPLICATE KEY UPDATE `id`=`id`") != null);
}

test "escape: single quote" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try escapeAndAppend(a, &buf, "O'Brien");
    try std.testing.expectEqualStrings("'O''Brien'", buf.items);
}

test "escape: empty string becomes NULL" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try escapeAndAppend(a, &buf, "");
    try std.testing.expectEqualStrings("NULL", buf.items);
}

test "escape: numeric literal is unquoted" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try escapeAndAppend(a, &buf, "100.50");
    try std.testing.expectEqualStrings("100.50", buf.items);
}

test "escape: control chars" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try escapeAndAppend(a, &buf, "line1\nline2\r");
    try std.testing.expectEqualStrings("'line1\\nline2\\r'", buf.items);
}

test "buildBatchInsertSql: empty rows" {
    const a = std.testing.allocator;
    const sql = try buildBatchInsertSql(a, "t", &.{}, .update, "");
    defer a.free(sql);
    try std.testing.expectEqualStrings("", sql);
}

test "buildBatchInsertSql: fail strategy" {
    const a = std.testing.allocator;
    var row = transform.engine.RowData.init(a);
    defer row.deinit();
    try row.put("a", "1");
    try row.put("b", "hello");
    const rows = [_]transform.engine.RowData{row};
    const sql = try buildBatchInsertSql(a, "t", &rows, .fail, "");
    defer a.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO `t`") != null);
    // 数字不加引号, 字符串加引号
    try std.testing.expect(std.mem.indexOf(u8, sql, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'hello'") != null);
    // fail 策略不加 ON DUPLICATE
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DUPLICATE") == null);
}

test "buildBatchInsertSql: skip unique_key column" {
    const a = std.testing.allocator;
    var row = transform.engine.RowData.init(a);
    defer row.deinit();
    try row.put("mall_id", "m1");
    try row.put("order_no", "ON001");
    try row.put("amount", "100.00");
    const rows = [_]transform.engine.RowData{row};
    const sql = try buildBatchInsertSql(a, "orders", &rows, .update, "order_no");
    defer a.free(sql);
    // order_no 是唯一键, 不出现在 ON DUPLICATE
    try std.testing.expect(std.mem.indexOf(u8, sql, "VALUES(`order_no`)") == null);
    // amount 应该出现
    try std.testing.expect(std.mem.indexOf(u8, sql, "VALUES(`amount`)") != null);
    // mall_id 是分区键, 不应该被覆盖
    try std.testing.expect(std.mem.indexOf(u8, sql, "VALUES(`mall_id`)") == null);
}

test "buildBatchInsertSql: multi-row batch" {
    const a = std.testing.allocator;
    var r1 = transform.engine.RowData.init(a);
    defer r1.deinit();
    try r1.put("id", "1");
    try r1.put("name", "Alice");
    var r2 = transform.engine.RowData.init(a);
    defer r2.deinit();
    try r2.put("id", "2");
    try r2.put("name", "Bob");
    var r3 = transform.engine.RowData.init(a);
    defer r3.deinit();
    try r3.put("id", "3");
    try r3.put("name", "Carol");
    const rows = [_]transform.engine.RowData{ r1, r2, r3 };
    const sql = try buildBatchInsertSql(a, "users", &rows, .ignore, "");
    defer a.free(sql);
    // 三行 VALUES 应该都在
    try std.testing.expect(std.mem.indexOf(u8, sql, "'Alice'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'Bob'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'Carol'") != null);
    // ignore 策略
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DUPLICATE KEY UPDATE `id`=`id`") != null);
}
