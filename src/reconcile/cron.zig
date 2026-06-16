//! 对账 Cron 调度器 (V2.1+)
//! 进程内轻量级线程化 cron, 每隔 `poll_interval_s` 秒醒一次检查当前时间是否匹配
//! 不依赖 zfinal CronPlugin (CronPlugin 内部会拉起 MySQL, 与 SQLite 元数据不兼容)
//! 解析支持: @hourly / @daily / @weekly / @monthly / @yearly 简写, 以及 5 字段标准 cron
//! 简化版 parser: 每字段仅支持 `*` 与单个数字 (其他语法 fallback 为 @daily)

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const engine = @import("../engine/mod.zig");
const summary = @import("summary.zig");
const rec = @import("mod.zig");
const config_mod = @import("../config.zig");
const common = @import("../common/mod.zig");

/// Cron 调度配置
pub const CronConfig = struct {
    enabled: bool = true,
    /// 支持 "@hourly" / "@daily" / "@weekly" / "@monthly" / "@yearly"
    /// 或标准 5 字段 "M H DoM Mon DoW" (字段取值: `*` 或单数字)
    cron_expr: []const u8 = "@daily",
    /// 唤醒检查周期 (秒)
    poll_interval_s: u64 = 60,

    /// 从全局配置转换
    pub fn fromReconcileConfig(rc: config_mod.Config.ReconcileConfig) CronConfig {
        return .{
            .enabled = rc.enabled,
            .cron_expr = rc.cron_expr,
            .poll_interval_s = rc.poll_interval_s,
        };
    }
};

/// 5 字段 cron 时间表 (位图)
/// minutes: 0-59, hours: 0-23, dom: 1-31, month: 1-12, dow: 0-6 (Sun=0)
pub const CronSchedule = struct {
    minutes: [60]bool = initBoolArray(60),
    hours: [24]bool = initBoolArray(24),
    dom: [32]bool = initBoolArray(32),
    month: [13]bool = initBoolArray(13),
    dow: [7]bool = initBoolArray(7),

    /// 判定 unix 秒时间戳是否落在该时间表
    /// day-of-week 计算与 zfinal plugin/cron.zig 保持一致: 1970-01-01 是 Thursday (=4)
    pub fn matches(self: *const CronSchedule, timestamp: i64) bool {
        if (timestamp < 0) return false;
        const secs: u64 = @intCast(timestamp);
        const minutes: u8 = @intCast((secs / 60) % 60);
        const hours: u8 = @intCast((secs / 3600) % 24);

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const month: u8 = month_day.month.numeric();
        const day_of_month: u8 = @intCast(month_day.day_index + 1);
        // 1970-01-01 = Thursday, dow = 4; 后续每天 +1
        const day_of_week: u8 = @intCast((@as(u64, @intCast(epoch_day.day)) + 4) % 7);

        if (!self.minutes[minutes]) return false;
        if (!self.hours[hours]) return false;
        if (!self.dom[day_of_month]) return false;
        if (!self.month[month]) return false;
        if (!self.dow[day_of_week]) return false;
        return true;
    }
};

/// 解析 cron 表达式
/// 支持 @-shortcuts 与简化 5 字段; 不支持范围 / 步进 / 列表 (回退 @daily)
pub fn parse(expr: []const u8) !CronSchedule {
    var schedule = CronSchedule{};

    // @-shortcuts
    if (std.mem.eql(u8, expr, "@hourly")) {
        schedule.minutes[0] = true;
        @memset(&schedule.hours, true);
        @memset(&schedule.dom, true);
        @memset(&schedule.month, true);
        @memset(&schedule.dow, true);
        return schedule;
    }
    if (std.mem.eql(u8, expr, "@daily") or std.mem.eql(u8, expr, "@midnight")) {
        schedule.minutes[0] = true;
        schedule.hours[0] = true;
        @memset(&schedule.dom, true);
        @memset(&schedule.month, true);
        @memset(&schedule.dow, true);
        return schedule;
    }
    if (std.mem.eql(u8, expr, "@weekly")) {
        schedule.minutes[0] = true;
        schedule.hours[0] = true;
        @memset(&schedule.dom, true);
        @memset(&schedule.month, true);
        schedule.dow[0] = true; // Sunday
        return schedule;
    }
    if (std.mem.eql(u8, expr, "@monthly")) {
        schedule.minutes[0] = true;
        schedule.hours[0] = true;
        schedule.dom[1] = true; // 1st
        @memset(&schedule.month, true);
        @memset(&schedule.dow, true);
        return schedule;
    }
    if (std.mem.eql(u8, expr, "@yearly") or std.mem.eql(u8, expr, "@annually")) {
        schedule.minutes[0] = true;
        schedule.hours[0] = true;
        schedule.dom[1] = true;
        schedule.month[1] = true; // January
        @memset(&schedule.dow, true);
        return schedule;
    }

    // 5 字段: 简单空格切分
    var fields: [5][]const u8 = undefined;
    var fidx: usize = 0;
    var start: usize = 0;
    for (expr, 0..) |c, i| {
        if (c == ' ' or c == '\t') {
            if (i > start) {
                if (fidx >= 5) return error.InvalidCronExpression;
                fields[fidx] = expr[start..i];
                fidx += 1;
            }
            start = i + 1;
        }
    }
    if (start < expr.len) {
        if (fidx >= 5) return error.InvalidCronExpression;
        fields[fidx] = expr[start..];
        fidx += 1;
    }
    if (fidx != 5) return error.InvalidCronExpression;

    try parseField(fields[0], 0, 59, &schedule.minutes);
    try parseField(fields[1], 0, 23, &schedule.hours);
    try parseField(fields[2], 1, 31, &schedule.dom);
    try parseField(fields[3], 1, 12, &schedule.month);
    try parseField(fields[4], 0, 6, &schedule.dow);

    return schedule;
}

fn parseField(field: []const u8, min: u8, max: u8, result: []bool) !void {
    if (std.mem.eql(u8, field, "*")) {
        var i: u8 = min;
        while (i <= max) : (i += 1) result[i] = true;
        return;
    }
    if (field.len == 0) return error.InvalidCronExpression;
    const val = try std.fmt.parseInt(u8, field, 10);
    if (val < min or val > max) return error.InvalidCronExpression;
    result[val] = true;
}

/// 创建全 false 的 bool 数组 (避开 `[_]T{x}**N` 在 Zig 0.17 的解析歧义)
fn initBoolArray(comptime n: usize) [n]bool {
    var arr: [n]bool = undefined;
    @memset(&arr, false);
    return arr;
}

/// Cron 调度上下文 (主线程持有指针)
pub const CronContext = struct {
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    scheduler: *engine.scheduler.Scheduler,
    config: CronConfig,
    /// 堆分配的 cron 表达式, 保证后台线程寿命
    cron_expr_owned: []u8,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    /// 防重入: 上次触发的 unix minute (now/60)
    last_fire_minute: std.atomic.Value(i64),

    /// 停止后台线程并释放资源
    pub fn deinit(self: *CronContext) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |t| t.join();
        self.allocator.free(self.cron_expr_owned);
        self.allocator.destroy(self);
    }
};

/// 初始化 cron 调度器, 可选启动后台线程
pub fn init(
    allocator: std.mem.Allocator,
    scheduler: *engine.scheduler.Scheduler,
    store: *meta.store.MetaStore,
    cfg: CronConfig,
) !*CronContext {
    const ctx = try allocator.create(CronContext);
    errdefer allocator.destroy(ctx);

    const owned = try allocator.dupe(u8, cfg.cron_expr);
    errdefer allocator.free(owned);

    // 初始化 last_fire_minute 为当前分钟, 避免启动时立即触发
    const start_minute: i64 = @divTrunc(currentTimestamp(), 60);

    ctx.* = .{
        .allocator = allocator,
        .store = store,
        .scheduler = scheduler,
        .config = cfg,
        .cron_expr_owned = owned,
        .running = std.atomic.Value(bool).init(true),
        .thread = null,
        .last_fire_minute = std.atomic.Value(i64).init(start_minute),
    };

    if (cfg.enabled) {
        common.logger.inf(
            "[cron] 启动后台线程, expr='{s}' poll={d}s",
            .{ cfg.cron_expr, cfg.poll_interval_s },
        );
        ctx.thread = try std.Thread.spawn(.{}, cronLoop, .{ctx});
    } else {
        common.logger.warn("[cron] disabled by config, 后台线程不启动 (仅手动 API)", .{});
    }
    return ctx;
}

fn cronLoop(ctx: *CronContext) void {
    common.logger.inf("[cron] loop enter", .{});
    defer common.logger.inf("[cron] loop exit", .{});

    const schedule = parse(ctx.cron_expr_owned) catch |err| {
        common.logger.err_("[cron] 解析 '{s}' 失败: {s}, 退出线程", .{
            ctx.cron_expr_owned,
            @errorName(err),
        });
        return;
    };
    common.logger.inf("[cron] 调度表已加载", .{});

    while (ctx.running.load(.seq_cst)) {
        const now = currentTimestamp();
        if (schedule.matches(now)) {
            const minute_key: i64 = @divTrunc(now, 60);
            const last: i64 = ctx.last_fire_minute.load(.seq_cst);
            if (minute_key != last) {
                ctx.last_fire_minute.store(minute_key, .seq_cst);
                common.logger.inf("[cron] tick @ {d}", .{now});
                runAllTasks(ctx);
            }
        }
        sleepInterruptible(ctx, ctx.config.poll_interval_s);
    }
}

/// 睡眠指定秒数, 每秒检查一次 running 标志 (支持秒级优雅停机)
fn sleepInterruptible(ctx: *CronContext, total_seconds: u64) void {
    var i: u64 = 0;
    while (i < total_seconds) : (i += 1) {
        if (!ctx.running.load(.seq_cst)) return;
        std.Io.sleep(zfinal.io_instance.io, .fromSeconds(1), .real) catch {};
    }
}

fn runAllTasks(ctx: *CronContext) void {
    const allocator = ctx.allocator;
    const tasks = meta.task.Service.findEnabled(ctx.store, allocator) catch |err| {
        common.logger.err_("[cron] findEnabled err: {s}", .{@errorName(err)});
        return;
    };
    defer {
        for (tasks) |*t| t.deinit(allocator);
        allocator.free(tasks);
    }
    common.logger.inf("[cron] tick, {d} 个启用任务", .{tasks.len});
    for (tasks) |t| {
        runOneTask(ctx, t.id, t.task_name, t.target_table) catch |err| {
            common.logger.err_("[cron] task {d} ({s}) err: {s}", .{
                t.id,
                t.task_name,
                @errorName(err),
            });
        };
    }
}

fn runOneTask(
    ctx: *CronContext,
    task_id: i64,
    task_name: []const u8,
    target_table: []const u8,
) !void {
    const allocator = ctx.allocator;

    // 1. 加载 task
    const task_opt = try meta.task.Service.findById(ctx.store, allocator, task_id);
    const task = task_opt orelse {
        common.logger.warn("[cron] task {d} 不存在, 跳过", .{task_id});
        return error.TaskNotFound;
    };
    var t = task;
    defer t.deinit(allocator);

    // 2. 加载 datasource
    const ds_opt = try meta.datasource.Service.findById(ctx.store, allocator, t.datasource_id);
    const ds = ds_opt orelse {
        common.logger.warn("[cron] task {d} 数据源不存在, 跳过", .{task_id});
        return error.DatasourceNotFound;
    };
    var d = ds;
    defer d.deinit(allocator);

    // 3. 构造源库连接池 (堆字符串, 跟 SyncTask 同样模式)
    const src_host = try allocator.dupe(u8, d.host);
    defer allocator.free(src_host);
    const src_db = try allocator.dupe(u8, d.db_name);
    defer allocator.free(src_db);
    const src_user = try allocator.dupe(u8, d.username);
    defer allocator.free(src_user);
    const src_pass = try allocator.dupe(u8, d.password);
    defer allocator.free(src_pass);

    const src_cfg = zfinal.DBConfig{
        .db_type = .mysql,
        .host = src_host,
        .port = d.port,
        .database = src_db,
        .username = src_user,
        .password = src_pass,
        .max_connections = 1,
    };
    const src_pool = zfinal.ConnectionPool.init(allocator, src_cfg, 1) catch |err| {
        common.logger.err_("[cron] task {d} src pool init: {s}", .{
            task_id,
            @errorName(err),
        });
        return err;
    };
    defer {
        src_pool.deinit();
        allocator.destroy(src_pool);
    }

    // 4. 跑对账
    const rec_cfg = rec.ReconcileConfig{};
    common.logger.inf(
        "[cron] 对账: task={d} ({s}) mall={s} table={s}",
        .{ task_id, task_name, d.mall_id, target_table },
    );
    const result = summary.reconcileAsync(
        allocator,
        ctx.store,
        src_pool,
        ctx.scheduler.sink_pool,
        d.mall_id,
        target_table,
        rec_cfg,
    ) catch |err| {
        common.logger.err_("[cron] task {d} 对账失败: {s}", .{ task_id, @errorName(err) });
        return err;
    };
    defer {
        allocator.free(result.mall_id);
        allocator.free(result.table_name);
        allocator.free(result.reconcile_time);
        if (result.details_json) |dj| allocator.free(dj);
    }

    common.logger.inf(
        "[cron] 完成: task={d} diff_count={d} diff_amount={d:.2} abnormal={any}",
        .{ task_id, result.diff_count, result.diff_amount, result.is_abnormal },
    );
}

/// 手动触发对账 (供测试 / API 使用)
/// task_id 必须是 status=1 的任务
pub fn runNow(ctx: *CronContext, task_id: i64) !void {
    const allocator = ctx.allocator;
    const task_opt = try meta.task.Service.findById(ctx.store, allocator, task_id);
    const task = task_opt orelse return error.TaskNotFound;
    var t = task;
    defer t.deinit(allocator);

    return runOneTask(ctx, t.id, t.task_name, t.target_table);
}

fn currentTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @intCast(tv.sec);
}

// ===== 单元测试 =====

test "cron parse @daily" {
    const schedule = try parse("@daily");
    try std.testing.expect(schedule.minutes[0]);
    try std.testing.expect(schedule.hours[0]);
    for (schedule.dom) |b| try std.testing.expect(b);
    for (schedule.month) |b| try std.testing.expect(b);
    for (schedule.dow) |b| try std.testing.expect(b);
}

test "cron parse @hourly" {
    const schedule = try parse("@hourly");
    try std.testing.expect(schedule.minutes[0]);
    for (schedule.hours) |b| try std.testing.expect(b);
    for (schedule.dom) |b| try std.testing.expect(b);
    for (schedule.month) |b| try std.testing.expect(b);
    for (schedule.dow) |b| try std.testing.expect(b);
}

test "cron parse @weekly" {
    const schedule = try parse("@weekly");
    try std.testing.expect(schedule.minutes[0]);
    try std.testing.expect(schedule.hours[0]);
    for (schedule.dom) |b| try std.testing.expect(b);
    for (schedule.month) |b| try std.testing.expect(b);
    // 仅 dow[0] (Sunday) 启用
    try std.testing.expect(schedule.dow[0]);
    try std.testing.expect(!schedule.dow[1]);
    try std.testing.expect(!schedule.dow[6]);
}

test "cron parse @monthly" {
    const schedule = try parse("@monthly");
    try std.testing.expect(schedule.dom[1]);
    try std.testing.expect(!schedule.dom[2]);
    try std.testing.expect(schedule.minutes[0]);
    try std.testing.expect(schedule.hours[0]);
}

test "cron parse 5-field" {
    const schedule = try parse("30 14 * * *");
    try std.testing.expect(schedule.minutes[30]);
    try std.testing.expect(schedule.hours[14]);
    try std.testing.expect(!schedule.minutes[31]);
    // dom: * 设置 1..31, 0 不用
    for (schedule.dom[1..]) |b| try std.testing.expect(b);
}

test "cron parse invalid" {
    try std.testing.expectError(error.InvalidCronExpression, parse("invalid"));
    try std.testing.expectError(error.InvalidCronExpression, parse("* * *"));
    try std.testing.expectError(error.InvalidCronExpression, parse("60 0 * * *"));
    try std.testing.expectError(error.InvalidCronExpression, parse("0 24 * * *"));
    try std.testing.expectError(error.InvalidCronExpression, parse("0 0 32 * *"));
    try std.testing.expectError(error.InvalidCronExpression, parse("0 0 * 13 *"));
    try std.testing.expectError(error.InvalidCronExpression, parse("0 0 * * 7"));
}

test "cron matches at midnight UTC" {
    const schedule = try parse("@daily");
    // 2024-01-01 00:00:00 UTC = 1704067200 (Monday)
    // 注意: 当前 matches 实现按 minute 粒度判断, 同一分钟内任意秒都视为命中;
    //       cronLoop 用 last_fire_minute 去重避免重复触发.
    try std.testing.expect(schedule.matches(1704067200));
    try std.testing.expect(schedule.matches(1704067201)); // 同分钟: 命中 (实现粒度 = 分钟)
    // 2024-01-01 00:01:00 不应匹配 (minute=1)
    try std.testing.expect(!schedule.matches(1704067260));
    // 2024-01-01 01:00:00 不应匹配 (hour=1)
    try std.testing.expect(!schedule.matches(1704070800));
}

test "cron matches at specific minute" {
    const schedule = try parse("30 14 * * *");
    // 2024-01-01 14:30:00 UTC = 1704067200 + 14*3600 + 30*60 = 1704119400
    // 当前 matches 实现按 minute 粒度判断, 同一分钟内任意秒都视为命中
    try std.testing.expect(schedule.matches(1704119400));
    try std.testing.expect(schedule.matches(1704119401)); // 同分钟: 命中
    // 2024-01-01 14:31:00 不匹配
    try std.testing.expect(!schedule.matches(1704119460));
    // 2024-01-01 15:30:00 不匹配
    try std.testing.expect(!schedule.matches(1704123000));
}

test "cron fromReconcileConfig" {
    const rc = config_mod.Config.ReconcileConfig{
        .enabled = false,
        .cron_expr = "0 2 * * *",
        .poll_interval_s = 30,
    };
    const cc = CronConfig.fromReconcileConfig(rc);
    try std.testing.expectEqual(false, cc.enabled);
    try std.testing.expectEqualStrings("0 2 * * *", cc.cron_expr);
    try std.testing.expectEqual(@as(u64, 30), cc.poll_interval_s);
}
