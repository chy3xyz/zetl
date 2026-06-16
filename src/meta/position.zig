//! 同步位点 - 伪 CDC 用 last_pk(全量) + last_update_time(增量)
//! 严格按 docs/superpowers/specs/2026-06-16-zetl-v1-design.md §2.1

const std = @import("std");
const zfinal = @import("zfinal");
const store_mod = @import("store.zig");

pub const SyncStage = enum {
    full, // 全量阶段 (主键分页)
    incremental, // 增量阶段 (update_time 游标, poll 模式)
    binlog, // MySQL binlog CDC 阶段

    pub fn toString(s: SyncStage) []const u8 {
        return switch (s) {
            .full => "full",
            .incremental => "incremental",
            .binlog => "binlog",
        };
    }

    pub fn fromString(s: []const u8) SyncStage {
        if (std.mem.eql(u8, s, "incremental")) return .incremental;
        if (std.mem.eql(u8, s, "binlog")) return .binlog;
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
    binlog_file: []const u8 = "",
    binlog_pos: i64 = 0,

    pub fn deinit(self: *SyncPosition, allocator: std.mem.Allocator) void {
        allocator.free(self.last_pk);
        self.last_pk = "";
        allocator.free(self.last_update_time);
        self.last_update_time = "";
        if (self.last_event_time) |e| {
            allocator.free(e);
            self.last_event_time = null;
        }
        allocator.free(self.updated_at);
        self.updated_at = "";
        allocator.free(self.binlog_file);
        self.binlog_file = "";
    }

    pub fn isInitial(self: *const SyncPosition) bool {
        return self.last_pk.len == 0 and self.last_update_time.len == 0 and self.binlog_file.len == 0;
    }
};

pub const Service = struct {
    pub fn load(store: *store_mod.MetaStore, allocator: std.mem.Allocator, task_id: i64) !SyncPosition {
        const sql: [:0]const u8 =
            "SELECT task_id, last_pk, last_update_time, last_event_time, stage, updated_at, " ++
            "binlog_file, binlog_pos FROM sync_position WHERE task_id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = task_id }});
        defer result.deinit();
        if (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                const last_pk_s = row.get("last_pk") orelse "";
                const last_ut_s = row.get("last_update_time") orelse "";
                const last_et_s = row.get("last_event_time") orelse "";
                const stage_s = row.get("stage") orelse "full";
                const updated_s = row.get("updated_at") orelse "";
                const binlog_file_s = row.get("binlog_file") orelse "";
                const binlog_pos_s = row.get("binlog_pos") orelse "0";

                var pos = SyncPosition{
                    .task_id = try std.fmt.parseInt(i64, row.get("task_id") orelse "0", 10),
                };
                errdefer pos.deinit(allocator);
                pos.last_pk = try allocator.dupe(u8, last_pk_s);
                pos.last_update_time = try allocator.dupe(u8, last_ut_s);
                pos.last_event_time = if (last_et_s.len == 0) null else try allocator.dupe(u8, last_et_s);
                pos.stage = SyncStage.fromString(stage_s);
                pos.updated_at = try allocator.dupe(u8, updated_s);
                pos.binlog_file = try allocator.dupe(u8, binlog_file_s);
                pos.binlog_pos = std.fmt.parseInt(i64, binlog_pos_s, 10) catch 0;
                return pos;
            }
        }
        return SyncPosition{ .task_id = task_id };
    }

    pub fn save(store: *store_mod.MetaStore, pos: SyncPosition) !void {
        const sql: [:0]const u8 =
            "INSERT INTO sync_position (task_id, last_pk, last_update_time, last_event_time, stage, updated_at, binlog_file, binlog_pos) " ++
            "VALUES ($1, $2, $3, $4, $5, datetime('now'), $6, $7) " ++
            "ON CONFLICT(task_id) DO UPDATE SET " ++
            "last_pk = excluded.last_pk, " ++
            "last_update_time = excluded.last_update_time, " ++
            "last_event_time = excluded.last_event_time, " ++
            "stage = excluded.stage, " ++
            "updated_at = excluded.updated_at, " ++
            "binlog_file = excluded.binlog_file, " ++
            "binlog_pos = excluded.binlog_pos";

        const event_param: zfinal.SqlParam = if (pos.last_event_time) |e| .{ .text = e } else .null;
        try store.db.execParams(sql, &.{
            .{ .int = pos.task_id },
            .{ .text = pos.last_pk },
            .{ .text = pos.last_update_time },
            event_param,
            .{ .text = pos.stage.toString() },
            .{ .text = pos.binlog_file },
            .{ .int = pos.binlog_pos },
        });
    }

    pub fn delete(store: *store_mod.MetaStore, task_id: i64) !void {
        const sql: [:0]const u8 = "DELETE FROM sync_position WHERE task_id = $1";
        try store.db.execParams(sql, &.{.{ .int = task_id }});
    }
};

test "SyncPosition load/save roundtrip" {
    const a = std.testing.allocator;
    var store = try store_mod.MetaStore.init(a, ":memory:");
    defer store.deinit();
    try store.createAllTables();

    var pos = SyncPosition{
        .task_id = 1,
        .last_pk = try a.dupe(u8, "100"),
        .last_update_time = try a.dupe(u8, "2026-01-01 00:00:00"),
        .binlog_file = try a.dupe(u8, "mysql-bin.000001"),
        .binlog_pos = 1234,
        .stage = .binlog,
    };
    defer pos.deinit(a);
    try Service.save(&store, pos);

    var loaded = try Service.load(&store, a, 1);
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings("100", loaded.last_pk);
    try std.testing.expectEqualStrings("mysql-bin.000001", loaded.binlog_file);
    try std.testing.expectEqual(@as(i64, 1234), loaded.binlog_pos);
    try std.testing.expectEqual(SyncStage.binlog, loaded.stage);
}

test "SyncPosition deinit is idempotent" {
    const a = std.testing.allocator;
    var pos = SyncPosition{ .task_id = 1 };
    pos.deinit(a);
    pos.deinit(a); // should not double-free
    try std.testing.expectEqualStrings("", pos.last_pk);
    try std.testing.expectEqual(@as(?[]const u8, null), pos.last_event_time);
}
