//! 同步位点 - 伪 CDC 用 last_pk(全量) + last_update_time(增量)
//! 严格按 docs/superpowers/specs/2026-06-16-zetl-v1-design.md §2.1

const std = @import("std");
const zfinal = @import("zfinal");
const store_mod = @import("store.zig");

pub const SyncStage = enum {
    full, // 全量阶段 (主键分页)
    incremental, // 增量阶段 (update_time 游标)

    pub fn toString(s: SyncStage) []const u8 {
        return switch (s) {
            .full => "full",
            .incremental => "incremental",
        };
    }

    pub fn fromString(s: []const u8) SyncStage {
        if (std.mem.eql(u8, s, "incremental")) return .incremental;
        return .full;
    }
};

pub const SyncPosition = struct {
    task_id: i64,
    last_pk: []const u8 = "",
    last_update_time: []const u8 = "",
    last_event_time: ?[]const u8 = null,
    stage: SyncStage = .full,
    updated_at: []const u8 = "",

    pub fn deinit(self: *SyncPosition, allocator: std.mem.Allocator) void {
        allocator.free(self.last_pk);
        allocator.free(self.last_update_time);
        if (self.last_event_time) |e| allocator.free(e);
        allocator.free(self.updated_at);
    }

    pub fn isInitial(self: *const SyncPosition) bool {
        return self.last_pk.len == 0 and self.last_update_time.len == 0;
    }
};

pub const Service = struct {
    pub fn load(store: *store_mod.MetaStore, allocator: std.mem.Allocator, task_id: i64) !SyncPosition {
        const sql: [:0]const u8 = "SELECT task_id, last_pk, last_update_time, last_event_time, stage, updated_at FROM sync_position WHERE task_id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = task_id }});
        defer result.deinit();
        if (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                const last_pk_s = row.get("last_pk") orelse "";
                const last_ut_s = row.get("last_update_time") orelse "";
                const last_et_s = row.get("last_event_time") orelse "";
                const stage_s = row.get("stage") orelse "full";
                const updated_s = row.get("updated_at") orelse "";

                return SyncPosition{
                    .task_id = try std.fmt.parseInt(i64, row.get("task_id") orelse "0", 10),
                    .last_pk = try allocator.dupe(u8, last_pk_s),
                    .last_update_time = try allocator.dupe(u8, last_ut_s),
                    .last_event_time = if (last_et_s.len == 0) null else try allocator.dupe(u8, last_et_s),
                    .stage = SyncStage.fromString(stage_s),
                    .updated_at = try allocator.dupe(u8, updated_s),
                };
            }
        }
        return SyncPosition{ .task_id = task_id };
    }

    pub fn save(store: *store_mod.MetaStore, pos: SyncPosition) !void {
        const sql: [:0]const u8 =
            "INSERT INTO sync_position (task_id, last_pk, last_update_time, last_event_time, stage, updated_at) " ++
            "VALUES ($1, $2, $3, $4, $5, datetime('now')) " ++
            "ON CONFLICT(task_id) DO UPDATE SET " ++
            "last_pk = excluded.last_pk, " ++
            "last_update_time = excluded.last_update_time, " ++
            "last_event_time = excluded.last_event_time, " ++
            "stage = excluded.stage, " ++
            "updated_at = excluded.updated_at";

        const event_param: zfinal.SqlParam = if (pos.last_event_time) |e| .{ .text = e } else .null;
        try store.db.execParams(sql, &.{
            .{ .int = pos.task_id },
            .{ .text = pos.last_pk },
            .{ .text = pos.last_update_time },
            event_param,
            .{ .text = pos.stage.toString() },
        });
    }

    pub fn delete(store: *store_mod.MetaStore, task_id: i64) !void {
        const sql: [:0]const u8 = "DELETE FROM sync_position WHERE task_id = $1";
        try store.db.execParams(sql, &.{.{ .int = task_id }});
    }
};
