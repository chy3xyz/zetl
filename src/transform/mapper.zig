//! 字段映射 - JSON 解析 + 映射逻辑
//! 字段映射 JSON 格式: [{"source": "order_no", "target": "order_no", "default": ""}, ...]
//! V1 简化为 std.json 解析 (无外部依赖)

const std = @import("std");

pub const FieldMapping = struct {
    source: []const u8, // 源字段名
    target: []const u8, // 目标字段名
    default_value: ?[]const u8 = null, // 缺失默认值
    /// 类型转换提示: "string" | "int" | "float" | "datetime" | null
    type_convert: ?[]const u8 = null,
};

/// Source schema 列元数据, 用于自动生成默认映射.
pub const ColumnMeta = struct {
    name: []const u8,
    /// MySQL 类型常量 (可选, 暂未使用).
    type: u8 = 0,
};

pub const NamingRule = union(enum) {
    identity,
    camel_to_snake,
    snake_to_camel,
    upper,
    lower,
    add_prefix: []const u8,
    strip_prefix: []const u8,
};

pub fn applyNamingRule(rule: NamingRule, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return switch (rule) {
        .identity => allocator.dupe(u8, source),
        .camel_to_snake => camelToSnake(allocator, source),
        .snake_to_camel => snakeToCamel(allocator, source),
        .upper => upperStr(allocator, source),
        .lower => lowerStr(allocator, source),
        .add_prefix => |prefix| std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, source }),
        .strip_prefix => |prefix| stripPrefix(allocator, prefix, source),
    };
}

fn upperStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf;
}

fn lowerStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

fn camelToSnake(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, source.len * 2);
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        const is_upper = c >= 'A' and c <= 'Z';
        if (is_upper and i > 0 and out_idx > 0) {
            buf[out_idx] = '_';
            out_idx += 1;
        }
        buf[out_idx] = std.ascii.toLower(c);
        out_idx += 1;
    }
    return allocator.realloc(buf, out_idx);
}

fn snakeToCamel(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, source.len);
    var out_idx: usize = 0;
    var at_word_start = true;
    for (source) |c| {
        if (c == '_') {
            at_word_start = true;
        } else if (at_word_start) {
            if (out_idx == 0) {
                buf[out_idx] = std.ascii.toLower(c);
            } else {
                buf[out_idx] = std.ascii.toUpper(c);
            }
            out_idx += 1;
            at_word_start = false;
        } else {
            buf[out_idx] = c;
            out_idx += 1;
        }
    }
    return allocator.realloc(buf, out_idx);
}

fn stripPrefix(allocator: std.mem.Allocator, prefix: []const u8, source: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, source, prefix)) {
        return allocator.dupe(u8, source[prefix.len..]);
    }
    return allocator.dupe(u8, source);
}

pub const Mapper = struct {
    allocator: std.mem.Allocator,
    mappings: []FieldMapping = &.{},

    pub fn deinit(self: *Mapper) void {
        for (self.mappings) |m| {
            self.allocator.free(m.source);
            self.allocator.free(m.target);
            if (m.default_value) |d| self.allocator.free(d);
            if (m.type_convert) |t| self.allocator.free(t);
        }
        self.allocator.free(self.mappings);
    }

    /// 从 source 列元数据生成 identity 映射 (列名 == 列名).
    pub fn fromSchema(allocator: std.mem.Allocator, columns: []const ColumnMeta) !Mapper {
        var mappings = try allocator.alloc(FieldMapping, columns.len);
        errdefer {
            for (mappings) |m| {
                allocator.free(m.source);
                allocator.free(m.target);
            }
            allocator.free(mappings);
        }
        for (columns, 0..) |col, i| {
            mappings[i] = .{
                .source = try allocator.dupe(u8, col.name),
                .target = try allocator.dupe(u8, col.name),
            };
        }
        return Mapper{ .allocator = allocator, .mappings = mappings };
    }

    /// 用 user_json 中的覆盖项替换同 source 的 mapping.
    /// user_json 格式与 fromJson 相同: [{"source": "...", "target": "...", "default": "...", "type": "..."}]
    /// 已有的 auto mappings 中, 命中 source 的项的 target / default / type 被替换.
    /// user_json 中 source 不在 auto 里的项作为额外 mapping 追加.
    pub fn mergeOverrides(self: *Mapper, allocator: std.mem.Allocator, user_json: []const u8) !void {
        if (user_json.len == 0) return;
        var override_mapper = try fromJson(allocator, user_json);
        defer override_mapper.deinit();

        var idx = std.StringHashMap(usize).init(allocator);
        defer idx.deinit();
        for (override_mapper.mappings, 0..) |m, i| {
            try idx.put(m.source, i);
        }

        for (self.mappings) |*auto_m| {
            if (idx.get(auto_m.source)) |ov_idx| {
                const ov = override_mapper.mappings[ov_idx];
                allocator.free(auto_m.target);
                auto_m.target = try allocator.dupe(u8, ov.target);
                if (auto_m.default_value) |d| allocator.free(d);
                auto_m.default_value = null;
                if (ov.default_value) |d| auto_m.default_value = try allocator.dupe(u8, d);
                if (auto_m.type_convert) |t| allocator.free(t);
                auto_m.type_convert = null;
                if (ov.type_convert) |t| auto_m.type_convert = try allocator.dupe(u8, t);
            }
        }

        for (override_mapper.mappings) |ov| {
            var found = false;
            for (self.mappings) |auto_m| {
                if (std.mem.eql(u8, auto_m.source, ov.source)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                var new_m: FieldMapping = .{
                    .source = try allocator.dupe(u8, ov.source),
                    .target = try allocator.dupe(u8, ov.target),
                };
                if (ov.default_value) |d| new_m.default_value = try allocator.dupe(u8, d);
                if (ov.type_convert) |t| new_m.type_convert = try allocator.dupe(u8, t);
                const new_list = try allocator.realloc(self.mappings, self.mappings.len + 1);
                new_list[self.mappings.len] = new_m;
                self.mappings = new_list;
            }
        }
    }

    /// 从 task.field_mappings (JSON 字符串) 解析
    pub fn fromJson(allocator: std.mem.Allocator, json_text: []const u8) !Mapper {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .use_last,
        });
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return Mapper{ .allocator = allocator, .mappings = &.{} },
        };

        var list = std.ArrayList(FieldMapping).empty;
        errdefer {
            for (list.items) |m| {
                allocator.free(m.source);
                allocator.free(m.target);
                if (m.default_value) |d| allocator.free(d);
                if (m.type_convert) |t| allocator.free(t);
            }
            list.deinit(allocator);
        }

        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const source_v = obj.get("source") orelse continue;
            const target_v = obj.get("target") orelse continue;
            const source_str = switch (source_v) {
                .string => |s| s,
                else => continue,
            };
            const target_str = switch (target_v) {
                .string => |s| s,
                else => continue,
            };

            var m = FieldMapping{
                .source = try allocator.dupe(u8, source_str),
                .target = try allocator.dupe(u8, target_str),
            };

            if (obj.get("default")) |dv| {
                if (dv == .string) m.default_value = try allocator.dupe(u8, dv.string);
            }
            if (obj.get("type")) |tv| {
                if (tv == .string) m.type_convert = try allocator.dupe(u8, tv.string);
            }
            try list.append(allocator, m);
        }
        return Mapper{ .allocator = allocator, .mappings = try list.toOwnedSlice(allocator) };
    }

    /// 把源行 map 成目标行 (caller 负责 free).
    /// 当 mappings 为空时, 默认做 identity 映射 (源字段名直接作为目标字段名),
    /// 避免 field_mappings 未配置时 target 为空导致 sink INSERT 缺少必填列.
    pub fn apply(self: *Mapper, source: std.StringHashMap([]const u8)) !std.StringHashMap([]const u8) {
        var target = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = target.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            target.deinit();
        }

        if (self.mappings.len == 0) {
            // identity 模式: 直接遍历 source 字段
            var it = source.iterator();
            while (it.next()) |e| {
                const key_dup = try self.allocator.dupe(u8, e.key_ptr.*);
                errdefer self.allocator.free(key_dup);
                const val_dup = try self.allocator.dupe(u8, e.value_ptr.*);
                errdefer self.allocator.free(val_dup);
                try target.put(key_dup, val_dup);
            }
            return target;
        }

        for (self.mappings) |m| {
            const val = source.get(m.source) orelse m.default_value orelse continue;
            const key_dup = try self.allocator.dupe(u8, m.target);
            errdefer self.allocator.free(key_dup);
            const val_dup = try self.allocator.dupe(u8, val);
            errdefer self.allocator.free(val_dup);
            try target.put(key_dup, val_dup);
        }
        return target;
    }
};

test "mapper roundtrip" {
    const a = std.testing.allocator;
    const json =
        \\[{"source": "order_no", "target": "order_no"},
        \\ {"source": "amount", "target": "order_total", "type": "float"},
        \\ {"source": "status", "target": "order_status", "default": "0"}]
    ;
    var mapper = try Mapper.fromJson(a, json);
    defer mapper.deinit();
    try std.testing.expectEqual(@as(usize, 3), mapper.mappings.len);
    try std.testing.expectEqualStrings("order_no", mapper.mappings[0].source);
    try std.testing.expectEqualStrings("0", mapper.mappings[2].default_value.?);
}

test "mapper: apply copies values + uses default" {
    const a = std.testing.allocator;
    const json =
        \\[{"source": "order_no", "target": "order_no"},
        \\ {"source": "status", "target": "order_status", "default": "0"}]
    ;
    var mapper = try Mapper.fromJson(a, json);
    defer mapper.deinit();

    var source = std.StringHashMap([]const u8).init(a);
    defer source.deinit();
    try source.put("order_no", "ON001");
    // status 缺失 -> 用 default "0"

    var target = try mapper.apply(source);
    defer {
        var it = target.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        target.deinit();
    }
    try std.testing.expectEqualStrings("ON001", target.get("order_no").?);
    try std.testing.expectEqualStrings("0", target.get("order_status").?);
}

test "mapper: empty json yields empty mapper" {
    const a = std.testing.allocator;
    var mapper = try Mapper.fromJson(a, "[]");
    defer mapper.deinit();
    try std.testing.expectEqual(@as(usize, 0), mapper.mappings.len);
}

test "mapper: malformed json returns error" {
    const a = std.testing.allocator;
    // malformed json 应该返回错误, 不应静默吞掉
    const result = Mapper.fromJson(a, "not json");
    try std.testing.expectError(error.SyntaxError, result);
}

test "mapper: source field reuses underlying value" {
    const a = std.testing.allocator;
    const json =
        \\[{"source": "id", "target": "id"},
        \\ {"source": "name", "target": "user_name"}]
    ;
    var mapper = try Mapper.fromJson(a, json);
    defer mapper.deinit();

    var source = std.StringHashMap([]const u8).init(a);
    defer source.deinit();
    try source.put("id", "42");
    try source.put("name", "Alice");

    var target = try mapper.apply(source);
    defer {
        var it = target.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        target.deinit();
    }
    try std.testing.expectEqualStrings("42", target.get("id").?);
    try std.testing.expectEqualStrings("Alice", target.get("user_name").?);
}

test "Mapper.fromSchema generates identity mappings" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "paid_at" },
        .{ .name = "amount" },
    };
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 3), m.mappings.len);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].source);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].target);
    try std.testing.expectEqualStrings("paid_at", m.mappings[1].source);
    try std.testing.expectEqualStrings("paid_at", m.mappings[1].target);
    try std.testing.expectEqualStrings("amount", m.mappings[2].source);
    try std.testing.expectEqualStrings("amount", m.mappings[2].target);
}

test "Mapper.mergeOverrides replaces target for matching source" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "paid_at" },
    };
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();

    try m.mergeOverrides(a,
        \\[{"source":"order_id","target":"id"}]
    );

    try std.testing.expectEqual(@as(usize, 2), m.mappings.len);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].source);
    try std.testing.expectEqualStrings("id", m.mappings[0].target);
    try std.testing.expectEqualStrings("paid_at", m.mappings[1].target);
}

test "Mapper.mergeOverrides with empty json is no-op" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{.{ .name = "x" }};
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();
    try m.mergeOverrides(a, "");
    try std.testing.expectEqual(@as(usize, 1), m.mappings.len);
    try std.testing.expectEqualStrings("x", m.mappings[0].target);
}

test "Mapper.mergeOverrides appends user-only mappings" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{.{ .name = "x" }};
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();

    try m.mergeOverrides(a,
        \\[{"source":"x","target":"y"},{"source":"z","target":"z_out"}]
    );

    try std.testing.expectEqual(@as(usize, 2), m.mappings.len);
    try std.testing.expectEqualStrings("x", m.mappings[0].source);
    try std.testing.expectEqualStrings("y", m.mappings[0].target);
    try std.testing.expectEqualStrings("z", m.mappings[1].source);
    try std.testing.expectEqualStrings("z_out", m.mappings[1].target);
}

test "applyNamingRule identity" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.identity, "order_id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("order_id", out);
}

test "applyNamingRule camel_to_snake converts orderId to order_id" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.camel_to_snake, "orderId", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("order_id", out);
}

test "applyNamingRule camel_to_snake handles consecutive capitals" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.camel_to_snake, "userIDNumber", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("user_i_d_number", out);
}

test "applyNamingRule snake_to_camel converts order_id to orderId" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.snake_to_camel, "order_id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("orderId", out);
}

test "applyNamingRule upper converts to UPPER" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.upper, "foo", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("FOO", out);
}

test "applyNamingRule lower converts to lower" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.lower, "FOO", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("foo", out);
}

test "applyNamingRule add_prefix prepends" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.{ .add_prefix = "dt_" }, "id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("dt_id", out);
}

test "applyNamingRule strip_prefix removes matching prefix" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.{ .strip_prefix = "dt_" }, "dt_id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("id", out);
}

test "applyNamingRule strip_prefix returns original if no match" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.{ .strip_prefix = "dt_" }, "id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("id", out);
}
