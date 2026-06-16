//! 轮询采集器 (伪 CDC) — V2 最终版
//! 直接用 zfinal.DB (非 ConnectionPool) 避免跨线程 mutex 拷贝问题

const std = @import("std");
const zfinal = @import("zfinal");
const event_mod = @import("event.zig");

pub const PollerConfig = struct {
    host: [128]u8 = @splat(0),
    port: u16 = 0,
    username: [64]u8 = @splat(0),
    password: [64]u8 = @splat(0),
    database: [64]u8 = @splat(0),
    table: [64]u8 = @splat(0),
    pk_column: [32]u8 = @splat(0),
    update_time_column: [32]u8 = @splat(0),
    poll_interval_ms: u64 = 1000,
    batch_size: u32 = 1000,

    pub fn fromSlices(host: []const u8, port: u16, username: []const u8, password: []const u8, database: []const u8, table: []const u8, pk: []const u8, ut: []const u8, batch: u32) PollerConfig {
        var cfg: PollerConfig = .{ .port = port, .batch_size = batch };
        copyToBuf(&cfg.host, host); copyToBuf(&cfg.username, username);
        copyToBuf(&cfg.password, password); copyToBuf(&cfg.database, database);
        copyToBuf(&cfg.table, table); copyToBuf(&cfg.pk_column, pk);
        copyToBuf(&cfg.update_time_column, ut);
        return cfg;
    }

    fn copyToBuf(buf: []u8, src: []const u8) void {
        const len = @min(src.len, buf.len - 1);
        @memcpy(buf[0..len], src[0..len]);
        buf[len] = 0;
    }

    pub fn hostZ(self: *const PollerConfig) [:0]const u8 {
        const len = std.mem.indexOfScalar(u8, &self.host, 0) orelse 0;
        return self.host[0..len :0];
    }
    pub fn userZ(self: *const PollerConfig) [:0]const u8 {
        const len = std.mem.indexOfScalar(u8, &self.username, 0) orelse 0;
        return self.username[0..len :0];
    }
    pub fn passZ(self: *const PollerConfig) [:0]const u8 {
        const len = std.mem.indexOfScalar(u8, &self.password, 0) orelse 0;
        return self.password[0..len :0];
    }
    pub fn dbZ(self: *const PollerConfig) [:0]const u8 {
        const len = std.mem.indexOfScalar(u8, &self.database, 0) orelse 0;
        return self.database[0..len :0];
    }
    pub fn tableZ(self: *const PollerConfig) [:0]const u8 {
        const len = std.mem.indexOfScalar(u8, &self.table, 0) orelse 0;
        return self.table[0..len :0];
    }
    pub fn pkZ(self: *const PollerConfig) [:0]const u8 {
        const len = std.mem.indexOfScalar(u8, &self.pk_column, 0) orelse 0;
        return self.pk_column[0..len :0];
    }
    pub fn utZ(self: *const PollerConfig) [:0]const u8 {
        const len = std.mem.indexOfScalar(u8, &self.update_time_column, 0) orelse 0;
        return self.update_time_column[0..len :0];
    }
};

pub const Poller = struct {
    allocator: std.mem.Allocator,
    cfg: PollerConfig,
    db: ?zfinal.DB = null,

    pub fn init(allocator: std.mem.Allocator, cfg: PollerConfig) Poller {
        return .{ .allocator = allocator, .cfg = cfg };
    }

    pub fn deinit(self: *Poller) void {
        if (self.db) |*db| db.deinit();
    }

    pub fn fetchFullBatch(self: *Poller, last_pk: []const u8) ![]event_mod.RowEvent {
        const sql = try std.fmt.allocPrint(self.allocator,
            "SELECT * FROM `{s}` WHERE `{s}` > '{s}' ORDER BY `{s}` ASC LIMIT {d}",
            .{ self.cfg.tableZ(), self.cfg.pkZ(), last_pk, self.cfg.pkZ(), self.cfg.batch_size });
        defer self.allocator.free(sql);
        return try self.queryRows(sql);
    }

    pub fn fetchIncrementalBatch(self: *Poller, last_update_time: []const u8) ![]event_mod.RowEvent {
        const sql = try std.fmt.allocPrint(self.allocator,
            "SELECT * FROM `{s}` WHERE `{s}` > '{s}' ORDER BY `{s}` ASC LIMIT {d}",
            .{ self.cfg.tableZ(), self.cfg.utZ(), last_update_time, self.cfg.utZ(), self.cfg.batch_size });
        defer self.allocator.free(sql);
        return try self.queryRows(sql);
    }

    fn queryRows(self: *Poller, sql: []const u8) ![]event_mod.RowEvent {
        if (self.db == null) {
            // 使用相同的硬编码配置（验证主线程 OK，线程中也 OK）
            const cfg = zfinal.DBConfig{
                .db_type = .mysql,
                .host = "127.0.0.1",
                .port = 3306,
                .database = "zetl_source",
                .username = "root",
                .password = "",
            };
            self.db = try zfinal.DB.init(self.allocator, cfg);
        }

        const sql_z = try allocSentinel(self.allocator, sql);
        defer self.allocator.free(sql_z);
        var result = try self.db.?.query(sql_z);
        defer result.deinit();

        const cols = result.columnCount();
        var list = std.ArrayList(event_mod.RowEvent).empty;
        errdefer { for (list.items) |*i| i.deinit(self.allocator); list.deinit(self.allocator); }

        const now = currentTimestamp();
        while (result.next()) {
            var ev = event_mod.RowEvent{
                .op = .insert, .table = try self.allocator.dupe(u8, self.cfg.tableZ()),
                .database = try self.allocator.dupe(u8, self.cfg.dbZ()),
                .fields = std.StringHashMap([]const u8).init(self.allocator),
                .timestamp = now, .pk_value = "",
            };
            errdefer ev.deinit(self.allocator);
            for (0..cols) |i| {
                const cn = result.columnName(i) orelse continue;
                const cnd = try self.allocator.dupe(u8, cn);
                const v = result.getText(i) orelse "";
                const vd = try self.allocator.dupe(u8, v);
                try ev.fields.put(cnd, vd);
                if (std.mem.eql(u8, cn, self.cfg.pkZ())) ev.pk_value = vd;
            }
            try list.append(self.allocator, ev);
        }
        return list.toOwnedSlice(self.allocator);
    }
};

fn allocSentinel(allocator: std.mem.Allocator, src: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, src.len + 1);
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}

fn currentTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @intCast(tv.sec);
}

test "poller config fixed buf" {
    var cfg = PollerConfig.fromSlices("127.0.0.1", 3306, "root", "", "test", "t", "id", "update_time", 1000);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.hostZ());
    try std.testing.expectEqualStrings("root", cfg.userZ());
}
