//! tasks_config Service 命名空间 (V5 Phase 5)
//!
//! Phase 5 Task 2: 实现 `tasks_config` 表的 CRUD:
//!   - `create`     插入新任务, 返回自增 ID
//!   - `getById`    按 ID 查询, 返回 `?TaskConfig` (未找到 → null)
//!   - `list`       列出全部或按 `TaskActiveStatus` 过滤
//!   - `update`     按 ID 覆盖业务字段
//!   - `delete`     按 ID 删除
//!   - `setStatus`  按 ID 更新 status 字段
//!
//! SQL 模式与列绑定 API 与 `src/meta/task.zig` 中的 `SyncTask.Service` 完全一致:
//!   - `store.db.execParams(sql, &params)`
//!   - `store.db.query / queryParams(sql, &params)`
//!   - `store.db.lastInsertId()`
//!   - `result.next()` + `result.getCurrentRowMap()` → `row.get(name)`

const std = @import("std");
const zfinal = @import("zfinal");
const store_mod = @import("../store.zig");

pub const config_mod = @import("config.zig");
pub const TaskConfig = config_mod.TaskConfig;
pub const TaskActiveStatus = config_mod.TaskActiveStatus;

const SQL_COLUMNS =
    "id, name, source_db, source_table, target_table, sync_mode, " ++
    "config_json, status, created_at, updated_at";

/// 获取当前 Unix 秒 (Zig 0.17 没有 std.time.timestamp(), 改用 std.Io.Clock).
/// 测试环境下 zfinal.io_instance.io 由 io_instance.zig 自动初始化为 std.testing.io.
fn nowSec() i64 {
    return std.Io.Clock.now(.real, zfinal.io_instance.io).toSeconds();
}

/// tasks_config 表的 Service 命名空间.
///
/// 字段:
///   - `store` 指向 `MetaStore`, 复用其 allocator 与 zfinal.DB 句柄.
pub const Service = struct {
    store: *store_mod.MetaStore,

    pub fn create(self: *Service, cfg: TaskConfig) !i64 {
        const now_s = nowSec();
        const sql: [:0]const u8 =
            "INSERT INTO tasks_config " ++
            "(name, source_db, source_table, target_table, sync_mode, config_json, status, created_at, updated_at) " ++
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)";
        try self.store.db.execParams(sql, &.{
            .{ .text = cfg.name },
            .{ .text = cfg.source_db },
            .{ .text = cfg.source_table },
            .{ .text = cfg.target_table },
            .{ .int = cfg.sync_mode },
            .{ .text = cfg.config_json },
            .{ .int = @intFromEnum(cfg.status) },
            .{ .int = now_s },
            .{ .int = now_s },
        });
        return try self.store.db.lastInsertId();
    }

    pub fn getById(self: *Service, id: i64) !?TaskConfig {
        const a = self.store.allocator;
        const sql: [:0]const u8 =
            "SELECT " ++ SQL_COLUMNS ++ " FROM tasks_config WHERE id = $1";
        var result = try self.store.db.queryParams(sql, &.{.{ .int = id }});
        defer result.deinit();
        if (result.next()) {
            if (result.getCurrentRowMap()) |row| return try rowToConfig(a, row);
        }
        return null;
    }

    pub fn list(self: *Service, filter: ?TaskActiveStatus) ![]TaskConfig {
        const a = self.store.allocator;

        var result: zfinal.ResultSet = if (filter) |s| blk: {
            const sql: [:0]const u8 =
                "SELECT " ++ SQL_COLUMNS ++ " FROM tasks_config WHERE status = $1";
            break :blk try self.store.db.queryParams(sql, &.{.{ .int = @intFromEnum(s) }});
        } else blk: {
            const sql: [:0]const u8 =
                "SELECT " ++ SQL_COLUMNS ++ " FROM tasks_config";
            break :blk try self.store.db.query(sql);
        };
        defer result.deinit();

        var out = std.ArrayList(TaskConfig).empty;
        errdefer {
            for (out.items) |*c| c.deinit(a);
            out.deinit(a);
        }
        while (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                try out.append(a, try rowToConfig(a, row));
            }
        }
        return out.toOwnedSlice(a);
    }

    pub fn update(self: *Service, id: i64, cfg: TaskConfig) !void {
        const now_s = nowSec();
        const sql: [:0]const u8 =
            "UPDATE tasks_config SET " ++
            "name = $1, source_db = $2, source_table = $3, target_table = $4, " ++
            "sync_mode = $5, config_json = $6, status = $7, updated_at = $8 " ++
            "WHERE id = $9";
        try self.store.db.execParams(sql, &.{
            .{ .text = cfg.name },
            .{ .text = cfg.source_db },
            .{ .text = cfg.source_table },
            .{ .text = cfg.target_table },
            .{ .int = cfg.sync_mode },
            .{ .text = cfg.config_json },
            .{ .int = @intFromEnum(cfg.status) },
            .{ .int = now_s },
            .{ .int = id },
        });
    }

    pub fn delete(self: *Service, id: i64) !void {
        try self.store.db.execParams(
            "DELETE FROM tasks_config WHERE id = $1",
            &.{.{ .int = id }},
        );
    }

    pub fn setStatus(self: *Service, id: i64, status: TaskActiveStatus) !void {
        const now_s = nowSec();
        try self.store.db.execParams(
            "UPDATE tasks_config SET status = $1, updated_at = $2 WHERE id = $3",
            &.{ .{ .int = @intFromEnum(status) }, .{ .int = now_s }, .{ .int = id } },
        );
    }
};

fn rowToConfig(a: std.mem.Allocator, row: zfinal.ResultSet.RowMap) !TaskConfig {
    const name = try a.dupe(u8, row.get("name") orelse "");
    errdefer a.free(name);
    const source_db = try a.dupe(u8, row.get("source_db") orelse "");
    errdefer a.free(source_db);
    const source_table = try a.dupe(u8, row.get("source_table") orelse "");
    errdefer a.free(source_table);
    const target_table = try a.dupe(u8, row.get("target_table") orelse "");
    errdefer a.free(target_table);
    const config_json = try a.dupe(u8, row.get("config_json") orelse "{}");
    errdefer a.free(config_json);

    const id_str = row.get("id") orelse "0";
    const id = try std.fmt.parseInt(i64, id_str, 10);
    const sync_mode_str = row.get("sync_mode") orelse "1";
    const sync_mode: u8 = @intCast(try std.fmt.parseInt(i64, sync_mode_str, 10));
    const status_str = row.get("status") orelse "1";
    const status_int: u8 = @intCast(try std.fmt.parseInt(i64, status_str, 10));
    const status: TaskActiveStatus = @enumFromInt(status_int);
    const created_at_str = row.get("created_at") orelse "0";
    const created_at = try std.fmt.parseInt(i64, created_at_str, 10);
    const updated_at_str = row.get("updated_at") orelse "0";
    const updated_at = try std.fmt.parseInt(i64, updated_at_str, 10);

    return .{
        .id = id,
        .name = name,
        .source_db = source_db,
        .source_table = source_table,
        .target_table = target_table,
        .sync_mode = sync_mode,
        .config_json = config_json,
        .status = status,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

// ===== 单元测试 =====

test "Service create / getById / list / update / delete round-trip" {
    const a = std.testing.allocator;
    var db = try store_mod.MetaStore.init(a, ":memory:");
    defer db.deinit();

    var svc = Service{ .store = &db };

    const id = try svc.create(.{
        .name = "order_sync",
        .source_db = "primary",
        .source_table = "order_info",
        .target_table = "order_info",
        .sync_mode = 2,
        .config_json = "{\"polling_interval_sec\":60}",
    });
    try std.testing.expect(id > 0);

    const cfg = (try svc.getById(id)).?;
    var cfg_owned = cfg;
    defer cfg_owned.deinit(a);
    try std.testing.expectEqualStrings("order_sync", cfg_owned.name);
    try std.testing.expectEqualStrings("primary", cfg.source_db);
    try std.testing.expectEqualStrings("order_info", cfg.source_table);
    try std.testing.expectEqualStrings("order_info", cfg.target_table);
    try std.testing.expectEqual(@as(u8, 2), cfg.sync_mode);
    try std.testing.expectEqualStrings("{\"polling_interval_sec\":60}", cfg.config_json);
    try std.testing.expectEqual(TaskActiveStatus.active, cfg.status);

    const all = try svc.list(null);
    defer {
        for (all) |*c| c.deinit(a);
        a.free(all);
    }
    try std.testing.expectEqual(@as(usize, 1), all.len);
    try std.testing.expectEqualStrings("order_sync", all[0].name);

    try svc.update(id, .{
        .name = "order_sync_v2",
        .source_db = "primary",
        .source_table = "order_info",
        .target_table = "order_info",
        .sync_mode = 2,
        .config_json = "{\"polling_interval_sec\":30}",
    });

    const updated = (try svc.getById(id)).?;
    var updated_owned = updated;
    defer updated_owned.deinit(a);
    try std.testing.expectEqualStrings("order_sync_v2", updated_owned.name);
    try std.testing.expectEqualStrings("{\"polling_interval_sec\":30}", updated_owned.config_json);

    try svc.delete(id);
    try std.testing.expect(try svc.getById(id) == null);
}

test "Service list filters by status" {
    const a = std.testing.allocator;
    var db = try store_mod.MetaStore.init(a, ":memory:");
    defer db.deinit();

    var svc = Service{ .store = &db };

    _ = try svc.create(.{ .name = "active_a", .source_db = "p", .source_table = "t", .target_table = "t", .sync_mode = 1, .config_json = "{}", .status = .active });
    _ = try svc.create(.{ .name = "active_b", .source_db = "p", .source_table = "t", .target_table = "t", .sync_mode = 1, .config_json = "{}", .status = .active });
    _ = try svc.create(.{ .name = "disabled", .source_db = "p", .source_table = "t", .target_table = "t", .sync_mode = 1, .config_json = "{}", .status = .disabled });

    const active = try svc.list(.active);
    defer {
        for (active) |*c| c.deinit(a);
        a.free(active);
    }
    try std.testing.expectEqual(@as(usize, 2), active.len);

    const disabled = try svc.list(.disabled);
    defer {
        for (disabled) |*c| c.deinit(a);
        a.free(disabled);
    }
    try std.testing.expectEqual(@as(usize, 1), disabled.len);
    try std.testing.expectEqualStrings("disabled", disabled[0].name);
}

test "Service setStatus toggles active/disabled" {
    const a = std.testing.allocator;
    var db = try store_mod.MetaStore.init(a, ":memory:");
    defer db.deinit();

    var svc = Service{ .store = &db };
    const id = try svc.create(.{ .name = "t", .source_db = "p", .source_table = "t", .target_table = "t", .sync_mode = 1, .config_json = "{}" });
    {
        var first = (try svc.getById(id)).?;
        defer first.deinit(a);
        try std.testing.expectEqual(TaskActiveStatus.active, first.status);
    }

    try svc.setStatus(id, .disabled);
    {
        var got = (try svc.getById(id)).?;
        defer got.deinit(a);
        try std.testing.expectEqual(TaskActiveStatus.disabled, got.status);
    }

    try svc.setStatus(id, .active);
    {
        var got = (try svc.getById(id)).?;
        defer got.deinit(a);
        try std.testing.expectEqual(TaskActiveStatus.active, got.status);
    }
}
