//! 用户模型 - V2.2
const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const pwd = @import("bcrypt.zig");

pub const User = struct {
    id: i64, username: []const u8, display_name: []const u8, email: []const u8, is_active: i32, created_at: []const u8, last_login_at: []const u8,
    pub fn deinit(self: *User, a: std.mem.Allocator) void { a.free(self.username); a.free(self.display_name); a.free(self.email); a.free(self.created_at); a.free(self.last_login_at); }
};

fn rowTo(a: std.mem.Allocator, row: zfinal.ResultSet.RowMap) !User {
    return .{
        .id = try std.fmt.parseInt(i64, row.get("id") orelse "0", 10),
        .username = try a.dupe(u8, row.get("username") orelse ""),
        .display_name = try a.dupe(u8, row.get("display_name") orelse ""),
        .email = try a.dupe(u8, row.get("email") orelse ""),
        .is_active = try std.fmt.parseInt(i32, row.get("is_active") orelse "1", 10),
        .created_at = try a.dupe(u8, row.get("created_at") orelse ""),
        .last_login_at = try a.dupe(u8, row.get("last_login_at") orelse ""),
    };
}

pub fn findAll(store: *meta.store.MetaStore, a: std.mem.Allocator) ![]User {
    var r = try store.db.query("SELECT id, username, COALESCE(display_name,'') dn, COALESCE(email,'') em, is_active, created_at, COALESCE(last_login_at,'') ll FROM user ORDER BY id");
    defer r.deinit();
    var l = std.ArrayList(User).empty; defer l.deinit(a);
    while (r.next()) { if (r.getCurrentRowMap()) |rm| try l.append(a, try rowTo(a, rm)); }
    return l.toOwnedSlice(a);
}

pub fn createUser(store: *meta.store.MetaStore, a: std.mem.Allocator, username: []const u8, password: []const u8, dn: []const u8, email: []const u8) !i64 {
    const h = try pwd.hashPassword(a, password);
    defer a.free(h);
    try store.db.execParams("INSERT INTO user (username, password_hash, display_name, email) VALUES ($1,$2,$3,$4)", &.{.{.text=username},.{.text=h},.{.text=dn},.{.text=email}});
    return try store.db.lastInsertId();
}

pub fn verifyUserPassword(store: *meta.store.MetaStore, username: []const u8, password: []const u8) bool {
    var r = store.db.queryParams("SELECT password_hash FROM user WHERE username=$1 AND is_active=1", &.{.{.text=username}}) catch return false;
    defer r.deinit();
    if (r.next()) {
        const hash = r.getText(0) orelse return false;
        return pwd.verifyPassword(password, hash);
    }
    return false;
}

pub fn updateLoginTime(store: *meta.store.MetaStore, username: []const u8) !void {
    try store.db.execParams("UPDATE user SET last_login_at=datetime('now') WHERE username=$1", &.{.{.text=username}});
}

/// 把 [meta] 引导账号同步进 user 表并绑定 admin 角色.
/// 全新部署时 user 表为空, RBAC 中间件按 user 表校验 — 缺此同步会导致
/// 引导账号登录成功但所有受保护端点 403 ("用户不存在或已停用").
/// 幂等: 该 username 已存在 (无论 is_active) 则跳过.
pub fn ensureBootstrapAdmin(store: *meta.store.MetaStore, a: std.mem.Allocator, username: []const u8, password: []const u8) !void {
    var r = try store.db.queryParams("SELECT id FROM user WHERE username=$1", &.{.{ .text = username }});
    defer r.deinit();
    if (r.next()) return;

    const uid = try createUser(store, a, username, password, "bootstrap admin", "");
    const rid = (try @import("role.zig").getRoleIdByName(store, "admin")) orelse return error.AdminRoleMissing;
    try store.db.execParams("INSERT OR IGNORE INTO user_role (user_id, role_id) VALUES ($1,$2)", &.{ .{ .int = uid }, .{ .int = rid } });
}

fn makeTestStore(allocator: std.mem.Allocator) !meta.store.MetaStore {
    return try meta.store.MetaStore.init(allocator, ":memory:");
}

test "createUser: insert returns positive id" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    const id = try createUser(&store, a, "alice", "secret", "Alice", "alice@example.com");
    try std.testing.expect(id > 0);
}

test "createUser: stored password is hashed not plaintext" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    _ = try createUser(&store, a, "bob", "plain-pw", "", "");
    var r = try store.db.queryParams("SELECT password_hash FROM user WHERE username=$1", &.{.{.text="bob"}});
    defer r.deinit();
    if (r.next()) {
        const hash = r.getText(0).?;
        try std.testing.expect(!std.mem.eql(u8, hash, "plain-pw"));
        try std.testing.expect(std.mem.indexOfScalar(u8, hash, ':') != null);
    } else {
        return error.TestFailed;
    }
}

test "findAll: lists all users" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    _ = try createUser(&store, a, "u1", "p1", "", "");
    _ = try createUser(&store, a, "u2", "p2", "", "");
    _ = try createUser(&store, a, "u3", "p3", "", "");

    const users = try findAll(&store, a);
    defer {
        for (users) |*u| u.deinit(a);
        a.free(users);
    }
    try std.testing.expectEqual(@as(usize, 3), users.len);
    try std.testing.expectEqualStrings("u1", users[0].username);
    try std.testing.expectEqualStrings("u2", users[1].username);
    try std.testing.expectEqualStrings("u3", users[2].username);
}

test "findAll: empty store returns empty slice" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    const users = try findAll(&store, a);
    defer a.free(users);
    try std.testing.expectEqual(@as(usize, 0), users.len);
}

test "verifyUserPassword: correct password returns true" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    _ = try createUser(&store, a, "carol", "goodpass", "", "");
    try std.testing.expect(verifyUserPassword(&store, "carol", "goodpass"));
}

test "verifyUserPassword: wrong password returns false" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    _ = try createUser(&store, a, "dave", "rightpw", "", "");
    try std.testing.expect(!verifyUserPassword(&store, "dave", "wrongpw"));
}

test "verifyUserPassword: nonexistent user returns false" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try std.testing.expect(!verifyUserPassword(&store, "ghost", "whatever"));
}

test "updateLoginTime: sets last_login_at to non-empty" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    _ = try createUser(&store, a, "eve", "pw", "", "");
    try updateLoginTime(&store, "eve");

    var r = try store.db.queryParams("SELECT last_login_at FROM user WHERE username=$1", &.{.{.text="eve"}});
    defer r.deinit();
    if (r.next()) {
        const ts = r.getText(0) orelse "";
        try std.testing.expect(ts.len > 0);
    } else {
        return error.TestFailed;
    }
}

test "ensureBootstrapAdmin: creates admin user, binds admin role, idempotent" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    try @import("role.zig").initRoles(&store);

    try ensureBootstrapAdmin(&store, a, "admin", "admin123");
    // 幂等: 第二次不报错不重复
    try ensureBootstrapAdmin(&store, a, "admin", "admin123");

    // RBAC 主路径可用: 密码校验通过
    try std.testing.expect(verifyUserPassword(&store, "admin", "admin123"));
    // 拿 uid 校验 admin 权限 (*)
    var r = try store.db.query("SELECT id FROM user WHERE username='admin'");
    defer r.deinit();
    try std.testing.expect(r.next());
    const uid = (try r.getInt(0)).?;
    const role_mod = @import("role.zig");
    const perms = try role_mod.getUserPermissions(&store, a, uid);
    defer a.free(perms);
    try std.testing.expectEqualStrings("*", perms);
}
