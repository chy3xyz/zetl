//! SyncTask 运行时 — zfinal v0.10.4 + 堆字符串寿命管理

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const cdc = @import("../cdc/mod.zig");
const transform = @import("../transform/mod.zig");
const sink_mod = @import("../sink/mod.zig");
const common = @import("../common/mod.zig");

pub const RuntimeConfig = struct {
    task_id: i64,
    source_table: []const u8,
    target_table: []const u8,
    pk_column: []const u8 = "id",
    update_time_column: []const u8 = "update_time",
    batch_size: u32 = 1000,
    sync_mode: meta.task.SyncMode = .both,
    field_mappings_json: ?[]const u8 = null,
    filter_condition: ?[]const u8 = null,
    enable_commission_calc: bool = false,
    full_sync_sleep_ms: u64 = 50,
    incremental_poll_ms: u64 = 1000,
    mall_id: []const u8 = "",
};

/// binlog 启动位点 (file + pos). pos 为 i64 与 SyncPosition.binlog_pos 对齐;
/// 调用 BinlogReader.open 时需 @intCast 到 u64.
pub const BinlogStartPos = struct {
    file: []const u8,
    pos: i64,
};

/// SyncTask 生命周期状态. 所有转换通过 atomic.Value 在 SyncTask 结构体内同步.
pub const TaskStatus = enum(u8) {
    pending = 0,
    running = 1,
    success = 2,
    @"error" = 3,
};

pub const SyncTask = struct {
    allocator: std.mem.Allocator,
    cfg: RuntimeConfig,
    transformer: transform.engine.TransformEngine,
    sink: sink_mod.mysql_sink.MySqlSink,
    store: *meta.store.MetaStore,
    sink_pool: *zfinal.ConnectionPool,
    src_pool: *zfinal.ConnectionPool,
    poller: cdc.poller.Poller,
    _sh: []u8,
    _sd: []u8,
    _su: []u8,
    _sp: []u8, // 持有 src DBConfig 的 dupe'd 字符串
    /// binlog CDC 用的源库 DB 连接 (P2 Task 11 注入, 当前为 null).
    binlog_db: ?zfinal.DB = null,
    /// 当前任务状态. 所有转换: start → running, runLoop 退出 → success/error.
    state: std.atomic.Value(TaskStatus) = std.atomic.Value(TaskStatus).init(.pending),
    /// stop() 翻转此标志, runLoop 检测后优雅退出. 与 state 字段独立 (state 是结果, 这是原因).
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// runLoop 退出后置 true, 供 stopAll 提前结束等待. 与 state 区分: state=结果, is_finished=过程完成.
    is_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// deinit() 幂等保护: 多次调用只生效一次.
    _deinit_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// src_pool.deinit() 幂等保护: zfinal ConnectionPool 二次 deinit 会 crash.
    _pool_deinit_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 上次成功加载佣金规则的 Unix 时间 (秒). 0 = 从未成功加载过.
    /// 用于 stale-retry: 归集库恢复后, 每隔 rules_max_age_sec 再尝试拉一次.
    last_rules_loaded_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// 规则过期阈值 (秒). 默认 300s = 5 min. 0 = 每次同步都重新加载.
    rules_max_age_sec: i64 = 300,
    pos: meta.position.SyncPosition,
    last_error: ?[]const u8 = null,
    thread: ?std.Thread = null,

    pub fn init(a: std.mem.Allocator, cfg: RuntimeConfig, ds: meta.datasource.Datasource, store: *meta.store.MetaStore, sp: *zfinal.ConnectionPool, src_pool: *zfinal.ConnectionPool, src_host: []u8, src_db: []u8, src_user: []u8, src_pass: []u8) !SyncTask {
        // TransformEngine / MySqlSink 会在内部复制需要的字符串, 这里直接传借用值.
        const tr = try transform.engine.TransformEngine.init(a, .{
            .mall_id = cfg.mall_id,
            .source_type = "mysql",
            .field_mappings_json = cfg.field_mappings_json,
            .enable_commission_calc = cfg.enable_commission_calc,
        });
        const sk = sink_mod.mysql_sink.MySqlSink.init(a, sp, cfg.target_table, cfg.batch_size, "order_no");
        const po = try meta.position.Service.load(store, a, cfg.task_id);
        const pl_cfg = cdc.poller.PollerConfig.fromSlices(src_host, ds.port, src_user, src_pass, src_db, cfg.source_table, cfg.pk_column, cfg.update_time_column, @intCast(cfg.batch_size));
        const pl = cdc.poller.Poller.init(a, pl_cfg, src_pool);
        // P2 Task 11: 专用 binlog 连接 (与 src_pool 独立, 避免 binlong dump 阻塞 poll 查询).
        // 复用 src_host/_db/_user/_pass (堆分配, 由 _sh/_sd/_su/_sp 持有寿命).
        // MySQL driver 在 connect 内部已 bufPrint 到栈, 不持有外部字符串引用, 故字符串寿命
        // 仅需覆盖到 binlog_db.deinit().
        const binlog_cfg = zfinal.DBConfig{
            .db_type = .mysql,
            .host = src_host,
            .port = ds.port,
            .database = src_db,
            .username = src_user,
            .password = src_pass,
        };
        const binlog_db = try zfinal.DB.init(a, binlog_cfg);
        errdefer binlog_db.deinit();
        return .{ .allocator = a, .cfg = cfg, .transformer = tr, .sink = sk, .store = store, .sink_pool = sp, .src_pool = src_pool, .poller = pl, ._sh = src_host, ._sd = src_db, ._su = src_user, ._sp = src_pass, .pos = po, .binlog_db = binlog_db };
    }

    pub fn deinit(self: *SyncTask) void {
        self.transformer.deinit();
        self.sink.deinit();
        // src_pool 由 ConnectionPool.init 在内部 self-destroy, 外部只需 deinit.
        self.src_pool.deinit();
        // binlog_db 必须在 _sh/_sd/_su/_sp 释放前 deinit — MySQL driver 不持有外部字符串引用,
        // 但顺序上保持 deinit 早于堆字符串释放更安全 (后续若 driver 变化).
        if (self.binlog_db) |*bd| bd.deinit();
        self.allocator.free(self._sh);
        self.allocator.free(self._sd);
        self.allocator.free(self._su);
        self.allocator.free(self._sp);
        self.pos.deinit(self.allocator);
        if (self.last_error) |e| self.allocator.free(e);
    }

    pub fn start(self: *SyncTask) !void {
        if (self.is_running.load(.acquire)) return;
        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *SyncTask) void {
        self.is_running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *SyncTask) void {
        common.logger.inf("[task {d}] 启动 stage={s}", .{ self.cfg.task_id, self.pos.stage.toString() });
        defer {
            common.logger.inf("[task {d}] 退出", .{self.cfg.task_id});
            self.is_finished.store(true, .release);
        }

        // 启动时 / 全量后尝试加载佣金规则; enable_commission_calc 为 true 才需要.
        // 归集库不可达时 loadRules 内部已优雅降级 (打 warn + 空规则), 不抛 error.
        if (self.cfg.enable_commission_calc) {
            self.reloadRulesIfStale();
        }

        // 1. 全量阶段 (sync_mode=full/both 或 stage=full)
        if (self.pos.stage == .full and (self.cfg.sync_mode == .full or self.cfg.sync_mode == .both)) {
            self.runFull() catch |err| {
                common.logger.err_("[task {d}] 全量: {s}", .{ self.cfg.task_id, @errorName(err) });
                self.markError(@errorName(err));
                return;
            };
        }

        // 2. 增量阶段 (按 sync_mode 分发)
        if (!self.is_running.load(.acquire)) return;

        // 增量阶段
        switch (self.cfg.sync_mode) {
            .full => return,
            .poll => self.runIncremental() catch |err| {
                common.logger.err_("[task {d}] 增量轮询: {s}", .{ self.cfg.task_id, @errorName(err) });
                self.markError(@errorName(err));
            },
            .binlog, .both => {
                if (self.pos.stage != .binlog) {
                    self.pos.stage = .binlog;
                    self.savePosition() catch |err| {
                        common.logger.warn("[task {d}] stage→binlog savePosition: {s}", .{ self.cfg.task_id, @errorName(err) });
                    };
                }
                self.runBinlogIncremental() catch |err| {
                    common.logger.err_("[task {d}] binlog: {s}", .{ self.cfg.task_id, @errorName(err) });
                    self.markError(@errorName(err));
                };
            },
        }
    }

    fn runFull(self: *SyncTask) !void {
        common.logger.inf("[task {d}] 全量 pk='{s}'", .{ self.cfg.task_id, self.pos.last_pk });
        var last = try self.allocator.dupe(u8, if (self.pos.last_pk.len > 0) self.pos.last_pk else "0");
        defer self.allocator.free(last);
        while (self.is_running.load(.acquire)) {
            const rows = try self.poller.fetchFullBatch(last);
            if (rows.len == 0) {
                common.logger.inf("[task {d}] 全量完成", .{self.cfg.task_id});
                // 切换到增量阶段
                self.pos.stage = .incremental;
                try self.savePosition();
                break;
            }
            // 先提取下一批游标, 再处理/释放本批
            const next_pk = try self.allocator.dupe(u8, rows[rows.len - 1].pk_value);
            errdefer self.allocator.free(next_pk);
            try self.processBatch(rows, .insert);
            self.freeRowEvents(rows);
            self.allocator.free(last);
            last = next_pk;
            // 释放旧 pos.last_pk 再赋值新值
            self.allocator.free(self.pos.last_pk);
            self.pos.last_pk = try self.allocator.dupe(u8, last);
            try self.savePosition();
            common.logger.inf("[task {d}] {d}行 pk={s}", .{ self.cfg.task_id, rows.len, last });
            sleepMs(self.cfg.full_sync_sleep_ms);
        }
    }

    fn runIncremental(self: *SyncTask) !void {
        common.logger.inf("[task {d}] 增量 last_update_time='{s}' last_pk='{s}'", .{ self.cfg.task_id, self.pos.last_update_time, self.pos.last_pk });
        var last_ut = try self.allocator.dupe(u8, if (self.pos.last_update_time.len > 0) self.pos.last_update_time else "1970-01-01 00:00:00");
        defer self.allocator.free(last_ut);
        var last_pk = try self.allocator.dupe(u8, if (self.pos.last_pk.len > 0) self.pos.last_pk else "0");
        defer self.allocator.free(last_pk);
        while (self.is_running.load(.acquire)) {
            const rows = try self.poller.fetchIncrementalBatch(last_ut, last_pk);
            if (rows.len > 0) {
                const next_ut = try self.allocator.dupe(u8, rows[rows.len - 1].fields.get(self.cfg.update_time_column) orelse "");
                errdefer self.allocator.free(next_ut);
                const next_pk = try self.allocator.dupe(u8, rows[rows.len - 1].pk_value);
                errdefer self.allocator.free(next_pk);
                try self.processBatch(rows, .insert);
                self.freeRowEvents(rows);
                self.allocator.free(last_ut);
                last_ut = next_ut;
                self.allocator.free(last_pk);
                last_pk = next_pk;
                self.allocator.free(self.pos.last_update_time);
                self.pos.last_update_time = try self.allocator.dupe(u8, last_ut);
                self.allocator.free(self.pos.last_pk);
                self.pos.last_pk = try self.allocator.dupe(u8, last_pk);
                try self.savePosition();
                common.logger.inf("[task {d}] 增量 {d}行 ut={s} pk={s}", .{ self.cfg.task_id, rows.len, last_ut, last_pk });
            }
            sleepMs(self.cfg.incremental_poll_ms);
        }
    }

    /// binlog CDC 增量同步 (P2 Task 11).
    ///
    /// 流程:
    ///   1. 取 binlog_db (Task 11 注入的专用 MySQL 连接) 的指针;
    ///   2. 启动位点优先用持久化的 binlog_file/binlog_pos, 否则 SHOW MASTER STATUS 取当前位点;
    ///   3. 循环: reader.nextEvent → parser.processEvent → 分发 (rotate / heartbeat / row / table_map / unknown);
    ///   4. 每轮末尾用 reader.currentPosition 更新 self.pos 并 savePosition 持久化.
    fn runBinlogIncremental(self: *SyncTask) !void {
        const bd = if (self.binlog_db) |*p| p else return error.NoBinlogDb;
        common.logger.inf("[task {d}] 启动 binlog CDC", .{self.cfg.task_id});

        var reader = cdc.binlog.BinlogReader.init(self.allocator, bd);
        defer reader.deinit();

        // 启动位点: 优先使用持久化的 binlog_file/binlog_pos, 否则 SHOW MASTER STATUS.
        const start_pos: BinlogStartPos = if (self.pos.binlog_file.len > 0)
            .{ .file = self.pos.binlog_file, .pos = self.pos.binlog_pos }
        else
            try self.queryMasterStatus();

        // start_pos.pos 是 i64 (SyncPosition.binlog_pos 类型); reader.open 需要 u64.
        try reader.open(start_pos.file, @intCast(start_pos.pos));

        var parser = cdc.binlog.parser.Parser.init(self.allocator);
        defer parser.deinit();

        while (self.is_running.load(.acquire)) {
            const raw = reader.nextEvent() catch |err| {
                common.logger.err_("[task {d}] binlog fetch: {s}", .{ self.cfg.task_id, @errorName(err) });
                sleepMs(1000);
                continue;
            } orelse continue;

            // raw.buffer 是 C 指针, 指向 mysql client 内部 buffer — 必须在下一轮 nextEvent 前拷出.
            const buf = try self.allocator.dupe(u8, raw.buffer[0..raw.size]);
            defer self.allocator.free(buf);

            const parsed = parser.processEvent(buf) catch |err| {
                common.logger.err_("[task {d}] binlog parse: {s}", .{ self.cfg.task_id, @errorName(err) });
                continue;
            };

            switch (parsed) {
                .rotate => |pos_c| {
                    // union payload 按值捕获, 是 const; deinit 需要 *Position (可变),
                    // 拷到 var 上 deinit. 反正 rotate 不再复用 pos.
                    var pos = pos_c;
                    defer pos.deinit(self.allocator);
                    self.allocator.free(self.pos.binlog_file);
                    self.pos.binlog_file = try self.allocator.dupe(u8, pos.file orelse "");
                    // pos.pos 是 u64 (Position 类型), binlog_pos 是 i64, 需要显式 cast.
                    self.pos.binlog_pos = @intCast(pos.pos);
                },
                .heartbeat => {},
                .row => |rows| {
                    defer cdc.binlog.parser.freeRowEvents(self.allocator, rows);
                    try self.processBatch(rows, .insert);
                },
                .table_map => {},
                .unknown => {},
            }

            // 保存当前位点 (rotate 后会再覆盖一次, 但当前 reader.current_pos 还停在 rotate 事件之后).
            const cur = reader.currentPosition() catch null;
            if (cur) |p_c| {
                // currentPosition 返回 by-value, 同样是 const; 拷到 var 上 deinit.
                var p = p_c;
                defer p.deinit(self.allocator);
                self.allocator.free(self.pos.binlog_file);
                self.pos.binlog_file = try self.allocator.dupe(u8, p.file orelse "");
                // p.pos 是 u64 (Position 类型), binlog_pos 是 i64.
                self.pos.binlog_pos = @intCast(p.pos);
                self.savePosition() catch |err| {
                    common.logger.warn("[task {d}] savePosition: {s}", .{ self.cfg.task_id, @errorName(err) });
                };
            }
        }
    }

    /// 从 src_pool 拿一个连接查询当前 binlog 位点.
    /// MySQL 8 优先使用 SHOW BINARY LOG STATUS, 失败则回退到 SHOW MASTER STATUS.
    /// 启动位点无持久化值时调用. file 由 allocator.dupe, 调用方负责释放 (start_pos 借用, 不 free).
    fn queryMasterStatus(self: *SyncTask) !BinlogStartPos {
        const conn = try self.src_pool.acquire();
        defer self.src_pool.release(conn) catch {};

        var result = blk: {
            break :blk conn.query("SHOW BINARY LOG STATUS") catch |err| {
                common.logger.warn(
                    "[task {d}] SHOW BINARY LOG STATUS failed ({s}), falling back to SHOW MASTER STATUS",
                    .{ self.cfg.task_id, @errorName(err) },
                );
                break :blk try conn.query("SHOW MASTER STATUS");
            };
        };
        defer result.deinit();

        if (result.next()) {
            if (result.getCurrentRowMap()) |row| {
                const file = row.get("File") orelse return error.MissingMasterStatus;
                const pos_s = row.get("Position") orelse return error.MissingMasterStatus;
                const pos = try std.fmt.parseInt(i64, pos_s, 10);
                return .{ .file = try self.allocator.dupe(u8, file), .pos = pos };
            }
        }
        return error.MissingMasterStatus;
    }

    fn savePosition(self: *SyncTask) !void {
        try meta.position.Service.save(self.store, self.pos);
    }

    fn sleepMs(ms: u64) void {
        _ = std.c.nanosleep(&.{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .nsec = @intCast(@mod(ms, 1000) * 1_000_000),
        }, null);
    }

    fn processBatch(self: *SyncTask, rows: []cdc.event.RowEvent, default_op: cdc.event.RowOp) !void {
        for (rows) |*ev| {
            // 轮询式 CDC 只能拿到当前快照, 默认当作 upsert.
            // binlog 行已经带有正确的 op (insert/update/delete), 直接采用.
            var op = ev.op;
            if (op == .insert and default_op != .insert) {
                op = default_op;
            }
            if (ev.fields.get("is_delete")) |v| {
                if (std.mem.eql(u8, v, "1")) op = .delete;
            }
            ev.op = op;
            const t = self.transformer.process(ev.*) catch |err| switch (err) {
                transform.engine.TransformError.FilterSkip => continue,
                else => {
                    common.logger.warn("[task {d}] xf: {s}", .{ self.cfg.task_id, @errorName(err) });
                    continue;
                },
            };
            try self.sink.append(t);
        }
        try self.sink.flush();
        meta.metrics.Service.incrementSuccess(self.store, self.cfg.task_id, @intCast(rows.len)) catch {};
        // 注意: rows 由调用方释放, 以便调用方在释放前读取最后一条的游标字段
    }

    fn freeRowEvents(self: *SyncTask, rows: []cdc.event.RowEvent) void {
        for (rows) |*ev| ev.deinit(self.allocator);
        self.allocator.free(rows);
    }

    /// 加载佣金规则 (委托给 transform.commission.loadCommissionRules).
    /// 内部已优雅降级: 归集库不可达时返回空切片, 不抛 error.
    /// 成功加载后更新 last_rules_loaded_at.
    fn loadRules(self: *SyncTask) void {
        const rules = transform.commission.loadCommissionRules(self.sink_pool, self.allocator);
        // setRules 在内部 deep-dupe 字符串, 因此我们用完 rules 后必须释放外层切片.
        self.transformer.setRules(rules) catch |err| {
            common.logger.warn("[task {d}] 佣金规则 setRules 失败: {s}", .{ self.cfg.task_id, @errorName(err) });
            transform.commission.freeCommissionRules(self.allocator, rules);
            return;
        };
        defer transform.commission.freeCommissionRules(self.allocator, rules);

        if (rules.len > 0) {
            const now = curTs();
            self.last_rules_loaded_at.store(now, .release);
            common.logger.inf("[task {d}] 加载 {d} 条佣金规则", .{ self.cfg.task_id, rules.len });
        } else {
            common.logger.warn("[task {d}] 佣金规则为空 (归集库可能不可达)", .{self.cfg.task_id});
        }
    }

    /// Stale-retry: 如果距上次成功加载已过 rules_max_age_sec, 再尝试加载一次.
    /// 每次都重置 last_rules_loaded_at = 0 表示"待重试", 不管成败.
    /// P1 任务 1.5: 归集库恢复后, 下次同步周期自动重新拉取.
    pub fn reloadRulesIfStale(self: *SyncTask) void {
        const last = self.last_rules_loaded_at.load(.acquire);
        const now = curTs();
        if (last != 0 and (now - last) < self.rules_max_age_sec) {
            // 规则新鲜, 跳过
            return;
        }
        self.loadRules();
    }

    fn markError(self: *SyncTask, msg: []const u8) void {
        self.status = 2;
        if (self.last_error) |e| self.allocator.free(e);
        self.last_error = self.allocator.dupe(u8, msg) catch null;
        meta.task.Service.updateStatus(self.store, self.cfg.task_id, 2, msg) catch {};
    }
};

fn allocS(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const b = try a.alloc(u8, s.len + 1);
    @memcpy(b[0..s.len], s);
    b[s.len] = 0;
    return b[0..s.len :0];
}
fn curTs() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @intCast(tv.sec);
}
