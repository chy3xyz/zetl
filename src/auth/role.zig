//! 角色 + 权限模型 - V2.2
const std = @import("std");
const meta = @import("../meta/mod.zig");

pub fn initRoles(store: *meta.store.MetaStore) !void {
    const c = try count(store);
    if (c > 0) return;
    const roles = [_]struct { n: []const u8, d: []const u8, p: []const u8 }{
        .{ .n = "admin", .d = "超级管理员", .p = "*" },
        .{ .n = "operator", .d = "运维操作员", .p = "datasource:*,task:*,reconcile:run,alarm:*,audit:*" },
        .{ .n = "viewer", .d = "只读观察者", .p = "datasource:read,task:read,monitor:read,reconcile:read,audit:read" },
    };
    for (roles) |r| { try createRole(store, r.n, r.d, r.p); }
}

fn count(store: *meta.store.MetaStore) !i64 {
    var r = try store.db.query("SELECT COUNT(*) FROM role");
    defer r.deinit();
    if (r.next()) { if (try r.getInt(0)) |c| return c; }
    return 0;
}

fn createRole(store: *meta.store.MetaStore, name: []const u8, desc: []const u8, perms: []const u8) !void {
    try store.db.execParams("INSERT INTO role (role_name, description) VALUES ($1,$2)", &.{.{.text=name},.{.text=desc}});
    const rid = try store.db.lastInsertId();
    var it = std.mem.splitScalar(u8, perms, ',');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " ");
        if (t.len > 0) try store.db.execParams("INSERT INTO role_permission (role_id, permission) VALUES ($1,$2)", &.{.{.int=rid},.{.text=t}});
    }
}

pub fn getUserPermissions(store: *meta.store.MetaStore, a: std.mem.Allocator, uid: i64) ![]u8 {
    var r = try store.db.queryParams(
        "SELECT rp.permission FROM role_permission rp JOIN user_role ur ON rp.role_id=ur.role_id WHERE ur.user_id=$1",
        &.{.{.int=uid}});
    defer r.deinit();
    var l = std.ArrayList([]const u8).empty; defer l.deinit(a);
    while (r.next()) {
        if (r.getText(0)) |p| {
            if (std.mem.eql(u8, p, "*")) return a.dupe(u8, "*");
            try l.append(a, try a.dupe(u8, p));
        }
    }
    if (l.items.len == 0) return a.dupe(u8, "");
    var b = std.ArrayList(u8).empty; defer b.deinit(a);
    for (l.items, 0..) |p, i| { if (i>0) try b.append(a, ','); try b.appendSlice(a, p); }
    return b.toOwnedSlice(a);
}
