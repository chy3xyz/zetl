//! 操作审计 - V2.1
//! 所有 API 写操作自动记录 operation_log 表

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");

/// 记录操作审计 (ip 为空则表示内部调用)
pub fn logOp(
    store: *meta.store.MetaStore,
    operator: []const u8,
    op_type: []const u8,
    op_target: []const u8,
    op_detail: ?[]const u8,
    ip: ?[]const u8,
) !void {
    const sql: [:0]const u8 = "INSERT INTO operation_log (operator, op_type, op_target, op_detail, ip) VALUES ($1, $2, $3, $4, $5)";
    const detail_param: zfinal.SqlParam = if (op_detail) |d| .{ .text = d } else .null;
    const ip_param: zfinal.SqlParam = if (ip) |i| .{ .text = i } else .null;
    try store.db.execParams(sql, &.{ .{ .text = operator }, .{ .text = op_type }, .{ .text = op_target }, detail_param, ip_param });
}

pub fn logFromCtx(ctx: *zfinal.Context, store: *meta.store.MetaStore, op_type: []const u8, op_target: []const u8, op_detail: ?[]const u8) void {
    const operator = ctx.getHeader("x-operator") orelse "admin";
    // 取客户端 IP
    var ip_buf: [64]u8 = undefined;
    const ip_str = if (ctx.remote_addr) |addr|
        try std.fmt.bufPrint(&ip_buf, "{}", .{addr}) catch null
    else
        null;
    logOp(store, operator, op_type, op_target, op_detail, ip_str) catch {};
}
