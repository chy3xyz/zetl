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

// ===== 单元测试 =====
fn makeTestStore(a: std.mem.Allocator) !meta.store.MetaStore {
    return try meta.store.MetaStore.init(a, ":memory:");
}

test "audit.logOp: insert log row succeeds" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try logOp(&store, "admin", "user.create", "user:1", "create user foo", "127.0.0.1");
    try logOp(&store, "alice", "task.start", "task:42", null, null);

    const sql: [:0]const u8 = "SELECT COUNT(*) FROM operation_log";
    var result = try store.db.query(sql);
    defer result.deinit();
    try std.testing.expect(result.next());
    const cnt = (try result.getInt(0)) orelse 0;
    try std.testing.expectEqual(@as(i64, 2), cnt);
}

test "audit.logOp: detail and ip null are stored as NULL" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try logOp(&store, "bob", "datasource.test", "ds:5", null, null);

    const sql: [:0]const u8 = "SELECT op_detail, ip FROM operation_log LIMIT 1";
    var result = try store.db.query(sql);
    defer result.deinit();
    try std.testing.expect(result.next());
    // getText returns null for NULL column
    try std.testing.expect(result.getText(0) == null);
    try std.testing.expect(result.getText(1) == null);
}

test "audit.logOp: multiple ops are independently retrievable" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();

    try logOp(&store, "u1", "login", "u1", "ok", "10.0.0.1");
    try logOp(&store, "u2", "logout", "u2", "ok", "10.0.0.2");
    try logOp(&store, "u3", "task.stop", "task:7", "manual stop", null);

    const sql: [:0]const u8 = "SELECT operator, op_type FROM operation_log ORDER BY id";
    var result = try store.db.query(sql);
    defer result.deinit();
    try std.testing.expect(result.next());
    try std.testing.expectEqualStrings("u1", result.getText(0) orelse "");
    try std.testing.expectEqualStrings("login", result.getText(1) orelse "");
    try std.testing.expect(result.next());
    try std.testing.expectEqualStrings("u2", result.getText(0) orelse "");
    try std.testing.expect(result.next());
    try std.testing.expectEqualStrings("u3", result.getText(0) orelse "");
    try std.testing.expect(!result.next());
}
