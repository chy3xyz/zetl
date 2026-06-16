//! 告警模块 - V2.1
//! alarm_config CRUD + webhook 推送 + 企业微信模板 + 触发器引擎

const std = @import("std");
const zfinal = @import("zfinal");

pub const AlarmType = enum {
    delay_warn,    // 延迟 30s 预警
    delay_alert,   // 延迟 60s 告警
    task_fail,     // 任务异常停止
    conn_lost,     // 连接断开
    reconcile_diff,// 对账差值超标

    pub fn toString(a: AlarmType) []const u8 {
        return switch (a) {
            .delay_warn  => "delay_warn",
            .delay_alert => "delay_alert",
            .task_fail   => "task_fail",
            .conn_lost   => "conn_lost",
            .reconcile_diff => "reconcile_diff",
        };
    }

    pub fn title(a: AlarmType) []const u8 {
        return switch (a) {
            .delay_warn  => "⚠️ 同步延迟预警",
            .delay_alert => "🚨 同步延迟告警",
            .task_fail   => "❌ 任务异常停止",
            .conn_lost   => "🔌 连接断开",
            .reconcile_diff => "📊 对账差值超标",
        };
    }
};

pub const AlarmRule = struct {
    id: i64,
    alarm_type: []const u8,
    threshold: []const u8,   // JSON
    webhook_url: []const u8,
    is_enabled: i32,         // 0/1

    pub fn deinit(self: *AlarmRule, a: std.mem.Allocator) void {
        a.free(self.alarm_type);
        a.free(self.threshold);
        a.free(self.webhook_url);
    }
};

pub const WebhookPayload = struct {
    alarm_type: []const u8,
    title: []const u8,
    description: []const u8,
    task_id: i64,
    task_name: []const u8,
    current_value: []const u8,
    threshold: []const u8,
    timestamp: []const u8,
    /// 钉钉/企微 markdown 文本
    markdown: []const u8,
};
