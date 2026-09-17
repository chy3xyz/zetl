//! 同步任务 Model + Service (V1)
//!
//! V5 Phase 5 扩展: re-export V5 `tasks_config` 子模块:
//!   - `meta.task.config`   → `TaskConfig` / `TaskActiveStatus`
//!   - `meta.task.service`  → V5 Service 命名空间 (create/getById/list/update/delete/setStatus)

const std = @import("std");
const zfinal = @import("zfinal");
const store_mod = @import("store.zig");

// V5: 暴露给 Scheduler / Web handler 使用.
pub const config = @import("task/config.zig");
pub const service = @import("task/service.zig");

pub const SyncMode = enum {
    full,
    poll,
    binlog,
    both,

    pub fn toString(s: SyncMode) []const u8 {
        return switch (s) {
            .full => "full",
            .poll => "poll",
            .binlog => "binlog",
            .both => "both",
        };
    }
};

pub const SyncTask = struct {
    id: i64,
    task_name: []const u8,
    datasource_id: i64,
    source_table: []const u8,
    target_table: []const u8,
    sync_mode: []const u8,
    field_mappings: ?[]const u8, // JSON 字符串
    filter_condition: ?[]const u8,
    batch_size: i32,
    enable_commission_calc: i32,
    status: i32, // 0 停止 / 1 运行中 / 2 异常
    last_run_time: ?[]const u8,
    last_error: ?[]const u8,
    created_at: []const u8,

    pub fn deinit(self: *SyncTask, allocator: std.mem.Allocator) void {
        allocator.free(self.task_name);
        allocator.free(self.source_table);
        allocator.free(self.target_table);
        allocator.free(self.sync_mode);
        if (self.field_mappings) |f| allocator.free(f);
        if (self.filter_condition) |f| allocator.free(f);
        if (self.last_run_time) |f| allocator.free(f);
        if (self.last_error) |f| allocator.free(f);
        allocator.free(self.created_at);
    }
};

pub const CreateInput = struct {
    task_name: []const u8,
    datasource_id: i64,
    source_table: []const u8,
    target_table: []const u8,
    sync_mode: SyncMode = .both,
    field_mappings: ?[]const u8 = null, // JSON 文本
    filter_condition: ?[]const u8 = null,
    batch_size: i32 = 1000,
    enable_commission_calc: bool = false,
};

pub const Service = struct {
    pub fn insert(store: *store_mod.MetaStore, input: CreateInput) !i64 {
        const sql: [:0]const u8 =
            "INSERT INTO sync_task (task_name, datasource_id, source_table, target_table, sync_mode, " ++
            "field_mappings, filter_condition, batch_size, enable_commission_calc) " ++
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)";

        const fm: zfinal.SqlParam = if (input.field_mappings) |f| .{ .text = f } else .null;
        const fc: zfinal.SqlParam = if (input.filter_condition) |f| .{ .text = f } else .null;

        const params = [_]zfinal.SqlParam{
            .{ .text = input.task_name },
            .{ .int = input.datasource_id },
            .{ .text = input.source_table },
            .{ .text = input.target_table },
            .{ .text = @tagName(input.sync_mode) },
            fm,
            fc,
            .{ .int = input.batch_size },
            .{ .int = if (input.enable_commission_calc) 1 else 0 },
        };

        try store.db.execParams(sql, &params);
        return try store.db.lastInsertId();
    }

    pub fn findById(store: *store_mod.MetaStore, allocator: std.mem.Allocator, id: i64) !?SyncTask {
        const sql: [:0]const u8 = "SELECT id, task_name, datasource_id, source_table, target_table, sync_mode, " ++
            "field_mappings, filter_condition, batch_size, enable_commission_calc, status, " ++
            "last_run_time, last_error, created_at FROM sync_task WHERE id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = id }});
        defer result.deinit();
        if (result.next()) {
            if (result.getCurrentRowMap()) |row| return try rowToTask(allocator, row);
        }
        return null;
    }

    pub fn findAll(store: *store_mod.MetaStore, allocator: std.mem.Allocator) ![]SyncTask {
        const sql: [:0]const u8 = "SELECT id, task_name, datasource_id, source_table, target_table, sync_mode, " ++
            "field_mappings, filter_condition, batch_size, enable_commission_calc, status, " ++
            "last_run_time, last_error, created_at FROM sync_task ORDER BY id DESC";
        var result = try store.db.query(sql);
        defer result.deinit();
        var list = std.ArrayList(SyncTask).empty;
        errdefer {
            for (list.items) |*it| it.deinit(allocator);
            list.deinit(allocator);
        }
        while (result.next()) {
            if (result.getCurrentRowMap()) |row| try list.append(allocator, try rowToTask(allocator, row));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn findEnabled(store: *store_mod.MetaStore, allocator: std.mem.Allocator) ![]SyncTask {
        const sql: [:0]const u8 = "SELECT id, task_name, datasource_id, source_table, target_table, sync_mode, " ++
            "field_mappings, filter_condition, batch_size, enable_commission_calc, status, " ++
            "last_run_time, last_error, created_at FROM sync_task WHERE status = 1";
        var result = try store.db.query(sql);
        defer result.deinit();
        var list = std.ArrayList(SyncTask).empty;
        errdefer {
            for (list.items) |*it| it.deinit(allocator);
            list.deinit(allocator);
        }
        while (result.next()) {
            if (result.getCurrentRowMap()) |row| try list.append(allocator, try rowToTask(allocator, row));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn updateStatus(store: *store_mod.MetaStore, id: i64, status: i32, last_error: ?[]const u8) !void {
        const sql: [:0]const u8 = "UPDATE sync_task SET status = $1, last_run_time = datetime('now'), last_error = $2 WHERE id = $3";
        const err_param: zfinal.SqlParam = if (last_error) |e| .{ .text = e } else .null;
        try store.db.execParams(sql, &.{ .{ .int = status }, err_param, .{ .int = id } });
    }

    pub fn deleteById(store: *store_mod.MetaStore, id: i64) !void {
        const sql: [:0]const u8 = "DELETE FROM sync_task WHERE id = $1";
        try store.db.execParams(sql, &.{.{ .int = id }});
    }

    pub fn countByDatasource(store: *store_mod.MetaStore, datasource_id: i64) !i64 {
        const sql: [:0]const u8 = "SELECT COUNT(*) FROM sync_task WHERE datasource_id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = datasource_id }});
        defer result.deinit();
        if (result.next()) {
            if (try result.getInt(0)) |c| return c;
        }
        return 0;
    }

    pub fn countAll(store: *store_mod.MetaStore) !i64 {
        const sql: [:0]const u8 = "SELECT COUNT(*) FROM sync_task";
        var result = try store.db.query(sql);
        defer result.deinit();
        if (result.next()) {
            if (try result.getInt(0)) |c| return c;
        }
        return 0;
    }

    pub fn countByStatus(store: *store_mod.MetaStore, status: i32) !i64 {
        const sql: [:0]const u8 = "SELECT COUNT(*) FROM sync_task WHERE status = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = status }});
        defer result.deinit();
        if (result.next()) {
            if (try result.getInt(0)) |c| return c;
        }
        return 0;
    }

    fn rowToTask(allocator: std.mem.Allocator, row: zfinal.ResultSet.RowMap) !SyncTask {
        const id_str = row.get("id") orelse "0";
        const task_name_str = row.get("task_name") orelse "";
        const ds_id_str = row.get("datasource_id") orelse "0";
        const source_str = row.get("source_table") orelse "";
        const target_str = row.get("target_table") orelse "";
        const mode_str = row.get("sync_mode") orelse "cdc";
        const fm_str = row.get("field_mappings") orelse "";
        const fc_str = row.get("filter_condition") orelse "";
        const batch_str = row.get("batch_size") orelse "1000";
        const ecc_str = row.get("enable_commission_calc") orelse "0";
        const status_str = row.get("status") orelse "0";
        const lrt_str = row.get("last_run_time") orelse "";
        const le_str = row.get("last_error") orelse "";
        const ca_str = row.get("created_at") orelse "";

        return .{
            .id = try std.fmt.parseInt(i64, id_str, 10),
            .task_name = try allocator.dupe(u8, task_name_str),
            .datasource_id = try std.fmt.parseInt(i64, ds_id_str, 10),
            .source_table = try allocator.dupe(u8, source_str),
            .target_table = try allocator.dupe(u8, target_str),
            .sync_mode = try allocator.dupe(u8, mode_str),
            .field_mappings = if (fm_str.len == 0) null else try allocator.dupe(u8, fm_str),
            .filter_condition = if (fc_str.len == 0) null else try allocator.dupe(u8, fc_str),
            .batch_size = @intCast(try std.fmt.parseInt(i32, batch_str, 10)),
            .enable_commission_calc = try std.fmt.parseInt(i32, ecc_str, 10),
            .status = try std.fmt.parseInt(i32, status_str, 10),
            .last_run_time = if (lrt_str.len == 0) null else try allocator.dupe(u8, lrt_str),
            .last_error = if (le_str.len == 0) null else try allocator.dupe(u8, le_str),
            .created_at = try allocator.dupe(u8, ca_str),
        };
    }
};
