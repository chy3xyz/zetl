//! 对账 Cron 调度器 — V2.0 (留接口, 真 Cron 待 enqueue)
//! 使用 zfinal CronPlugin 做后台定时对账
//! 注: CronPlugin 依赖 MySQL 初始化, V2 暂时在 Web 层注册手动触发入口

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const engine = @import("../engine/mod.zig");

/// 初始化对账 Cron (V2.0 留接口, 由 main() 调用)
/// 需要 scheduler 有 sink_pool 引用
pub fn init(_: std.mem.Allocator, _: *engine.scheduler.Scheduler) !void {
    std.log.info("[reconcile] Cron 调度待 V2.1 CronPlugin 集成, 当前仅支持手动触发", .{});
}
