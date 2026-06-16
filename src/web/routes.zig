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
    _ = auth_mw.authInterceptor(); // 旧版简单 token-only 拦截器, 已用 permissionInterceptor 替代

    // ========================================================================
    // P1 任务 1.1: RBAC 细粒度权限中间件 (additive, 不影响原有 auth_intc)
    // ========================================================================
    // 每个 *_intc 都是 "token 校验 + 权限校验" 的双拦截器链.
    // permissionInterceptor(perm) 在编译期把 perm 嵌入 Interceptor.before,
    // 每个 perm 字符串生成独立的 before 函数, 不需要运行时查表.
    //
    // 权限分级:
    //   *:read  → 任意登录用户 (viewer+)
    //   *:write → operator+ (管理员自动通过)
    //   user:*, role:* → 仅 admin
    const datasource_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("datasource:read") };
    const datasource_write_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("datasource:write") };
    const datasource_delete_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("datasource:write") };
    const task_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:read") };
    const task_write_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:write") };
    const task_start_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:write") };
    const task_stop_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:write") };
    const task_delete_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:write") };
    const reconcile_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("reconcile:read") };
    const reconcile_run_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("reconcile:run") };
    const alarm_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("alarm:read") };
    const alarm_write_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("alarm:write") };
    const alarm_delete_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("alarm:write") };
    const audit_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("audit:read") };
    const user_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("user:read") };
    const user_write_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("user:write") };
    const role_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("role:read") };

    // 用户管理 (V2.2) — admin 专属 (user:read / user:write / role:read)
    try app.getWithInterceptors("/api/v1/user", auth_handler.listUsers, &user_read_intc);
    try app.postWithInterceptors("/api/v1/user", auth_handler.createUser, &user_write_intc);
    try app.getWithInterceptors("/api/v1/role", auth_handler.listRoles, &role_read_intc);

    try app.postWithInterceptors("/api/v1/datasource", datasource.create, &datasource_write_intc);
    try app.postWithInterceptors("/api/v1/datasource/test", datasource.testConnection, &datasource_read_intc);
    try app.getWithInterceptors("/api/v1/datasource/list", datasource.list, &datasource_read_intc);
    try app.deleteWithInterceptors("/api/v1/datasource/:id", datasource.delete, &datasource_delete_intc);

    // 任务
    try app.postWithInterceptors("/api/v1/task", task.create, &task_write_intc);
    try app.getWithInterceptors("/api/v1/task/list", task.list, &task_read_intc);
    try app.getWithInterceptors("/api/v1/task/:id", task.detail, &task_read_intc);
    try app.postWithInterceptors("/api/v1/task/:id/start", task.start, &task_start_intc);
    try app.postWithInterceptors("/api/v1/task/:id/stop", task.stop, &task_stop_intc);
    try app.deleteWithInterceptors("/api/v1/task/:id", task.delete, &task_delete_intc);

    // 监控
    const monitor_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("monitor:read") };
    try app.getWithInterceptors("/api/v1/monitor/overview", monitor.overview, &monitor_read_intc);
    try app.getWithInterceptors("/api/v1/monitor/task/:id", monitor.taskMetrics, &monitor_read_intc);

    // 对账 (V2.0)
    const rec_handler = @import("../reconcile/handler.zig");
    try app.postWithInterceptors("/api/v1/reconcile/run", rec_handler.run, &reconcile_run_intc);
    try app.getWithInterceptors("/api/v1/reconcile/list", rec_handler.list, &reconcile_read_intc);
    try app.getWithInterceptors("/api/v1/reconcile/:id", rec_handler.detail, &reconcile_read_intc);
    // P1 任务 1.4: CSV 导出
    try app.getWithInterceptors("/api/v1/reconcile/:id/export", rec_handler.exportCsv, &reconcile_read_intc);

    // 告警 (V2.1)
    const alarm_handler = @import("../alarm/handler.zig");
    try app.getWithInterceptors("/api/v1/alarm/config", alarm_handler.listConfig, &alarm_read_intc);
    try app.postWithInterceptors("/api/v1/alarm/config", alarm_handler.createConfig, &alarm_write_intc);
    try app.deleteWithInterceptors("/api/v1/alarm/config/:id", alarm_handler.deleteConfig, &alarm_delete_intc);
    try app.postWithInterceptors("/api/v1/alarm/test", alarm_handler.testAlarm, &alarm_write_intc);

    // 审计 (V2.1)
    const audit_handler = @import("../audit/handler.zig");
    try app.getWithInterceptors("/api/v1/audit/list", audit_handler.list, &audit_read_intc);

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

    // 离线 vendor 静态资源 (前端 UI, 无鉴权)
    try app.get("/static/vendor/:filename", vendorHandler);
}

fn healthHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .service = "zetl", .version = "0.1.0" });
}

fn indexHandler(ctx: *zfinal.Context) !void {
    const html = @embedFile("../assets/index.html");
    try ctx.renderHtml(html);
}

/// 离线 vendor 静态资源 handler.
/// 通过 path 参数 :filename 匹配 src/assets/vendor/ 下的预下载文件,
/// 用 @embedFile 嵌入二进制, 无需外网.
fn vendorHandler(ctx: *zfinal.Context) !void {
    const filename = ctx.getPathParam("filename") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .code = 400, .msg = "missing filename" });
        return;
    };

    const Content = struct { data: []const u8, mime: []const u8 };
    const content: Content = blk: {
        if (std.mem.eql(u8, filename, "tailwind.min.css")) {
            break :blk .{
                .data = @embedFile("../assets/vendor/tailwind.min.css"),
                .mime = "text/css; charset=utf-8",
            };
        } else if (std.mem.eql(u8, filename, "htmx.min.js")) {
            break :blk .{
                .data = @embedFile("../assets/vendor/htmx.min.js"),
                .mime = "application/javascript; charset=utf-8",
            };
        } else if (std.mem.eql(u8, filename, "alpine.min.js")) {
            break :blk .{
                .data = @embedFile("../assets/vendor/alpine.min.js"),
                .mime = "application/javascript; charset=utf-8",
            };
        } else {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .code = 404, .msg = "vendor file not found" });
            return;
        }
    };

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(ctx.allocator);
    try headers.append(ctx.allocator, .{ .name = "Content-Type", .value = content.mime });
    try headers.append(ctx.allocator, .{ .name = "Cache-Control", .value = "public, max-age=86400" });

    ctx.res_status = .ok;
    try ctx.req.respond(content.data, .{
        .status = ctx.res_status,
        .extra_headers = headers.items,
    });
}
