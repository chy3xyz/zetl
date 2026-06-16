//! 对账 REST 端点
//! 路由: /api/v1/reconcile/*

const std = @import("std");
const zfinal = @import("zfinal");
const reconcile = @import("mod.zig");
const summary = @import("summary.zig");
const web_deps = @import("../web/deps.zig");
const response = @import("../web/response.zig");

/// POST /api/v1/reconcile/run
/// 手动触发对账, 请求体: {"mall_id": "xxx", "table_name": "union_all_order"}
pub fn run(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = ctx.parseJsonBody(struct {
        mall_id: []const u8,
        table_name: []const u8 = "union_all_order",
    }) catch {
        try response.fail(ctx, .param_error, "请求体不合法, 需要 {mall_id, table_name}");
        return;
    };
    defer parsed.deinit();
    const v = parsed.value;

    if (v.mall_id.len == 0) {
        try response.fail(ctx, .param_error, "mall_id 必填");
        return;
    }

    // 需要用 datasource 信息构造源库连接池 (简化: 直接用归集库的 pool 作为演示)
    // 正式使用时, poller 和 sink 有各自的 pool
    const cfg = reconcile.ReconcileConfig{};
    const result = summary.reconcileAsync(
        allocator,
        web_deps.store_ptr,
        web_deps.scheduler_ptr.sink_pool, // 暂时用 sink pool 模拟源库 (需真实部署时修正)
        web_deps.scheduler_ptr.sink_pool,
        v.mall_id,
        v.table_name,
        cfg,
    ) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };

    try response.ok(ctx, .{
        .record_id = result.record_id,
        .mall_id = result.mall_id,
        .table_name = result.table_name,
        .source_count = result.source_count,
        .target_count = result.target_count,
        .diff_count = result.diff_count,
        .source_amount = result.source_amount,
        .target_amount = result.target_amount,
        .diff_amount = result.diff_amount,
        .is_abnormal = result.is_abnormal,
    });
}

/// GET /api/v1/reconcile/list
/// 查询参数: ?page=1&page_size=20&mall_id=
pub fn list(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const records = summary.listRecords(web_deps.store_ptr, allocator) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    const RecItem = struct {
        id: i64,
        mall_id: []const u8,
        table_name: []const u8,
        source_count: i64,
        target_count: i64,
        diff_count: i64,
        source_amount: f64,
        target_amount: f64,
        diff_amount: f64,
        is_abnormal: i32,
        reconcile_time: []const u8,
    };

    var items = try allocator.alloc(RecItem, records.len);
    defer allocator.free(items);

    for (records, 0..) |r, i| {
        items[i] = .{
            .id = r.id,
            .mall_id = r.mall_id,
            .table_name = r.table_name,
            .source_count = r.source_count,
            .target_count = r.target_count,
            .diff_count = r.diff_count,
            .source_amount = r.source_amount,
            .target_amount = r.target_amount,
            .diff_amount = r.diff_amount,
            .is_abnormal = r.is_abnormal,
            .reconcile_time = r.reconcile_time,
        };
    }

    try response.ok(ctx, .{ .total = @as(i64, @intCast(records.len)), .list = items });
}

/// GET /api/v1/reconcile/:id  单次对账详情
pub fn detail(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    const r = (summary.getRecord(web_deps.store_ptr, allocator, id) catch {
        try response.fail(ctx, .system_error, "查询失败");
        return;
    }) orelse {
        try response.fail(ctx, .business_error, "记录不存在");
        return;
    };
    defer {
        var rr = r;
        rr.deinit(allocator);
    }

    try response.ok(ctx, .{
        .id = r.id,
        .mall_id = r.mall_id,
        .table_name = r.table_name,
        .source_count = r.source_count,
        .target_count = r.target_count,
        .diff_count = r.diff_count,
        .source_amount = r.source_amount,
        .target_amount = r.target_amount,
        .diff_amount = r.diff_amount,
        .is_abnormal = r.is_abnormal,
        .reconcile_time = r.reconcile_time,
    });
}
