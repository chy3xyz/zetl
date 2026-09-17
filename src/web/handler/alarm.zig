//! 告警 REST 端点
//! 路由: /api/v1/alarm/*

const std = @import("std");
const zfinal = @import("zfinal");
const alarm_mod = @import("mod.zig");
const rule = @import("rule.zig");
const webhook = @import("webhook.zig");
const web_deps = @import("../web/deps.zig");
const response = @import("../web/response.zig");

/// GET /api/v1/alarm/config  — 规则列表
pub fn listConfig(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const rules = rule.findAll(web_deps.store_ptr, allocator) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer {
        for (rules) |*r| r.deinit(allocator);
        allocator.free(rules);
    }

    const Item = struct { id: i64, alarm_type: []const u8, threshold: []const u8, webhook_url: []const u8, is_enabled: i32 };
    var items = try allocator.alloc(Item, rules.len);
    defer allocator.free(items);
    for (rules, 0..) |r, i| {
        items[i] = .{ .id = r.id, .alarm_type = r.alarm_type, .threshold = r.threshold, .webhook_url = r.webhook_url, .is_enabled = r.is_enabled };
    }
    try response.ok(ctx, .{ .total = @as(i64, @intCast(rules.len)), .list = items });
}

/// POST /api/v1/alarm/config  — 新增规则
pub fn createConfig(ctx: *zfinal.Context) !void {
    const parsed = ctx.parseJsonBody(struct {
        alarm_type: []const u8,
        threshold: []const u8 = "{}",
        webhook_url: []const u8,
    }) catch { try response.fail(ctx, .param_error, "请求体不合法（需要 alarm_type, webhook_url）"); return; };
    defer parsed.deinit();
    const v = parsed.value;
    if (v.alarm_type.len == 0) { try response.fail(ctx, .param_error, "alarm_type 必填"); return; }
    const id = rule.insert(web_deps.store_ptr, v.alarm_type, v.threshold, v.webhook_url) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err)); return;
    };
    try response.ok(ctx, .{ .id = id });
}

/// DELETE /api/v1/alarm/config/:id
pub fn deleteConfig(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse { try response.fail(ctx, .param_error, "id 必填"); return; };
    const id = try std.fmt.parseInt(i64, id_str, 10);
    rule.delete(web_deps.store_ptr, id) catch |err| { try response.fail(ctx, .system_error, @errorName(err)); return; };
    try response.ok(ctx, .{ .deleted = true });
}

/// POST /api/v1/alarm/test  — 测试推送
pub fn testAlarm(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = ctx.parseJsonBody(struct {
        webhook_url: []const u8,
        content: []const u8 = "zetl 测试告警 - 推送链路正常",
    }) catch { try response.fail(ctx, .param_error, "请求体不合法"); return; };
    defer parsed.deinit();
    const v = parsed.value;

    const p = alarm_mod.WebhookPayload{
        .alarm_type = "test",
        .title = "🧪 测试告警",
        .description = v.content,
        .task_id = 0,
        .task_name = "测试",
        .current_value = "N/A",
        .threshold = "N/A",
        .timestamp = "now",
        .markdown = try webhook.buildWechatMarkdown(.{
            .alarm_type = "test",
            .title = "🧪 测试告警",
            .description = v.content,
            .task_id = 0,
            .task_name = "测试",
            .current_value = "N/A",
            .threshold = "N/A",
            .timestamp = "now",
            .markdown = "",
        }, allocator),
    };
    try webhook.sendSync(allocator, v.webhook_url, p);
    try response.ok(ctx, .{ .sent = true });
}
