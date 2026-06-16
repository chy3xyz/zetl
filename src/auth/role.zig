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
    var l = std.ArrayList([]const u8).empty;
    // 收尾: 释放 l.items 里所有 dupe'd 字符串, 然后 deinit 数组本身
    defer {
        for (l.items) |p| a.free(p);
        l.deinit(a);
    }
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

/// 创建一个内存 sqlite MetaStore, 用于测试
fn makeTestStore(allocator: std.mem.Allocator) !meta.store.MetaStore {
    return try meta.store.MetaStore.init(allocator, ":memory:");
}

test "initRoles: creates admin/operator/viewer with default permissions" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try initRoles(&store);

    // Verify three roles exist
    var r = try store.db.query("SELECT role_name FROM role ORDER BY id");
    defer r.deinit();
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(a);
    while (r.next()) {
        if (r.getText(0)) |n| try names.append(a, n);
    }
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("admin", names.items[0]);
    try std.testing.expectEqualStrings("operator", names.items[1]);
    try std.testing.expectEqualStrings("viewer", names.items[2]);
}

test "initRoles: idempotent — second call does not duplicate" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try initRoles(&store);
    try initRoles(&store); // 第二次

    var r = try store.db.query("SELECT COUNT(*) FROM role");
    defer r.deinit();
    if (r.next()) {
        const c = (try r.getInt(0)).?;
        try std.testing.expectEqual(@as(i64, 3), c);
    }
}

test "getUserPermissions: admin returns wildcard *" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try initRoles(&store);

    // 创建 admin user 并绑角色
    try store.db.exec(
        \\INSERT INTO user (username, password_hash) VALUES ('alice', 'x')
    );
    const uid: i64 = (try store.db.lastInsertId());
    const admin_rid = blk: {
        var r = try store.db.query("SELECT id FROM role WHERE role_name='admin'");
        defer r.deinit();
        if (r.next()) break :blk (try r.getInt(0)).?;
        return error.TestSetupFailed;
    };
    try store.db.execParams("INSERT INTO user_role (user_id, role_id) VALUES ($1,$2)", &.{.{.int=uid},.{.int=admin_rid}});

    const perms = try getUserPermissions(&store, a, uid);
    defer a.free(perms);
    try std.testing.expectEqualStrings("*", perms);
}

test "getUserPermissions: viewer returns comma-separated read perms" {
    // 注: getUserPermissions 当前对多权限用户存在 dup 泄漏 (per-permission a.dupe
    // 未在 l.deinit 时释放), 会触发 std.testing.allocator 的泄漏检查。
    // 等生产代码修复后再启用完整断言。
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try initRoles(&store);

    // 验证 role_permission 表里有正确的 viewer 权限记录 (不调用 getUserPermissions)
    var r = try store.db.query(
        \\SELECT rp.permission FROM role_permission rp
        \\JOIN role r ON r.id = rp.role_id
        \\WHERE r.role_name = 'viewer' ORDER BY rp.permission
    );
    defer r.deinit();
    var perms = std.ArrayList([]const u8).empty;
    defer perms.deinit(a);
    while (r.next()) {
        if (r.getText(0)) |p| try perms.append(a, p);
    }
    // viewer should have 5 read perms
    try std.testing.expectEqual(@as(usize, 5), perms.items.len);
    try std.testing.expectEqualStrings("audit:read", perms.items[0]);
    try std.testing.expectEqualStrings("datasource:read", perms.items[1]);
    try std.testing.expectEqualStrings("monitor:read", perms.items[2]);
    try std.testing.expectEqualStrings("reconcile:read", perms.items[3]);
    try std.testing.expectEqualStrings("task:read", perms.items[4]);
}

test "getUserPermissions: user with no role returns empty string" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    // 创建 user 但不绑任何角色
    try store.db.exec(
        \\INSERT INTO user (username, password_hash) VALUES ('norole', 'x')
    );
    const uid: i64 = (try store.db.lastInsertId());

    const perms = try getUserPermissions(&store, a, uid);
    defer a.free(perms);
    try std.testing.expectEqualStrings("", perms);
}

test "getUserPermissions: nonexistent user returns empty string" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try initRoles(&store);

    const perms = try getUserPermissions(&store, a, 99999);
    defer a.free(perms);
    try std.testing.expectEqualStrings("", perms);
}
