//! 数据源管理 Handler
//! 路由: /api/v1/datasource/*

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../../meta/mod.zig");
const deps = @import("../deps.zig");
const response = @import("../response.zig");

/// POST /api/v1/datasource  新增数据源
pub fn create(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = ctx.parseJsonBody(struct {
        mall_id: []const u8,
        ds_type: []const u8 = "mysql",
        host: []const u8,
        port: u16 = 3306,
        db_name: []const u8,
        username: []const u8,
        password: []const u8,
        remark: ?[]const u8 = null,
    }) catch {
        try response.fail(ctx, .param_error, "请求体不合法");
        return;
    };
    defer parsed.deinit();

    const input = parsed.value;
    if (input.mall_id.len == 0 or input.host.len == 0 or input.db_name.len == 0) {
        try response.fail(ctx, .param_error, "mall_id/host/db_name 必填");
        return;
    }

    const id = meta.datasource.Service.insert(deps.store_ptr, allocator, .{
        .mall_id = input.mall_id,
        .ds_type = input.ds_type,
        .host = input.host,
        .port = input.port,
        .db_name = input.db_name,
        .username = input.username,
        .password = input.password,
        .remark = input.remark,
    }) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };

    try response.ok(ctx, .{ .id = id });
}

/// POST /api/v1/datasource/test  测试连通性
pub fn testConnection(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = ctx.parseJsonBody(struct {
        host: []const u8,
        port: u16 = 3306,
        db_name: []const u8,
        username: []const u8,
        password: []const u8,
    }) catch {
        try response.fail(ctx, .param_error, "请求体不合法");
        return;
    };
    defer parsed.deinit();

    const v = parsed.value;
    // 用 zfinal.ConnectionPool 测试连通 (size=1 池, 临时)
    const host_z = try allocSentinel(allocator, v.host);
    defer allocator.free(host_z);
    const db_z = try allocSentinel(allocator, v.db_name);
    defer allocator.free(db_z);
    const user_z = try allocSentinel(allocator, v.username);
    defer allocator.free(user_z);
    const pass_z = try allocSentinel(allocator, v.password);
    defer allocator.free(pass_z);

    var test_pool = try zfinal.ConnectionPool.init(allocator, .{
        .db_type = .mysql,
        .host = host_z,
        .port = v.port,
        .database = db_z,
        .username = user_z,
        .password = pass_z,
    }, 1);
    defer test_pool.deinit();

    const conn = test_pool.acquire() catch |err| {
        try response.ok(ctx, .{ .connected = false, .err_msg = @errorName(err) });
        return;
    };
    const ok_flag = conn.ping();
    test_pool.release(conn) catch {};

    try response.ok(ctx, .{ .connected = ok_flag });
}

/// GET /api/v1/datasource/list  分页列表
pub fn list(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const page: usize = @intCast(ctx.getParaToIntDefault("page", 1) catch 1);
    const page_size: usize = @intCast(ctx.getParaToIntDefault("page_size", 20) catch 20);

    const all = meta.datasource.Service.findAll(deps.store_ptr, allocator) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer {
        for (all) |*d| d.deinit(allocator);
        allocator.free(all);
    }

    // 简化为前端拉全量 (数据量小, 商城通常 < 100)
    const DsItem = struct {
        id: i64,
        mall_id: []const u8,
        ds_type: []const u8,
        host: []const u8,
        port: u16,
        db_name: []const u8,
        username: []const u8,
        remark: ?[]const u8,
        status: i32,
        bind_task_count: bool,
        created_at: []const u8,
    };

    var items = try allocator.alloc(DsItem, all.len);
    defer allocator.free(items);

    const start_idx: usize = if (page == 0) 0 else (page - 1) * page_size;
    const end = @min(start_idx + page_size, all.len);
    var i: usize = start_idx;
    var out_idx: usize = 0;
    while (i < end) : (i += 1) {
        const d = all[i];
        items[out_idx] = .{
            .id = d.id,
            .mall_id = d.mall_id,
            .ds_type = d.ds_type,
            .host = d.host,
            .port = d.port,
            .db_name = d.db_name,
            .username = d.username,
            .remark = d.remark,
            .status = d.status,
            .bind_task_count = meta.datasource.Service.hasTaskBinding(deps.store_ptr, d.id) catch false,
            .created_at = d.created_at,
        };
        out_idx += 1;
    }

    try response.ok(ctx, .{
        .total = @as(i64, @intCast(all.len)),
        .list = items[0..out_idx],
    });
}

/// DELETE /api/v1/datasource/:id
pub fn delete(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    // 已绑定任务不可删
    if (try meta.datasource.Service.hasTaskBinding(deps.store_ptr, id)) {
        try response.fail(ctx, .business_error, "该数据源已绑定同步任务, 请先删除任务");
        return;
    }

    try meta.datasource.Service.deleteById(deps.store_ptr, id);
    try response.ok(ctx, .{ .deleted = true });
}

fn allocSentinel(allocator: std.mem.Allocator, src: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, src.len + 1);
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}
