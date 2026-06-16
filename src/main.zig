//! zetl V2 - 多源 MySQL 数据归集 ETL 引擎入口

const std = @import("std");
const zfinal = @import("zfinal");

pub const config_mod = @import("config.zig");
pub const common = @import("common/mod.zig");
pub const meta = @import("meta/mod.zig");
pub const engine = @import("engine/mod.zig");
pub const reconcile = @import("reconcile/mod.zig");
pub const alarm = @import("alarm/mod.zig");
pub const metrics_mod = @import("metrics/prometheus.zig");
pub const audit = @import("audit/mod.zig");
pub const auth = @import("auth/mod.zig");
pub const web = @import("web/mod.zig");

/// 全局单例 scheduler
var global_scheduler: ?*engine.scheduler.Scheduler = null;

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    // 0. P1 任务 1.8: 优雅停机 - 注册 SIGINT/SIGTERM handler
    //    zfinal.shutdown 用 atomic flag 置位, server.acceptLoop 在下个循环迭代时退出
    zfinal.shutdown.registerHandlers();

    // 1. 加载配置
    var cfg = try config_mod.loadConfig(allocator, "config.toml");
    defer cfg.deinit(allocator);

    // 2. 初始化全局日志
    common.logger.initLogger(cfg.log.level);

    // 3. 初始化元数据 SQLite
    var store = try meta.store.MetaStore.init(allocator, cfg.meta.sqlite_path);
    defer store.deinit();

    // 4. 初始化归集库连接池
    const sink_pool = try web.deps_mod.initSinkPool(allocator, cfg);

    // 5. 初始化全局 token
    var token_mgr = try allocator.create(zfinal.TokenManager);
    defer allocator.destroy(token_mgr);
    token_mgr.* = zfinal.TokenManager.init(allocator);
    token_mgr.setTTL(3600);

    // 6. V2.2 鉴权: 初始化角色表 (首次启动自动建 role/user_role/role_permission)
    auth.role.initRoles(&store) catch |err| {
        common.logger.warn("initRoles failed (OK on first boot): {s}", .{@errorName(err)});
    };

    // 7. 初始化 scheduler
    const scheduler = try allocator.create(engine.scheduler.Scheduler);
    defer allocator.destroy(scheduler);
    scheduler.* = engine.scheduler.Scheduler.init(allocator, &store, sink_pool);
    global_scheduler = scheduler;

    // 7. 启动时加载所有 status=1 任务
    scheduler.bootstrapAll() catch |err| {
        common.logger.err_("启动任务失败: {s}", .{@errorName(err)});
    };

    // 8. 启动 Web 控制台
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setPort(cfg.server.port);
    try web.routes.registerAll(&app, allocator, &cfg, &store, scheduler, token_mgr, sink_pool);

    // 9. 启动对账 Cron 后台线程 (V2.1+)
    const cron_cfg = reconcile.cron.CronConfig.fromReconcileConfig(cfg.reconcile);
    const cron_ctx = reconcile.cron.init(allocator, scheduler, &store, cron_cfg) catch |err| {
        common.logger.err_("cron init 失败: {s}", .{@errorName(err)});
        return err;
    };
    defer cron_ctx.deinit();

    common.logger.inf("zetl V2 服务启动, 端口: {d}", .{cfg.server.port});
    try app.start();

    // 10. P1 任务 1.8: app.start() 返回后做收尾
    //    信号已被 zfinal.shutdown 捕获, isShuttingDown() = true
    if (zfinal.shutdown.isShuttingDown()) {
        common.logger.warn("收到停机信号, 正在停止调度器...", .{});
        // 软等待 30s 让运行中 task 跑完当前 batch
        const stopped = scheduler.stopAll(30_000);
        common.logger.inf("已停止 {d} 个任务, 退出", .{stopped});
    }
}

// ===== 单元测试 =====
// 触发所有子模块的 test block
test {
    std.testing.refAllDecls(@This());
    _ = @import("common/crypto.zig");
    _ = @import("common/logger.zig");
    _ = @import("common/alarm.zig");
    _ = @import("meta/datasource.zig");
    _ = @import("meta/task.zig");
    _ = @import("cdc/poller.zig");
    _ = @import("transform/mapper.zig");
    _ = @import("transform/commission.zig");
    _ = @import("transform/engine.zig");
    _ = @import("sink/mysql_sink.zig");
    _ = @import("web/auth_middleware.zig");
    _ = @import("reconcile/summary.zig");
    _ = @import("reconcile/handler.zig");
    _ = @import("reconcile/cron.zig");
    _ = @import("alarm/rule.zig");
    _ = @import("alarm/webhook.zig");
    _ = @import("alarm/handler.zig");
    _ = @import("alarm/trigger.zig");
    _ = @import("metrics/prometheus.zig");
    _ = @import("audit/handler.zig");
    _ = @import("auth/bcrypt.zig");
    _ = @import("auth/user.zig");
    _ = @import("auth/role.zig");
    _ = @import("auth/handler.zig");
    _ = @import("config.zig");
}

test "load config smoke" {
    const a = std.testing.allocator;
    const cfg = try config_mod.loadConfig(a, "config.toml");
    var mutable = cfg;
    defer mutable.deinit(a);
    try std.testing.expect(cfg.server.port > 0);
}
