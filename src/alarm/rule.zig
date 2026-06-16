//! 告警规则 CRUD + 查询

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const alarm_mod = @import("mod.zig");

const Service = struct {
    pub fn findAll(store: *meta.store.MetaStore, allocator: std.mem.Allocator) ![]alarm_mod.AlarmRule {
        const sql: [:0]const u8 = "SELECT id, alarm_type, threshold, webhook_url, is_enabled FROM alarm_config ORDER BY id";
        var result = try store.db.query(sql);
        defer result.deinit();
        var list = std.ArrayList(alarm_mod.AlarmRule).empty;
        errdefer { for (list.items) |*r| r.deinit(allocator); list.deinit(allocator); }
        while (result.next()) {
            if (result.getCurrentRowMap()) |row| try list.append(allocator, try rowToRule(allocator, row));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn findByType(store: *meta.store.MetaStore, allocator: std.mem.Allocator, atype: []const u8) ![]alarm_mod.AlarmRule {
        const sql: [:0]const u8 = "SELECT id, alarm_type, threshold, webhook_url, is_enabled FROM alarm_config WHERE alarm_type = $1 AND is_enabled = 1";
        var result = try store.db.queryParams(sql, &.{.{ .text = atype }});
        defer result.deinit();
        var list = std.ArrayList(alarm_mod.AlarmRule).empty;
        errdefer { for (list.items) |*r| r.deinit(allocator); list.deinit(allocator); }
        while (result.next()) {
            if (result.getCurrentRowMap()) |row| try list.append(allocator, try rowToRule(allocator, row));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn insert(store: *meta.store.MetaStore, alarm_type: []const u8, threshold: []const u8, webhook_url: []const u8) !i64 {
        const sql: [:0]const u8 = "INSERT INTO alarm_config (alarm_type, threshold, webhook_url, is_enabled) VALUES ($1, $2, $3, 1)";
        try store.db.execParams(sql, &.{ .{ .text = alarm_type }, .{ .text = threshold }, .{ .text = webhook_url } });
        return try store.db.lastInsertId();
    }

    pub fn update(store: *meta.store.MetaStore, id: i64, threshold: []const u8, webhook_url: []const u8) !void {
        const sql: [:0]const u8 = "UPDATE alarm_config SET threshold = $1, webhook_url = $2 WHERE id = $3";
        try store.db.execParams(sql, &.{ .{ .text = threshold }, .{ .text = webhook_url }, .{ .int = id } });
    }

    pub fn enable(store: *meta.store.MetaStore, id: i64, en: bool) !void {
        const sql: [:0]const u8 = "UPDATE alarm_config SET is_enabled = $1 WHERE id = $2";
        try store.db.execParams(sql, &.{ .{ .int = if (en) 1 else 0 }, .{ .int = id } });
    }

    pub fn delete(store: *meta.store.MetaStore, id: i64) !void {
        const sql: [:0]const u8 = "DELETE FROM alarm_config WHERE id = $1";
        try store.db.execParams(sql, &.{.{ .int = id }});
    }

    fn rowToRule(a: std.mem.Allocator, row: zfinal.ResultSet.RowMap) !alarm_mod.AlarmRule {
        return alarm_mod.AlarmRule{
            .id = try std.fmt.parseInt(i64, row.get("id") orelse "0", 10),
            .alarm_type = try a.dupe(u8, row.get("alarm_type") orelse ""),
            .threshold = try a.dupe(u8, row.get("threshold") orelse "{}"),
            .webhook_url = try a.dupe(u8, row.get("webhook_url") orelse ""),
            .is_enabled = try std.fmt.parseInt(i32, row.get("is_enabled") orelse "1", 10),
        };
    }
};

pub fn findAll(store: *meta.store.MetaStore, allocator: std.mem.Allocator) ![]alarm_mod.AlarmRule { return Service.findAll(store, allocator); }
pub fn findByType(store: *meta.store.MetaStore, allocator: std.mem.Allocator, atype: []const u8) ![]alarm_mod.AlarmRule { return Service.findByType(store, allocator, atype); }
pub fn insert(store: *meta.store.MetaStore, alarm_type: []const u8, threshold: []const u8, webhook_url: []const u8) !i64 { return Service.insert(store, alarm_type, threshold, webhook_url); }
pub fn update(store: *meta.store.MetaStore, id: i64, threshold: []const u8, webhook_url: []const u8) !void { return Service.update(store, id, threshold, webhook_url); }
pub fn enable(store: *meta.store.MetaStore, id: i64, en: bool) !void { return Service.enable(store, id, en); }

fn makeTestStore(allocator: std.mem.Allocator) !meta.store.MetaStore {
    return try meta.store.MetaStore.init(allocator, ":memory:");
}

test "alarm rule: insert/findAll/findByType roundtrip" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    const id1 = try insert(&store, "delay_warn", "{\"seconds\":30}", "https://hook/1");
    const id2 = try insert(&store, "task_fail", "{}", "https://hook/2");
    try std.testing.expect(id1 > 0 and id2 > 0 and id1 != id2);

    const all = try findAll(&store, a);
    defer {
        for (all) |*r| r.deinit(a);
        a.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("delay_warn", all[0].alarm_type);
    try std.testing.expectEqualStrings("task_fail", all[1].alarm_type);

    // findByType: 启用 is_enabled=1, 应该返回
    const delay_rules = try findByType(&store, a, "delay_warn");
    defer {
        for (delay_rules) |*r| r.deinit(a);
        a.free(delay_rules);
    }
    try std.testing.expectEqual(@as(usize, 1), delay_rules.len);
    try std.testing.expectEqualStrings("https://hook/1", delay_rules[0].webhook_url);
}

test "alarm rule: update and enable toggle" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    const id = try insert(&store, "conn_lost", "{}", "https://hook/x");
    try update(&store, id, "{\"v\":2}", "https://hook/y");

    const all = try findAll(&store, a);
    defer {
        for (all) |*r| r.deinit(a);
        a.free(all);
    }
    try std.testing.expectEqualStrings("{\"v\":2}", all[0].threshold);
    try std.testing.expectEqualStrings("https://hook/y", all[0].webhook_url);
    try std.testing.expectEqual(@as(i32, 1), all[0].is_enabled);

    // disable
    try enable(&store, id, false);
    const all2 = try findAll(&store, a);
    defer {
        for (all2) |*r| r.deinit(a);
        a.free(all2);
    }
    try std.testing.expectEqual(@as(i32, 0), all2[0].is_enabled);

    // findByType only returns enabled, so should be empty after disable
    const empty = try findByType(&store, a, "conn_lost");
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "alarm rule: delete removes rule" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    const id = try insert(&store, "delay_alert", "{}", "https://hook/d");
    try delete(&store, id);
    const all = try findAll(&store, a);
    defer a.free(all);
    try std.testing.expectEqual(@as(usize, 0), all.len);
}

test "alarm_type enum: all values have stable strings" {
    // 验证 AlarmType 的字符串表示 (用于 webhook JSON 和 trigger 匹配)
    try std.testing.expectEqualStrings("delay_warn", alarm_mod.AlarmType.delay_warn.toString());
    try std.testing.expectEqualStrings("delay_alert", alarm_mod.AlarmType.delay_alert.toString());
    try std.testing.expectEqualStrings("task_fail", alarm_mod.AlarmType.task_fail.toString());
    try std.testing.expectEqualStrings("conn_lost", alarm_mod.AlarmType.conn_lost.toString());
    try std.testing.expectEqualStrings("reconcile_diff", alarm_mod.AlarmType.reconcile_diff.toString());
}
pub fn delete(store: *meta.store.MetaStore, id: i64) !void { return Service.delete(store, id); }
