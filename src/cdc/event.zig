//! CDC 统一行事件
//! 伪 CDC 模式: 只产生 after map (无 before), 删除按软删 is_delete 字段
//! 见 docs/superpowers/specs/2026-06-16-zetl-v1-design.md §3.1

const std = @import("std");

pub const RowOp = enum {
    insert,
    update,
    delete,
};

pub const RowEvent = struct {
    op: RowOp = .insert,
    table: []const u8 = "",
    database: []const u8 = "",
    fields: std.StringHashMap([]const u8),
    timestamp: i64 = 0,
    /// 主键值 (字符串, 来自源库, 可能需要类型转换)
    pk_value: []const u8 = "",

    pub fn deinit(self: *RowEvent, allocator: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.fields.deinit();
        allocator.free(self.table);
        allocator.free(self.database);
        allocator.free(self.pk_value);
    }

    pub fn getField(self: *const RowEvent, name: []const u8) ?[]const u8 {
        return self.fields.get(name);
    }
};
