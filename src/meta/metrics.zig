//! 运行时指标 (含今日同步条数, 成功/失败数, 最近错误)
//! 内存态为主, 定期落盘

const std = @import("std");
const zfinal = @import("zfinal");
const store_mod = @import("store.zig");

pub const TaskMetrics = struct {
    task_id: i64,
    today_rows: i64 = 0,
    success_count: i64 = 0,
    fail_count: i64 = 0,
    last_error: ?[]const u8 = null,
    updated_at: i64 = 0,
    /// 本次启动累计行数 (用于监控大盘, 不持久化)
    session_rows: i64 = 0,

    pub fn deinit(self: *TaskMetrics, allocator: std.mem.Allocator) void {
        if (self.last_error) |e| allocator.free(e);
    }
};

pub const Service = struct {
    pub fn load(store: *store_mod.MetaStore, task_id: i64) !TaskMetrics {
        const sql: [:0]const u8 = "SELECT task_id, today_rows, success_count, fail_count, last_error FROM runtime_metrics WHERE task_id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = task_id }});
        defer result.deinit();
        if (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                const last_err_s = row.get("last_error") orelse "";
                return TaskMetrics{
                    .task_id = try std.fmt.parseInt(i64, row.get("task_id") orelse "0", 10),
                    .today_rows = try std.fmt.parseInt(i64, row.get("today_rows") orelse "0", 10),
                    .success_count = try std.fmt.parseInt(i64, row.get("success_count") orelse "0", 10),
                    .fail_count = try std.fmt.parseInt(i64, row.get("fail_count") orelse "0", 10),
                    .last_error = if (last_err_s.len == 0) null else null,
                };
            }
        }
        return TaskMetrics{ .task_id = task_id };
    }

    /// 累加 + 落盘 (简化: UPSERT 一次)
    pub fn incrementSuccess(store: *store_mod.MetaStore, task_id: i64, delta: i64) !void {
        const sql: [:0]const u8 =
            "INSERT INTO runtime_metrics (task_id, today_rows, success_count, fail_count, updated_at) " ++
            "VALUES ($1, $2, 0, 0, datetime('now')) " ++
            "ON CONFLICT(task_id) DO UPDATE SET " ++
            "today_rows = today_rows + $2, " ++
            "success_count = success_count + $2, " ++
            "updated_at = datetime('now')";
        try store.db.execParams(sql, &.{ .{ .int = task_id }, .{ .int = delta } });
    }

    pub fn incrementFail(store: *store_mod.MetaStore, task_id: i64, delta: i64) !void {
        const sql: [:0]const u8 =
            "INSERT INTO runtime_metrics (task_id, today_rows, success_count, fail_count, updated_at) " ++
            "VALUES ($1, 0, 0, $2, datetime('now')) " ++
            "ON CONFLICT(task_id) DO UPDATE SET " ++
            "fail_count = fail_count + $2, " ++
            "updated_at = datetime('now')";
        try store.db.execParams(sql, &.{ .{ .int = task_id }, .{ .int = delta } });
    }

    /// 监控大盘全局
    pub fn globalOverview(store: *store_mod.MetaStore) !OverviewSnapshot {
        const sql: [:0]const u8 = "SELECT " ++
            "(SELECT COUNT(*) FROM sync_task WHERE status = 1) AS running, " ++
            "(SELECT COUNT(*) FROM sync_task WHERE status = 2) AS err, " ++
            "(SELECT COALESCE(SUM(today_rows), 0) FROM runtime_metrics) AS today_rows, " ++
            "(SELECT COUNT(*) FROM datasource WHERE status = 1) AS ds_count, " ++
            "(SELECT COUNT(*) FROM sync_task) AS task_count";
        var result = try store.db.query(sql);
        defer result.deinit();
        if (result.next()) {
            return OverviewSnapshot{
                .running_task_count = @intCast(try std.fmt.parseInt(i64, result.getText(0) orelse "0", 10)),
                .error_task_count = @intCast(try std.fmt.parseInt(i64, result.getText(1) orelse "0", 10)),
                .today_sync_rows = @intCast(try std.fmt.parseInt(i64, result.getText(2) orelse "0", 10)),
                .datasource_count = @intCast(try std.fmt.parseInt(i64, result.getText(3) orelse "0", 10)),
                .task_count = @intCast(try std.fmt.parseInt(i64, result.getText(4) orelse "0", 10)),
            };
        }
        return OverviewSnapshot{};
    }
};

pub const OverviewSnapshot = struct {
    running_task_count: i64 = 0,
    error_task_count: i64 = 0,
    today_sync_rows: i64 = 0,
    datasource_count: i64 = 0,
    task_count: i64 = 0,
    avg_delay_seconds: i64 = 0, // V1 简化: 取最后一个任务的延迟
};
