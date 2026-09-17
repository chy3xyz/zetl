//! 操作审计 REST API
//! /api/v1/audit/list

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const web_deps = @import("../web/deps.zig");
const response = @import("../web/response.zig");

/// GET /api/v1/audit/list
pub fn list(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const sql: [:0]const u8 = "SELECT id, operator, op_type, op_target, op_detail, ip, created_at FROM operation_log ORDER BY id DESC LIMIT 200";
    var result = web_deps.store_ptr.db.query(sql) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer result.deinit();

    const Item = struct { id: i64, operator: []const u8, op_type: []const u8, op_target: []const u8, op_detail: []const u8, ip: []const u8, created_at: []const u8 };
    var items = std.ArrayList(Item).empty;
    defer items.deinit(allocator);

    while (result.next()) {
        if (result.getCurrentRowMap()) |row| {
            try items.append(allocator, .{
                .id = try std.fmt.parseInt(i64, row.get("id") orelse "0", 10),
                .operator = try allocator.dupe(u8, row.get("operator") orelse ""),
                .op_type = try allocator.dupe(u8, row.get("op_type") orelse ""),
                .op_target = try allocator.dupe(u8, row.get("op_target") orelse ""),
                .op_detail = try allocator.dupe(u8, row.get("op_detail") orelse ""),
                .ip = try allocator.dupe(u8, row.get("ip") orelse ""),
                .created_at = try allocator.dupe(u8, row.get("created_at") orelse ""),
            });
        }
    }

    try response.ok(ctx, .{ .total = @as(i64, @intCast(items.items.len)), .list = items.items });
}
