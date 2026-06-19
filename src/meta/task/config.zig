//! tasks_config 动态任务配置 Model (V5 Phase 5)
//!
//! 与 zetl Phase 5 配套: 把 YAML 静态任务定义搬到 SQLite `tasks_config` 表,
//! 通过 `/api/tasks` HTTP 接口运行时增删改, `Scheduler` 启动时按 status=1 加载.

const std = @import("std");

pub const TaskActiveStatus = enum(u8) {
    disabled = 0,
    active = 1,
};

/// tasks_config 表的一行 (运行时的同步任务定义)
/// 字段含义对齐 docs/superpowers/specs/2026-06-15-zetl-config-dynamic-tasks-design.md
pub const TaskConfig = struct {
    id: i64 = 0,
    name: []const u8 = "",
    source_db: []const u8 = "",
    source_table: []const u8 = "",
    target_table: []const u8 = "",
    sync_mode: u8 = 1,
    config_json: []const u8 = "{}",
    status: TaskActiveStatus = .active,
    created_at: i64 = 0,
    updated_at: i64 = 0,

    /// 释放所有从 DB dupe 出来的字符串切片.
    /// 默认值 (`""`, `"{}"`) 是静态字面量, len>0 不足以判断; 因此对空字符串显式跳过.
    pub fn deinit(self: *TaskConfig, a: std.mem.Allocator) void {
        // 约定: 通过 Service / rowToConfig 读出的字段都是 a.dupe 的,
        // 所以可以无脑 free — 但默认值 (`""` / `"{}"`) 是静态字面量, 长度为 0.
        if (self.name.len > 0) a.free(self.name);
        if (self.source_db.len > 0) a.free(self.source_db);
        if (self.source_table.len > 0) a.free(self.source_table);
        if (self.target_table.len > 0) a.free(self.target_table);
        if (self.config_json.len > 0) a.free(self.config_json);
    }
};

test "TaskConfig deinit frees owned slices" {
    const a = std.testing.allocator;
    var cfg = TaskConfig{
        .name = try a.dupe(u8, "test"),
        .source_db = try a.dupe(u8, "primary"),
        .source_table = try a.dupe(u8, "t"),
        .target_table = try a.dupe(u8, "t"),
        .config_json = try a.dupe(u8, "{}"),
    };
    cfg.deinit(a);
}

test "TaskConfig defaults are TaskActiveStatus.active and sync_mode=1" {
    const cfg = TaskConfig{};
    try std.testing.expectEqual(TaskActiveStatus.active, cfg.status);
    try std.testing.expectEqual(@as(u8, 1), cfg.sync_mode);
    try std.testing.expectEqualStrings("{}", cfg.config_json);
    try std.testing.expectEqual(@as(i64, 0), cfg.id);
}
