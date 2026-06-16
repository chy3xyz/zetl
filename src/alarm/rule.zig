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
pub fn delete(store: *meta.store.MetaStore, id: i64) !void { return Service.delete(store, id); }
