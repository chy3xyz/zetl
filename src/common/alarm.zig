//! 告警 - V1 仅留接口与占位实现
//! 真实企业微信推送在 V2 接入 (本周期不实现)

const std = @import("std");

pub const Alarmer = struct {
    /// V1 stub: 仅打印日志, 不实际发送
    pub fn fire(_: *Alarmer, comptime fmt: []const u8, args: anytype) void {
        std.log.warn("[ALARM] " ++ fmt, args);
    }
};

pub fn noopAlarm(comptime fmt: []const u8, args: anytype) void {
    std.log.warn("[ALARM-stub] " ++ fmt, args);
}
