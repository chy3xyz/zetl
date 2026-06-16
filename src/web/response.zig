//! Web 统一响应 - {code, msg, data}

const std = @import("std");
const zfinal = @import("zfinal");

pub const Code = enum(i32) {
    success = 0,
    param_error = 1,
    permission_denied = 2,
    business_error = 3,
    system_error = 5,

    pub fn toString(c: Code) []const u8 {
        return switch (c) {
            .success => "success",
            .param_error => "参数错误",
            .permission_denied => "权限不足",
            .business_error => "业务异常",
            .system_error => "系统错误",
        };
    }
};

pub fn ok(ctx: *zfinal.Context, data: anytype) !void {
    const payload = .{ .code = @intFromEnum(Code.success), .msg = "success", .data = data };
    try ctx.renderJson(payload);
}

pub fn fail(ctx: *zfinal.Context, code: Code, msg: []const u8) !void {
    ctx.res_status = .bad_request;
    if (code == .system_error) ctx.res_status = .internal_server_error;
    const payload = .{ .code = @intFromEnum(code), .msg = msg, .data = @as(?[]const u8, null) };
    try ctx.renderJson(payload);
}

/// 从 Authorization header 提取 token (去除 "Bearer " 前缀)
pub fn extractToken(ctx: *zfinal.Context) ?[]const u8 {
    const auth = ctx.getHeader("Authorization") orelse return null;
    if (!std.mem.startsWith(u8, auth, "Bearer ")) return null;
    return auth["Bearer ".len..];
}
