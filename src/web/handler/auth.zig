//! 鉴权 Handler (V1 简易 token)
//! 路由: /api/v1/auth/*

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../deps.zig");
const response = @import("../response.zig");

/// POST /api/v1/auth/login
pub fn login(ctx: *zfinal.Context) !void {
    const parsed = ctx.parseJsonBody(struct {
        username: []const u8,
        password: []const u8,
    }) catch {
        try response.fail(ctx, .param_error, "请求体不合法");
        return;
    };
    defer parsed.deinit();

    const v = parsed.value;
    if (!std.mem.eql(u8, v.username, deps.config_ptr.meta.admin_username) or
        !std.mem.eql(u8, v.password, deps.config_ptr.meta.admin_password))
    {
        try response.fail(ctx, .permission_denied, "账号或密码错误");
        return;
    }

    const token = try deps.tokenMgr.generate();
    try response.ok(ctx, .{ .token = token, .expires_in = 3600 });
}

/// GET /api/v1/auth/me  (示例: 需鉴权接口)
pub fn me(ctx: *zfinal.Context) !void {
    const token = response.extractToken(ctx) orelse {
        try response.fail(ctx, .permission_denied, "未携带 token");
        return;
    };
    if (!deps.tokenMgr.exists(token)) {
        try response.fail(ctx, .permission_denied, "token 无效或已过期");
        return;
    }
    try response.ok(ctx, .{
        .username = deps.config_ptr.meta.admin_username,
    });
}

/// POST /api/v1/auth/logout
/// V1: 客户端丢弃 token 即可, 服务端 token 由 TTL 自动过期 (1h)
/// 主动销毁走 validate() 在某些 zfinal 版本下会卡住 (mutex + cleanExpired 死锁)
/// 如需服务端立即失效, 改用 exists() + 自定义删除
pub fn logout(ctx: *zfinal.Context) !void {
    _ = response.extractToken(ctx) orelse {
        try response.fail(ctx, .permission_denied, "未携带 token");
        return;
    };
    // V1 简化: 客户端丢弃 token, 服务端在 TTL 过期后自动清理
    try response.ok(ctx, .{ .logged_out = true, .note = "请在客户端丢弃 token, 服务端将在 TTL 过期后清理" });
}
