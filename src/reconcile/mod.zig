//! 对账引擎 - V2.0 核心
//! 提供: 汇总对账 (count + amount) + 增量 diff (抽 10%) + CSV 导出
//! Cron 调度: 默认凌晨 2 点自动跑

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const engine = @import("../engine/mod.zig");
const common = @import("../common/mod.zig");

/// 对账结果
pub const ReconcileResult = struct {
    record_id: i64,
    mall_id: []const u8,
    table_name: []const u8,
    source_count: i64,
    target_count: i64,
    diff_count: i64,
    source_amount: f64,
    target_amount: f64,
    diff_amount: f64,
    is_abnormal: bool,
    reconcile_time: []const u8,
    /// 差分详情 (仅增量 diff 有效, 以 JSON 形式存 reconcile_record)
    details_json: ?[]const u8 = null,
};

pub const ReconcileError = error{
    SourceConnectFailed,
    TargetConnectFailed,
    QueryFailed,
    InvalidTable,
};

/// 加载 config.toml 内 [reconcile] 段 (可选, 无则用默认值)
pub const ReconcileConfig = struct {
    schedule: []const u8 = "0 0 2 * * *", // 默认凌晨 2 点
    sample_ratio: f64 = 0.1, // 增量 diff 抽 10%
    diff_count_threshold: i64 = 5,
    diff_amount_threshold: f64 = 100.0,
    retention_days: u32 = 90,
};
