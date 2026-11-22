//! 鉴权 + 用户/角色 Handler (V1 简易 token + V2.2 RBAC 合并)
//! 路由: /api/v1/auth/*, /api/v1/user, /api/v1/role
//!
//! login: 优先查 user 表 (bcrypt 校验), 未命中回退 config 引导账号
//!   (原 V1 静态 login 已删除, 逻辑被 login 的 fallback 分支完全覆盖)

const std = @import("std");
const zfinal = @import("zfinal");
const au = @import("../../auth/user.zig");
const deps = @import("../deps.zig");
const response = @import("../response.zig");

/// POST /api/v1/auth/login
pub fn login(ctx: *zfinal.Context) !void {
    const parsed = ctx.parseJsonBody(struct { username: []const u8, password: []const u8 }) catch {
        try response.fail(ctx, .param_error, "请求体不合法");
        return;
    };
    defer parsed.deinit();
    const v = parsed.value;
    if (au.verifyUserPassword(deps.store_ptr, v.username, v.password)) {
        au.updateLoginTime(deps.store_ptr, v.username) catch {};
        const t = try deps.tokenMgr.generate();
        // 绑定 token → username, 让 permissionInterceptor 能反查用户身份
        deps.bindTokenToUser(t, v.username) catch {};
        try response.ok(ctx, .{ .token = t, .expires_in = 3600, .username = v.username });
        return;
    }
    // fallback V1 admin
    if (std.mem.eql(u8, v.username, deps.config_ptr.meta.admin_username) and
        std.mem.eql(u8, v.password, deps.config_ptr.meta.admin_password))
    {
        const t = try deps.tokenMgr.generate();
        deps.bindTokenToUser(t, v.username) catch {};
        try response.ok(ctx, .{ .token = t, .expires_in = 3600, .username = v.username });
        return;
    }
    try response.fail(ctx, .permission_denied, "账号或密码错误");
}

/// GET /api/v1/auth/me
pub fn me(ctx: *zfinal.Context) !void {
    const token = response.extractToken(ctx) orelse {
        try response.fail(ctx, .permission_denied, "未携带 token");
        return;
    };
    if (!deps.tokenMgr.exists(token)) {
        try response.fail(ctx, .permission_denied, "token 无效或已过期");
        return;
    }
    // token → username 反查 (RBAC 用户返回真实账号; 引导账号 fallback admin)
    const username = deps.getUsernameByToken(token) orelse deps.config_ptr.meta.admin_username;
    try response.ok(ctx, .{
        .username = username,
    });
}

/// POST /api/v1/auth/logout
/// V1: 客户端丢弃 token 即可, 服务端 token 由 TTL 自动过期 (1h)
/// 主动销毁走 validate() 在某些 zfinal 版本下会卡住 (mutex + cleanExpired 死锁)
/// 如需服务端立即失效, 改用 exists() + 自定义删除
pub fn logout(ctx: *zfinal.Context) !void {
    const token = response.extractToken(ctx) orelse {
        try response.fail(ctx, .permission_denied, "未携带 token");
        return;
    };
    // 解除 token → username 绑定 (RBAC 中间件用)
    deps.unbindToken(token);
    // V1 简化: 客户端丢弃 token, 服务端在 TTL 过期后自动清理
    try response.ok(ctx, .{ .logged_out = true, .note = "请在客户端丢弃 token, 服务端将在 TTL 过期后清理" });
}

/// GET /api/v1/user
pub fn listUsers(ctx: *zfinal.Context) !void {
    const a = ctx.allocator;
    const us = au.findAll(deps.store_ptr, a) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer {
        for (us) |*u| u.deinit(a);
        a.free(us);
    }
    const It = struct { id: i64, username: []const u8, display_name: []const u8, email: []const u8, is_active: i32, created_at: []const u8, last_login_at: []const u8 };
    var items = try a.alloc(It, us.len);
    defer a.free(items);
    for (us, 0..) |u, i| items[i] = .{ .id = u.id, .username = u.username, .display_name = u.display_name, .email = u.email, .is_active = u.is_active, .created_at = u.created_at, .last_login_at = u.last_login_at };
    try response.ok(ctx, .{ .total = @as(i64, @intCast(us.len)), .list = items });
}

/// POST /api/v1/user
pub fn createUser(ctx: *zfinal.Context) !void {
    const a = ctx.allocator;
    const p = ctx.parseJsonBody(struct { username: []const u8, password: []const u8, display_name: []const u8 = "", email: []const u8 = "" }) catch {
        try response.fail(ctx, .param_error, "请求体不合法");
        return;
    };
    defer p.deinit();
    const v = p.value;
    const id = au.createUser(deps.store_ptr, a, v.username, v.password, v.display_name, v.email) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    try response.ok(ctx, .{ .id = id, .username = v.username });
}

/// GET /api/v1/role
pub fn listRoles(ctx: *zfinal.Context) !void {
    const a = ctx.allocator;
    var r = deps.store_ptr.db.query("SELECT id, role_name, COALESCE(description,'') d FROM role") catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer r.deinit();
    const It = struct { id: i64, role_name: []const u8, description: []const u8 };
    var items = std.ArrayList(It).empty;
    defer items.deinit(a);
    while (r.next()) {
        if (r.getCurrentRowMap()) |rm| try items.append(a, .{ .id = try std.fmt.parseInt(i64, rm.get("id") orelse "0", 10), .role_name = try a.dupe(u8, rm.get("role_name") orelse ""), .description = try a.dupe(u8, rm.get("d") orelse "") });
    }
    try response.ok(ctx, .{ .total = @as(i64, @intCast(items.items.len)), .list = items.items });
}
