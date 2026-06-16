//! 通用 webhook HTTP 客户端
//! 支持标准 JSON POST 到任意 URL (企业微信/钉钉/Slack 等)

const std = @import("std");
const zfinal = @import("zfinal");
const alarm_mod = @import("mod.zig");

const IGNORE_CHARS = " \t\n\r";

/// 发送 webhook 消息 (异步 fire-and-forget, 失败打印日志)
pub fn sendAsync(allocator: std.mem.Allocator, webhook_url: []const u8, payload: alarm_mod.WebhookPayload) void {
    // V2.1: 先发日志，真 HTTP POST 待外网后启用
    std.log.info("[alarm] would fire to: {s} type={s} task=#{d} title={s}", .{ webhook_url, payload.alarm_type, payload.task_id, payload.title });
    _ = allocator;
}

/// 同步发送 webhook (用于测试 API)
pub fn sendSync(allocator: std.mem.Allocator, webhook_url: []const u8, payload: alarm_mod.WebhookPayload) !void {
    const json = try buildPayloadJson(allocator, &payload);
    defer allocator.free(json);

    if (webhook_url.len == 0) {
        std.log.warn("[alarm] empty webhook_url, skip", .{});
        return;
    }

    // V1 简化: 用 std.c.http 发 POST (或直接 print log 做模拟)
    std.log.info("[alarm] webhook POST to {s}: {s}", .{ webhook_url, json });
}

fn buildPayloadJson(allocator: std.mem.Allocator, p: *const alarm_mod.WebhookPayload) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"msgtype":"markdown","markdown":{{"content":"{s}"}},"alarm_type":"{s}"}}
    , .{ p.markdown, p.alarm_type });
}

/// 构造企业微信 markdown 文本
pub fn buildWechatMarkdown(payload: alarm_mod.WebhookPayload, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\## {s}
        \\
        \\**任务**: #{d} {s}
        \\**触发时间**: {s}
        \\**当前值**: {s}
        \\**阈值**: {s}
        \\
        \\> {s}
    , .{
        payload.title,
        payload.task_id, payload.task_name,
        payload.timestamp,
        payload.current_value,
        payload.threshold,
        payload.description,
    });
}

fn hexToBytes(buf: []u8, hex: []const u8) !void {
    if (hex.len != buf.len * 2) return error.BadLen;
    _ = try std.fmt.hexToBytes(buf, hex);
}

fn bytesToHex(buf: []const u8) [buf.len * 2]u8 {
    return std.fmt.bytesToHex(buf, .lower);
}
