//! 监控大盘 Handler
//! 路由: /api/v1/monitor/*

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../../meta/mod.zig");
const deps = @import("../deps.zig");
const response = @import("../response.zig");

/// GET /api/v1/monitor/overview
pub fn overview(ctx: *zfinal.Context) !void {
    const snap = try meta.metrics.Service.globalOverview(deps.store_ptr);

    // 计算平均延迟: 简化 = 0 (V1 不做时间序列)
    try response.ok(ctx, .{
        .running_task_count = snap.running_task_count,
        .error_task_count = snap.error_task_count,
        .today_sync_rows = snap.today_sync_rows,
        .datasource_count = snap.datasource_count,
        .task_count = snap.task_count,
        .avg_delay_seconds = snap.avg_delay_seconds,
    });
}

/// GET /api/v1/monitor/task/:id  单任务实时指标
pub fn taskMetrics(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    const m = try meta.metrics.Service.load(deps.store_ptr, id);
    const t = (try meta.task.Service.findById(deps.store_ptr, allocator, id)) orelse {
        try response.fail(ctx, .business_error, "任务不存在");
        return;
    };
    defer {
        var tt = t;
        tt.deinit(allocator);
    }
    const pos = try meta.position.Service.load(deps.store_ptr, allocator, id);
    defer {
        var p = pos;
        p.deinit(allocator);
    }

    try response.ok(ctx, .{
        .task_id = id,
        .task_name = t.task_name,
        .status = t.status,
        .last_error = t.last_error,
        .position = .{
            .stage = pos.stage.toString(),
            .last_pk = pos.last_pk,
            .last_update_time = pos.last_update_time,
        },
        .metrics = .{
            .today_rows = m.today_rows,
            .success_count = m.success_count,
            .fail_count = m.fail_count,
        },
    });
}
