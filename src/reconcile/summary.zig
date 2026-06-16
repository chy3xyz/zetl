//! 全量汇总对账 + 增量行级 diff
//! 依赖: 源库池 + 归集库池 (都从 engine 层获取)

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const engine = @import("../engine/mod.zig");
const common = @import("../common/mod.zig");
const rec = @import("mod.zig");

/// 执行一次 mall_id + 指定表对账
/// src_pool: 源库连接池 (由 caller 按 datasource 配置构建)
/// sink_pool: 归集库连接池 (全局归集库)
pub fn reconcileAsync(
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    src_pool: *zfinal.ConnectionPool,
    sink_pool: *zfinal.ConnectionPool,
    mall_id: []const u8,
    table_name: []const u8,
    cfg: rec.ReconcileConfig,
) !rec.ReconcileResult {
    // 1. 源库汇总
    var src_count: i64 = 0;
    var src_amount: f64 = 0;
    try summaryQuery(allocator, src_pool, mall_id, table_name, &src_count, &src_amount);

    // 2. 目标库汇总
    var tgt_count: i64 = 0;
    var tgt_amount: f64 = 0;
    try summaryQuery(allocator, sink_pool, mall_id, table_name, &tgt_count, &tgt_amount);

    const diff_count = src_count - tgt_count;
    const diff_amount = src_amount - tgt_amount;

    const count_abnormal = @abs(diff_count) > cfg.diff_count_threshold;
    const amount_abnormal = @abs(diff_amount) > cfg.diff_amount_threshold;
    const is_abnormal = count_abnormal or amount_abnormal;

    // 3. 写入 reconcile_record (SQLite)
    const record_id = try saveRecord(store, mall_id, table_name, src_count, tgt_count, diff_count, src_amount, tgt_amount, diff_amount, is_abnormal);

    // 4. 异常时跑一次增量 diff (抽样)
    var details_json: ?[]u8 = null;
    if (is_abnormal) {
        details_json = try runDiff(allocator, src_pool, sink_pool, mall_id, table_name, cfg.sample_ratio);
    }

    return rec.ReconcileResult{
        .record_id = record_id,
        .mall_id = try allocator.dupe(u8, mall_id),
        .table_name = try allocator.dupe(u8, table_name),
        .source_count = src_count,
        .target_count = tgt_count,
        .diff_count = diff_count,
        .source_amount = src_amount,
        .target_amount = tgt_amount,
        .diff_amount = diff_amount,
        .is_abnormal = is_abnormal,
        .reconcile_time = try allocator.dupe(u8, "now"),
        .details_json = details_json,
    };
}

/// 源库 / 归集库 汇总查询: COUNT(*) + SUM(order_total)
fn summaryQuery(
    _: std.mem.Allocator,
    pool: *zfinal.ConnectionPool,
    mall_id: []const u8,
    table_name: []const u8,
    count_out: *i64,
    amount_out: *f64,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn) catch {};

    const sql = try std.fmt.allocPrintSentinel(conn.allocator,
        "SELECT COUNT(*) AS cnt, COALESCE(SUM(order_total), 0) AS amt FROM `{s}` WHERE mall_id = $1", .{table_name}, 0);
    defer conn.allocator.free(sql);

    var result = try conn.queryParams(sql, &.{.{ .text = mall_id }});
    defer result.deinit();

    if (result.next()) {
        if (try result.getInt(0)) |c| count_out.* = c;
        const amt_text = result.getText(1) orelse "0";
        amount_out.* = std.fmt.parseFloat(f64, amt_text) catch 0.0;
    }
}

/// 增量 diff: 抽样源库与归集库行, 找出 order_total 不一致的
fn runDiff(
    allocator: std.mem.Allocator,
    src_pool: *zfinal.ConnectionPool,
    sink_pool: *zfinal.ConnectionPool,
    mall_id: []const u8,
    table_name: []const u8,
    sample_ratio: f64,
) !?[]u8 {
    const src_conn = try src_pool.acquire();
    defer src_pool.release(src_conn) catch {};
    const tgt_conn = try sink_pool.acquire();
    defer sink_pool.release(tgt_conn) catch {};

    // 先从源库抽样 N 行
    var sample = std.ArrayList(SampleRow).empty;
    defer sample.deinit(allocator);

    const limit: i64 = @intFromFloat(1000.0 * sample_ratio);
    if (limit == 0) return null;

    const src_sql = try std.fmt.allocPrintSentinel(allocator,
        "SELECT order_no, order_total FROM `{s}` WHERE mall_id = $1 ORDER BY id ASC LIMIT $2", .{table_name}, 0);
    defer allocator.free(src_sql);

    var src_result = try src_conn.queryParams(src_sql, &.{ .{ .text = mall_id }, .{ .int = limit } });
    defer src_result.deinit();

    while (src_result.next()) {
        const order_no = src_result.getText(0) orelse continue;
        const total_str = src_result.getText(1) orelse "0";
        try sample.append(allocator, .{
            .order_no = try allocator.dupe(u8, order_no),
            .src_total = try std.fmt.parseFloat(f64, total_str),
        });
    }

    // 对每个抽样行, 在目标库查对应值
    var diffs = std.ArrayList(DiffRow).empty;
    defer {
        for (diffs.items) |*d| allocator.free(d.order_no);
        diffs.deinit(allocator);
        for (sample.items) |*s| allocator.free(s.order_no);
    }

    for (sample.items) |s_row| {
        const tgt_sql = try std.fmt.allocPrintSentinel(allocator,
            "SELECT order_total FROM `{s}` WHERE mall_id = $1 AND order_no = $2", .{table_name}, 0);
        defer allocator.free(tgt_sql);
        var tgt_result = try tgt_conn.queryParams(tgt_sql, &.{ .{ .text = mall_id }, .{ .text = s_row.order_no } });
        defer tgt_result.deinit();

        if (tgt_result.next()) {
            const tgt_str = tgt_result.getText(0) orelse "0";
            const tgt_total = try std.fmt.parseFloat(f64, tgt_str);
            if (@abs(s_row.src_total - tgt_total) > 0.01) {
                try diffs.append(allocator, .{
                    .order_no = s_row.order_no, // 转移所有权
                    .src_total = s_row.src_total,
                    .tgt_total = tgt_total,
                });
                _ = s_row.order_no; // 转移到 diffs 了, 设为空避免 double free
                continue;
            }
        }
        // 不太一致: 目标库缺少行 → 标记为 diff
        try diffs.append(allocator, .{
            .order_no = s_row.order_no,
            .src_total = s_row.src_total,
            .tgt_total = -1.0, // -1 = 目标库缺失
        });
        _ = s_row.order_no;
    }

    if (diffs.items.len == 0) return null;

    // 序列化为 JSON
    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(allocator);
    try json_buf.appendSlice(allocator, "[");
    for (diffs.items, 0..) |d, i| {
        if (i > 0) try json_buf.append(allocator, ',');
        try json_buf.print(allocator, "{{\"order_no\":\"{s}\",\"src\":{d:.2},\"tgt\":{d:.2}}}", .{ d.order_no, d.src_total, d.tgt_total });
    }
    try json_buf.append(allocator, ']');
    return try json_buf.toOwnedSlice(allocator);
}

const SampleRow = struct { order_no: []const u8, src_total: f64 };
const DiffRow = struct { order_no: []const u8, src_total: f64, tgt_total: f64 };

/// 写入 reconcile_record 表
fn saveRecord(
    store: *meta.store.MetaStore,
    mall_id: []const u8,
    table_name: []const u8,
    src_count: i64,
    tgt_count: i64,
    diff_count: i64,
    src_amount: f64,
    tgt_amount: f64,
    diff_amount: f64,
    is_abnormal: bool,
) !i64 {
    const sql: [:0]const u8 =
        "INSERT INTO reconcile_record (mall_id, table_name, source_count, target_count, diff_count, " ++
        "source_amount, target_amount, diff_amount, is_abnormal) " ++
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)";

    try store.db.execParams(sql, &.{
        .{ .text = mall_id },
        .{ .text = table_name },
        .{ .int = src_count },
        .{ .int = tgt_count },
        .{ .int = diff_count },
        .{ .real = src_amount },
        .{ .real = tgt_amount },
        .{ .real = diff_amount },
        .{ .int = if (is_abnormal) 1 else 0 },
    });
    return try store.db.lastInsertId();
}

/// 获取已存储的对账记录 (用于 API)
pub fn listRecords(store: *meta.store.MetaStore, allocator: std.mem.Allocator) ![]RecRecord {
    const sql: [:0]const u8 = "SELECT id, mall_id, table_name, source_count, target_count, diff_count, "
        ++ "source_amount, target_amount, diff_amount, is_abnormal, reconcile_time "
        ++ "FROM reconcile_record ORDER BY id DESC LIMIT 100";
    var result = try store.db.query(sql);
    defer result.deinit();

    var list = std.ArrayList(RecRecord).empty;
    errdefer {
        for (list.items) |*r| r.deinit(allocator);
        list.deinit(allocator);
    }
    while (result.next()) {
        if (result.getCurrentRowMap()) |row| {
            try list.append(allocator, try rowToRecRecord(allocator, row));
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn getRecord(store: *meta.store.MetaStore, allocator: std.mem.Allocator, id: i64) !?RecRecord {
    const sql: [:0]const u8 = "SELECT id, mall_id, table_name, source_count, target_count, diff_count, "
        ++ "source_amount, target_amount, diff_amount, is_abnormal, reconcile_time "
        ++ "FROM reconcile_record WHERE id = $1";
    var result = try store.db.queryParams(sql, &.{.{ .int = id }});
    defer result.deinit();
    if (result.next()) {
        if (result.getCurrentRowMap()) |row| {
            return try rowToRecRecord(allocator, row);
        }
    }
    return null;
}

pub const RecRecord = struct {
    id: i64,
    mall_id: []const u8,
    table_name: []const u8,
    source_count: i64,
    target_count: i64,
    diff_count: i64,
    source_amount: f64,
    target_amount: f64,
    diff_amount: f64,
    is_abnormal: i32,
    reconcile_time: []const u8,

    pub fn deinit(self: *RecRecord, a: std.mem.Allocator) void {
        a.free(self.mall_id);
        a.free(self.table_name);
        a.free(self.reconcile_time);
    }
};

fn rowToRecRecord(a: std.mem.Allocator, row: zfinal.ResultSet.RowMap) !RecRecord {
    const id_s = row.get("id") orelse "0";
    const mall_s = row.get("mall_id") orelse "";
    const tn_s = row.get("table_name") orelse "";
    const sc_s = row.get("source_count") orelse "0";
    const tc_s = row.get("target_count") orelse "0";
    const dc_s = row.get("diff_count") orelse "0";
    const sa_s = row.get("source_amount") orelse "0";
    const ta_s = row.get("target_amount") orelse "0";
    const da_s = row.get("diff_amount") orelse "0";
    const ia_s = row.get("is_abnormal") orelse "0";
    const rt_s = row.get("reconcile_time") orelse "";

    return RecRecord{
        .id = try std.fmt.parseInt(i64, id_s, 10),
        .mall_id = try a.dupe(u8, mall_s),
        .table_name = try a.dupe(u8, tn_s),
        .source_count = try std.fmt.parseInt(i64, sc_s, 10),
        .target_count = try std.fmt.parseInt(i64, tc_s, 10),
        .diff_count = try std.fmt.parseInt(i64, dc_s, 10),
        .source_amount = try std.fmt.parseFloat(f64, sa_s),
        .target_amount = try std.fmt.parseFloat(f64, ta_s),
        .diff_amount = try std.fmt.parseFloat(f64, da_s),
        .is_abnormal = try std.fmt.parseInt(i32, ia_s, 10),
        .reconcile_time = try a.dupe(u8, rt_s),
    };
}
