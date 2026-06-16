//! 告警触发器引擎 (V2.1 核心)
//! 延迟检测 / 任务异常 / 连接断开 / 对账差值超标
//! V2.1 暂用内存态去重 (HashMap), 不落盘

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const alarm_mod = @import("mod.zig");
const rule_mod = @import("rule.zig");
const webhook = @import("webhook.zig");
const common = @import("../common/mod.zig");

/// 全局冷却 map (alarm_type|task_id → last_fire_ts)
/// 内存态, 进程重启即失效 (V2.1 够用)
var cooldown_cache: ?std.StringHashMap(i64) = null;

fn ensureCache(allocator: std.mem.Allocator) void {
    if (cooldown_cache == null) cooldown_cache = std.StringHashMap(i64).init(allocator);
}

/// 任务延迟告警 (当延迟超过阈值时触发)
pub fn checkDelay(
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    task_id: i64,
    task_name: []const u8,
    delay_seconds: i64,
) void {
    ensureCache(allocator);

    // 延迟超过 60s 才触发告警
    if (delay_seconds < 60) return;

    const atype = alarm_mod.AlarmType.delay_alert;
    _ = fire(allocator, store, atype, task_id, task_name,
        try std.fmt.allocPrint(allocator, "{d}s", .{delay_seconds}),
        "60s",
        try std.fmt.allocPrint(allocator, "任务 #{d} {s} 同步延迟超过 60 秒: {d}s", .{ task_id, task_name, delay_seconds }),
    );
}

/// 任务异常告警
pub fn checkTaskFail(
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    task_id: i64,
    task_name: []const u8,
    err_msg: []const u8,
) void {
    ensureCache(allocator);
    _ = fire(allocator, store, .task_fail, task_id, task_name,
        "异常",
        "N/A",
        try std.fmt.allocPrint(allocator, "任务 #{d} {s} 异常停止: {s}", .{ task_id, task_name, err_msg }),
    );
}

/// 连接断开告警
pub fn checkConnLost(
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    task_id: i64,
    task_name: []const u8,
) void {
    ensureCache(allocator);
    _ = fire(allocator, store, .conn_lost, task_id, task_name,
        "连接断开",
        "N/A",
        try std.fmt.allocPrint(allocator, "任务 #{d} {s} 与源库连接已断开", .{ task_id, task_name }),
    );
}

/// 对账差值告警
pub fn checkReconcileDiff(
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    task_id: i64,
    task_name: []const u8,
    diff_info: []const u8,
) void {
    ensureCache(allocator);
    _ = fire(allocator, store, .reconcile_diff, task_id, task_name,
        diff_info,
        "count_delta>5 or amount_delta>100",
        try std.fmt.allocPrint(allocator, "对账异常: 任务 #{d} {s} - {s}", .{ task_id, task_name, diff_info }),
    );
}

fn fire(
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    atype: alarm_mod.AlarmType,
    task_id: i64,
    task_name: []const u8,
    current_value: []const u8,
    threshold: []const u8,
    description: []const u8,
) !void {
    const rules = rule_mod.findByType(store, allocator, atype.toString()) catch return;
    defer { for (rules) |*r| r.deinit(allocator); allocator.free(rules); }
    if (rules.len == 0) return;

    // 冷却检查 (5min 内同类型不重发)
    var cache_key_buf: [64]u8 = undefined;
    const cache_key = try std.fmt.bufPrint(&cache_key_buf, "{s}|{d}", .{ atype.toString(), task_id });
    const now = std.time.nanoTimestamp() / 1_000_000_000;
    if (cooldown_cache.?.get(cache_key)) |last_fire| {
        if (now - last_fire < 300) return; // 冷却 5min
    }

    // 更新冷却时间戳
    try cooldown_cache.?.put(cache_key, now);

    // 推送到所有匹配的 webhook
    for (rules) |r| {
        const markdown = webhook.buildWechatMarkdown(.{
            .alarm_type = atype.toString(),
            .title = atype.title(),
            .description = description,
            .task_id = task_id,
            .task_name = task_name,
            .current_value = current_value,
            .threshold = threshold,
            .timestamp = "now",
            .markdown = "",
        }, allocator) catch continue;
        webhook.sendAsync(allocator, r.webhook_url, .{
            .alarm_type = atype.toString(),
            .title = atype.title(),
            .description = description,
            .task_id = task_id,
            .task_name = task_name,
            .current_value = current_value,
            .threshold = threshold,
            .timestamp = "now",
            .markdown = markdown,
        });
    }
}
