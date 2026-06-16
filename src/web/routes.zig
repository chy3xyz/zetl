//! 路由注册
//! V1 全部业务接口以 /api/v1 开头, 通过 auth 中间件保护

const std = @import("std");
const zfinal = @import("zfinal");
const config_mod = @import("../config.zig");
const meta = @import("../meta/mod.zig");
const engine = @import("../engine/mod.zig");
const deps = @import("deps.zig");
const auth_mw = @import("auth_middleware.zig");
const auth = @import("handler/auth.zig");
const datasource = @import("handler/datasource.zig");
const task = @import("handler/task.zig");
const monitor = @import("handler/monitor.zig");

/// 注册所有路由. 启动时调用一次.
pub fn registerAll(
    app: *zfinal.ZFinal,
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    store: *meta.store.MetaStore,
    scheduler: *engine.scheduler.Scheduler,
    token_mgr: *zfinal.TokenManager,
    sink_pool: *zfinal.ConnectionPool,
) !void {
    // 初始化 web 全局依赖
    deps.initWebDeps(allocator, cfg, store, scheduler, token_mgr, sink_pool);

    // 健康检查 (无鉴权)
    try app.get("/health", healthHandler);

    // 鉴权
    const auth_handler = @import("../auth/handler.zig");
    try app.post("/api/v1/auth/login", auth_handler.loginV2);
    try app.get("/api/v1/auth/me", auth.me);
    try app.post("/api/v1/auth/logout", auth.logout);

    // 数据源 (需鉴权)
    const auth_intc = [_]zfinal.Interceptor{auth_mw.authInterceptor()};

    // 用户管理 (V2.2) — 在 auth_intc 声明之后
    try app.getWithInterceptors("/api/v1/user", auth_handler.listUsers, &auth_intc);
    try app.postWithInterceptors("/api/v1/user", auth_handler.createUser, &auth_intc);
    try app.getWithInterceptors("/api/v1/role", auth_handler.listRoles, &auth_intc);

    try app.postWithInterceptors("/api/v1/datasource", datasource.create, &auth_intc);
    try app.postWithInterceptors("/api/v1/datasource/test", datasource.testConnection, &auth_intc);
    try app.getWithInterceptors("/api/v1/datasource/list", datasource.list, &auth_intc);
    try app.deleteWithInterceptors("/api/v1/datasource/:id", datasource.delete, &auth_intc);

    // 任务
    try app.postWithInterceptors("/api/v1/task", task.create, &auth_intc);
    try app.getWithInterceptors("/api/v1/task/list", task.list, &auth_intc);
    try app.getWithInterceptors("/api/v1/task/:id", task.detail, &auth_intc);
    try app.postWithInterceptors("/api/v1/task/:id/start", task.start, &auth_intc);
    try app.postWithInterceptors("/api/v1/task/:id/stop", task.stop, &auth_intc);
    try app.deleteWithInterceptors("/api/v1/task/:id", task.delete, &auth_intc);

    // 监控
    try app.getWithInterceptors("/api/v1/monitor/overview", monitor.overview, &auth_intc);
    try app.getWithInterceptors("/api/v1/monitor/task/:id", monitor.taskMetrics, &auth_intc);

    // 对账 (V2.0)
    const rec_handler = @import("../reconcile/handler.zig");
    try app.postWithInterceptors("/api/v1/reconcile/run", rec_handler.run, &auth_intc);
    try app.getWithInterceptors("/api/v1/reconcile/list", rec_handler.list, &auth_intc);
    try app.getWithInterceptors("/api/v1/reconcile/:id", rec_handler.detail, &auth_intc);

    // 告警 (V2.1)
    const alarm_handler = @import("../alarm/handler.zig");
    try app.getWithInterceptors("/api/v1/alarm/config", alarm_handler.listConfig, &auth_intc);
    try app.postWithInterceptors("/api/v1/alarm/config", alarm_handler.createConfig, &auth_intc);
    try app.deleteWithInterceptors("/api/v1/alarm/config/:id", alarm_handler.deleteConfig, &auth_intc);
    try app.postWithInterceptors("/api/v1/alarm/test", alarm_handler.testAlarm, &auth_intc);

    // 审计 (V2.1)
    const audit_handler = @import("../audit/handler.zig");
    try app.getWithInterceptors("/api/v1/audit/list", audit_handler.list, &auth_intc);

    // 健康检查 + 指标 (公开)
    const prom = @import("../metrics/prometheus.zig");
    try app.get("/health/live", prom.liveHandler);
    try app.get("/health/ready", prom.readyHandler);
    try app.get("/metrics", prom.metricsHandler);

    // 前端根路由 (无鉴权)
    try app.get("/", indexHandler);
    try app.get("/admin", indexHandler);
    try app.get("/admin/datasource", indexHandler);
    try app.get("/admin/task", indexHandler);
    try app.get("/admin/monitor", indexHandler);
}

fn healthHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .service = "zetl", .version = "0.1.0" });
}

fn indexHandler(ctx: *zfinal.Context) !void {
    const html = @embedFile("../assets/index.html");
    try ctx.renderHtml(html);
}
