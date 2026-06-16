//! SyncTask 运行时 — zfinal v0.10.4 + 堆字符串寿命管理

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const cdc = @import("../cdc/mod.zig");
const transform = @import("../transform/mod.zig");
const sink_mod = @import("../sink/mod.zig");
const common = @import("../common/mod.zig");

pub const RuntimeConfig = struct {
    task_id: i64, source_table: []const u8, target_table: []const u8,
    pk_column: []const u8 = "id", update_time_column: []const u8 = "update_time",
    batch_size: u32 = 1000, sync_mode: meta.task.SyncMode = .both,
    field_mappings_json: ?[]const u8 = null, filter_condition: ?[]const u8 = null,
    enable_commission_calc: bool = false, full_sync_sleep_ms: u64 = 50,
    incremental_poll_ms: u64 = 1000, mall_id: []const u8 = "",
};

pub const SyncTask = struct {
    allocator: std.mem.Allocator, cfg: RuntimeConfig,
    transformer: transform.engine.TransformEngine, sink: sink_mod.mysql_sink.MySqlSink,
    store: *meta.store.MetaStore, sink_pool: *zfinal.ConnectionPool,
    src_pool: *zfinal.ConnectionPool,
    _sh: []u8, _sd: []u8, _su: []u8, _sp: []u8, // 持有 src DBConfig 的 dupe'd 字符串
    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 上次成功加载佣金规则的 Unix 时间 (秒). 0 = 从未成功加载过.
    /// 用于 stale-retry: 归集库恢复后, 每隔 rules_max_age_sec 再尝试拉一次.
    last_rules_loaded_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// 规则过期阈值 (秒). 默认 300s = 5 min. 0 = 每次同步都重新加载.
    rules_max_age_sec: i64 = 300,
    pos: meta.position.SyncPosition, status: i32 = 1, last_error: ?[]const u8 = null,
    thread: ?std.Thread = null,

    pub fn init(a: std.mem.Allocator, cfg: RuntimeConfig, _: meta.datasource.Datasource, store: *meta.store.MetaStore,
               sp: *zfinal.ConnectionPool, src_pool: *zfinal.ConnectionPool,
               src_host: []u8, src_db: []u8, src_user: []u8, src_pass: []u8) !SyncTask {
        const mid = try a.dupe(u8, cfg.mall_id);
        const tgt = try a.dupe(u8, cfg.target_table);
        const fm: ?[]u8 = if (cfg.field_mappings_json) |f| try a.dupe(u8, f) else null;
        const tr = try transform.engine.TransformEngine.init(a, .{.mall_id=mid,.source_type="mysql",.field_mappings_json=fm,.enable_commission_calc=cfg.enable_commission_calc});
        const sk = sink_mod.mysql_sink.MySqlSink.init(a, sp, tgt, cfg.batch_size, "order_no");
        const po = try meta.position.Service.load(store, a, cfg.task_id);
        return .{.allocator=a,.cfg=cfg,.transformer=tr,.sink=sk,.store=store,.sink_pool=sp,.src_pool=src_pool,
            ._sh=src_host,._sd=src_db,._su=src_user,._sp=src_pass,.pos=po};
    }

    pub fn deinit(self: *SyncTask) void {
        self.transformer.deinit(); self.sink.deinit();
        self.src_pool.deinit(); self.allocator.destroy(self.src_pool);
        self.allocator.free(self._sh); self.allocator.free(self._sd);
        self.allocator.free(self._su); self.allocator.free(self._sp);
        self.pos.deinit(self.allocator);
        if (self.last_error) |e| self.allocator.free(e);
    }

    pub fn start(self: *SyncTask) !void {
        if (self.is_running.load(.acquire)) return;
        self.is_running.store(true,.release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *SyncTask) void {
        self.is_running.store(false,.release);
        if (self.thread) |t| { t.join(); self.thread=null; }
    }

    fn runLoop(self: *SyncTask) void {
        common.logger.inf("[task {d}] 启动", .{self.cfg.task_id});
        defer common.logger.inf("[task {d}] 退出", .{self.cfg.task_id});
        if (self.cfg.sync_mode == .full or self.cfg.sync_mode == .both) self.runFull() catch |err| {
            common.logger.err_("[task {d}] 全量: {s}", .{self.cfg.task_id,@errorName(err)}); self.markError(@errorName(err));
        };
        // 启动时 / 全量后尝试加载佣金规则; enable_commission_calc 为 true 才需要.
        // 归集库不可达时 loadRules 内部已优雅降级 (打 warn + 空规则), 不抛 error.
        if (self.cfg.enable_commission_calc and self.status == 1) {
            self.reloadRulesIfStale();
        }
    }

    fn runFull(self: *SyncTask) !void {
        common.logger.inf("[task {d}] 全量 pk='{s}'", .{self.cfg.task_id, self.pos.last_pk});
        const conn = self.src_pool.acquire() catch |err| {
            common.logger.err_("[task {d}] srcAcquire: {s}", .{self.cfg.task_id,@errorName(err)}); return err;
        };
        defer self.src_pool.release(conn) catch {};

        var last = try self.allocator.dupe(u8, if (self.pos.last_pk.len>0) self.pos.last_pk else "0");
        defer self.allocator.free(last);
        while (self.is_running.load(.acquire)) {
            const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM `order_info` WHERE `id` > '{s}' ORDER BY `id` ASC LIMIT {d}", .{last,self.cfg.batch_size});
            defer self.allocator.free(sql);
            const sz = try allocS(self.allocator, sql); defer self.allocator.free(sz);
            var rs = conn.query(sz) catch |err| { common.logger.err_("[task {d}] q: {s}",.{self.cfg.task_id,@errorName(err)}); return err; };
            defer rs.deinit();
            const now = curTs(); const cols = rs.columnCount();
            var evs = std.ArrayList(cdc.event.RowEvent).empty;
            while (rs.next()) {
                var ev = cdc.event.RowEvent{.op=.insert,.table=try self.allocator.dupe(u8,"order_info"),.database=try self.allocator.dupe(u8,"zetl_source"),.fields=std.StringHashMap([]const u8).init(self.allocator),.timestamp=now,.pk_value=""};
                for (0..cols) |i| {
                    const cn = rs.columnName(i) orelse continue; const v = rs.getText(i) orelse "";
                    try ev.fields.put(try self.allocator.dupe(u8,cn), try self.allocator.dupe(u8,v));
                    if (std.mem.eql(u8,cn,"id")) { self.allocator.free(ev.pk_value); ev.pk_value=try self.allocator.dupe(u8,v); }
                }
                try evs.append(self.allocator, ev);
            }
            const rows = try evs.toOwnedSlice(self.allocator);
            if (rows.len==0) { common.logger.inf("[task {d}] 全量完成",.{self.cfg.task_id}); break; }
            try self.processBatch(rows);
            self.allocator.free(last); last=try self.allocator.dupe(u8,rows[rows.len-1].pk_value);
            common.logger.inf("[task {d}] {d}行 pk={s}",.{self.cfg.task_id,rows.len,last});
            _ = std.c.nanosleep(&.{
                .sec = @intCast(@divTrunc(self.cfg.full_sync_sleep_ms, 1000)),
                .nsec = @intCast(@mod(self.cfg.full_sync_sleep_ms, 1000) * 1_000_000),
            }, null);
        }
    }

    fn processBatch(self: *SyncTask, rows: []cdc.event.RowEvent) !void {
        for (rows) |*ev| {
            const t = self.transformer.process(ev.*) catch |err| switch(err) { transform.engine.TransformError.FilterSkip=>continue, else=>{common.logger.warn("[task {d}] xf: {s}",.{self.cfg.task_id,@errorName(err)}); continue;} };
            try self.sink.append(t);
        }
        try self.sink.flush();
        meta.metrics.Service.incrementSuccess(self.store, self.cfg.task_id, @intCast(rows.len)) catch {};
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

    fn markError(self: *SyncTask, msg: []const u8) void { self.status=2; if (self.last_error) |e| self.allocator.free(e); self.last_error=self.allocator.dupe(u8,msg) catch null; meta.task.Service.updateStatus(self.store,self.cfg.task_id,2,msg) catch {}; }
};

fn allocS(a: std.mem.Allocator, s: []const u8) ![:0]u8 { const b=try a.alloc(u8,s.len+1); @memcpy(b[0..s.len],s); b[s.len]=0; return b[0..s.len:0]; }
fn curTs() i64 { var tv: std.c.timeval=undefined; if(std.c.gettimeofday(&tv,null)!=0) return 0; return @intCast(tv.sec); }
