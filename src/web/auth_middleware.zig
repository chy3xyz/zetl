//! 鉴权中间件 - 校验 Bearer Token
//! 用法: 在 web/routes.zig 的 getWithInterceptors/postWithInterceptors 上挂载

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("deps.zig");
const response = @import("response.zig");

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

test "isPublicPath" {
    try std.testing.expect(isPublicPath("/api/v1/auth/login"));
    try std.testing.expect(isPublicPath("/health"));
    try std.testing.expect(isPublicPath("/"));
    try std.testing.expect(isPublicPath("/admin/datasource"));
    try std.testing.expect(!isPublicPath("/api/v1/datasource/list"));
    try std.testing.expect(!isPublicPath("/api/v1/task/list"));
}
