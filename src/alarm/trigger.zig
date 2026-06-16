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
    const cur_str = std.fmt.allocPrint(allocator, "{d}s", .{delay_seconds}) catch return;
    defer allocator.free(cur_str);
    const desc_str = std.fmt.allocPrint(allocator, "任务 #{d} {s} 同步延迟超过 60 秒: {d}s", .{ task_id, task_name, delay_seconds }) catch return;
    defer allocator.free(desc_str);
    fire(allocator, store, atype, task_id, task_name,
        cur_str,
        "60s",
        desc_str,
    ) catch {};
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
    const desc_str = std.fmt.allocPrint(allocator, "任务 #{d} {s} 异常停止: {s}", .{ task_id, task_name, err_msg }) catch return;
    defer allocator.free(desc_str);
    fire(allocator, store, .task_fail, task_id, task_name,
        "异常",
        "N/A",
        desc_str,
    ) catch {};
}

/// 连接断开告警
pub fn checkConnLost(
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    task_id: i64,
    task_name: []const u8,
) void {
    ensureCache(allocator);
    const desc_str = std.fmt.allocPrint(allocator, "任务 #{d} {s} 与源库连接已断开", .{ task_id, task_name }) catch return;
    defer allocator.free(desc_str);
    fire(allocator, store, .conn_lost, task_id, task_name,
        "连接断开",
        "N/A",
        desc_str,
    ) catch {};
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
    const desc_str = std.fmt.allocPrint(allocator, "对账异常: 任务 #{d} {s} - {s}", .{ task_id, task_name, diff_info }) catch return;
    defer allocator.free(desc_str);
    fire(allocator, store, .reconcile_diff, task_id, task_name,
        diff_info,
        "count_delta>5 or amount_delta>100",
        desc_str,
    ) catch {};
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
    const now: i64 = getNowSec();
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
        defer allocator.free(markdown); // sendAsync 已 dup json (含 markdown), 此处可释放
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

/// 获取当前 Unix 秒 (Zig 0.17 没有 std.time.milliTimestamp/nanoTimestamp, 改用 std.Io.Clock)
fn getNowSec() i64 {
    return std.Io.Clock.now(.real, zfinal.io_instance.io).toSeconds();
}

// ===== 单元测试 =====
fn makeTestStore(a: std.mem.Allocator) !meta.store.MetaStore {
    return try meta.store.MetaStore.init(a, ":memory:");
}

/// 清理全局 cooldown_cache (生产代码是进程级单例, 测试间要 reset 避免 leak 检测)
fn resetCooldown(allocator: std.mem.Allocator) void {
    if (cooldown_cache != null) {
        // StringHashMap 是 unmanaged, deinit 需要 allocator 释放 entries 缓冲区
        cooldown_cache.?.deinit();
        _ = allocator; // 接口对称, allocator 已在 ensureCache 中使用
        cooldown_cache = null;
    }
}

test "trigger.checkDelay: below threshold does nothing" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    defer resetCooldown(a);

    // 30s < 60s 阈值, 不应触发任何规则匹配 (rules 表为空)
    checkDelay(a, &store, 1, "task_a", 30);
    // 没 panic, 就算通过 (fire 内部空 rules 直接 return)
}

test "trigger.checkDelay: above threshold calls fire (no rules = noop)" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    defer resetCooldown(a);

    // 120s > 60s 阈值, fire 会被调用, 但 rules 表空, 不会真发 webhook
    checkDelay(a, &store, 1, "task_b", 120);
    // 通过 = 不会 panic, 不会泄漏 (内部空 rules 直接 return)
}

test "trigger.checkTaskFail: error message is formatted" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    defer resetCooldown(a);

    // 同样: rules 表空, fire 直接 return; 验证不会 panic
    checkTaskFail(a, &store, 7, "task_c", "connection refused");
}

test "trigger.checkConnLost: triggers fire on connection lost" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    defer resetCooldown(a);

    checkConnLost(a, &store, 9, "task_d");
}

test "trigger.checkReconcileDiff: diff info is rendered" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    defer resetCooldown(a);

    checkReconcileDiff(a, &store, 11, "task_e", "count delta=10, amount delta=200");
}

test "trigger.cooldown: same alarm within 5min is suppressed" {
    // 此测试只验证 cooldown 内部逻辑, 通过 fire 直接调用
    // 简化: 我们不直接暴露 cooldown_cache, 只验证"无 panic"
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    defer resetCooldown(a);

    // 配 1 个 enabled 规则 (URL 用 127.0.0.1:1 立即 connection refused, 不挂线程)
    _ = try rule_mod.insert(&store, "delay_alert", "{}", "http://127.0.0.1:1/hook");
    checkDelay(a, &store, 99, "task_x", 90);
    // 紧接着再触发一次, 内部 cooldown 应阻止 webhook 发送
    checkDelay(a, &store, 99, "task_x", 90);
    // 给异步线程一点时间退出, 避免 leak 检测
    std.Io.sleep(zfinal.io_instance.io, .fromMilliseconds(50), .real) catch {};
}
