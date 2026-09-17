//! V5 Phase 5 Task 5: HTTP API endpoints for `/api/tasks`.
//!
//! CRUD over `tasks_config` table with scheduler integration:
//!   - GET    /api/tasks              → list      列出所有任务 (可按 ?status= 过滤)
//!   - POST   /api/tasks              → create    新建任务, 自动注册到 Scheduler
//!   - GET    /api/tasks/{id}         → detail    查询单个任务
//!   - PUT    /api/tasks/{id}         → update    覆盖业务字段, 触发 Scheduler.reloadTask
//!   - DELETE /api/tasks/{id}         → delete    从 DB + Scheduler 移除
//!   - POST   /api/tasks/{id}/reload  → reload    用最新 DB 配置替换 in-memory SyncTask
//!
//! 适配: 复用 `src/web/response.zig` 的统一响应壳 (`code/msg/data`),
//! 复用 `src/web/deps.zig` 的全局 scheduler/store 句柄, 避免 handler 签名引入新依赖.
//! 鉴权不在本次范围, 路由以 `app.get/post/...` 注册 (不带 interceptors).

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../../meta/mod.zig");
const engine = @import("../../engine/mod.zig");
const deps = @import("../deps.zig");
const response = @import("../response.zig");

const TaskConfig = meta.task.service.TaskConfig;
const TaskActiveStatus = meta.task.service.TaskActiveStatus;
const Service = meta.task.service.Service;

/// 请求体 JSON 形状 — 与 `tasks_config` 列对齐, 字段可选默认值.
const Input = struct {
    name: []const u8,
    source_db: []const u8,
    source_table: []const u8,
    target_table: []const u8,
    sync_mode: u8 = 1,
    config_json: []const u8 = "{}",
    status: u8 = 1,
};

/// HTTP 响应里序列化的任务结构 (隐藏内部切片生命周期细节).
const TaskItem = struct {
    id: i64,
    name: []const u8,
    source_db: []const u8,
    source_table: []const u8,
    target_table: []const u8,
    sync_mode: u8,
    config_json: []const u8,
    status: u8,
    created_at: i64,
    updated_at: i64,
};

/// 把已解析的 `Input` 转成 `TaskConfig`. 字符串字段全部 dup, 调用方负责 `cfg.deinit(a)`.
fn inputToConfig(allocator: std.mem.Allocator, input: Input) !TaskConfig {
    if (input.name.len == 0 or
        input.source_db.len == 0 or
        input.source_table.len == 0 or
        input.target_table.len == 0)
    {
        return error.MissingField;
    }
    if (input.status != 0 and input.status != 1) {
        return error.InvalidStatus;
    }

    return .{
        .name = try allocator.dupe(u8, input.name),
        .source_db = try allocator.dupe(u8, input.source_db),
        .source_table = try allocator.dupe(u8, input.source_table),
        .target_table = try allocator.dupe(u8, input.target_table),
        .sync_mode = input.sync_mode,
        .config_json = try allocator.dupe(u8, input.config_json),
        .status = @enumFromInt(input.status),
    };
}

/// 从 JSON 字符串解析并 dup 所有字符串字段.
fn parseConfigFromJson(allocator: std.mem.Allocator, body: []const u8) !TaskConfig {
    var parsed = std.json.parseFromSlice(Input, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        // 区分字段缺失 (semantic) 与 JSON 语法错误 (syntactic), 便于上层做差异化提示.
        error.MissingField => return error.MissingField,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    return try inputToConfig(allocator, parsed.value);
}

/// 把 `TaskConfig` 投影成可序列化的 `TaskItem`.
fn configToItem(cfg: TaskConfig) TaskItem {
    return .{
        .id = cfg.id,
        .name = cfg.name,
        .source_db = cfg.source_db,
        .source_table = cfg.source_table,
        .target_table = cfg.target_table,
        .sync_mode = cfg.sync_mode,
        .config_json = cfg.config_json,
        .status = @intFromEnum(cfg.status),
        .created_at = cfg.created_at,
        .updated_at = cfg.updated_at,
    };
}

/// 从路径参数 `:id` 解析 i64, 失败返回参数错误.
fn parseIdParam(ctx: *zfinal.Context) !i64 {
    const raw = ctx.getPathParam("id") orelse return error.MissingId;
    return std.fmt.parseInt(i64, raw, 10) catch return error.InvalidId;
}

// ============================================================
// Handlers
// ============================================================

/// GET /api/tasks?status=0|1
/// `status` 缺省 → 返回全部; 提供 → 仅返回匹配行.
pub fn list(ctx: *zfinal.Context) !void {
    const allocator = deps.allocator_ptr;
    const raw_status = ctx.getParaToIntDefault("status", -1) catch -1;
    const status_filter: ?TaskActiveStatus = if (raw_status < 0 or raw_status > 1)
        null
    else
        @enumFromInt(@as(u8, @intCast(raw_status)));

    var svc = Service{ .store = deps.store_ptr };
    const cfgs = svc.list(status_filter) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer {
        for (cfgs) |*c| c.deinit(allocator);
        allocator.free(cfgs);
    }

    var items = try allocator.alloc(TaskItem, cfgs.len);
    defer allocator.free(items);
    for (cfgs, 0..) |c, i| {
        items[i] = configToItem(c);
    }

    try response.ok(ctx, .{
        .total = @as(i64, @intCast(cfgs.len)),
        .list = items,
    });
}

/// POST /api/tasks
/// Body: JSON Input. 流程: 解析 → Service.create → Scheduler.addTask.
pub fn create(ctx: *zfinal.Context) !void {
    const allocator = deps.allocator_ptr;
    const body = ctx.getBodyText() catch {
        try response.fail(ctx, .param_error, "读取请求体失败");
        return;
    };
    defer allocator.free(body);

    var cfg = parseConfigFromJson(allocator, body) catch |err| {
        try response.fail(ctx, .param_error, switch (err) {
            error.InvalidJson => "请求体不是合法 JSON",
            error.MissingField => "name/source_db/source_table/target_table 必填",
            error.InvalidStatus => "status 必须是 0 或 1",
            else => @errorName(err),
        });
        return;
    };
    defer cfg.deinit(allocator);

    var svc = Service{ .store = deps.store_ptr };
    const id = svc.create(cfg) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };

    // 启动到 Scheduler (test_mode 走 stub, 生产路径需要 datasource + MySQL 连接).
    // DB 已落盘, 即便 scheduler 注册失败也不回滚 (运维可手动 reload).
    deps.scheduler_ptr.addTask(id) catch |err| {
        try response.ok(ctx, .{
            .id = id,
            .status = "stored_only",
            .scheduler_error = @errorName(err),
        });
        return;
    };

    try response.ok(ctx, .{ .id = id, .status = "running" });
}

/// GET /api/tasks/{id}
pub fn detail(ctx: *zfinal.Context) !void {
    const allocator = deps.allocator_ptr;
    const id = parseIdParam(ctx) catch {
        try response.fail(ctx, .param_error, "id 必填且必须是整数");
        return;
    };

    var svc = Service{ .store = deps.store_ptr };
    var cfg = (svc.getById(id) catch {
        try response.fail(ctx, .system_error, "查询失败");
        return;
    }) orelse {
        try response.fail(ctx, .business_error, "任务不存在");
        return;
    };
    defer cfg.deinit(allocator);

    try response.ok(ctx, configToItem(cfg));
}

/// PUT /api/tasks/{id}
/// Body: JSON Input. 流程: 解析 → 校验 id 存在 → Service.update → Scheduler.reloadTask.
pub fn update(ctx: *zfinal.Context) !void {
    const allocator = deps.allocator_ptr;
    const id = parseIdParam(ctx) catch {
        try response.fail(ctx, .param_error, "id 必填且必须是整数");
        return;
    };
    const body = ctx.getBodyText() catch {
        try response.fail(ctx, .param_error, "读取请求体失败");
        return;
    };
    defer allocator.free(body);

    var cfg = parseConfigFromJson(allocator, body) catch |err| {
        try response.fail(ctx, .param_error, switch (err) {
            error.InvalidJson => "请求体不是合法 JSON",
            error.MissingField => "name/source_db/source_table/target_table 必填",
            error.InvalidStatus => "status 必须是 0 或 1",
            else => @errorName(err),
        });
        return;
    };
    defer cfg.deinit(allocator);

    var svc = Service{ .store = deps.store_ptr };
    // 先确认 id 存在 (Service.update 不报错, 但 reload 会在 TaskNotFound 时失败)
    _ = (svc.getById(id) catch {
        try response.fail(ctx, .system_error, "查询失败");
        return;
    }) orelse {
        try response.fail(ctx, .business_error, "任务不存在");
        return;
    };

    svc.update(id, cfg) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };

    deps.scheduler_ptr.reloadTask(id) catch |err| {
        try response.ok(ctx, .{
            .id = id,
            .status = "updated",
            .scheduler_error = @errorName(err),
        });
        return;
    };

    try response.ok(ctx, .{ .id = id, .status = "reloaded" });
}

/// DELETE /api/tasks/{id}
pub fn delete(ctx: *zfinal.Context) !void {
    const id = parseIdParam(ctx) catch {
        try response.fail(ctx, .param_error, "id 必填且必须是整数");
        return;
    };

    deps.scheduler_ptr.removeTask(id) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };

    try response.ok(ctx, .{ .id = id, .status = "deleted" });
}

/// POST /api/tasks/{id}/reload
/// 不接受 body — 直接用 DB 最新配置替换 in-memory SyncTask.
pub fn reload(ctx: *zfinal.Context) !void {
    const id = parseIdParam(ctx) catch {
        try response.fail(ctx, .param_error, "id 必填且必须是整数");
        return;
    };

    deps.scheduler_ptr.reloadTask(id) catch |err| switch (err) {
        error.TaskNotFound => {
            try response.fail(ctx, .business_error, "任务不存在");
            return;
        },
        error.ShutdownInProgress => {
            try response.fail(ctx, .business_error, "服务正在停机, 请稍后重试");
            return;
        },
        error.DatasourceNotFound => {
            try response.fail(ctx, .business_error, "任务绑定的数据源不存在");
            return;
        },
        else => {
            try response.fail(ctx, .system_error, @errorName(err));
            return;
        },
    };

    try response.ok(ctx, .{ .id = id, .status = "reloaded" });
}

// ============================================================
// 单元测试 (走 Scheduler.initForTest, 不实例化真实 SyncTask)
// ============================================================

test "parseConfigFromJson dups all string fields" {
    const a = std.testing.allocator;
    const body =
        \\{"name":"order_sync","source_db":"primary","source_table":"order_info",
        \\"target_table":"order_info","sync_mode":2,"config_json":"{\"x\":1}","status":0}
    ;
    var cfg = try parseConfigFromJson(a, body);
    defer cfg.deinit(a);

    try std.testing.expectEqualStrings("order_sync", cfg.name);
    try std.testing.expectEqualStrings("primary", cfg.source_db);
    try std.testing.expectEqualStrings("order_info", cfg.source_table);
    try std.testing.expectEqualStrings("order_info", cfg.target_table);
    try std.testing.expectEqual(@as(u8, 2), cfg.sync_mode);
    try std.testing.expectEqualStrings("{\"x\":1}", cfg.config_json);
    try std.testing.expectEqual(TaskActiveStatus.disabled, cfg.status);
}

test "parseConfigFromJson defaults: sync_mode=1, status=active, config_json={}" {
    const a = std.testing.allocator;
    const body =
        \\{"name":"t","source_db":"d","source_table":"t","target_table":"t"}
    ;
    var cfg = try parseConfigFromJson(a, body);
    defer cfg.deinit(a);

    try std.testing.expectEqual(@as(u8, 1), cfg.sync_mode);
    try std.testing.expectEqualStrings("{}", cfg.config_json);
    try std.testing.expectEqual(TaskActiveStatus.active, cfg.status);
}

test "parseConfigFromJson rejects missing required fields" {
    const a = std.testing.allocator;
    const body = "{\"name\":\"t\"}";
    try std.testing.expectError(error.MissingField, parseConfigFromJson(a, body));
}

test "parseConfigFromJson rejects invalid status value" {
    const a = std.testing.allocator;
    const body =
        \\{"name":"t","source_db":"d","source_table":"t","target_table":"t","status":9}
    ;
    try std.testing.expectError(error.InvalidStatus, parseConfigFromJson(a, body));
}

test "parseConfigFromJson rejects malformed JSON" {
    const a = std.testing.allocator;
    const body = "{not json";
    try std.testing.expectError(error.InvalidJson, parseConfigFromJson(a, body));
}

test "create flow: parseConfigFromJson → Service.create → Scheduler.addTask (test_mode)" {
    const a = std.testing.allocator;
    var db = try meta.store.MetaStore.init(a, ":memory:");
    defer db.deinit();

    var sched = engine.scheduler.Scheduler.initForTest(a, &db);
    defer sched.deinit();

    const body =
        \\{"name":"order_sync","source_db":"primary","source_table":"order_info",
        \\"target_table":"order_info","sync_mode":1,"config_json":"{}","status":1}
    ;
    var cfg = try parseConfigFromJson(a, body);
    defer cfg.deinit(a);

    var svc = Service{ .store = &db };
    const id = try svc.create(cfg);
    try std.testing.expect(id > 0);

    try sched.addTask(id);
    try std.testing.expect(sched.tasks.contains(id));

    // listTasks 应包含该 task 的 V5 config
    const listed = try sched.listTasks();
    defer {
        for (listed) |*c| c.deinit(a);
        a.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("order_sync", listed[0].name);
    try std.testing.expectEqual(id, listed[0].id);

    try sched.reloadTask(id);
    try std.testing.expect(sched.tasks.contains(id));

    try sched.removeTask(id);
    try std.testing.expect(!sched.tasks.contains(id));
    try std.testing.expect(try svc.getById(id) == null);
}

test "Service.list with status filter returns only matching rows" {
    const a = std.testing.allocator;
    var db = try meta.store.MetaStore.init(a, ":memory:");
    defer db.deinit();

    var svc = Service{ .store = &db };
    _ = try svc.create(.{ .name = "active_a", .source_db = "p", .source_table = "t", .target_table = "t", .sync_mode = 1, .config_json = "{}", .status = .active });
    _ = try svc.create(.{ .name = "disabled_b", .source_db = "p", .source_table = "t", .target_table = "t", .sync_mode = 1, .config_json = "{}", .status = .disabled });

    const active = try svc.list(.active);
    defer {
        for (active) |*c| c.deinit(a);
        a.free(active);
    }
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings("active_a", active[0].name);

    const disabled = try svc.list(.disabled);
    defer {
        for (disabled) |*c| c.deinit(a);
        a.free(disabled);
    }
    try std.testing.expectEqual(@as(usize, 1), disabled.len);
    try std.testing.expectEqualStrings("disabled_b", disabled[0].name);
}
