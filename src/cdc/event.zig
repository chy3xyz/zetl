//! CDC 统一行事件
//! V1/V2 伪 CDC: 只产生 after map (无 before), 删除按软删 is_delete 字段
//! V3 binlog CDC: 支持 before/after 双镜像, 可感知物理 DELETE

const std = @import("std");

pub const RowOp = enum {
    insert,
    update,
    delete,
};

/// 所有字符串字段 (table, database, pk_value, fields 的 key/value,
/// before_fields 的 key/value) 必须由 allocator 分配, 由 deinit 统一释放.
pub const RowEvent = struct {
    op: RowOp = .insert,
    table: []const u8 = "",
    database: []const u8 = "",
    fields: std.StringHashMap([]const u8),
    timestamp: i64 = 0,
    /// 主键值 (字符串, 来自源库, 可能需要类型转换)
    pk_value: []const u8 = "",
    before_fields: ?std.StringHashMap([]const u8) = null,

    pub fn deinit(self: *RowEvent, allocator: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.fields.deinit();
        if (self.before_fields) |*bf| {
            var bit = bf.iterator();
            while (bit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            bf.deinit();
        }
        allocator.free(self.table);
        allocator.free(self.database);
        allocator.free(self.pk_value);
    }

    pub fn getField(self: *const RowEvent, name: []const u8) ?[]const u8 {
        return self.fields.get(name);
    }

    pub fn getBeforeField(self: *const RowEvent, name: []const u8) ?[]const u8 {
        if (self.before_fields) |bf| return bf.get(name);
        return null;
    }
};


test "RowEvent deinit frees fields and before_fields" {
    const a = std.testing.allocator;
    var ev = RowEvent{
        .op = .update,
        .table = try a.dupe(u8, "order_info"),
        .database = try a.dupe(u8, "shop_db"),
        .fields = std.StringHashMap([]const u8).init(a),
        .before_fields = std.StringHashMap([]const u8).init(a),
        .pk_value = try a.dupe(u8, "42"),
    };
    try ev.fields.put(try a.dupe(u8, "order_total"), try a.dupe(u8, "100.00"));
    try ev.before_fields.?.put(try a.dupe(u8, "order_total"), try a.dupe(u8, "90.00"));
    try std.testing.expectEqualStrings("100.00", ev.getField("order_total").?);
    try std.testing.expectEqualStrings("90.00", ev.getBeforeField("order_total").?);
    ev.deinit(a);
}

test "RowEvent without before_fields" {
    const a = std.testing.allocator;
    var ev = RowEvent{
        .op = .insert,
        .table = try a.dupe(u8, "order_info"),
        .database = try a.dupe(u8, "shop_db"),
        .fields = std.StringHashMap([]const u8).init(a),
        .pk_value = try a.dupe(u8, "1"),
    };
    try ev.fields.put(try a.dupe(u8, "mall_id"), try a.dupe(u8, "mall_001"));
    try std.testing.expect(ev.getBeforeField("mall_id") == null);
    ev.deinit(a);
}
