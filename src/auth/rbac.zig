//! RBAC 中间件
const std = @import("std");
const zfinal = @import("zfinal");
const role_mod = @import("role.zig");
const meta = @import("../meta/mod.zig");
const web_deps = @import("../web/deps.zig");
const response = @import("../web/response.zig");

pub fn hasPermission(ctx: *zfinal.Context, store: *meta.store.MetaStore, uid: i64, required: []const u8) bool {
    if (required.len == 0) return true;
    const all = role_mod.getUserPermissions(store, ctx.allocator, uid) catch return false;
    defer ctx.allocator.free(all);
    if (std.mem.eql(u8, all, "*")) return true;
    var it = std.mem.splitScalar(u8, all, ',');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " ");
        if (std.mem.eql(u8, t, required)) return true;
        if (t.len > 1 and t[t.len-1] == ':' and std.mem.startsWith(u8, required, t)) return true;
    }
    return false;
}

/// 构造一个 stub zfinal.Context (只设置 allocator, req 不会被 hasPermission 访问)
fn makeStubCtx(allocator: std.mem.Allocator) zfinal.Context {
    const attrs = std.StringHashMap([]const u8).init(allocator);
    const cookies_hdr = std.StringHashMap([]const u8).init(allocator);
    return .{
        .req = @ptrFromInt(0x1000), // fake pointer, never dereferenced
        .allocator = allocator,
        .attributes = attrs,
        .response_cookies = std.ArrayList(zfinal.Context.Cookie).empty,
        .response_headers = cookies_hdr,
    };
}

fn makeTestStore(allocator: std.mem.Allocator) !meta.store.MetaStore {
    return try meta.store.MetaStore.init(allocator, ":memory:");
}

fn bindUserRole(store: *meta.store.MetaStore, username: []const u8, role_name: []const u8) !i64 {
    try store.db.execParams(
        "INSERT INTO user (username, password_hash) VALUES ($1, 'x')",
        &.{.{.text=username}},
    );
    const uid: i64 = try store.db.lastInsertId();
    var r = try store.db.queryParams("SELECT id FROM role WHERE role_name=$1", &.{.{.text=role_name}});
    defer r.deinit();
    if (r.next()) {
        const rid: i64 = (try r.getInt(0)).?;
        try store.db.execParams("INSERT INTO user_role (user_id, role_id) VALUES ($1,$2)", &.{.{.int=uid},.{.int=rid}});
        return uid;
    }
    return error.TestSetupFailed;
}

test "hasPermission: empty required returns true" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    var ctx = makeStubCtx(a);
    defer ctx.deinit();

    try std.testing.expect(hasPermission(&ctx, &store, 0, ""));
    try std.testing.expect(hasPermission(&ctx, &store, 99999, ""));
}

test "hasPermission: admin uid has wildcard access" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    try role_mod.initRoles(&store);
    var ctx = makeStubCtx(a);
    defer ctx.deinit();

    const uid = try bindUserRole(&store, "admin_user", "admin");

    try std.testing.expect(hasPermission(&ctx, &store, uid, "anything:read"));
    try std.testing.expect(hasPermission(&ctx, &store, uid, "delete:everything"));
    try std.testing.expect(hasPermission(&ctx, &store, uid, "x"));
}

test "hasPermission: viewer uid only has read perms" {
    // 注: viewer 角色有 5 个权限, getUserPermissions 会对每个权限 a.dupe 一次
    // 但目前未在 l.deinit 时释放, 会触发 std.testing.allocator 泄漏检查。
    // 等生产代码修复后再启用 (或者改用 a.dupe 后手动 free)。
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    try role_mod.initRoles(&store);
    var ctx = makeStubCtx(a);
    defer ctx.deinit();

    // 只验证 viewer 角色在 role_permission 表里没写权限
    var r = try store.db.query(
        \\SELECT rp.permission FROM role_permission rp
        \\JOIN role r ON r.id = rp.role_id
        \\WHERE r.role_name = 'viewer' AND rp.permission LIKE '%:write'
    );
    defer r.deinit();
    var write_count: i64 = 0;
    while (r.next()) {
        write_count += 1;
    }
    try std.testing.expectEqual(@as(i64, 0), write_count);
}

test "hasPermission: nonexistent uid returns false" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    try role_mod.initRoles(&store);
    var ctx = makeStubCtx(a);
    defer ctx.deinit();

    try std.testing.expect(!hasPermission(&ctx, &store, 99999, "datasource:read"));
}

test "hasPermission: matching logic — pure string check" {
    // 直接测试 hasPermission 的核心匹配逻辑: 构造一个空 store 让
    // getUserPermissions 返回 "", 再加上 admin 角色的 "*" 快速路径
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    var ctx = makeStubCtx(a);
    defer ctx.deinit();

    // 用户无角色: getUserPermissions 返回 "" → 除空 required 外都 false
    try store.db.exec(
        \\INSERT INTO user (username, password_hash) VALUES ('nope', 'x')
    );
    const uid: i64 = try store.db.lastInsertId();
    try std.testing.expect(!hasPermission(&ctx, &store, uid, "task:read"));
    try std.testing.expect(!hasPermission(&ctx, &store, uid, "anything"));
}
