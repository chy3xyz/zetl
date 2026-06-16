//! 轻量 binlog 事件解析器
//!
//! 阶段 1 (Task 8): 解析事件头 + ROTATE_EVENT (位点更新) + HEARTBEAT_EVENT.
//! 阶段 2 (Task 9): 解析 TABLE_MAP_EVENT (缓存 table_id → 表定义) +
//!                   WRITE_ROWS_EVENT_V2 (生成 RowEvent 列表).
//! 阶段 2 (Task 3): DELETE_ROWS_EVENT_V2 解析 (before image).
//! 阶段 2 (Task 4): UPDATE_ROWS_EVENT_V2 解析 (before/after 双镜像).
//! 阶段 3 (后续): 更多 MySQL 字段类型解码.
//!
//! ## 支持的 MySQL 字段类型
//! - INTEGER 家族 (统一按无符号小端读取, 输出十进制字符串):
//!     TINYINT (0x01, 1B), SHORT (0x02, 2B), INT24 (0x09, 3B),
//!     LONG (0x03, 4B), LONGLONG (0x08, 8B)
//! - VARCHAR (0x0f): max_bytes ≤ 255 时按 1 字节长度 + N 字节数据解码.
//!
//! ## 不支持的类型 (占位 0 字节, 字段值固定为字符串 "TODO")
//! FLOAT / DOUBLE / DATE / TIME / DATETIME / TIMESTAMP / BLOB / TEXT /
//! JSON / DECIMAL / BIT / ENUM / SET / 几何类型 / 等.
//! 后续 Task 添加解码 (Task 9c).
//!
//! ## 限制
//! - 仅支持 ROWS_EVENT v2 (MySQL 5.6+ 默认); v1 (0x17) 未实现
//! - WRITE/UPDATE/DELETE_ROWS_EVENT_V2 已解析
//! - 列名固定为 `c0`, `c1`, ... (binlog 流不含列名, 需外部 transform 映射)
//! - 假定 binlog_row_image=FULL (binlog 含所有列, used_bitmap 全 1)
//! - column_metadata 暂不解析 (后续支持 VARCHAR>255/CHAR 时按类型步进)

const std = @import("std");
const event_mod = @import("../event.zig");
const position_mod = @import("position.zig");

pub const EventType = enum(u8) {
    rotate = 0x04,
    heartbeat = 0x1b,
    table_map = 0x13,
    write_rows_v2 = 0x1e,
    update_rows_v2 = 0x1f,
    delete_rows_v2 = 0x20,
    xid = 0x10,
    _,
};

pub const EventHeader = struct {
    timestamp: u32,
    type_code: u8,
    server_id: u32,
    event_size: u32,
    log_pos: u32,
    flags: u16,
};

/// 缓存的 table_id → 表定义.
/// 用于将后续 WRITE/UPDATE/DELETE_ROWS_EVENT 中的二进制列值映射到具体表/列.
/// 所有切片由 allocator 分配, deinit 时统一释放.
pub const TableMap = struct {
    table_id: u64,
    database: []const u8,
    table: []const u8,
    column_types: []const u8,
    column_metadata: []const u8,
    null_bitmap: []const u8,

    pub fn deinit(self: *TableMap, allocator: std.mem.Allocator) void {
        allocator.free(self.database);
        allocator.free(self.table);
        allocator.free(self.column_types);
        allocator.free(self.column_metadata);
        allocator.free(self.null_bitmap);
        self.* = undefined;
    }
};

pub const ParsedEvent = union(enum) {
    rotate: position_mod.Position,
    heartbeat,
    /// TABLE_MAP 已缓存到 Parser, 此 variant 携带内部缓存的副本.
    /// **注意**: 切片所有权在 Parser.table_maps, 外部不要 free, 也不要长期持有.
    table_map: TableMap,
    /// WRITE/UPDATE/DELETE_ROWS_EVENT 生成的行事件. 切片所有权属于调用方:
    ///   `for (rows) |*r| r.deinit(allocator); allocator.free(rows);`
    /// 调用方也可直接使用 `freeRowEvents(allocator, rows)` 辅助函数.
    row: []event_mod.RowEvent,
    unknown: EventHeader,
};

pub const ParseError = error{
    BufferTooShort,
    InvalidEvent,
    OutOfMemory,
    UnknownTableId,
};

// ============================================================================
// 公共 API
// ============================================================================

/// 解析 19 字节 binlog 事件头. buffer 太短时返回 error.BufferTooShort.
pub fn parseHeader(buffer: []const u8) ParseError!EventHeader {
    if (buffer.len < 19) return error.BufferTooShort;
    return .{
        .timestamp = std.mem.readInt(u32, buffer[0..4], .little),
        .type_code = buffer[4],
        .server_id = std.mem.readInt(u32, buffer[5..9], .little),
        .event_size = std.mem.readInt(u32, buffer[9..13], .little),
        .log_pos = std.mem.readInt(u32, buffer[13..17], .little),
        .flags = std.mem.readInt(u16, buffer[17..19], .little),
    };
}

/// 释放 `ParsedEvent.row` 切片. 调用方所有.
pub fn freeRowEvents(allocator: std.mem.Allocator, rows: []event_mod.RowEvent) void {
    for (rows) |*r| r.deinit(allocator);
    allocator.free(rows);
}

// ============================================================================
// Parser - 状态机: 缓存 TableMap, 处理事件流
// ============================================================================

pub const Parser = struct {
    allocator: std.mem.Allocator,
    /// table_id → TableMap. 解析 TABLE_MAP_EVENT 时填充,
    /// 解析 WRITE/UPDATE/DELETE_ROWS_EVENT 时查询.
    table_maps: std.AutoHashMap(u64, TableMap),

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .table_maps = std.AutoHashMap(u64, TableMap).init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        var it = self.table_maps.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.table_maps.deinit();
        self.* = undefined;
    }

    /// 派发单个 binlog 事件到对应的子解析器.
    /// - ROTATE → .rotate (更新 file + position)
    /// - HEARTBEAT → .heartbeat (无负载)
    /// - TABLE_MAP → .table_map (内部缓存 + 副本返回)
    /// - WRITE_ROWS_V2 → .row (RowEvent 切片)
    /// - DELETE_ROWS_V2 → .row (before image 填充到 before_fields)
    /// - UPDATE_ROWS_V2 → .row (before/after 双镜像)
    /// - 其它 → .unknown (原始 header)
    pub fn processEvent(self: *Parser, buffer: []const u8) ParseError!ParsedEvent {
        const header = try parseHeader(buffer);
        const event_type: EventType = @enumFromInt(header.type_code);

        // MySQL 在 binlog 事件尾部追加 4 字节 CRC32 校验和.
        // 这里假设服务端启用了 CRC32 (即非 binlog_checksum=NONE); 否则 event_size 不会包含 CRC,
        // 继续减 4 会截断真实 body. V3 默认要求 binlog_checksum = CRC32.
        if (header.event_size < 19) return error.InvalidEvent;
        const body_end = if (header.event_size >= 19 + 4) header.event_size - 4 else header.event_size;
        if (buffer.len < body_end) return error.BufferTooShort;
        const body = buffer[19..body_end];

        return switch (event_type) {
            .rotate => try parseRotate(self.allocator, header, body),
            .heartbeat => ParsedEvent.heartbeat,
            .table_map => try self.processTableMap(body),
            .write_rows_v2 => try self.parseWriteRows(header, body),
            .delete_rows_v2 => try self.parseDeleteRows(header, body),
            .update_rows_v2 => try self.parseUpdateRows(header, body),
            else => ParsedEvent{ .unknown = header },
        };
    }

    fn processTableMap(self: *Parser, body: []const u8) ParseError!ParsedEvent {
        var tm = try parseTableMap(self.allocator, body);
        errdefer tm.deinit(self.allocator);

        // 替换: 若同 table_id 已有旧 map, 释放后替换
        if (try self.table_maps.fetchPut(tm.table_id, tm)) |old| {
            var old_tm = old.value;
            old_tm.deinit(self.allocator);
        }
        // 返回缓存中的副本 (浅拷贝, 不分配). 调用方只读不可长期持有.
        const cached = self.table_maps.get(tm.table_id).?;
        return ParsedEvent{ .table_map = cached };
    }

    const RowsEventHeader = struct {
        table_id: u64,
        tm: TableMap,
        col_count: usize,
        used_bitmap: []const u8,
        used_columns: []usize,
        num_rows: usize,
        pos: usize,
        update_bitmap: ?[]const u8 = null,
    };

    /// 解析 WRITE/UPDATE/DELETE_ROWS_EVENT_V2 的公共前导部分:
    /// post-header (table_id + flags + extra_data_len) → table map 查询 →
    /// col_count → used_bitmap → (UPDATE 时 update_bitmap) → used_columns → num_rows.
    /// 返回的 `used_columns` 由调用方负责释放; `tm` 为 Parser 内部缓存, 只读不可长期持有。
    fn parseRowsEventHeader(
        self: *Parser,
        body: []const u8,
        has_update_bitmap: bool,
    ) ParseError!RowsEventHeader {
        var pos: usize = 0;

        // post-header (V2): table_id (6) + flags (2) + extra_data_length (2)
        if (body.len < pos + 6) return error.BufferTooShort;
        const table_id = readInt48(body[pos..][0..6]);
        pos += 6;

        if (body.len < pos + 2) return error.BufferTooShort;
        pos += 2; // flags (无符号后置过滤在 Parser.processEvent 入口)

        if (body.len < pos + 2) return error.BufferTooShort;
        const extra_data_len = std.mem.readInt(u16, body[pos..][0..2], .little);
        pos += 2;

        if (body.len < pos + extra_data_len) return error.BufferTooShort;
        pos += extra_data_len;

        // 查 table map
        const tm = self.table_maps.get(table_id) orelse return error.UnknownTableId;

        // column_count (packed int)
        const col_count_p = try readPackedInt(body[pos..]);
        pos += col_count_p.len;
        const col_count: usize = @intCast(col_count_p.value);

        // columns_used_bitmap
        const used_bitmap_len = (col_count + 7) / 8;
        if (body.len < pos + used_bitmap_len) return error.BufferTooShort;
        const used_bitmap = body[pos..][0..used_bitmap_len];
        pos += used_bitmap_len;

        // UPDATE_ROWS_EVENT_V2 在 used_bitmap 之后多一个 columns_used_for_update_bitmap
        var update_bitmap: ?[]const u8 = null;
        if (has_update_bitmap) {
            if (body.len < pos + used_bitmap_len) return error.BufferTooShort;
            update_bitmap = body[pos..][0..used_bitmap_len];
            pos += used_bitmap_len;
        }

        // 收集 used column 索引 (按列号升序)
        var used_columns = std.ArrayList(usize).empty;
        errdefer used_columns.deinit(self.allocator);
        for (0..col_count) |i| {
            if (isBitSet(used_bitmap, i)) {
                try used_columns.append(self.allocator, i);
            }
        }

        // row_count (packed int)
        const num_rows_p = try readPackedInt(body[pos..]);
        pos += num_rows_p.len;
        const num_rows: usize = @intCast(num_rows_p.value);

        return .{
            .table_id = table_id,
            .tm = tm,
            .col_count = col_count,
            .used_bitmap = used_bitmap,
            .used_columns = try used_columns.toOwnedSlice(self.allocator),
            .num_rows = num_rows,
            .pos = pos,
            .update_bitmap = update_bitmap,
        };
    }

    fn parseWriteRows(self: *Parser, header: EventHeader, body: []const u8) ParseError!ParsedEvent {
        const reh = try self.parseRowsEventHeader(body, false);
        defer self.allocator.free(reh.used_columns);

        const tm = reh.tm;
        var pos = reh.pos;

        var rows = std.ArrayList(event_mod.RowEvent).empty;
        errdefer {
            for (rows.items) |*r| r.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        for (0..reh.num_rows) |_| {
            var row = event_mod.RowEvent{
                .op = .insert,
                .table = try self.allocator.dupe(u8, tm.table),
                .database = try self.allocator.dupe(u8, tm.database),
                .fields = std.StringHashMap([]const u8).init(self.allocator),
                .timestamp = @as(i64, header.timestamp),
            };
            errdefer row.deinit(self.allocator);

            try self.readRowInto(&row.fields, tm, reh.used_columns, body, &pos);
            try rows.append(self.allocator, row);
        }

        return ParsedEvent{ .row = try rows.toOwnedSlice(self.allocator) };
    }

    fn parseDeleteRows(self: *Parser, header: EventHeader, body: []const u8) ParseError!ParsedEvent {
        const reh = try self.parseRowsEventHeader(body, false);
        defer self.allocator.free(reh.used_columns);

        const tm = reh.tm;
        var pos = reh.pos;

        var rows = std.ArrayList(event_mod.RowEvent).empty;
        errdefer {
            for (rows.items) |*r| r.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        for (0..reh.num_rows) |_| {
            var row = event_mod.RowEvent{
                .op = .delete,
                .table = try self.allocator.dupe(u8, tm.table),
                .database = try self.allocator.dupe(u8, tm.database),
                .fields = std.StringHashMap([]const u8).init(self.allocator),
                .timestamp = @as(i64, header.timestamp),
            };
            errdefer row.deinit(self.allocator);
            row.before_fields = std.StringHashMap([]const u8).init(self.allocator);

            // DELETE 仅含 before image, 填充到 before_fields; fields 保持为空.
            try self.readRowInto(&row.before_fields.?, tm, reh.used_columns, body, &pos);
            try rows.append(self.allocator, row);
        }

        return ParsedEvent{ .row = try rows.toOwnedSlice(self.allocator) };
    }

    fn parseUpdateRows(self: *Parser, header: EventHeader, body: []const u8) ParseError!ParsedEvent {
        const rh = try self.parseRowsEventHeader(body, true);
        defer self.allocator.free(rh.used_columns);

        // For FULL row image, update_bitmap should match used_bitmap.
        if (rh.update_bitmap) |ub| {
            if (!std.mem.eql(u8, rh.used_bitmap, ub)) {
                return error.InvalidEvent;
            }
        }

        const tm = rh.tm;
        var pos = rh.pos;

        var rows = std.ArrayList(event_mod.RowEvent).empty;
        errdefer {
            for (rows.items) |*r| r.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        for (0..rh.num_rows) |_| {
            var row = event_mod.RowEvent{
                .op = .update,
                .table = try self.allocator.dupe(u8, tm.table),
                .database = try self.allocator.dupe(u8, tm.database),
                .fields = std.StringHashMap([]const u8).init(self.allocator),
                .timestamp = @as(i64, header.timestamp),
            };
            errdefer row.deinit(self.allocator);

            row.before_fields = std.StringHashMap([]const u8).init(self.allocator);
            try self.readRowInto(&row.before_fields.?, tm, rh.used_columns, body, &pos);
            try self.readRowInto(&row.fields, tm, rh.used_columns, body, &pos);

            try rows.append(self.allocator, row);
        }

        return ParsedEvent{ .row = try rows.toOwnedSlice(self.allocator) };
    }

    /// 从 body 中读取一行的 null_bitmap 与 used_columns 指定列的字段值,
    /// 填充到 target 中. 列名固定为 `c{d}` 格式.
    /// `target` 必须已初始化; 本函数将 key/value 的所有权转移给 target (出错时释放).
    fn readRowInto(
        self: *Parser,
        target: *std.StringHashMap([]const u8),
        tm: TableMap,
        used_columns: []const usize,
        body: []const u8,
        pos: *usize,
    ) (ParseError || std.mem.Allocator.Error)!void {
        const null_bitmap_len = (used_columns.len + 7) / 8;
        if (body.len < pos.* + null_bitmap_len) return error.BufferTooShort;
        const null_bitmap = body[pos.*..][0..null_bitmap_len];
        pos.* += null_bitmap_len;

        for (used_columns, 0..) |col_idx, used_idx| {
            if (isBitSet(null_bitmap, used_idx)) continue; // NULL 跳过

            const col_type = tm.column_types[col_idx];
            const value = try readColumnValue(self.allocator, col_type, body, pos);
            errdefer self.allocator.free(value);

            const col_name = try std.fmt.allocPrint(self.allocator, "c{d}", .{col_idx});
            errdefer self.allocator.free(col_name);

            try target.put(col_name, value);
        }
    }
};

// ============================================================================
// 静态辅助函数
// ============================================================================

fn parseRotate(allocator: std.mem.Allocator, header: EventHeader, body: []const u8) ParseError!ParsedEvent {
    _ = header;
    if (body.len < 8) return error.BufferTooShort;
    const rot_pos = std.mem.readInt(u64, body[0..8], .little);
    const name_len = body.len - 8;
    const name = body[8..][0..name_len];
    return ParsedEvent{ .rotate = .{
        .file = try allocator.dupe(u8, name),
        .pos = rot_pos,
    } };
}

fn parseTableMap(allocator: std.mem.Allocator, body: []const u8) ParseError!TableMap {
    var pos: usize = 0;

    // table_id (6 bytes)
    if (body.len < pos + 6) return error.BufferTooShort;
    const table_id = readInt48(body[pos..][0..6]);
    pos += 6;

    // database_name_length (1 byte, 实际可变但目前 MySQL 用 1)
    if (body.len < pos + 1) return error.BufferTooShort;
    const db_len: usize = body[pos];
    pos += 1;

    if (body.len < pos + db_len) return error.BufferTooShort;
    const database = try allocator.dupe(u8, body[pos..][0..db_len]);
    pos += db_len;

    // null terminator
    if (body.len < pos + 1) return error.BufferTooShort;
    if (body[pos] != 0) return error.InvalidEvent;
    pos += 1;

    // table_name_length (1 byte)
    if (body.len < pos + 1) return error.BufferTooShort;
    const tbl_len: usize = body[pos];
    pos += 1;

    if (body.len < pos + tbl_len) return error.BufferTooShort;
    const table = try allocator.dupe(u8, body[pos..][0..tbl_len]);
    pos += tbl_len;

    if (body.len < pos + 1) return error.BufferTooShort;
    if (body[pos] != 0) return error.InvalidEvent;
    pos += 1;

    // column_count (packed int)
    const col_count_p = try readPackedInt(body[pos..]);
    pos += col_count_p.len;
    const col_count: usize = @intCast(col_count_p.value);

    // column_types
    if (body.len < pos + col_count) return error.BufferTooShort;
    const column_types = try allocator.dupe(u8, body[pos..][0..col_count]);
    pos += col_count;

    // column_metadata_length (packed int)
    const meta_len_p = try readPackedInt(body[pos..]);
    pos += meta_len_p.len;
    const meta_len: usize = @intCast(meta_len_p.value);

    // column_metadata
    if (body.len < pos + meta_len) return error.BufferTooShort;
    const column_metadata = try allocator.dupe(u8, body[pos..][0..meta_len]);
    pos += meta_len;

    // null_bitmap
    const null_bitmap_len = (col_count + 7) / 8;
    if (body.len < pos + null_bitmap_len) return error.BufferTooShort;
    const null_bitmap = try allocator.dupe(u8, body[pos..][0..null_bitmap_len]);
    pos += null_bitmap_len;

    return TableMap{
        .table_id = table_id,
        .database = database,
        .table = table,
        .column_types = column_types,
        .column_metadata = column_metadata,
        .null_bitmap = null_bitmap,
    };
}

const PackedInt = struct {
    value: u64,
    len: usize,
};

/// 读取 MySQL 长度编码整数 (packed integer, 1/3/4/9 字节).
/// 见 MySQL 协议: https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_data_types.html
fn readPackedInt(buf: []const u8) ParseError!PackedInt {
    if (buf.len < 1) return error.BufferTooShort;
    const first = buf[0];
    if (first < 0xfb) {
        return .{ .value = first, .len = 1 };
    } else if (first == 0xfb) {
        if (buf.len < 3) return error.BufferTooShort;
        return .{ .value = std.mem.readInt(u16, buf[1..3], .little), .len = 3 };
    } else if (first == 0xfc) {
        if (buf.len < 4) return error.BufferTooShort;
        return .{ .value = @as(u64, std.mem.readInt(u24, buf[1..4], .little)), .len = 4 };
    } else if (first == 0xfd or first == 0xfe) {
        if (buf.len < 9) return error.BufferTooShort;
        return .{ .value = std.mem.readInt(u64, buf[1..9], .little), .len = 9 };
    } else {
        // 0xff: NULL sentinel — packed int 不会出现, 但保险起见拒绝
        return error.InvalidEvent;
    }
}

fn readInt48(buf: []const u8) u64 {
    return @as(u64, buf[0]) |
        (@as(u64, buf[1]) << 8) |
        (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) |
        (@as(u64, buf[4]) << 32) |
        (@as(u64, buf[5]) << 40);
}

fn readInt24(buf: []const u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16);
}

fn isBitSet(bitmap: []const u8, bit: usize) bool {
    return (bitmap[bit / 8] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
}

/// 解码单个 MySQL 字段值, 返回堆分配的字符串.
/// 已知类型: 1/2/3/4/8 字节整数 (无符号小端, 输出十进制字符串) +
///           VARCHAR≤255 (1 字节长度 + N 字节).
/// 其他类型: 占位 0 字节, 返回 "TODO" 标记.
fn readColumnValue(allocator: std.mem.Allocator, col_type: u8, body: []const u8, pos: *usize) (ParseError || std.mem.Allocator.Error)![]const u8 {
    switch (col_type) {
        0x01 => { // MYSQL_TYPE_TINY (1B)
            if (body.len < pos.* + 1) return error.BufferTooShort;
            const v = body[pos.*];
            pos.* += 1;
            return std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        0x02 => { // MYSQL_TYPE_SHORT (2B)
            if (body.len < pos.* + 2) return error.BufferTooShort;
            const v = std.mem.readInt(u16, body[pos.*..][0..2], .little);
            pos.* += 2;
            return std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        0x09 => { // MYSQL_TYPE_INT24 (3B)
            if (body.len < pos.* + 3) return error.BufferTooShort;
            const v = readInt24(body[pos.*..][0..3]);
            pos.* += 3;
            return std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        0x03 => { // MYSQL_TYPE_LONG (4B)
            if (body.len < pos.* + 4) return error.BufferTooShort;
            const v = std.mem.readInt(u32, body[pos.*..][0..4], .little);
            pos.* += 4;
            return std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        0x08 => { // MYSQL_TYPE_LONGLONG (8B)
            if (body.len < pos.* + 8) return error.BufferTooShort;
            const v = std.mem.readInt(u64, body[pos.*..][0..8], .little);
            pos.* += 8;
            return std.fmt.allocPrint(allocator, "{d}", .{v});
        },
        0x0f => { // MYSQL_TYPE_VARCHAR (max_bytes ≤ 255: 1B len + N bytes)
            if (body.len < pos.* + 1) return error.BufferTooShort;
            const str_len: usize = body[pos.*];
            pos.* += 1;
            if (body.len < pos.* + str_len) return error.BufferTooShort;
            const value = try allocator.dupe(u8, body[pos.*..][0..str_len]);
            pos.* += str_len;
            return value;
        },
        else => {
            // TODO: 未实现的字段类型. 当前不读字节, 字段值标记为 "TODO".
            return allocator.dupe(u8, "TODO");
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parseHeader with buffer too short returns BufferTooShort" {
    var buf: [10]u8 = undefined; // < 19 字节
    @memset(&buf, 0);
    try std.testing.expectError(error.BufferTooShort, parseHeader(&buf));
    try std.testing.expectError(error.BufferTooShort, parseHeader(&.{}));
}

test "processEvent returns InvalidEvent when event_size < 19" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    var buf: [19]u8 = undefined;
    @memset(&buf, 0);
    buf[4] = 0x13; // TABLE_MAP
    std.mem.writeInt(u32, buf[5..9], 1, .little);
    std.mem.writeInt(u32, buf[9..13], 18, .little); // event_size < 19
    std.mem.writeInt(u32, buf[13..17], 0, .little);
    std.mem.writeInt(u16, buf[17..19], 0, .little);
    try std.testing.expectError(error.InvalidEvent, p.processEvent(&buf));
}

test "processEvent returns BufferTooShort when buffer shorter than body_end" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: event_size = 40 (含 CRC), 但 buffer 只有 35 字节, 小于 body_end = 36.
    var buf: [35]u8 = undefined;
    @memset(&buf, 0);
    buf[4] = 0x13;
    std.mem.writeInt(u32, buf[5..9], 1, .little);
    std.mem.writeInt(u32, buf[9..13], 40, .little);
    std.mem.writeInt(u32, buf[13..17], 0, .little);
    std.mem.writeInt(u16, buf[17..19], 0, .little);
    try std.testing.expectError(error.BufferTooShort, p.processEvent(&buf));
}

test "Parser init/deinit works" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    // 初始状态: table_maps 为空
    try std.testing.expectEqual(@as(usize, 0), p.table_maps.count());
    p.deinit();
}

test "Parser processEvent dispatches ROTATE / HEARTBEAT / unknown" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // ROTATE_EVENT: header(19) + pos(8) + name(10) + crc(4) = 41
    var buf: [41]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0, .little);
    buf[4] = 0x04; // ROTATE
    std.mem.writeInt(u32, buf[5..9], 1, .little);
    std.mem.writeInt(u32, buf[9..13], 41, .little);
    std.mem.writeInt(u32, buf[13..17], 0, .little);
    std.mem.writeInt(u16, buf[17..19], 0, .little);
    std.mem.writeInt(u64, buf[19..27], 12345, .little);
    @memcpy(buf[27..][0..10], "bin.000001");
    // bytes 37..40 为 CRC (已清零)

    var ev = try p.processEvent(&buf);
    try std.testing.expect(ev == .rotate);
    try std.testing.expectEqualStrings("bin.000001", ev.rotate.file orelse "");
    try std.testing.expectEqual(@as(u64, 12345), ev.rotate.pos);
    ev.rotate.deinit(a);

    // HEARTBEAT_EVENT: header(19) + crc(4) = 23
    var hb: [23]u8 = undefined;
    @memset(&hb, 0);
    hb[4] = 0x1b; // HEARTBEAT
    std.mem.writeInt(u32, hb[5..9], 1, .little);
    std.mem.writeInt(u32, hb[9..13], 23, .little);
    std.mem.writeInt(u32, hb[13..17], 0, .little);
    std.mem.writeInt(u16, hb[17..19], 0, .little);
    // bytes 19..22 为 CRC (已清零)
    ev = try p.processEvent(&hb);
    try std.testing.expect(ev == .heartbeat);

    // 未知事件: header(19) + crc(4) = 23
    var unk: [23]u8 = undefined;
    @memset(&unk, 0);
    unk[4] = 0x99; // 未知类型
    std.mem.writeInt(u32, unk[9..13], 23, .little);
    // bytes 19..22 为 CRC (已清零)
    ev = try p.processEvent(&unk);
    try std.testing.expect(ev == .unknown);
    try std.testing.expectEqual(@as(u8, 0x99), ev.unknown.type_code);
}

test "Parser parses TABLE_MAP and caches it" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP_EVENT layout: header(19) + body + crc(4)
    //   body = table_id(6) + db_len(1) + "db"(2) + NUL(1) + tbl_len(1) + "t"(1) + NUL(1) +
    //          col_count(1) + col_types(1) + meta_len(1) + null_bitmap(1) = 17
    //   event_size = 19 + 17 + 4 = 40
    var buf: [40]u8 = undefined;
    @memset(&buf, 0);
    // header
    std.mem.writeInt(u32, buf[0..4], 0, .little); // timestamp
    buf[4] = 0x13; // TABLE_MAP
    std.mem.writeInt(u32, buf[5..9], 1, .little); // server_id
    std.mem.writeInt(u32, buf[9..13], 40, .little); // event_size
    std.mem.writeInt(u32, buf[13..17], 0, .little); // log_pos
    std.mem.writeInt(u16, buf[17..19], 0, .little); // flags
    // body
    std.mem.writeInt(u48, buf[19..25], 0x42, .little); // table_id (6B LE)
    buf[25] = 2; // db_len
    @memcpy(buf[26..][0..2], "db");
    buf[28] = 0; // null term
    buf[29] = 1; // tbl_len
    @memcpy(buf[30..][0..1], "t");
    buf[31] = 0; // null term
    buf[32] = 1; // col_count (packed int)
    buf[33] = 0x01; // col_type: TINYINT
    buf[34] = 0; // meta_len
    buf[35] = 0; // null_bitmap (1 byte, all zero)
    // bytes 36..39 为 CRC (已清零)

    const ev = try p.processEvent(&buf);
    try std.testing.expect(ev == .table_map);
    try std.testing.expectEqualStrings("db", ev.table_map.database);
    try std.testing.expectEqualStrings("t", ev.table_map.table);
    try std.testing.expectEqual(@as(u64, 0x42), ev.table_map.table_id);
    try std.testing.expectEqual(@as(usize, 1), ev.table_map.column_types.len);

    // 缓存已建立: table_maps 应有 1 个 entry
    try std.testing.expectEqual(@as(usize, 1), p.table_maps.count());
}

test "Parser parses WRITE_ROWS_V2 with single TINYINT row" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // 1. 先发 TABLE_MAP (1 col TINYINT). body = 17 字节, event_size = 19 + 17 + 4 = 40.
    var tm_buf: [40]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 40, .little);
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    std.mem.writeInt(u48, tm_buf[19..25], 0x42, .little);
    tm_buf[25] = 2;
    @memcpy(tm_buf[26..][0..2], "db");
    tm_buf[28] = 0;
    tm_buf[29] = 1;
    @memcpy(tm_buf[30..][0..1], "t");
    tm_buf[31] = 0;
    tm_buf[32] = 1; // 1 col
    tm_buf[33] = 0x01; // TINYINT
    tm_buf[34] = 0; // no metadata
    tm_buf[35] = 0; // null_bitmap
    // bytes 36..39 为 CRC (已清零)
    _ = try p.processEvent(&tm_buf);

    // 2. 发 WRITE_ROWS_V2: 1 行, 1 列 = 42.
    //    body = post-header(10) + col_count(1) + used_bitmap(1) +
    //           num_rows(1) + null_bitmap(1) + value(1) = 15.
    //    event_size = 19 + 15 + 4 = 38.
    var wr_buf: [38]u8 = undefined;
    @memset(&wr_buf, 0);
    // header
    std.mem.writeInt(u32, wr_buf[0..4], 0x12345678, .little);
    wr_buf[4] = 0x1e; // WRITE_ROWS_V2
    std.mem.writeInt(u32, wr_buf[5..9], 1, .little);
    std.mem.writeInt(u32, wr_buf[9..13], 38, .little);
    std.mem.writeInt(u32, wr_buf[13..17], 0, .little);
    std.mem.writeInt(u16, wr_buf[17..19], 0, .little);
    // body
    std.mem.writeInt(u48, wr_buf[19..25], 0x42, .little); // table_id
    wr_buf[25] = 0;
    wr_buf[26] = 0; // flags + extra_data_len = 0 (默认 memset)
    wr_buf[27] = 0;
    wr_buf[28] = 0;
    wr_buf[29] = 1; // col_count = 1
    wr_buf[30] = 0x01; // used_bitmap (col 0 used)
    wr_buf[31] = 1; // num_rows = 1
    wr_buf[32] = 0x00; // null_bitmap (no NULL)
    wr_buf[33] = 42; // value
    // bytes 34..37 为 CRC (已清零)

    var ev = try p.processEvent(&wr_buf);
    defer freeRowEvents(a, ev.row);

    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    const row = &ev.row[0];
    try std.testing.expectEqual(event_mod.RowOp.insert, row.op);
    try std.testing.expectEqualStrings("t", row.table);
    try std.testing.expectEqualStrings("db", row.database);
    try std.testing.expectEqual(@as(i64, 0x12345678), row.timestamp);
    try std.testing.expectEqual(@as(usize, 1), row.fields.count());
    try std.testing.expectEqualStrings("42", row.getField("c0").?);
}

test "Parser parses WRITE_ROWS_V2 with VARCHAR and LONGLONG columns" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 3 cols [LONGLONG, VARCHAR, INT24], db="mydb", tbl="tbl"
    //   body = table_id(6) + db_len(1) + "mydb"(4) + NUL(1) +
    //          tbl_len(1) + "tbl"(3) + NUL(1) + col_count(1) + col_types(3) +
    //          meta_len(1) + meta(0) + null_bitmap(1)
    //   = 6+1+4+1+1+3+1+1+3+1+0+1 = 23. event_size = 19 + 23 + 4 = 46.
    var tm_buf: [46]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 46, .little);
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    std.mem.writeInt(u48, tm_buf[19..25], 0x10, .little); // table_id
    tm_buf[25] = 4;
    @memcpy(tm_buf[26..][0..4], "mydb");
    tm_buf[30] = 0;
    tm_buf[31] = 3;
    @memcpy(tm_buf[32..][0..3], "tbl");
    tm_buf[35] = 0;
    tm_buf[36] = 3; // col_count
    tm_buf[37] = 0x08; // LONGLONG
    tm_buf[38] = 0x0f; // VARCHAR
    tm_buf[39] = 0x09; // INT24
    tm_buf[40] = 0; // meta_len = 0
    tm_buf[41] = 0; // null_bitmap (1 byte, no NULL)
    // bytes 42..45 为 CRC (已清零)
    _ = try p.processEvent(&tm_buf);

    // WRITE_ROWS_V2: 1 行, 3 列 = [12345, "hi", 0x123456]
    //   col values: LONGLONG(8B) + VARCHAR(1B len + 2B) + INT24(3B) = 14
    //   body = post-header(10) + col_count(1) + used_bitmap(1) + num_rows(1) +
    //          null_bitmap(1) + values(14) = 28. event_size = 19 + 28 + 4 = 51.
    var wr_buf: [51]u8 = undefined;
    @memset(&wr_buf, 0);
    std.mem.writeInt(u32, wr_buf[0..4], 0, .little);
    wr_buf[4] = 0x1e;
    std.mem.writeInt(u32, wr_buf[5..9], 1, .little);
    std.mem.writeInt(u32, wr_buf[9..13], 51, .little);
    std.mem.writeInt(u32, wr_buf[13..17], 0, .little);
    std.mem.writeInt(u16, wr_buf[17..19], 0, .little);
    // body
    std.mem.writeInt(u48, wr_buf[19..25], 0x10, .little); // table_id
    // flags + extra_data_len 默认 memset 为 0
    wr_buf[29] = 3; // col_count
    wr_buf[30] = 0x07; // used_bitmap: cols 0,1,2 used
    wr_buf[31] = 1; // num_rows
    wr_buf[32] = 0x00; // null_bitmap (no NULL)
    // values: LONGLONG = 12345 (0x3039)
    std.mem.writeInt(u64, wr_buf[33..41], 12345, .little);
    // VARCHAR = "hi"
    wr_buf[41] = 2;
    @memcpy(wr_buf[42..][0..2], "hi");
    // INT24 = 0x123456 (1193046)
    wr_buf[44] = 0x56;
    wr_buf[45] = 0x34;
    wr_buf[46] = 0x12;
    // bytes 47..50 为 CRC (已清零)

    var ev = try p.processEvent(&wr_buf);
    defer freeRowEvents(a, ev.row);

    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    const row = &ev.row[0];
    try std.testing.expectEqualStrings("mydb", row.database);
    try std.testing.expectEqualStrings("tbl", row.table);
    try std.testing.expectEqual(@as(usize, 3), row.fields.count());
    try std.testing.expectEqualStrings("12345", row.getField("c0").?);
    try std.testing.expectEqualStrings("hi", row.getField("c1").?);
    try std.testing.expectEqualStrings("1193046", row.getField("c2").?);
}

test "Parser WRITE_ROWS_V2 returns empty for unknown table_id" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // 没注册 TABLE_MAP, 直接发 WRITE_ROWS_V2
    // body = 15 字节, event_size = 19 + 15 + 4 = 38
    var wr_buf: [38]u8 = undefined;
    @memset(&wr_buf, 0);
    std.mem.writeInt(u32, wr_buf[0..4], 0, .little);
    wr_buf[4] = 0x1e;
    std.mem.writeInt(u32, wr_buf[5..9], 1, .little);
    std.mem.writeInt(u32, wr_buf[9..13], 38, .little);
    std.mem.writeInt(u32, wr_buf[13..17], 0, .little);
    std.mem.writeInt(u16, wr_buf[17..19], 0, .little);
    std.mem.writeInt(u48, wr_buf[19..25], 0xff, .little);
    // 其它字段不重要, 期望在 lookup 时返回 UnknownTableId
    // bytes 34..37 为 CRC (已清零)
    try std.testing.expectError(error.UnknownTableId, p.processEvent(&wr_buf));
}

test "Parser parses UPDATE_ROWS_V2 with before and after images" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 2 cols [TINYINT, VARCHAR], db="db", tbl="t", body=18, event_size=41
    var tm_buf: [80]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 41, .little);
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    var tpos: usize = 19;
    std.mem.writeInt(u48, tm_buf[tpos..][0..6], 0x42, .little);
    tpos += 6;
    tm_buf[tpos] = 2;
    tpos += 1;
    @memcpy(tm_buf[tpos..][0..2], "db");
    tpos += 2;
    tm_buf[tpos] = 0;
    tpos += 1;
    tm_buf[tpos] = 1;
    tpos += 1;
    @memcpy(tm_buf[tpos..][0..1], "t");
    tpos += 1;
    tm_buf[tpos] = 0;
    tpos += 1;
    tm_buf[tpos] = 2;
    tpos += 1;
    tm_buf[tpos] = 0x01;
    tpos += 1;
    tm_buf[tpos] = 0x0f;
    tpos += 1;
    tm_buf[tpos] = 0;
    tpos += 1;
    tm_buf[tpos] = 0;
    tpos += 1;
    _ = try p.processEvent(&tm_buf);

    // UPDATE_ROWS_V2 layout:
    // post-header(10) + col_count(1) + used_bitmap(1) + update_bitmap(1) +
    // num_rows(1) + before_null_bitmap(1) + before_values(TINYINT=1, VARCHAR=1+1) +
    // after_null_bitmap(1) + after_values(TINYINT=1, VARCHAR=1+1) = 22
    // event_size = 19 + 22 + 4 = 45
    var upd_buf: [80]u8 = undefined;
    @memset(&upd_buf, 0);
    std.mem.writeInt(u32, upd_buf[0..4], 0, .little);
    upd_buf[4] = 0x1f; // UPDATE_ROWS_V2
    std.mem.writeInt(u32, upd_buf[5..9], 1, .little);
    std.mem.writeInt(u32, upd_buf[9..13], 45, .little);
    std.mem.writeInt(u32, upd_buf[13..17], 0, .little);
    std.mem.writeInt(u16, upd_buf[17..19], 0, .little);
    std.mem.writeInt(u48, upd_buf[19..25], 0x42, .little);
    upd_buf[29] = 2; // col_count
    upd_buf[30] = 0x03; // used_bitmap: cols 0,1 used
    upd_buf[31] = 0x03; // update_bitmap: cols 0,1 used for update
    upd_buf[32] = 1; // num_rows
    // before image: id=5, name="a"
    upd_buf[33] = 0x00; // before null_bitmap
    upd_buf[34] = 5; // id
    upd_buf[35] = 1; // varchar len
    @memcpy(upd_buf[36..][0..1], "a");
    // after image: id=5, name="b"
    upd_buf[37] = 0x00; // after null_bitmap
    upd_buf[38] = 5; // id
    upd_buf[39] = 1; // varchar len
    @memcpy(upd_buf[40..][0..1], "b");

    var ev = try p.processEvent(&upd_buf);
    defer freeRowEvents(a, ev.row);

    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    const row = &ev.row[0];
    try std.testing.expectEqual(event_mod.RowOp.update, row.op);
    try std.testing.expectEqualStrings("5", row.getBeforeField("c0").?);
    try std.testing.expectEqualStrings("a", row.getBeforeField("c1").?);
    try std.testing.expectEqualStrings("5", row.getField("c0").?);
    try std.testing.expectEqualStrings("b", row.getField("c1").?);
}

test "readPackedInt handles 1 / 3 / 4 / 9 byte encodings" {
    // 1 byte
    var buf1: [1]u8 = .{42};
    var r = try readPackedInt(&buf1);
    try std.testing.expectEqual(@as(u64, 42), r.value);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    // 250 (max 1-byte)
    buf1[0] = 250;
    r = try readPackedInt(&buf1);
    try std.testing.expectEqual(@as(u64, 250), r.value);

    // 3 byte (0xfb + u16)
    var buf3: [3]u8 = .{ 0xfb, 0x00, 0x01 };
    r = try readPackedInt(&buf3);
    try std.testing.expectEqual(@as(u64, 256), r.value);
    try std.testing.expectEqual(@as(usize, 3), r.len);

    // 4 byte (0xfc + u24): 0xfc, 0x00, 0x01, 0x00 → u24 = 0x000100 = 256
    var buf4: [4]u8 = .{ 0xfc, 0x00, 0x01, 0x00 };
    r = try readPackedInt(&buf4);
    try std.testing.expectEqual(@as(u64, 256), r.value);
    try std.testing.expectEqual(@as(usize, 4), r.len);

    // 4 byte 大值: 0xfc, 0xff, 0xff, 0x00 → u24 = 0x00ffff = 65535
    buf4 = .{ 0xfc, 0xff, 0xff, 0x00 };
    r = try readPackedInt(&buf4);
    try std.testing.expectEqual(@as(u64, 65535), r.value);

    // 9 byte (0xfd + u64)
    var buf9: [9]u8 = .{ 0xfd, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    r = try readPackedInt(&buf9);
    try std.testing.expectEqual(@as(u64, 1), r.value);
    try std.testing.expectEqual(@as(usize, 9), r.len);
}

test "Parser parses DELETE_ROWS_V2 with before_fields" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 2 cols [TINYINT, VARCHAR], db="db", tbl="t"
    var tm_buf: [80]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 41, .little); // 19 + 18 body + 4 CRC
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    var tpos: usize = 19;
    std.mem.writeInt(u48, tm_buf[tpos..][0..6], 0x42, .little);
    tpos += 6;
    tm_buf[tpos] = 2;
    tpos += 1; // db_len
    @memcpy(tm_buf[tpos..][0..2], "db");
    tpos += 2;
    tm_buf[tpos] = 0;
    tpos += 1;
    tm_buf[tpos] = 1;
    tpos += 1; // tbl_len
    @memcpy(tm_buf[tpos..][0..1], "t");
    tpos += 1;
    tm_buf[tpos] = 0;
    tpos += 1;
    tm_buf[tpos] = 2;
    tpos += 1; // col_count
    tm_buf[tpos] = 0x01;
    tpos += 1; // TINYINT
    tm_buf[tpos] = 0x0f;
    tpos += 1; // VARCHAR
    tm_buf[tpos] = 0;
    tpos += 1; // meta_len
    tm_buf[tpos] = 0;
    tpos += 1; // null_bitmap
    _ = try p.processEvent(&tm_buf);

    // DELETE_ROWS_V2: 1 row [id=7, name="x"]
    // body = 10 (post-header) + 1 (col_count) + 1 (used_bitmap) + 1 (num_rows)
    //      + 1 (null_bitmap) + 1 (TINYINT) + 2 (VARCHAR len + data) = 17
    // event_size = 19 + 17 + 4 = 40
    var del_buf: [80]u8 = undefined;
    @memset(&del_buf, 0);
    std.mem.writeInt(u32, del_buf[0..4], 0, .little);
    del_buf[4] = 0x20; // DELETE_ROWS_V2
    std.mem.writeInt(u32, del_buf[5..9], 1, .little);
    std.mem.writeInt(u32, del_buf[9..13], 40, .little);
    std.mem.writeInt(u32, del_buf[13..17], 0, .little);
    std.mem.writeInt(u16, del_buf[17..19], 0, .little);
    std.mem.writeInt(u48, del_buf[19..25], 0x42, .little);
    del_buf[29] = 2; // col_count
    del_buf[30] = 0x03; // used_bitmap: cols 0,1 used
    del_buf[31] = 1; // num_rows
    del_buf[32] = 0x00; // null_bitmap
    del_buf[33] = 7; // id
    del_buf[34] = 1; // varchar len
    @memcpy(del_buf[35..][0..1], "x");

    var ev = try p.processEvent(&del_buf);
    defer freeRowEvents(a, ev.row);

    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    const row = &ev.row[0];
    try std.testing.expectEqual(event_mod.RowOp.delete, row.op);
    try std.testing.expectEqualStrings("7", row.getBeforeField("c0").?);
    try std.testing.expectEqualStrings("x", row.getBeforeField("c1").?);
    try std.testing.expectEqual(@as(usize, 0), row.fields.count());
}

test "processEvent strips 4-byte binlog checksum from WRITE_ROWS_V2" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 1 col TINYINT, db="db", tbl="t", body = 17 bytes, event_size = 19 + 17 + 4 = 40.
    var tm_buf: [40]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 40, .little);
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    std.mem.writeInt(u48, tm_buf[19..25], 0x42, .little);
    tm_buf[25] = 2;
    @memcpy(tm_buf[26..][0..2], "db");
    tm_buf[28] = 0;
    tm_buf[29] = 1;
    @memcpy(tm_buf[30..][0..1], "t");
    tm_buf[31] = 0;
    tm_buf[32] = 1;
    tm_buf[33] = 0x01; // TINYINT
    tm_buf[34] = 0;
    tm_buf[35] = 0;
    // bytes 36..39 为 CRC (已清零)
    _ = try p.processEvent(&tm_buf);

    // WRITE_ROWS_V2: 1 row, 1 col = 42. body = 15 bytes, event_size = 19 + 15 + 4 = 38.
    var wr_buf: [38]u8 = undefined;
    @memset(&wr_buf, 0);
    std.mem.writeInt(u32, wr_buf[0..4], 0, .little);
    wr_buf[4] = 0x1e;
    std.mem.writeInt(u32, wr_buf[5..9], 1, .little);
    std.mem.writeInt(u32, wr_buf[9..13], 38, .little);
    std.mem.writeInt(u32, wr_buf[13..17], 0, .little);
    std.mem.writeInt(u16, wr_buf[17..19], 0, .little);
    std.mem.writeInt(u48, wr_buf[19..25], 0x42, .little);
    wr_buf[29] = 1; // col_count
    wr_buf[30] = 0x01; // used_bitmap
    wr_buf[31] = 1; // num_rows
    wr_buf[32] = 0x00; // null_bitmap
    wr_buf[33] = 42; // value
    // bytes 34..37 为 CRC (已清零)

    var ev = try p.processEvent(&wr_buf);
    defer freeRowEvents(a, ev.row);
    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    try std.testing.expectEqualStrings("42", ev.row[0].getField("c0").?);
}
