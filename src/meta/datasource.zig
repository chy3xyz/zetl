//! 数据源 Model + Service
//! 密码字段: 写入加密, 读出明文 (service 层加解密, 不暴露 Model 字段)

const std = @import("std");
const zfinal = @import("zfinal");
const common = @import("../common/mod.zig");
const store_mod = @import("store.zig");

/// 数据源 (不含密码, 仅运行时使用)
pub const Datasource = struct {
    id: i64,
    mall_id: []const u8,
    ds_type: []const u8,
    host: []const u8,
    port: u16,
    db_name: []const u8,
    username: []const u8,
    password: []const u8, // 明文
    remark: ?[]const u8,
    status: i32,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: *Datasource, allocator: std.mem.Allocator) void {
        allocator.free(self.mall_id);
        allocator.free(self.ds_type);
        allocator.free(self.host);
        allocator.free(self.db_name);
        allocator.free(self.username);
        allocator.free(self.password);
        if (self.remark) |r| allocator.free(r);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

/// 用于创建数据源 (含明文密码)
pub const CreateInput = struct {
    mall_id: []const u8,
    ds_type: []const u8 = "mysql",
    host: []const u8,
    port: u16 = 3306,
    db_name: []const u8,
    username: []const u8,
    password: []const u8, // 明文
    remark: ?[]const u8 = null,
    status: i32 = 1,
};

pub const Service = struct {
    pub fn insert(store: *store_mod.MetaStore, allocator: std.mem.Allocator, input: CreateInput) !i64 {
        const enc_pw = try common.crypto.encrypt(allocator, input.password);
        defer allocator.free(enc_pw);

        const sql_owner = struct {
            const S = "INSERT INTO datasource (mall_id, ds_type, host, port, db_name, username, password, remark, status) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)";
        }.S;

        const remark_param: zfinal.SqlParam = if (input.remark) |r| .{ .text = r } else .null;

        const params = [_]zfinal.SqlParam{
            .{ .text = input.mall_id },
            .{ .text = input.ds_type },
            .{ .text = input.host },
            .{ .int = input.port },
            .{ .text = input.db_name },
            .{ .text = input.username },
            .{ .text = enc_pw },
            remark_param,
            .{ .int = input.status },
        };

        try store.db.execParams(@ptrCast(sql_owner), &params);
        return try store.db.lastInsertId();
    }

    pub fn findById(store: *store_mod.MetaStore, allocator: std.mem.Allocator, id: i64) !?Datasource {
        const sql: [:0]const u8 = "SELECT id, mall_id, ds_type, host, port, db_name, username, password, COALESCE(remark,''), status, created_at, updated_at FROM datasource WHERE id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = id }});
        defer result.deinit();
        if (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                return try rowToDatasource(allocator, row);
            }
        }
        return null;
    }

    pub fn findByMallId(store: *store_mod.MetaStore, allocator: std.mem.Allocator, mall_id: []const u8) !?Datasource {
        const sql: [:0]const u8 = "SELECT id, mall_id, ds_type, host, port, db_name, username, password, COALESCE(remark,''), status, created_at, updated_at FROM datasource WHERE mall_id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .text = mall_id }});
        defer result.deinit();
        if (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                return try rowToDatasource(allocator, row);
            }
        }
        return null;
    }

    pub fn findAll(store: *store_mod.MetaStore, allocator: std.mem.Allocator) ![]Datasource {
        const sql: [:0]const u8 = "SELECT id, mall_id, ds_type, host, port, db_name, username, password, COALESCE(remark,''), status, created_at, updated_at FROM datasource ORDER BY id DESC";
        var result = try store.db.query(sql);
        defer result.deinit();
        var list = std.ArrayList(Datasource).empty;
        errdefer {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
        }
        while (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                try list.append(allocator, try rowToDatasource(allocator, row));
            }
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn findEnabled(store: *store_mod.MetaStore, allocator: std.mem.Allocator) ![]Datasource {
        const sql: [:0]const u8 = "SELECT id, mall_id, ds_type, host, port, db_name, username, password, COALESCE(remark,''), status, created_at, updated_at FROM datasource WHERE status = 1";
        var result = try store.db.query(sql);
        defer result.deinit();
        var list = std.ArrayList(Datasource).empty;
        errdefer {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
        }
        while (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                try list.append(allocator, try rowToDatasource(allocator, row));
            }
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn deleteById(store: *store_mod.MetaStore, id: i64) !void {
        const sql: [:0]const u8 = "DELETE FROM datasource WHERE id = $1";
        try store.db.execParams(sql, &.{.{ .int = id }});
    }

    /// 检查数据源是否被任务绑定
    pub fn hasTaskBinding(store: *store_mod.MetaStore, id: i64) !bool {
        const sql: [:0]const u8 = "SELECT COUNT(*) FROM sync_task WHERE datasource_id = $1";
        var result = try store.db.queryParams(sql, &.{.{ .int = id }});
        defer result.deinit();
        if (result.next()) {
            if (try result.getInt(0)) |c| return c > 0;
        }
        return false;
    }

    fn rowToDatasource(allocator: std.mem.Allocator, row: zfinal.ResultSet.RowMap) !Datasource {
        const enc_pw = row.get("password") orelse "";
        const plain_pw = if (enc_pw.len == 0) try allocator.dupe(u8, "") else try common.crypto.decrypt(allocator, enc_pw);

        const id_s = row.get("id") orelse "0";
        const mall_s = row.get("mall_id") orelse "";
        const dst_s = row.get("ds_type") orelse "mysql";
        const host_s = row.get("host") orelse "";
        const port_s = row.get("port") orelse "3306";
        const dbname_s = row.get("db_name") orelse "";
        const user_s = row.get("username") orelse "";
        const remark_s = row.get("remark") orelse "";
        const status_s = row.get("status") orelse "1";
        const ca_s = row.get("created_at") orelse "";
        const ua_s = row.get("updated_at") orelse "";

        return .{
            .id = try std.fmt.parseInt(i64, id_s, 10),
            .mall_id = try allocator.dupe(u8, mall_s),
            .ds_type = try allocator.dupe(u8, dst_s),
            .host = try allocator.dupe(u8, host_s),
            .port = @intCast(try std.fmt.parseInt(u16, port_s, 10)),
            .db_name = try allocator.dupe(u8, dbname_s),
            .username = try allocator.dupe(u8, user_s),
            .password = plain_pw,
            .remark = if (remark_s.len == 0) null else try allocator.dupe(u8, remark_s),
            .status = try std.fmt.parseInt(i32, status_s, 10),
            .created_at = try allocator.dupe(u8, ca_s),
            .updated_at = try allocator.dupe(u8, ua_s),
        };
    }
};

test "datasource service - insert/find/delete" {
    const a = std.testing.allocator;
    const cfg = zfinal.DBConfig.sqliteMemory();
    var db = try zfinal.DB.init(a, cfg);
    defer db.deinit();
    _ = try db.exec(
        \\CREATE TABLE IF NOT EXISTS datasource (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  mall_id TEXT NOT NULL UNIQUE,
        \\  ds_type TEXT NOT NULL DEFAULT 'mysql',
        \\  host TEXT NOT NULL,
        \\  port INTEGER NOT NULL DEFAULT 3306,
        \\  db_name TEXT NOT NULL,
        \\  username TEXT NOT NULL,
        \\  password TEXT NOT NULL,
        \\  remark TEXT,
        \\  status INTEGER NOT NULL DEFAULT 1,
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  updated_at TEXT DEFAULT (datetime('now'))
        \\)
    );

    var store = store_mod.MetaStore{ .allocator = a, .db = db };
    const id = try Service.insert(&store, a, .{
        .mall_id = "test_mall",
        .host = "127.0.0.1",
        .db_name = "shop",
        .username = "user",
        .password = "secret123",
    });
    try std.testing.expect(id > 0);

    const found = (try Service.findById(&store, a, id)).?;
    defer {
        var f = found;
        f.deinit(a);
    }
    try std.testing.expectEqualStrings("test_mall", found.mall_id);
    try std.testing.expectEqualStrings("secret123", found.password);

    try Service.deleteById(&store, id);
    const after = try Service.findById(&store, a, id);
    try std.testing.expect(after == null);
}
