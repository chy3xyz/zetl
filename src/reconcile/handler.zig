//! 对账 REST 端点
//! 路由: /api/v1/reconcile/*

const std = @import("std");
const zfinal = @import("zfinal");
const reconcile = @import("mod.zig");
const summary = @import("summary.zig");
const web_deps = @import("../web/deps.zig");
const response = @import("../web/response.zig");

/// POST /api/v1/reconcile/run
/// 手动触发对账, 请求体: {"mall_id": "xxx", "table_name": "union_all_order"}
pub fn run(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = ctx.parseJsonBody(struct {
        mall_id: []const u8,
        table_name: []const u8 = "union_all_order",
    }) catch {
        try response.fail(ctx, .param_error, "请求体不合法, 需要 {mall_id, table_name}");
        return;
    };
    defer parsed.deinit();
    const v = parsed.value;

    if (v.mall_id.len == 0) {
        try response.fail(ctx, .param_error, "mall_id 必填");
        return;
    }

    // 需要用 datasource 信息构造源库连接池 (简化: 直接用归集库的 pool 作为演示)
    // 正式使用时, poller 和 sink 有各自的 pool
    const cfg = reconcile.ReconcileConfig{};
    const result = summary.reconcileAsync(
        allocator,
        web_deps.store_ptr,
        web_deps.scheduler_ptr.sink_pool, // 暂时用 sink pool 模拟源库 (需真实部署时修正)
        web_deps.scheduler_ptr.sink_pool,
        v.mall_id,
        v.table_name,
        cfg,
    ) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };

    try response.ok(ctx, .{
        .record_id = result.record_id,
        .mall_id = result.mall_id,
        .table_name = result.table_name,
        .source_count = result.source_count,
        .target_count = result.target_count,
        .diff_count = result.diff_count,
        .source_amount = result.source_amount,
        .target_amount = result.target_amount,
        .diff_amount = result.diff_amount,
        .is_abnormal = result.is_abnormal,
    });
}

/// GET /api/v1/reconcile/list
/// 查询参数: ?page=1&page_size=20&mall_id=
pub fn list(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const records = summary.listRecords(web_deps.store_ptr, allocator) catch |err| {
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    const RecItem = struct {
        id: i64,
        mall_id: []const u8,
        table_name: []const u8,
        source_count: i64,
        target_count: i64,
        diff_count: i64,
        source_amount: f64,
        target_amount: f64,
        diff_amount: f64,
        is_abnormal: i32,
        reconcile_time: []const u8,
    };

    var items = try allocator.alloc(RecItem, records.len);
    defer allocator.free(items);

    for (records, 0..) |r, i| {
        items[i] = .{
            .id = r.id,
            .mall_id = r.mall_id,
            .table_name = r.table_name,
            .source_count = r.source_count,
            .target_count = r.target_count,
            .diff_count = r.diff_count,
            .source_amount = r.source_amount,
            .target_amount = r.target_amount,
            .diff_amount = r.diff_amount,
            .is_abnormal = r.is_abnormal,
            .reconcile_time = r.reconcile_time,
        };
    }

    try response.ok(ctx, .{ .total = @as(i64, @intCast(records.len)), .list = items });
}

/// GET /api/v1/reconcile/:id  单次对账详情
pub fn detail(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const id_str = ctx.getPathParam("id") orelse {
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = try std.fmt.parseInt(i64, id_str, 10);

    const r = (summary.getRecord(web_deps.store_ptr, allocator, id) catch {
        try response.fail(ctx, .system_error, "查询失败");
        return;
    }) orelse {
        try response.fail(ctx, .business_error, "记录不存在");
        return;
    };
    defer {
        var rr = r;
        rr.deinit(allocator);
    }

    try response.ok(ctx, .{
        .id = r.id,
        .mall_id = r.mall_id,
        .table_name = r.table_name,
        .source_count = r.source_count,
        .target_count = r.target_count,
        .diff_count = r.diff_count,
        .source_amount = r.source_amount,
        .target_amount = r.target_amount,
        .diff_amount = r.diff_amount,
        .is_abnormal = r.is_abnormal,
        .reconcile_time = r.reconcile_time,
    });
}

// ============================================================================
// P1 任务 1.4: 对账 CSV 导出
// ============================================================================

/// CSV 字段转义: 含 `,` / `"` / `\n` 的字段用双引号包裹, 内部 `"` 写成 `""`.
/// 返回值由 allocator 分配, 调用方负责 free (与 dupe 语义一致).
fn csvEscape(allocator: std.mem.Allocator, field: []const u8) ![]u8 {
    var needs_quote = false;
    for (field) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) return allocator.dupe(u8, field);

    // 1. 先在栈上拼出最终结果 (避免 realloc 与 SafeAllocator remap 冲突)
    var stack_buf: [4096]u8 = undefined;
    if (field.len * 2 + 2 > stack_buf.len) {
        return error.FieldTooLong; // 4096 字节是合理的 CSV 字段上限
    }
    const w = csvEscapeInto(&stack_buf, field);

    // 2. 一次性 dupe 到堆, 返回的切片大小 = alloc 大小, free 安全
    return allocator.dupe(u8, stack_buf[0..w]);
}

fn csvEscapeInto(buf: []u8, field: []const u8) usize {
    buf[0] = '"';
    var w: usize = 1;
    for (field) |c| {
        if (c == '"') {
            buf[w] = '"';
            buf[w + 1] = '"';
            w += 2;
        } else {
            buf[w] = c;
            w += 1;
        }
    }
    buf[w] = '"';
    w += 1;
    return w;
}

/// GET /api/v1/reconcile/:id/export
/// 返回单条对账记录的 CSV (Content-Type: text/csv), 字段:
///   task_id, task_name, src_db, dst_db, source_count, target_count,
///   diff_count, status, created_at
pub fn exportCsv(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;

    // 1. 解析路径参数
    const id_str = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try response.fail(ctx, .param_error, "缺少 id");
        return;
    };
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        ctx.res_status = .bad_request;
        try response.fail(ctx, .param_error, "id 必须为整数");
        return;
    };

    // 2. 取记录
    const rec_opt = summary.getRecord(web_deps.store_ptr, allocator, id) catch |err| {
        ctx.res_status = .internal_server_error;
        try response.fail(ctx, .system_error, @errorName(err));
        return;
    };
    const rec = rec_opt orelse {
        ctx.res_status = .not_found;
        try response.fail(ctx, .business_error, "记录不存在");
        return;
    };
    defer {
        var rr = rec;
        rr.deinit(allocator);
    }

    // 3. 拼装字段
    // 注: 当前 meta 表 `reconcile_record` 没有 task_id/task_name/src_db/dst_db 字段,
    //     按现有 schema 用下列派生字段:
    //       task_id    = record.id
    //       task_name  = "{mall_id}.{table_name}"
    //       src_db     = "sink" (注: 源库连接池当前复用 sink_pool, 真实部署时按 datasource.mall_id 解析)
    //       dst_db     = table_name
    //       status     = "abnormal" if is_abnormal else "normal"
    //       created_at = reconcile_time
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // 表头
    try buf.appendSlice(allocator, "task_id,task_name,src_db,dst_db,source_count,target_count,diff_count,status,created_at\n");

    // 准备转义后的字符串
    var task_name_buf = std.ArrayList(u8).empty;
    defer task_name_buf.deinit(allocator);
    try task_name_buf.print(allocator, "{s}.{s}", .{ rec.mall_id, rec.table_name });

    const task_id_str = try std.fmt.allocPrint(allocator, "{d}", .{rec.id});
    defer allocator.free(task_id_str);
    const src_count_str = try std.fmt.allocPrint(allocator, "{d}", .{rec.source_count});
    defer allocator.free(src_count_str);
    const tgt_count_str = try std.fmt.allocPrint(allocator, "{d}", .{rec.target_count});
    defer allocator.free(tgt_count_str);
    const diff_count_str = try std.fmt.allocPrint(allocator, "{d}", .{rec.diff_count});
    defer allocator.free(diff_count_str);
    const status_str: []const u8 = if (rec.is_abnormal != 0) "abnormal" else "normal";

    const e_task_id = try csvEscape(allocator, task_id_str);
    defer allocator.free(e_task_id);
    const e_task_name = try csvEscape(allocator, task_name_buf.items);
    defer allocator.free(e_task_name);
    const e_src_db = try csvEscape(allocator, "sink");
    defer allocator.free(e_src_db);
    const e_dst_db = try csvEscape(allocator, rec.table_name);
    defer allocator.free(e_dst_db);
    const e_created = try csvEscape(allocator, rec.reconcile_time);
    defer allocator.free(e_created);

    // 拼行: 9 个字段, 逗号分隔
    try buf.print(
        allocator,
        "{s},{s},{s},{s},{s},{s},{s},{s},{s}\n",
        .{
            e_task_id,
            e_task_name,
            e_src_db,
            e_dst_db,
            src_count_str,
            tgt_count_str,
            diff_count_str,
            status_str,
            e_created,
        },
    );

    // 4. 返回 CSV (使用 zfinal 内置 renderCsv, 自动写 Content-Type: text/csv + 下载文件名)
    const filename = try std.fmt.allocPrintSentinel(allocator, "reconcile_{d}.csv", .{rec.id}, 0);
    defer allocator.free(filename);
    try ctx.renderCsv(buf.items, filename);
}

// ===== csvEscape 单元测试 (P1 任务 1.4) =====
test "csvEscape: plain field returns as-is" {
    const a = std.testing.allocator;
    const out = try csvEscape(a, "hello");
    defer a.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "csvEscape: empty field returns empty string" {
    const a = std.testing.allocator;
    const out = try csvEscape(a, "");
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "csvEscape: field with comma gets quoted" {
    const a = std.testing.allocator;
    const out = try csvEscape(a, "a,b,c");
    defer a.free(out);
    try std.testing.expectEqualStrings("\"a,b,c\"", out);
}

test "csvEscape: field with double-quote gets quoted with escaped quote" {
    const a = std.testing.allocator;
    const out = try csvEscape(a, "say \"hi\"");
    defer a.free(out);
    try std.testing.expectEqualStrings("\"say \"\"hi\"\"\"", out);
}

test "csvEscape: field with newline gets quoted" {
    const a = std.testing.allocator;
    const out = try csvEscape(a, "line1\nline2");
    defer a.free(out);
    try std.testing.expectEqualStrings("\"line1\nline2\"", out);
}
