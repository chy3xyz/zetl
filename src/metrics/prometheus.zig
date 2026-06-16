//! Prometheus 指标导出 - V2.1
//! /metrics 端点返回 text/plain Prometheus 格式

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const web_deps = @import("../web/deps.zig");

/// GET /metrics  返回 Prometheus text 格式
pub fn metricsHandler(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const overview = meta.metrics.Service.globalOverview(web_deps.store_ptr) catch return;

    try buf.print(allocator,
        \\# HELP zetl_task_total Total sync tasks
        \\# TYPE zetl_task_total gauge
        \\zetl_task_total{{status="running"}} {d}
        \\zetl_task_total{{status="error"}} {d}
        \\zetl_task_total{{status="idle"}} {d}
        \\
        \\# HELP zetl_datasource_total Total datasources
        \\# TYPE zetl_datasource_total gauge
        \\zetl_datasource_total {d}
        \\
        \\# HELP zetl_rows_synced_total Total rows synced today
        \\# TYPE zetl_rows_synced_total counter
        \\zetl_rows_synced_total {d}
        \\
        \\# HELP zetl_info Version info
        \\# TYPE zetl_info gauge
        \\zetl_info{{version="2.0.0"}} 1
        \\
    , .{
        overview.running_task_count,
        overview.error_task_count,
        overview.task_count - overview.running_task_count - overview.error_task_count,
        overview.datasource_count,
        overview.today_sync_rows,
    });

    try ctx.setHeader("Content-Type", "text/plain; version=0.0.4");
    try ctx.renderText(buf.items);
}

/// GET /health/live  (始终 200)
pub fn liveHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "alive", .service = "zetl", .version = "2.0.0" });
}

/// GET /health/ready  (DB 可连 → 200, 否则 503)
pub fn readyHandler(ctx: *zfinal.Context) !void {
    const ok = web_deps.store_ptr.db.ping();
    if (!ok) {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "meta_db_ping_failed" });
        return;
    }
    try ctx.renderJson(.{ .status = "ready", .service = "zetl" });
}
