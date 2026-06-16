//! 同步任务 Handler
//! 路由: /api/v1/task/*

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../../meta/mod.zig");
const engine = @import("../../engine/mod.zig");
const deps = @import("../deps.zig");
const response = @import("../response.zig");

/// POST /api/v1/task
pub fn create(ctx: *zfinal.Context) !void {
    const parsed = ctx.parseJsonBody(struct {
        task_name: []const u8,
        datasource_id: i64,
        source_table: []const u8,
        target_table: []const u8,
        sync_mode: []const u8 = "poll",
        field_mappings: ?[]const u8 = null,
        filter_condition: ?[]const u8 = null,
        batch_size: i32 = 1000,
        enable_commission_calc: bool = false,
    }) catch {
        try response.fail(ctx, .param_error, "请求体不合法");
        return;
    };
    defer parsed.deinit();

    const v = parsed.value;
    if (v.task_name.len == 0 or v.source_table.len == 0 or v.target_table.len == 0) {
        try response.fail(ctx, .param_error, "task_name/source_table/target_table 必填");
        return;
    }

    // sync_mode 校验与历史映射:
    //   - 缺省/未提供 -> poll (use JSON default above)
    //   - "cdc"       -> poll (legacy 字段名)
    //   - 其他合法值   -> full | poll | binlog | both
    //   - 非法值      -> 400, 列出所有合法选项
    const sync_mode = blk: {
        const raw = v.sync_mode;
        if (std.mem.eql(u8, raw, "cdc")) break :blk meta.task.SyncMode.poll;
        if (std.meta.stringToEnum(meta.task.SyncMode, raw)) |mode| break :blk mode;
        try response.fail(
            ctx,
            .param_error,
            "sync_mode 非法, 合法值: full / poll / binlog / both (cdc 已弃用, 等同 poll)",
        );
        return;
    };
    const id = meta.task.Service.insert(deps.store_ptr, .{
        .task_name = v.task_name,
        .datasource_id = v.datasource_id,
        .source_table = v.source_table,
        .target_table = v.target_table,
        .sync_mode = sync_mode,
        .field_mappings = v.field_mappings,
        .filter_condition = v.filter_condition,
        .batch_size = v.batch_size,
        .enable_commission_calc = v.enable_commission_calc,
    }) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };

    try response.ok(ctx, .{ .id = id });
}

/// GET /api/v1/task/list
pub fn list(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const page: usize = @intCast(ctx.getParaToIntDefault("page", 1) catch 1);
    const page_size: usize = @intCast(ctx.getParaToIntDefault("page_size", 20) catch 20);
    const status_filter = ctx.getParaToIntDefault("status", -1) catch -1;

    const all = meta.task.Service.findAll(deps.store_ptr, allocator) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer {
        for (all) |*t| t.deinit(allocator);
        allocator.free(all);
    }

    var filtered = std.ArrayList(meta.task.SyncTask).empty;
    defer {
        for (filtered.items) |*t| t.deinit(allocator);
        filtered.deinit(allocator);
    }
    for (all) |t| {
        if (status_filter < 0 or t.status == status_filter) {
            // 深拷贝任务
            const task_copy = try allocator.create(meta.task.SyncTask);
            task_copy.* = .{
                .id = t.id,
                .task_name = try allocator.dupe(u8, t.task_name),
                .datasource_id = t.datasource_id,
                .source_table = try allocator.dupe(u8, t.source_table),
                .target_table = try allocator.dupe(u8, t.target_table),
                .sync_mode = try allocator.dupe(u8, t.sync_mode),
                .field_mappings = if (t.field_mappings) |f| try allocator.dupe(u8, f) else null,
                .filter_condition = if (t.filter_condition) |f| try allocator.dupe(u8, f) else null,
                .batch_size = t.batch_size,
                .enable_commission_calc = t.enable_commission_calc,
                .status = t.status,
                .last_run_time = if (t.last_run_time) |f| try allocator.dupe(u8, f) else null,
                .last_error = if (t.last_error) |f| try allocator.dupe(u8, f) else null,
                .created_at = try allocator.dupe(u8, t.created_at),
            };
            try filtered.append(allocator, task_copy.*);
        }
    }
    const TaskItem = struct {
        id: i64,
        task_name: []const u8,
        datasource_id: i64,
        source_table: []const u8,
        target_table: []const u8,
        sync_mode: []const u8,
        batch_size: i32,
        enable_commission_calc: bool,
        status: i32,
        last_run_time: ?[]const u8,
        last_error: ?[]const u8,
        created_at: []const u8,
    };

    const start_idx: usize = if (page == 0) 0 else (page - 1) * page_size;
    const end = @min(start_idx + page_size, filtered.items.len);

    var items = try allocator.alloc(TaskItem, filtered.items.len);
    defer allocator.free(items);

    var i: usize = start_idx;
    var out_idx: usize = 0;
    while (i < end) : (i += 1) {
        const t = filtered.items[i];
        items[out_idx] = .{
            .id = t.id,
            .task_name = t.task_name,
            .datasource_id = t.datasource_id,
            .source_table = t.source_table,
            .target_table = t.target_table,
            .sync_mode = t.sync_mode,
            .batch_size = t.batch_size,
            .enable_commission_calc = t.enable_commission_calc == 1,
            .status = t.status,
            .last_run_time = t.last_run_time,
            .last_error = t.last_error,
            .created_at = t.created_at,
        };
        out_idx += 1;
    }

    try response.ok(ctx, .{
        .total = @as(i64, @intCast(filtered.items.len)),
        .list = items[0..out_idx],
    });
}

/// GET /api/v1/task/:id
pub fn detail(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    const t = (meta.task.Service.findById(deps.store_ptr, allocator, id) catch {
        try response.fail(ctx, .system_error, "查询失败");
        return;
    }) orelse {
        try response.fail(ctx, .business_error, "任务不存在");
        return;
    };
    defer {
        var tt = t;
        tt.deinit(allocator);
    }

    const pos = try meta.position.Service.load(deps.store_ptr, allocator, id);
    defer {
        var p = pos;
        p.deinit(allocator);
    }

    try response.ok(ctx, .{
        .id = t.id,
        .task_name = t.task_name,
        .datasource_id = t.datasource_id,
        .source_table = t.source_table,
        .target_table = t.target_table,
        .sync_mode = t.sync_mode,
        .field_mappings = t.field_mappings,
        .filter_condition = t.filter_condition,
        .batch_size = t.batch_size,
        .enable_commission_calc = t.enable_commission_calc == 1,
        .status = t.status,
        .last_run_time = t.last_run_time,
        .last_error = t.last_error,
        .created_at = t.created_at,
        .position = .{
            .stage = pos.stage.toString(),
            .last_pk = pos.last_pk,
            .last_update_time = pos.last_update_time,
            .updated_at = pos.updated_at,
        },
    });
}

/// POST /api/v1/task/:id/start
pub fn start(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    deps.scheduler_ptr.startTask(id) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    try response.ok(ctx, .{ .started = true, .task_id = id });
}

/// POST /api/v1/task/:id/stop
pub fn stop(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    deps.scheduler_ptr.stopTask(id) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    try response.ok(ctx, .{ .stopped = true, .task_id = id });
}

/// DELETE /api/v1/task/:id
pub fn delete(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    // 先停止, 再删除
    deps.scheduler_ptr.stopTask(id) catch {};
    meta.task.Service.deleteById(deps.store_ptr, id) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    meta.position.Service.delete(deps.store_ptr, id) catch {};

    try response.ok(ctx, .{ .deleted = true });
}
