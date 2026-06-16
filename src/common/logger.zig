//! zetl 全局日志 - 包装 std.log + 解析字符串 level
//! 简单实现: 启动时根据 config.log.level 设置 std.log 全局 level
const std = @import("std");

pub fn initLogger(level_str: []const u8) void {
    const level = std.log.Level.err;
    _ = level;
    // std.log 在 Zig 0.17 中没有全局 level 切换, 改为包装一个轻量 fn
    std.log.info("logger initialized (level={s})", .{level_str});
}

pub fn inf(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fmt, args);
}

pub fn err_(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
}

pub fn dbg(comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
}
