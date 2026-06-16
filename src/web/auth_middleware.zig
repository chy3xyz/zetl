//! 鉴权中间件 - 校验 Bearer Token + RBAC 权限校验
//! 用法: 在 web/routes.zig 的 getWithInterceptors/postWithInterceptors 上挂载

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("deps.zig");
const response = @import("response.zig");
const rbac = @import("../auth/rbac.zig");
const meta = @import("../meta/mod.zig");

/// 不需要鉴权的路径前缀
pub fn isPublicPath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/api/v1/auth/login")) return true;
    if (std.mem.eql(u8, path, "/api/v1/auth/logout")) return true;
    if (std.mem.eql(u8, path, "/health")) return true;
    if (std.mem.eql(u8, path, "/health/live")) return true;
    if (std.mem.eql(u8, path, "/health/ready")) return true;
    if (std.mem.eql(u8, path, "/metrics")) return true;
    if (std.mem.eql(u8, path, "/")) return true;
    if (std.mem.startsWith(u8, path, "/admin")) return true;
    return false;
}

/// Interceptor.before 函数: 校验 token
/// 返回 true = 继续, false = 已自行响应 (阻止 handler)
pub fn checkAuth(ctx: *zfinal.Context) anyerror!bool {
    if (isPublicPath(ctx.req.head.target)) return true;

    const token = response.extractToken(ctx);
    if (token == null) {
        ctx.res_status = .unauthorized;
        try response.fail(ctx, .permission_denied, "未携带 token");
        return false;
    }
    if (!deps.tokenMgr.exists(token.?)) {
        ctx.res_status = .unauthorized;
        try response.fail(ctx, .permission_denied, "token 无效或已过期");
        return false;
    }
    return true;
}

/// 构造鉴权 Interceptor (V1: 简化, 只用 before)
pub fn authInterceptor() zfinal.Interceptor {
    return .{ .name = "auth", .before = checkAuth };
}

// ============================================================================
// RBAC 权限中间件 (P1 任务 1.1)
// ============================================================================
//
// 设计要点:
// 1. 工厂 permissionInterceptor(perm) 在编译期把 perm 字符串嵌入 Interceptor.before 的闭包内层结构体;
//    由于 perm 是 comptime 参数, 生成的 before 函数对每个权限字符串都是独立的, 不需要运行时查表.
// 2. before 函数体里:
//    a) token 校验 (由 authInterceptor 负责, 这里假设已通过)
//    b) token → username 反查 (web_deps.token_user_map)
//    c) username → uid 反查 (查 user 表)
//    d) 调用 rbac.hasPermission(ctx, store, uid, perm) 做实际匹配
// 3. 失败统一返回 false, 由 zfinal chain 停止后续 handler.
//    响应通过 response.fail 写入 (JSON 格式, code=permission_denied).
//
// 权限字符串规范: "资源:动作", 例如
//   datasource:read, datasource:write, datasource:delete
//   task:read, task:write, task:start, task:stop, task:delete
//   reconcile:read, reconcile:run
//   alarm:read, alarm:write
//   audit:read
//   user:read, user:write
//   role:read, role:write
// 通配: "*" 表示所有权限; 角色也支持 "datasource:*" 这种前缀通配 (rbac.hasPermission 已实现).

/// 根据 username 查 user.id (返回 null = 用户不存在)
fn findUidByUsername(store: *meta.store.MetaStore, _: std.mem.Allocator, username: []const u8) !?i64 {
    var r = try store.db.queryParams(
        "SELECT id FROM user WHERE username=$1 AND is_active=1",
        &.{.{ .text = username }},
    );
    defer r.deinit();
    if (r.next()) {
        if (try r.getInt(0)) |uid| return uid;
    }
    return null;
}

/// 内部统一的权限检查函数 — 接受运行时 perm 字符串.
/// (工厂用 comptime perm + 这个 runtime 入口, 复用逻辑)
fn doPermissionCheck(ctx: *zfinal.Context, perm: []const u8) anyerror!bool {
    if (perm.len == 0) return true; // 空权限 = 不限制

    const token = response.extractToken(ctx) orelse {
        ctx.res_status = .unauthorized;
        try response.fail(ctx, .permission_denied, "未携带 token");
        return false;
    };
    if (!deps.tokenMgr.exists(token)) {
        ctx.res_status = .unauthorized;
        try response.fail(ctx, .permission_denied, "token 无效或已过期");
        return false;
    }

    const username = deps.getUsernameByToken(token) orelse {
        ctx.res_status = .unauthorized;
        try response.fail(ctx, .permission_denied, "token 未绑定用户, 请重新登录");
        return false;
    };

    const uid = (findUidByUsername(deps.store_ptr, ctx.allocator, username) catch {
        ctx.res_status = .internal_server_error;
        try response.fail(ctx, .system_error, "查询用户失败");
        return false;
    }) orelse {
        ctx.res_status = .unauthorized;
        try response.fail(ctx, .permission_denied, "用户不存在或已停用");
        return false;
    };

    if (!rbac.hasPermission(ctx, deps.store_ptr, uid, perm)) {
        ctx.res_status = .forbidden;
        // 拼一个明确的错误消息: "权限不足, 需要: <perm>"
        // 不用 std.fmt.allocPrint (省一次分配), 直接用 renderJson + 静态拼接
        const body = .{
            .code = @intFromEnum(response.Code.permission_denied),
            .msg = "权限不足",
            .data = .{ .required = perm },
        };
        try ctx.renderJson(body);
        return false;
    }
    return true;
}

/// 权限拦截器工厂 — P1 任务 1.1 核心 API
/// 用法: `auth_mw.permissionInterceptor("datasource:write")`
/// perm 必须是 comptime 字符串字面量, 才能嵌入 before 的内层结构体 (编译期唯一化).
pub fn permissionInterceptor(comptime perm: []const u8) zfinal.Interceptor {
    return .{
        .name = "perm:" ++ perm,
        .before = struct {
            fn check(ctx: *zfinal.Context) anyerror!bool {
                // comptime perm 在闭包里是字面量, 直接传给 runtime 入口
                return doPermissionCheck(ctx, perm);
            }
        }.check,
    };
}

test "isPublicPath" {
    try std.testing.expect(isPublicPath("/api/v1/auth/login"));
    try std.testing.expect(isPublicPath("/health"));
    try std.testing.expect(isPublicPath("/"));
    try std.testing.expect(isPublicPath("/admin/datasource"));
    try std.testing.expect(!isPublicPath("/api/v1/datasource/list"));
    try std.testing.expect(!isPublicPath("/api/v1/task/list"));
}

test "permissionInterceptor: factory creates interceptor with correct name" {
    const intc = permissionInterceptor("datasource:write");
    try std.testing.expectEqualStrings("perm:datasource:write", intc.name);
    try std.testing.expect(intc.before != null);
}

test "permissionInterceptor: each perm produces distinct interceptor" {
    const a = permissionInterceptor("a");
    const b = permissionInterceptor("b");
    try std.testing.expect(a.before != b.before); // 函数指针不同 (comptime 唯一化)
    try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
}

test "permissionInterceptor: same perm produces interceptor with matching name" {
    const a = permissionInterceptor("task:read");
    const b = permissionInterceptor("task:read");
    try std.testing.expectEqualStrings(a.name, b.name);
}

test "permissionInterceptor: perm string with colon is preserved in name" {
    const intc = permissionInterceptor("reconcile:run");
    try std.testing.expectEqualStrings("perm:reconcile:run", intc.name);
}

test "permissionInterceptor: factory works with all P1 perm categories" {
    // 覆盖任务规范中定义的所有权限字符串
    // 用 inline for 让每个 perm 在编译期展开 (满足 comptime 参数要求)
    const perms = [_][]const u8{
        "datasource:read", "datasource:write",
        "task:read",       "task:write",
        "reconcile:read",  "reconcile:run",
        "alarm:read",      "alarm:write",
        "audit:read",
        "user:read",       "user:write",
        "role:read",       "role:write",
    };
    inline for (perms) |p| {
        const intc = permissionInterceptor(p);
        const expected = "perm:" ++ p;
        try std.testing.expectEqualStrings(expected, intc.name);
        try std.testing.expect(intc.before != null);
    }
}
