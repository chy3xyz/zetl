//! 通用 webhook HTTP 客户端
//! 支持标准 JSON POST 到任意 URL (企业微信/钉钉/Slack 等)

const std = @import("std");
const zfinal = @import("zfinal");
const alarm_mod = @import("mod.zig");

const IGNORE_CHARS = " \t\n\r";

/// 异步发送 webhook (fire-and-forget): 在子线程调 sendSync, 失败仅记日志
pub fn sendAsync(allocator: std.mem.Allocator, webhook_url: []const u8, payload: alarm_mod.WebhookPayload) void {
    if (webhook_url.len == 0) {
        std.log.warn("[alarm] empty webhook_url, skip async", .{});
        return;
    }

    // 同步构建 JSON (将所有字符串 slice 拷贝到一块 buffer, 之后随 json 一起 dup 给线程)
    const json_local = buildPayloadJson(allocator, &payload) catch |err| {
        std.log.err("[alarm] async buildPayloadJson failed: {s}", .{@errorName(err)});
        return;
    };
    errdefer allocator.free(json_local);

    // dup url + json 给线程持有, 当前帧返回后这些 slice 必须仍存活
    const url_dup = allocator.dupe(u8, webhook_url) catch |err| {
        std.log.err("[alarm] async dup url failed: {s}", .{@errorName(err)});
        return;
    };
    errdefer allocator.free(url_dup);

    const json_dup = allocator.dupe(u8, json_local) catch |err| {
        std.log.err("[alarm] async dup json failed: {s}", .{@errorName(err)});
        return;
    };
    // 成功 dup 后 json_local 的所有权移交给 json_dup 路径
    allocator.free(json_local);

    const thread = std.Thread.spawn(.{}, asyncSendThread, .{ allocator, url_dup, json_dup }) catch |err| {
        std.log.err("[alarm] async spawn failed: {s}", .{@errorName(err)});
        allocator.free(url_dup);
        allocator.free(json_dup);
        return;
    };
    thread.detach();
}

fn asyncSendThread(allocator: std.mem.Allocator, url: []u8, json: []u8) void {
    defer {
        allocator.free(url);
        allocator.free(json);
    }
    sendHttp(allocator, url, json) catch |err| {
        std.log.err("[alarm] async webhook to {s} failed: {s}", .{ url, @errorName(err) });
    };
}

/// 同步发送 webhook (用于测试 API). 失败返回 error
pub fn sendSync(allocator: std.mem.Allocator, webhook_url: []const u8, payload: alarm_mod.WebhookPayload) !void {
    if (webhook_url.len == 0) {
        std.log.warn("[alarm] empty webhook_url, skip", .{});
        return;
    }
    const json = try buildPayloadJson(allocator, &payload);
    defer allocator.free(json);
    try sendHttp(allocator, webhook_url, json);
}

/// 实际执行 HTTP POST. 2xx 视为成功, 其它返回 error.WebhookNonSuccessStatus
fn sendHttp(allocator: std.mem.Allocator, webhook_url: []const u8, json_body: []const u8) !void {
    const io = zfinal.io_instance.io;

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = webhook_url },
        .method = .POST,
        .payload = json_body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    }) catch |err| {
        std.log.err("[alarm] HTTP POST {s} failed: {s}", .{ webhook_url, @errorName(err) });
        return err;
    };

    if (result.status.class() != .success) {
        std.log.warn("[alarm] webhook {s} non-2xx status: {d}", .{ webhook_url, @intFromEnum(result.status) });
        return error.WebhookNonSuccessStatus;
    }

    std.log.info("[alarm] webhook delivered: {s} status={d}", .{ webhook_url, @intFromEnum(result.status) });
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

test "buildWechatMarkdown: contains all key fields" {
    const a = std.testing.allocator;
    const payload = alarm_mod.WebhookPayload{
        .alarm_type = "delay_alert",
        .title = "🚨 同步延迟告警",
        .description = "任务延迟",
        .task_id = 42,
        .task_name = "订单同步",
        .current_value = "120s",
        .threshold = "60s",
        .timestamp = "2026-06-16 10:00:00",
        .markdown = "",
    };
    const md = try buildWechatMarkdown(payload, a);
    defer a.free(md);

    // 必含字段
    try std.testing.expect(std.mem.indexOf(u8, md, "🚨 同步延迟告警") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "#42") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "订单同步") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "2026-06-16 10:00:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "120s") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "60s") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "任务延迟") != null);
    // markdown 结构
    try std.testing.expect(std.mem.indexOf(u8, md, "## ") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "**任务**") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "**阈值**") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "> ") != null);
}

test "buildWechatMarkdown: empty fields handled" {
    const a = std.testing.allocator;
    const payload = alarm_mod.WebhookPayload{
        .alarm_type = "test",
        .title = "T",
        .description = "",
        .task_id = 0,
        .task_name = "",
        .current_value = "",
        .threshold = "",
        .timestamp = "",
        .markdown = "",
    };
    const md = try buildWechatMarkdown(payload, a);
    defer a.free(md);
    try std.testing.expect(md.len > 0);
    // 任务字段应该 #0 形式
    try std.testing.expect(std.mem.indexOf(u8, md, "#0") != null);
}

test "buildPayloadJson: contains msgtype and alarm_type" {
    const a = std.testing.allocator;
    const payload = alarm_mod.WebhookPayload{
        .alarm_type = "task_fail",
        .title = "T",
        .description = "D",
        .task_id = 1,
        .task_name = "N",
        .current_value = "X",
        .threshold = "Y",
        .timestamp = "Z",
        .markdown = "MARKDOWN_BODY",
    };
    const json = try buildPayloadJson(a, &payload);
    defer a.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"msgtype\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alarm_type\":\"task_fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "MARKDOWN_BODY") != null);
}

test "buildPayloadJson: empty markdown produces valid structure" {
    const a = std.testing.allocator;
    const payload = alarm_mod.WebhookPayload{
        .alarm_type = "conn_lost",
        .title = "T",
        .description = "",
        .task_id = 0,
        .task_name = "",
        .current_value = "",
        .threshold = "",
        .timestamp = "",
        .markdown = "",
    };
    const json = try buildPayloadJson(a, &payload);
    defer a.free(json);

    // JSON 结构必须包含 content 字段 (即使为空)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alarm_type\":\"conn_lost\"") != null);
    // msgtype 必须是 markdown
    try std.testing.expect(std.mem.indexOf(u8, json, "\"msgtype\":\"markdown\"") != null);
}

test "sendSync: empty url returns without error" {
    const a = std.testing.allocator;
    const payload = alarm_mod.WebhookPayload{
        .alarm_type = "test",
        .title = "T",
        .description = "",
        .task_id = 0,
        .task_name = "",
        .current_value = "",
        .threshold = "",
        .timestamp = "",
        .markdown = "m",
    };
    // 空 url 不应抛 error
    try sendSync(a, "", payload);
}
