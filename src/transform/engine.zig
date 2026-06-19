//! ETL 转换引擎 - 流水线
//! 顺序: 字段映射 → 常量注入(mall_id/sync_time) → 数据清洗 → 佣金计算 → 过滤
//! 错误返回 ErrXxx 供 sink 分流到 error_order

const std = @import("std");
const cdc = @import("../cdc/mod.zig");
const mapper_mod = @import("mapper.zig");
const commission_mod = @import("commission.zig");

pub const TransformError = error{
    FieldMissing,
    FieldTypeInvalid,
    FilterSkip,
    Other,
};

pub const RowData = std.StringHashMap([]const u8);

/// 释放 RowData 内部所有 key/value, 然后 deinit HashMap
/// 用法: defer freeRowData(target);
pub fn freeRowData(allocator: std.mem.Allocator, row: *RowData) void {
    var it = row.iterator();
    while (it.next()) |e| {
        std.debug.print("  freeRowData freeing key='{s}' value='{s}'\n", .{ e.key_ptr.*, e.value_ptr.* });
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    row.deinit();
}

pub const TransformConfig = struct {
    mall_id: []const u8,
    source_type: []const u8 = "mysql",
    field_mappings_json: ?[]const u8 = null,
    filter_condition: ?[]const u8 = null, // V1 简化为 >= 比较 (按字段)
    enable_commission_calc: bool = false,
    /// 可选: 用于过滤的字段名 (与 filter_value 配合, 数值比较)
    filter_field: ?[]const u8 = null,
    filter_op: FilterOp = .gte,
    filter_value: ?[]const u8 = null,
};

pub const FilterOp = enum { eq, ne, gt, gte, lt, lte };

pub const TransformEngine = struct {
    allocator: std.mem.Allocator,
    cfg: TransformConfig,
    mapper: mapper_mod.Mapper,
    calculator: commission_mod.Calculator,

    pub fn init(allocator: std.mem.Allocator, cfg: TransformConfig) !TransformEngine {
        const mapper = if (cfg.field_mappings_json) |fm|
            try mapper_mod.Mapper.fromJson(allocator, fm)
        else
            mapper_mod.Mapper{ .allocator = allocator };
        return .{
            .allocator = allocator,
            .cfg = .{
                .mall_id = try allocator.dupe(u8, cfg.mall_id),
                .source_type = try allocator.dupe(u8, cfg.source_type),
                .field_mappings_json = if (cfg.field_mappings_json) |fm| try allocator.dupe(u8, fm) else null,
                .filter_condition = if (cfg.filter_condition) |f| try allocator.dupe(u8, f) else null,
                .enable_commission_calc = cfg.enable_commission_calc,
                .filter_field = if (cfg.filter_field) |f| try allocator.dupe(u8, f) else null,
                .filter_op = cfg.filter_op,
                .filter_value = if (cfg.filter_value) |v| try allocator.dupe(u8, v) else null,
            },
            .mapper = mapper,
            .calculator = commission_mod.Calculator.init(allocator),
        };
    }

    /// 带 source schema 的 init. 先 fromSchema 生成 identity 映射, 再 mergeOverrides 应用用户覆盖.
    /// calculator 与 init 行为一致 (始终创建), enable_commission_calc 仅控制 process() 时是否启用.
    pub fn initWithSchema(
        allocator: std.mem.Allocator,
        cfg: TransformConfig,
        source_columns: []const mapper_mod.ColumnMeta,
    ) !TransformEngine {
        var mp = try mapper_mod.Mapper.fromSchema(allocator, source_columns);
        errdefer mp.deinit();

        if (cfg.field_mappings_json) |fm| {
            if (fm.len > 0) {
                try mp.mergeOverrides(allocator, fm);
            }
        }

        return .{
            .allocator = allocator,
            .cfg = .{
                .mall_id = try allocator.dupe(u8, cfg.mall_id),
                .source_type = try allocator.dupe(u8, cfg.source_type),
                .field_mappings_json = if (cfg.field_mappings_json) |fm| try allocator.dupe(u8, fm) else null,
                .filter_condition = if (cfg.filter_condition) |f| try allocator.dupe(u8, f) else null,
                .enable_commission_calc = cfg.enable_commission_calc,
                .filter_field = if (cfg.filter_field) |f| try allocator.dupe(u8, f) else null,
                .filter_op = cfg.filter_op,
                .filter_value = if (cfg.filter_value) |v| try allocator.dupe(u8, v) else null,
            },
            .mapper = mp,
            .calculator = commission_mod.Calculator.init(allocator),
        };
    }

    pub fn deinit(self: *TransformEngine) void {
        self.mapper.deinit();
        self.calculator.deinit();
        self.allocator.free(self.cfg.mall_id);
        self.allocator.free(self.cfg.source_type);
        if (self.cfg.field_mappings_json) |fm| self.allocator.free(fm);
        if (self.cfg.filter_condition) |f| self.allocator.free(f);
        if (self.cfg.filter_field) |f| self.allocator.free(f);
        if (self.cfg.filter_value) |v| self.allocator.free(v);
    }

    /// 设置佣金计算器规则
    pub fn setRules(self: *TransformEngine, rules: []const commission_mod.CommissionRule) !void {
        try self.calculator.loadRules(rules);
    }

    /// 转换单行. 成功返回 RowData; FieldMissing 抛错; FilterSkip 抛 FilterSkip.
    /// 返回的 RowData 拥有内部 key/value, caller 必须用 freeRowData() 释放.
    pub fn process(self: *TransformEngine, event: cdc.event.RowEvent) !RowData {
        // 1. 字段映射 (基于配置 JSON) → 初始 target
        var target = try self.mapper.apply(event.fields);
        // 注: target 已包含 dupe'd key/value, mapper.apply 成功后所有权完整转移
        // 后续 errdefer 用 freeRowData 整体释放

        // 2. 自动补齐目标表标准字段 (仅在尚未映射时)
        // create_time -> source_create_time, update_time -> source_update_time
        if (target.get("source_create_time") == null) {
            if (event.fields.get("create_time")) |v| {
                const k = try self.allocator.dupe(u8, "source_create_time");
                errdefer self.allocator.free(k);
                const val_dup = try self.allocator.dupe(u8, v);
                errdefer self.allocator.free(val_dup);
                try target.put(k, val_dup);
            }
        }
        if (target.get("source_update_time") == null) {
            if (event.fields.get("update_time")) |v| {
                const k = try self.allocator.dupe(u8, "source_update_time");
                errdefer self.allocator.free(k);
                const val_dup = try self.allocator.dupe(u8, v);
                errdefer self.allocator.free(val_dup);
                try target.put(k, val_dup);
            }
        }
        if (target.get("sync_type") == null) {
            const k = try self.allocator.dupe(u8, "sync_type");
            errdefer self.allocator.free(k);
            const v = try self.allocator.dupe(u8, "1");
            errdefer self.allocator.free(v);
            try target.put(k, v);
        }

        // 3. identity 模式下, 移除源表有但目标表不需要的字段 (如自增 id 和已重命名的 create_time/update_time)
        if (self.mapper.mappings.len == 0) {
            const to_remove = [_][]const u8{ "id", "create_time", "update_time" };
            for (to_remove) |key| {
                if (target.get(key) != null) {
                    const removed = target.fetchRemove(key) orelse continue;
                    self.allocator.free(removed.key);
                    self.allocator.free(removed.value);
                }
            }
        }

        // 4. 常量注入 (KEY 和 VALUE 都要 dupe, 因为 freeRowData 会统一释放)
        const mall_dup = try self.allocator.dupe(u8, self.cfg.mall_id);
        const mall_key = try self.allocator.dupe(u8, "mall_id");
        const source_type_dup = try self.allocator.dupe(u8, self.cfg.source_type);
        const source_type_key = try self.allocator.dupe(u8, "source_type");
        // 注: sync_time 列有 DEFAULT CURRENT_TIMESTAMP, 不在 INSERT 中指定让它自动填
        try target.put(mall_key, mall_dup);
        try target.put(source_type_key, source_type_dup);

        // 4.1 delete 事件软删除: 强制设置 is_delete = 1
        if (event.op == .delete) {
            const k = try self.allocator.dupe(u8, "is_delete");
            errdefer self.allocator.free(k);
            const v = try self.allocator.dupe(u8, "1");
            errdefer self.allocator.free(v);
            // 如果已有 is_delete, remove 并释放旧内存
            if (target.fetchRemove("is_delete")) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
            try target.put(k, v);
        }

        // 5. 过滤 (skip = 不通过 filter, 即 predicate 为 false)
        if (self.cfg.filter_field) |ff| {
            if (target.get(ff)) |fv| {
                const predicate = try self.evalFilter(ff, fv);
                if (!predicate) {
                    freeRowData(self.allocator, &target);
                    return TransformError.FilterSkip;
                }
            }
        }

        // 6. 佣金计算 (按 order_total)
        if (self.cfg.enable_commission_calc) {
            if (target.get("order_total")) |amt| {
                const agent_id = target.get("agent_id") orelse "";
                const result = try self.calculator.calculate(agent_id, self.cfg.mall_id, amt);
                const amount_dup = try self.allocator.dupe(u8, result.amount);
                const rate_dup = try self.allocator.dupe(u8, result.rate);
                const ac_key = try self.allocator.dupe(u8, "agent_commission");
                const cr_key = try self.allocator.dupe(u8, "commission_rate");
                try target.put(ac_key, amount_dup);
                try target.put(cr_key, rate_dup);
            }
        }

        return target;
    }

    /// 返回 true = 跳过 (filter 不通过)
    fn evalFilter(self: *TransformEngine, field: []const u8, value: []const u8) !bool {
        _ = field;
        const target_val = self.cfg.filter_value orelse return false;
        const v_f = std.fmt.parseFloat(f64, value) catch 0.0;
        const t_f = std.fmt.parseFloat(f64, target_val) catch 0.0;
        return switch (self.cfg.filter_op) {
            .eq => v_f == t_f,
            .ne => v_f != t_f,
            .gt => v_f > t_f,
            .gte => v_f >= t_f,
            .lt => v_f < t_f,
            .lte => v_f <= t_f,
        };
    }
};

fn currentTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @intCast(tv.sec);
}

test "freeRowData frees rows correctly" {
    const a = std.testing.allocator;
    var row: RowData = .init(a);
    // 注意: key/value 必须是 allocator 分配的可释放内存 (不能用字符串字面量)
    try row.put(try a.dupe(u8, "a"), try a.dupe(u8, "1"));
    try row.put(try a.dupe(u8, "b"), try a.dupe(u8, "2"));
    try row.put(try a.dupe(u8, "c"), try a.dupe(u8, "3"));
    freeRowData(a, &row);
}

test "transform: filter rejects below-threshold" {
    const a = std.testing.allocator;
    var eng = try TransformEngine.init(a, .{
        .mall_id = "mall_002",
        .field_mappings_json = "[{\"source\":\"amount\",\"target\":\"order_total\"}]",
        .filter_field = "order_total",
        .filter_op = .gte,
        .filter_value = "1000",
    });
    defer eng.deinit();

    var fields = std.StringHashMap([]const u8).init(a);
    defer fields.deinit();
    try fields.put("amount", "500");

    const ev = cdc.event.RowEvent{
        .op = .insert,
        .table = "t",
        .database = "db",
        .fields = fields,
        .timestamp = 0,
        .pk_value = "1",
    };

    const result = eng.process(ev);
    try std.testing.expectError(TransformError.FilterSkip, result);
}

test "transform: delete event sets is_delete=1" {
    const a = std.testing.allocator;
    var eng = try TransformEngine.init(a, .{
        .mall_id = "mall_003",
    });
    defer eng.deinit();

    var fields = std.StringHashMap([]const u8).init(a);
    defer fields.deinit();
    try fields.put("order_no", "ON_DEL_001");
    try fields.put("agent_id", "A001");
    try fields.put("order_total", "100.00");

    const ev = cdc.event.RowEvent{
        .op = .delete,
        .table = "order_info",
        .database = "zetl_source",
        .fields = fields,
        .timestamp = 0,
        .pk_value = "99",
    };

    var target = try eng.process(ev);
    defer freeRowData(a, &target);

    try std.testing.expectEqualStrings("1", target.get("is_delete").?);
    try std.testing.expectEqualStrings("mall_003", target.get("mall_id").?);
    try std.testing.expectEqualStrings("ON_DEL_001", target.get("order_no").?);
}

test "TransformEngine.init with empty source_columns uses field_mappings_json" {
    const a = std.testing.allocator;
    const cfg = TransformConfig{
        .mall_id = "mall_test_empty",
        .field_mappings_json = "[]",
    };
    var eng = try TransformEngine.init(a, cfg);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 0), eng.mapper.mappings.len);
}

test "TransformEngine.initWithSchema generates identity mappings" {
    const a = std.testing.allocator;
    const cfg = TransformConfig{
        .mall_id = "mall_schema",
        .field_mappings_json = "",
    };
    const cols = [_]mapper_mod.ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "amount" },
    };
    var eng = try TransformEngine.initWithSchema(a, cfg, &cols);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 2), eng.mapper.mappings.len);
    try std.testing.expectEqualStrings("order_id", eng.mapper.mappings[0].source);
    try std.testing.expectEqualStrings("order_id", eng.mapper.mappings[0].target);
    try std.testing.expectEqualStrings("amount", eng.mapper.mappings[1].target);
}

test "TransformEngine.initWithSchema merges user overrides" {
    const a = std.testing.allocator;
    const override_json = "[{\"source\":\"order_id\",\"target\":\"id\"}]";
    const cfg = TransformConfig{
        .mall_id = "mall_merge",
        .field_mappings_json = override_json,
    };
    const cols = [_]mapper_mod.ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "amount" },
    };
    var eng = try TransformEngine.initWithSchema(a, cfg, &cols);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 2), eng.mapper.mappings.len);
    try std.testing.expectEqualStrings("id", eng.mapper.mappings[0].target);
}
