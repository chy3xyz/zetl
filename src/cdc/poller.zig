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
    pool: *zfinal.ConnectionPool,

    pub fn init(allocator: std.mem.Allocator, cfg: PollerConfig, pool: *zfinal.ConnectionPool) Poller {
        return .{ .allocator = allocator, .cfg = cfg, .pool = pool };
    }

    pub fn deinit(self: *Poller) void {
        _ = self;
    }

    pub fn fetchFullBatch(self: *Poller, last_pk: []const u8) ![]event_mod.RowEvent {
        const sql = try std.fmt.allocPrint(self.allocator,
            "SELECT * FROM `{s}` WHERE `{s}` > '{s}' ORDER BY `{s}` ASC LIMIT {d}",
            .{ self.cfg.tableZ(), self.cfg.pkZ(), last_pk, self.cfg.pkZ(), self.cfg.batch_size });
        defer self.allocator.free(sql);
        return try self.queryRows(sql);
    }

    /// 增量轮询. 使用 (update_time > last_ut) OR (update_time = last_ut AND pk > last_pk)
    /// 避免同一 update_time 的数据被反复读取.
    pub fn fetchIncrementalBatch(self: *Poller, last_update_time: []const u8, last_pk: []const u8) ![]event_mod.RowEvent {
        const sql = try std.fmt.allocPrint(self.allocator,
            "SELECT * FROM `{s}` WHERE `{s}` > '{s}' OR (`{s}` = '{s}' AND `{s}` > '{s}') ORDER BY `{s}` ASC, `{s}` ASC LIMIT {d}",
            .{
                self.cfg.tableZ(), self.cfg.utZ(), last_update_time,
                self.cfg.utZ(), last_update_time, self.cfg.pkZ(), last_pk,
                self.cfg.utZ(), self.cfg.pkZ(), self.cfg.batch_size,
            });
        defer self.allocator.free(sql);
        return try self.queryRows(sql);
    }

    fn queryRows(self: *Poller, sql: []const u8) ![]event_mod.RowEvent {
        const conn = self.pool.acquire() catch |err| return err;
        defer self.pool.release(conn) catch {};

        const sql_z = try allocSentinel(self.allocator, sql);
        defer self.allocator.free(sql_z);
        var result = try conn.query(sql_z);
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
                if (std.mem.eql(u8, cn, self.cfg.pkZ())) {
                    // pk_value 单独分配, 避免与 fields 中的 value 共享同一块内存导致 double free
                    ev.pk_value = try self.allocator.dupe(u8, v);
                }
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
