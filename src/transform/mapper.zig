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
