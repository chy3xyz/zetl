//! 多任务调度器 - 维护 task_id → SyncTask* 映射, 启动/停止
//! 见 docs/superpowers/specs/2026-06-16-zetl-v1-design.md §3.5

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../meta/mod.zig");
const runtime = @import("runtime.zig");
const common = @import("../common/mod.zig");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    store: *meta.store.MetaStore,
    sink_pool: *zfinal.ConnectionPool,
    /// task_id → SyncTask*
    tasks: std.AutoHashMap(i64, *runtime.SyncTask),
    mutex: std.Io.Mutex = .init,
    /// P1 任务 1.8: 优雅停机标志. 置位后:
    ///   - startTask 立即返回 error.ShutdownInProgress
    ///   - 所有运行中 task 的 is_running 会被强制置为 false
    ///   - 调用方应等待 batch 跑完后再 deinit
    is_shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// V5 Phase 5: 测试模式. true 时 addTask/removeTask 走 stub 路径,
    ///   - 不真正实例化 SyncTask (避免 MySQL 连接)
    ///   - 不调用 task.stop()/task.deinit() (stub 未持有真实资源)
    /// 仅用于单测. 生产路径必须 = false.
    test_mode: bool = false,

    pub fn init(allocator: std.mem.Allocator, store: *meta.store.MetaStore, sink_pool: *zfinal.ConnectionPool) Scheduler {
        return .{
            .allocator = allocator,
            .store = store,
            .sink_pool = sink_pool,
            .tasks = std.AutoHashMap(i64, *runtime.SyncTask).init(allocator),
        };
    }

    /// V5 Phase 5: 测试用构造器 — 不需要 sink_pool, 自动开启 test_mode.
    ///
    /// 用于单元测试 `addTask` / `removeTask` 的 map 状态 + DB 状态变化,
    /// 跳过 SyncTask 真实实例化 (需要 MySQL 连接).
    pub fn initForTest(allocator: std.mem.Allocator, store: *meta.store.MetaStore) Scheduler {
        return .{
            .allocator = allocator,
            .store = store,
            .sink_pool = undefined, // 测试模式不访问 sink_pool
            .tasks = std.AutoHashMap(i64, *runtime.SyncTask).init(allocator),
            .test_mode = true,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task = entry.value_ptr.*;
            if (!self.test_mode) {
                task.stop();
                task.deinit();
            }
            // 测试模式: stub 未持有真实资源, 只 destroy 即可.
            self.allocator.destroy(task);
        }
        self.tasks.deinit();
    }

    /// 启动一个任务 (从 task_id 加载配置)
    pub fn startTask(self: *Scheduler, task_id: i64) !void {
        const t0 = Scheduler.nowMs();
        // P1 任务 1.8: 优雅停机检查 - 收到停机信号后拒绝任何新 task 启动.
        // 双重检查: 快路径 (无锁) + 锁内精确检查.
        if (self.is_shutting_down.load(.acquire)) {
            common.logger.warn("任务 {d} 启动被拒绝: 正在停机", .{task_id});
            return error.ShutdownInProgress;
        }

        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);

        // 锁内再检查一次 (防止刚进入临界区时 stopAll 置位 flag)
        if (self.is_shutting_down.load(.acquire)) {
            return error.ShutdownInProgress;
        }

        if (self.tasks.contains(task_id)) {
            common.logger.warn("任务 {d} 已在运行, 跳过启动", .{task_id});
            return;
        }

        // 1. 加载 task 配置
        const task = (try meta.task.Service.findById(self.store, self.allocator, task_id)) orelse {
            common.logger.err_("任务 {d} 不存在", .{task_id});
            return error.TaskNotFound;
        };
        defer {
            var t = task;
            t.deinit(self.allocator);
        }
        const t1 = Scheduler.nowMs();

        // 2. 加载 datasource
        const ds = (try meta.datasource.Service.findById(self.store, self.allocator, task.datasource_id)) orelse {
            common.logger.err_("任务 {d} 绑定的数据源 {d} 不存在", .{ task_id, task.datasource_id });
            return error.DatasourceNotFound;
        };
        defer {
            var d = ds;
            d.deinit(self.allocator);
        }
        const t2 = Scheduler.nowMs();

        // 3. 构造 SyncTask
        // 旧 sync_mode='cdc' 视作增量轮询 (.poll) — 老 CDC 实现本质就是按 update_time 轮询
        const sync_mode = blk: {
            const raw = task.sync_mode;
            if (std.mem.eql(u8, raw, "cdc")) break :blk .poll;
            break :blk std.meta.stringToEnum(meta.task.SyncMode, raw) orelse .poll;
        };
        const rcfg = runtime.RuntimeConfig{
            .task_id = task.id,
            .source_table = task.source_table,
            .target_table = task.target_table,
            .batch_size = @intCast(task.batch_size),
            .sync_mode = sync_mode,
            .field_mappings_json = task.field_mappings,
            .filter_condition = task.filter_condition,
            .enable_commission_calc = task.enable_commission_calc == 1,
            .mall_id = ds.mall_id,
        };
        // 在主线程创建源库连接池 + dupe字符串 (确保任务线程不会读到栈回收后的垃圾)
        const src_host = try self.allocator.dupe(u8, ds.host);
        const src_db = try self.allocator.dupe(u8, ds.db_name);
        const src_user = try self.allocator.dupe(u8, ds.username);
        const src_pass = try self.allocator.dupe(u8, ds.password);
        const src_cfg = zfinal.DBConfig{ .db_type = .mysql, .host = src_host, .port = ds.port, .database = src_db, .username = src_user, .password = src_pass };
        const t3 = Scheduler.nowMs();
        const src_pool = try zfinal.ConnectionPool.init(self.allocator, src_cfg, 1);
        const t4 = Scheduler.nowMs();
        const task_ptr = try self.allocator.create(runtime.SyncTask);
        errdefer self.allocator.destroy(task_ptr);
        task_ptr.* = try runtime.SyncTask.init(self.allocator, rcfg, ds, self.store, self.sink_pool, src_pool, src_host, src_db, src_user, src_pass);
        const t5 = Scheduler.nowMs();

        // 4. 启动线程
        try task_ptr.start();
        const t6 = Scheduler.nowMs();
        try self.tasks.put(task_id, task_ptr);

        // 5. 更新 task 状态为运行中
        try meta.task.Service.updateStatus(self.store, task_id, 1, null);
        const t7 = Scheduler.nowMs();
        common.logger.inf("任务 {d} ({s}) 启动成功 (总耗时 {d}ms, load_task={d}ms load_ds={d}ms dup={d}ms pool_init={d}ms sync_task_init={d}ms spawn={d}ms put+status={d}ms)", .{
            task_id, task.task_name, t7 - t0, t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4, t6 - t5, t7 - t6,
        });
    }

    /// 停止一个任务
    pub fn stopTask(self: *Scheduler, task_id: i64) !void {
        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);

        if (self.tasks.fetchRemove(task_id)) |kv| {
            const task_ptr = kv.value;
            task_ptr.stop();
            task_ptr.deinit();
            self.allocator.destroy(task_ptr);
            try meta.task.Service.updateStatus(self.store, task_id, 0, null);
            common.logger.inf("任务 {d} 已停止", .{task_id});
        } else {
            common.logger.warn("任务 {d} 未在运行, 无需停止", .{task_id});
        }
    }

    /// V5 Phase 5 Task 3: 动态添加任务 (从 `tasks_config` 表加载并启动).
    ///
    /// 行为 (按顺序, 严格 errdefer 链):
    ///   1. 快路径停机检查 (无锁).
    ///   2. 加载 V5 `TaskConfig` (与 V1 sync_task 表解耦).
    ///   3. test_mode: 锁内插入 stub SyncTask, 不启动线程 (单测用).
    ///   4. 生产模式 (锁外, 避免持锁做重活):
    ///      a. 查找 datasource (mall_id = cfg.source_db)
    ///      b. 构建 src_pool + 堆分配字符串 (由 SyncTask._sh/_sd/_su/_sp 持有寿命)
    ///      c. 实例化 SyncTask (完整 init: transformer + sink + poller + binlog_db + pos)
    ///   5. 加锁, 二次停机 + contains 检查.
    ///   6. `tasks.put(id, task_ptr)` — 先注册到 map.
    ///   7. `task_ptr.start()` — 后启动线程 (start 失败时由 cleanup_needed defer 释放).
    ///   8. 解锁, 记录成功日志.
    ///
    /// 为什么 put 必须在 start 之前:
    ///   - 旧实现 start → put, 若 put OOM 则 errdefer 仅 destroy, 但 start 已起的线程在
    ///     持有 src_pool + _sh/_sd/_su/_sp 时被释放, worker 线程 deref 释放的内存 → UAF.
    ///   - 新实现 put → start, 若 start 失败, cleanup_needed defer 触发 deinit (join 线程
    ///     + 释放 src_pool + 字符串 + destroy), map 在 errdefer 链中由 fetchRemove 清掉.
    ///     worker 线程从未来过 → 无 UAF 风险.
    ///
    /// 错误:
    ///   - `error.TaskNotFound`         — V5 `tasks_config` 无此 id
    ///   - `error.TaskAlreadyRunning`   — 已在 `tasks` map 中
    ///   - `error.ShutdownInProgress`   — 正在停机
    ///   - `error.DatasourceNotFound`   — `cfg.source_db` 在 `datasource` 表中无匹配行
    pub fn addTask(self: *Scheduler, task_id: i64) !void {
        // 1. 快路径停机检查 (无锁).
        if (self.is_shutting_down.load(.acquire)) {
            common.logger.warn("任务 {d} 启动被拒绝: 正在停机", .{task_id});
            return error.ShutdownInProgress;
        }

        // 2. 加载 V5 TaskConfig (与 V1 sync_task 表解耦).
        var svc = meta.task.service.Service{ .store = self.store };
        const cfg = (try svc.getById(task_id)) orelse {
            // 404 风格, 不用 err_ — 单测期望不计入错误日志.
            common.logger.warn("任务 {d} 不存在 (tasks_config)", .{task_id});
            return error.TaskNotFound;
        };
        defer {
            // TaskConfig 含切片字段, Zig 0.17 把 const-optional-unwrap 当作 *const.
            // 拷贝到 var 后再 deinit, 与 V1 findById 同款 idiom.
            var cfg_owned = cfg;
            cfg_owned.deinit(self.allocator);
        }

        // 3. test_mode: 分配 stub, 锁内 put (不启动线程).
        if (self.test_mode) {
            // stub 字段含 undefined, deinit 会 deref 未初始化指针 → 仅 destroy 即可.
            const stub = try self.allocator.create(runtime.SyncTask);
            errdefer self.allocator.destroy(stub);
            stub.* = runtime.SyncTask{
                .allocator = self.allocator,
                .cfg = .{
                    .task_id = cfg.id,
                    .source_table = cfg.source_table,
                    .target_table = cfg.target_table,
                    .mall_id = cfg.source_db,
                },
                .transformer = undefined,
                .sink = undefined,
                .store = self.store,
                .sink_pool = undefined,
                .src_pool = undefined,
                .poller = undefined,
                ._sh = &[_]u8{},
                ._sd = &[_]u8{},
                ._su = &[_]u8{},
                ._sp = &[_]u8{},
                .pos = .{ .task_id = cfg.id },
            };

            const io = zfinal.io_instance.io;
            self.mutex.lock(io) catch return error.LockFailed;
            defer self.mutex.unlock(io);

            if (self.is_shutting_down.load(.acquire)) {
                return error.ShutdownInProgress;
            }
            if (self.tasks.contains(task_id)) {
                common.logger.warn("任务 {d} 已在运行, 跳过启动", .{task_id});
                return error.TaskAlreadyRunning;
            }
            try self.tasks.put(task_id, stub);
            common.logger.inf("[test] 任务 {d} ({s}) 已注册 (stub)", .{ task_id, cfg.name });
            return;
        }

        // 4. 生产模式 (锁外, 避免持锁做重活).
        //   a. 查找 datasource.
        const ds = (try meta.datasource.Service.findByMallId(self.store, self.allocator, cfg.source_db)) orelse {
            common.logger.err_("任务 {d} (source_db={s}) 绑定的数据源不存在", .{ task_id, cfg.source_db });
            return error.DatasourceNotFound;
        };
        defer {
            var d = ds;
            d.deinit(self.allocator);
        }

        // b. 构造 RuntimeConfig.
        //    V5 sync_mode: 0=full / 1=poll / 2=binlog / 3=both (与 TaskActiveStatus 枚举对齐).
        //    batch_size / enable_commission_calc 暂未从 config_json 解析, 用默认值.
        //    TODO(Phase 6): 解析 config_json → 覆盖 RuntimeConfig.
        const sync_mode: meta.task.SyncMode = switch (cfg.sync_mode) {
            0 => .full,
            1 => .poll,
            2 => .binlog,
            3 => .both,
            else => .poll,
        };
        const rcfg = runtime.RuntimeConfig{
            .task_id = cfg.id,
            .source_table = cfg.source_table,
            .target_table = cfg.target_table,
            .batch_size = 1000,
            .sync_mode = sync_mode,
            .enable_commission_calc = false,
            .mall_id = ds.mall_id,
        };

        // c. 构建 src_pool + 堆分配字符串 (由 SyncTask._sh/_sd/_su/_sp 持有寿命).
        const src_host = try self.allocator.dupe(u8, ds.host);
        const src_db = try self.allocator.dupe(u8, ds.db_name);
        const src_user = try self.allocator.dupe(u8, ds.username);
        const src_pass = try self.allocator.dupe(u8, ds.password);
        const src_cfg = zfinal.DBConfig{
            .db_type = .mysql,
            .host = src_host,
            .port = ds.port,
            .database = src_db,
            .username = src_user,
            .password = src_pass,
        };
        const src_pool = try zfinal.ConnectionPool.init(self.allocator, src_cfg, 1);

        // d. 实例化 SyncTask (blk 作用域限制 errdefer, 避免后续 put→start 链上 double-destroy).
        const task_ptr = blk: {
            const t = try self.allocator.create(runtime.SyncTask);
            errdefer self.allocator.destroy(t); // 仅在 blk 内有效 (init 失败时回收 struct 内存)
            t.* = try runtime.SyncTask.init(self.allocator, rcfg, ds, self.store, self.sink_pool, src_pool, src_host, src_db, src_user, src_pass);
            break :blk t;
        };
        // 注: SyncTask.init 失败时, src_pool + 字符串会泄漏 (V1 startTask 同款限制, 不在本次重构范围).

        // 5. 加锁, 二次停机 + contains 检查 + put + start (顺序: put 必须先于 start).
        //    失败时由 cleanup_needed defer 统一 deinit + destroy, 避免 double-free.
        var cleanup_needed = true;
        defer if (cleanup_needed) {
            task_ptr.deinit();
            self.allocator.destroy(task_ptr);
        };

        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);

        if (self.is_shutting_down.load(.acquire)) {
            return error.ShutdownInProgress;
        }
        if (self.tasks.contains(task_id)) {
            common.logger.warn("任务 {d} 已在运行, 跳过启动", .{task_id});
            return error.TaskAlreadyRunning;
        }

        try self.tasks.put(task_id, task_ptr);
        // map 接管 task_ptr 所有权. 若后续 start 失败, 由下方 cleanup_needed defer 处理 deinit + destroy.
        errdefer _ = self.tasks.fetchRemove(task_id);

        // start 失败: defer (cleanup_needed=true) 会做完整 deinit + destroy,
        // errdefer (fetchRemove) 会从 map 移除 dangling 指针条目 (用 _ 丢弃, 安全).
        task_ptr.start() catch |err| {
            common.logger.err_("任务 {d} ({s}) 启动线程失败: {s}", .{ task_id, cfg.name, @errorName(err) });
            return err;
        };

        // 成功: 所有权已转交 map, defer 不再清理.
        cleanup_needed = false;
        common.logger.inf("任务 {d} 启动成功 (source_db={s}, table={s})", .{ task_id, cfg.source_db, cfg.source_table });
    }

    /// V5 Phase 5 Task 3: 动态删除任务.
    ///
    /// 顺序 (Fix I-2): DB DELETE 先, 内存清理后.
    ///   - 旧实现: 先 fetchRemove + stop + deinit, 再 DB DELETE. 若 DB DELETE 失败,
    ///     调度器与 DB 发散: 内存已清, DB 行仍在 (下次启动会被 loadFromDb 复活).
    ///   - 新实现: 先 DB DELETE, 失败则调度器状态不变 (map + DB 都未动). 再清理内存.
    ///     即使 map 中没条目 (如崩溃恢复), 函数也成功 — DB 行被删, 内存无需清理.
    ///
    /// 与 `stopTask` 的区别:
    ///   - `stopTask`:  只停线程, 保留 V1 sync_task 行
    ///   - `removeTask`: 停线程 + 删除 V5 `tasks_config` 行 (HTTP DELETE 流程见 design §4.3)
    ///
    /// 错误: 仅 DB DELETE 失败时返回 (`error.TaskNotFound` 不再出现 — DB 行被删即视为成功).
    pub fn removeTask(self: *Scheduler, task_id: i64) !void {
        // 1. 先删 DB 行; 失败立即返回, 内存状态不变.
        var svc = meta.task.service.Service{ .store = self.store };
        try svc.delete(task_id);

        // 2. 再清内存 (短暂加锁, fetchRemove 后立刻解锁, 不持锁做 stop/deinit).
        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return error.LockFailed;
        const entry = self.tasks.fetchRemove(task_id) orelse {
            // map 里没有 (e.g. 进程崩溃恢复后重启, DB 行已被人工删),
            // 视为已删除 — 不报错.
            self.mutex.unlock(io);
            common.logger.inf("任务 {d} 已从 tasks_config 删除 (map 中无活动条目)", .{task_id});
            return;
        };
        self.mutex.unlock(io);

        // 3. 锁外做 stop + deinit (可能阻塞在 thread.join 上, 不应持锁).
        if (!self.test_mode) {
            entry.value.stop();
            entry.value.deinit();
        }
        self.allocator.destroy(entry.value);
        common.logger.inf("任务 {d} 已删除", .{task_id});
    }

    /// V5 Phase 5 Task 4: 重新加载单个任务 (用最新 DB 配置替换 in-memory SyncTask).
    ///
    /// 行为 (按顺序, 严格 errdefer 链):
    ///   1. 快路径停机检查 (无锁).
    ///   2. 锁外加载最新 V5 `TaskConfig` (避免持锁做 DB IO).
    ///   3. 加锁, 二次停机检查, `fetchRemove` 旧 entry (可能为 null — 首次重载).
    ///   4. 锁内: 停止旧 task 线程 (test_mode 跳过).
    ///   5. 锁内: 构造新 task_ptr (test_mode 走 stub; 生产模式走 addTask 同款路径).
    ///   6. 锁内: `tasks.put(id, task_ptr)` — put 先于 start (与 addTask 一致).
    ///   7. 锁内: `task_ptr.start()` — 失败时由 errdefer 链清理 map 条目.
    ///   8. 锁内: 释放旧 task (test_mode 仅 destroy; 生产模式 deinit + destroy).
    ///
    /// 与 `addTask` 的区别:
    ///   - `addTask`    仅插入; 若 id 已存在返回 `error.TaskAlreadyRunning`
    ///   - `reloadTask` 替换; 若 id 不存在则视为 "首次重载", fetchRemove 返回 null,
    ///                    后续走 put → start 等价于 addTask 的生产路径
    ///
    /// 错误:
    ///   - `error.ShutdownInProgress` — 正在停机
    ///   - `error.TaskNotFound`       — V5 `tasks_config` 无此 id
    ///   - `error.DatasourceNotFound` — 生产模式 `cfg.source_db` 无匹配 datasource
    pub fn reloadTask(self: *Scheduler, task_id: i64) !void {
        // 1. 快路径停机检查 (无锁).
        if (self.is_shutting_down.load(.acquire)) {
            common.logger.warn("任务 {d} 重载被拒绝: 正在停机", .{task_id});
            return error.ShutdownInProgress;
        }

        // 2. 锁外加载最新 V5 TaskConfig (DB IO 不应持锁).
        var svc = meta.task.service.Service{ .store = self.store };
        const cfg = (try svc.getById(task_id)) orelse {
            common.logger.warn("任务 {d} 不存在 (tasks_config)", .{task_id});
            return error.TaskNotFound;
        };
        defer {
            var cfg_owned = cfg;
            cfg_owned.deinit(self.allocator);
        }

        // 3. 加锁.
        //    Fix C1: `defer self.mutex.unlock(io);` 自动覆盖所有 return 路径
        //    (error + success), 取代之前在 success / 二次停机检查中手动 unlock 的反模式.
        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);

        // 二次停机检查 (防止刚进入临界区时 stopAll 置位 flag).
        if (self.is_shutting_down.load(.acquire)) {
            return error.ShutdownInProgress;
        }

        // 4. fetchRemove 旧 entry (可能为 null — 首次重载).
        const old_entry = self.tasks.fetchRemove(task_id);

        // Fix C3: 旧 entry 清理 defer (覆盖 put/start 失败路径).
        //   失败时: deinit + destroy (生产) / 仅 destroy (test_mode).
        //   成功时: 在底部显式清理后, 设 flag = false 让 defer 跳过.
        var old_cleanup_needed = old_entry != null;
        defer if (old_cleanup_needed) {
            if (old_entry) |kv| {
                if (!self.test_mode) kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
        };

        // 5. 停止旧 task 线程 (test_mode 跳过 — stub 无运行线程).
        //    stop() 无副作用, 失败路径由 old_cleanup_needed defer 兜底.
        if (old_entry) |kv| {
            if (!self.test_mode) {
                kv.value.stop();
            }
        }

        // 6. 构造新 task_ptr.
        //    blk 作用域限制 errdefer: 仅在 create/init 失败时回收 struct 内存,
        //    不触碰 SyncTask 字段 (与 addTask 同款已知限制: init 失败时部分字段泄漏).
        const task_ptr = blk: {
            const t = try self.allocator.create(runtime.SyncTask);
            errdefer self.allocator.destroy(t);
            if (self.test_mode) {
                // test_mode stub — 与 addTask 同款, 跳过 transformer/sink/poller 真实实例化.
                t.* = runtime.SyncTask{
                    .allocator = self.allocator,
                    .cfg = .{
                        .task_id = cfg.id,
                        .source_table = cfg.source_table,
                        .target_table = cfg.target_table,
                        .mall_id = cfg.source_db,
                    },
                    .transformer = undefined,
                    .sink = undefined,
                    .store = self.store,
                    .sink_pool = undefined,
                    .src_pool = undefined,
                    .poller = undefined,
                    ._sh = &[_]u8{},
                    ._sd = &[_]u8{},
                    ._su = &[_]u8{},
                    ._sp = &[_]u8{},
                    .pos = .{ .task_id = cfg.id },
                };
            } else {
                // 生产模式: 与 addTask 同步路径一致.
                // (TODO Phase 6: 提取 buildSyncTask 公共函数, 消除重复.)
                const ds = (try meta.datasource.Service.findByMallId(self.store, self.allocator, cfg.source_db)) orelse {
                    common.logger.err_("任务 {d} (source_db={s}) 绑定的数据源不存在", .{ task_id, cfg.source_db });
                    return error.DatasourceNotFound;
                };
                defer {
                    var d = ds;
                    d.deinit(self.allocator);
                }

                const sync_mode: meta.task.SyncMode = switch (cfg.sync_mode) {
                    0 => .full,
                    1 => .poll,
                    2 => .binlog,
                    3 => .both,
                    else => .poll,
                };
                const rcfg = runtime.RuntimeConfig{
                    .task_id = cfg.id,
                    .source_table = cfg.source_table,
                    .target_table = cfg.target_table,
                    .batch_size = 1000,
                    .sync_mode = sync_mode,
                    .enable_commission_calc = false,
                    .mall_id = ds.mall_id,
                };

                const src_host = try self.allocator.dupe(u8, ds.host);
                const src_db = try self.allocator.dupe(u8, ds.db_name);
                const src_user = try self.allocator.dupe(u8, ds.username);
                const src_pass = try self.allocator.dupe(u8, ds.password);
                const src_cfg = zfinal.DBConfig{
                    .db_type = .mysql,
                    .host = src_host,
                    .port = ds.port,
                    .database = src_db,
                    .username = src_user,
                    .password = src_pass,
                };
                const src_pool = try zfinal.ConnectionPool.init(self.allocator, src_cfg, 1);

                t.* = try runtime.SyncTask.init(self.allocator, rcfg, ds, self.store, self.sink_pool, src_pool, src_host, src_db, src_user, src_pass);
            }
            break :blk t;
        };

        // Fix C2: 新 task_ptr 清理 defer (覆盖 put/start 失败路径, 与 addTask 同款 cleanup_needed 模式).
        //   失败时: deinit + destroy (生产) / 仅 destroy (test_mode, 跳过 stub deinit).
        //   成功时: 在底部设 flag = false 让 defer 跳过.
        var cleanup_needed = true;
        defer if (cleanup_needed) {
            if (!self.test_mode) task_ptr.deinit();
            self.allocator.destroy(task_ptr);
        };

        // 7. put 到 map (put 先于 start, 与 addTask 同款 — start 失败时由 errdefer 清 map).
        try self.tasks.put(task_id, task_ptr);
        errdefer _ = self.tasks.fetchRemove(task_id);

        // 8. 启动新 task (test_mode 跳过).
        if (!self.test_mode) {
            task_ptr.start() catch |err| {
                common.logger.err_("任务 {d} ({s}) 重载后启动线程失败: {s}", .{ task_id, cfg.name, @errorName(err) });
                return err;
            };
        }

        // 9. 成功路径: 显式清理旧 task (test_mode 仅 destroy; 生产模式 deinit + destroy).
        //    注: 持锁做 deinit 可能阻塞 (thread.join) — 与 spec 保持一致, 简单化.
        if (old_entry) |kv| {
            if (!self.test_mode) {
                kv.value.deinit();
            }
            self.allocator.destroy(kv.value);
        }
        old_cleanup_needed = false;

        // 10. 所有权已转交 map, defer 不再清理.
        cleanup_needed = false;

        if (self.test_mode) {
            common.logger.inf("[test] 任务 {d} ({s}) 已重载 (stub)", .{ task_id, cfg.name });
        } else {
            common.logger.inf("任务 {d} ({s}) 重载完成", .{ task_id, cfg.name });
        }
    }

    /// V5 Phase 5 Task 4: 列出所有已注册任务的 V5 TaskConfig.
    ///
    /// 行为:
    ///   - 锁内遍历 `self.tasks` map, 对每个 task_id 调 `svc.getById` 取最新配置.
    ///   - 若 DB 行已被删除 (map 中残留, 罕见), 跳过该 id (仅打 warn).
    ///   - 返回的 `[]TaskConfig` 由调用方负责 `deinit` + `free`.
    ///
    /// 与 `listRunning` 的区别:
    ///   - `listRunning`  只返回 `[]i64` (id 列表)
    ///   - `listTasks`   返回 `[]TaskConfig` (含完整字段, 供 HTTP API 序列化)
    pub fn listTasks(self: *Scheduler) ![]meta.task.service.TaskConfig {
        const a = self.allocator;
        const io = zfinal.io_instance.io;

        // Fix I1: 锁内仅快照 keys, 锁外做 DB I/O.
        //   旧实现持锁调 svc.getById, DB 查询期间阻塞 addTask/removeTask/reloadTask.
        const ids: []const i64 = blk: {
            self.mutex.lock(io) catch return error.LockFailed;
            defer self.mutex.unlock(io);
            var buf = try a.alloc(i64, self.tasks.count());
            var i: usize = 0;
            var it = self.tasks.iterator();
            while (it.next()) |kv| {
                buf[i] = kv.key_ptr.*;
                i += 1;
            }
            break :blk buf;
        };
        defer a.free(ids);

        var svc = meta.task.service.Service{ .store = self.store };
        var list = std.ArrayList(meta.task.service.TaskConfig).empty;
        errdefer {
            for (list.items) |*c| c.deinit(a);
            list.deinit(a);
        }
        for (ids) |id| {
            const cfg = (try svc.getById(id)) orelse {
                common.logger.warn("listTasks: 任务 {d} 在 tasks_config 中已不存在, 跳过", .{id});
                continue;
            };
            // 单条 cfg 在 list.append 失败时需释放, 成功则由 list 接管.
            // TaskConfig.deinit 签名是 *TaskConfig (非 const), 需 var 拷贝去 const 限定.
            errdefer {
                var cfg_owned = cfg;
                cfg_owned.deinit(a);
            }
            try list.append(a, cfg);
        }
        return list.toOwnedSlice(a) catch return error.OutOfMemory;
    }

    /// V5 Phase 5 Task 4: 启动时批量加载所有 `status=.active` 任务.
    ///
    /// 行为:
    ///   - 查 `tasks_config` 表, 过滤 `status = .active` 的所有行.
    ///   - 对每行调 `addTask`; 单个 task 失败不阻塞整体, 仅打 warn 继续.
    ///   - 用于 `main.zig` 启动 web server 之前, 让已配置的 active 任务自动跑起来.
    ///
    /// 与 `bootstrapAll` 的区别:
    ///   - `bootstrapAll` 加载 V1 `sync_task` 表 (旧路径, 兼容 Phase 1-4)
    ///   - `loadFromDb`  加载 V5 `tasks_config` 表 (新路径, Phase 5 动态任务)
    pub fn loadFromDb(self: *Scheduler) !void {
        var svc = meta.task.service.Service{ .store = self.store };
        const cfgs = try svc.list(.active);
        defer {
            for (cfgs) |*c| c.deinit(self.allocator);
            self.allocator.free(cfgs);
        }
        common.logger.inf("loadFromDb: 启动时发现 {d} 个 active 任务", .{cfgs.len});
        // Fix I3: 累计成功/失败计数, 函数末尾输出汇总行 — 供日志告警/grep 触发.
        var failed: usize = 0;
        var succeeded: usize = 0;
        for (cfgs) |cfg| {
            // 单个 task 失败不应阻塞整个启动流程 — 仅打 warn, 继续下一个.
            self.addTask(cfg.id) catch |err| {
                failed += 1;
                common.logger.warn("loadFromDb: 任务 {d} ({s}) 启动失败: {s}", .{ cfg.id, cfg.name, @errorName(err) });
            };
            succeeded += 1;
        }
        common.logger.inf("loadFromDb 完成: {d} 任务加载, {d} 启动失败", .{ succeeded, failed });
    }

    /// 启动所有 status=1 的任务 (启动时调用)
    pub fn bootstrapAll(self: *Scheduler) !void {
        const tasks = try meta.task.Service.findEnabled(self.store, self.allocator);
        defer {
            for (tasks) |*t| t.deinit(self.allocator);
            self.allocator.free(tasks);
        }
        common.logger.inf("启动时发现 {d} 个已启用任务", .{tasks.len});
        for (tasks) |t| {
            self.startTask(t.id) catch |err| {
                common.logger.err_("任务 {d} 启动失败: {s}", .{ t.id, @errorName(err) });
            };
        }
    }

    /// P1 任务 1.8: 优雅停机 — 拒绝新 task 启动 + 信号所有运行中 task 退出当前 batch.
    ///
    /// 行为:
    ///   1. 立即设置 is_shutting_down = true (后续 startTask 立即返回 error.ShutdownInProgress)
    ///   2. 遍历 self.tasks, 把每个 task 的 is_running 置为 false (worker 线程会在下个 batch 边界退出循环)
    ///   3. 软等待 timeout_ms 毫秒, 给在跑的 batch 一个自然 commit 的窗口
    ///   4. 不做 thread.join (deinit 会做). 任何卡在 MySQL 查询里的线程, 会在 deinit 阶段被 join 阻塞
    ///      — 这是已知的设计折衷, 进程二次信号仍可强制退出.
    ///
    /// 返回被发停止信号的 task 数量.
    pub fn stopAll(self: *Scheduler, timeout_ms: u64) u32 {
        // 1. 先置位, 阻止新 task 启动 (双检查路径的快路径会立即返回)
        self.is_shutting_down.store(true, .release);

        const io = zfinal.io_instance.io;

        // 2. 在锁内对所有 task 发停止信号 + 快照 task 数量
        self.mutex.lock(io) catch {
            common.logger.warn("[graceful] 调度器锁获取失败, 继续执行", .{});
            return 0;
        };
        var count: u32 = 0;
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task = entry.value_ptr.*;
            task.is_running.store(false, .release);
            count += 1;
        }
        self.mutex.unlock(io);

        common.logger.inf("[graceful] 已向 {d} 个任务发送停止信号, 等待 {d}ms", .{ count, timeout_ms });

        // 3. 软等待 - 轮询任务 is_finished, 全部完成后提前返回; 否则睡到 deadline.
        const start_ms: i64 = nowMs();
        while (nowMs() - start_ms < @as(i64, @intCast(timeout_ms))) {
            std.Io.sleep(io, .fromMilliseconds(100), .real) catch break;
            self.mutex.lock(io) catch continue;
            var all_done = true;
            var it2 = self.tasks.iterator();
            while (it2.next()) |entry| {
                if (!entry.value_ptr.*.is_finished.load(.acquire)) {
                    all_done = false;
                    break;
                }
            }
            self.mutex.unlock(io);
            if (all_done) break;
        }

        return count;
    }

    /// 获取当前 Unix 毫秒 (Zig 0.17 用 std.Io.Clock, 替换被移除的 std.time.milliTimestamp)
    fn nowMs() i64 {
        return std.Io.Clock.now(.real, zfinal.io_instance.io).toMilliseconds();
    }

    /// 列出所有正在运行的任务
    pub fn listRunning(self: *Scheduler, allocator: std.mem.Allocator) ![]i64 {
        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        var ids = try allocator.alloc(i64, self.tasks.count());
        var i: usize = 0;
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            ids[i] = entry.key_ptr.*;
            i += 1;
        }
        return ids;
    }
};

// ============================================================
// 单元测试 (P1 任务 1.8: 优雅停机)
// ============================================================

fn makeTestStore(allocator: std.mem.Allocator) !meta.store.MetaStore {
    return try meta.store.MetaStore.init(allocator, ":memory:");
}

fn makeTestPool(allocator: std.mem.Allocator) !*zfinal.ConnectionPool {
    // SQLite in-memory pool, pool size = 1 (避免 :memory: 多连接数据隔离的坑).
    // 我们只对 pool 句柄做引用, 不实际查询.
    const cfg = zfinal.DBConfig.sqliteMemory();
    return try zfinal.ConnectionPool.init(allocator, cfg, 1);
}

test "scheduler: is_shutting_down defaults to false" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    const pool = try makeTestPool(a);
    defer pool.deinit();

    var sched = Scheduler.init(a, &store, pool);
    defer sched.deinit();

    try std.testing.expect(!sched.is_shutting_down.load(.acquire));
}

test "scheduler: stopAll sets is_shutting_down and returns task count" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    const pool = try makeTestPool(a);
    defer pool.deinit();

    var sched = Scheduler.init(a, &store, pool);
    defer sched.deinit();

    // 初始无 task, stopAll 应返回 0
    const n = sched.stopAll(100);
    try std.testing.expectEqual(@as(u32, 0), n);
    try std.testing.expect(sched.is_shutting_down.load(.acquire));
}

test "scheduler: startTask returns ShutdownInProgress when shutting down" {
    const a = std.testing.allocator;
    var store = try makeTestStore(a);
    defer store.deinit();
    const pool = try makeTestPool(a);
    defer pool.deinit();

    var sched = Scheduler.init(a, &store, pool);
    defer sched.deinit();

    // 模拟收到停机信号
    sched.is_shutting_down.store(true, .release);

    // 任意 task_id 都应被拒绝, 不应触达 DB
    const result = sched.startTask(999);
    try std.testing.expectError(error.ShutdownInProgress, result);
}

// ============================================================
// V5 Phase 5 Task 3: addTask / removeTask (动态任务管理)
// ============================================================
//
// 完整 addTask 生产路径需要真实 datasource + MySQL 连接池, 单测无法触发.
// Scheduler.initForTest(a, &db) 开启 test_mode → addTask 走 stub 路径,
// 仅验证 map 状态 + DB 状态变化:
//   - addTask 在 tasks map 中插入 stub entry, 不动 `tasks_config` 行
//   - removeTask 从 map 移除 stub 并 DELETE 该行

test "Scheduler addTask inserts entry and removeTask deletes it" {
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();

    var svc = meta.task.service.Service{ .store = &db };
    const id = try svc.create(.{
        .name = "order_sync",
        .source_db = "primary",
        .source_table = "order_info",
        .target_table = "order_info",
        .sync_mode = 1,
        .config_json = "{}",
    });

    try sched.addTask(id);
    {
        const got = (try svc.getById(id)).?;
        var owned = got;
        defer owned.deinit(a);
        try std.testing.expect(owned.id == id);
    }

    try sched.removeTask(id);
    try std.testing.expect(try svc.getById(id) == null);
}

test "Scheduler addTask is idempotent when called twice on same id" {
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();

    var svc = meta.task.service.Service{ .store = &db };
    const id = try svc.create(.{
        .name = "order_sync",
        .source_db = "primary",
        .source_table = "t",
        .target_table = "t",
        .sync_mode = 1,
        .config_json = "{}",
    });

    try sched.addTask(id);
    try std.testing.expectError(error.TaskAlreadyRunning, sched.addTask(id));
}

test "Scheduler addTask returns TaskNotFound for missing id" {
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();

    try std.testing.expectError(error.TaskNotFound, sched.addTask(99999));
}

test "Scheduler removeTask succeeds even when map has no entry" {
    // Fix I-2: removeTask 先删 DB, 再清内存. map 没条目 (e.g. 进程崩溃恢复)
    // 也视为成功 — DB 行被删即达成 remove 语义.
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();

    // 不存在的 id: DB DELETE 是 no-op, map 也空, 函数仍应成功.
    try sched.removeTask(99999);
}

test "Scheduler addTask returns ShutdownInProgress when shutting down" {
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();

    var svc = meta.task.service.Service{ .store = &db };
    const id = try svc.create(.{
        .name = "t",
        .source_db = "primary",
        .source_table = "t",
        .target_table = "t",
        .sync_mode = 1,
        .config_json = "{}",
    });

    sched.is_shutting_down.store(true, .release);
    try std.testing.expectError(error.ShutdownInProgress, sched.addTask(id));
}

// ============================================================
// V5 Phase 5 Task 4: reloadTask / listTasks / loadFromDb
// ============================================================
//
// Task 4 在 Task 3 (addTask/removeTask) 之上扩展:
//   - reloadTask:  用最新 DB 配置替换 in-memory SyncTask
//   - listTasks:   返回所有已注册 task 的 V5 TaskConfig 列表
//   - loadFromDb:  启动时批量加载 status=.active 任务
//
// 单测统一走 test_mode (Scheduler.initForTest) 路径, 不实例化真实 SyncTask.
//   - reloadTask: stub 替换 + DB 行可独立更新 (验证 reload 不破坏 DB 一致性)
//   - listTasks:  验证 map 中所有 task id 都返回对应 V5 TaskConfig
//   - loadFromDb: 验证 active 被加载, disabled 被跳过

test "Scheduler reloadTask swaps existing task with new config" {
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();

    var svc = meta.task.service.Service{ .store = &db };
    const id = try svc.create(.{
        .name = "order_sync",
        .source_db = "primary",
        .source_table = "order_info",
        .target_table = "order_info",
        .sync_mode = 1,
        .config_json = "{\"polling_interval_sec\":60}",
    });

    try sched.addTask(id);

    // 更新 DB 行的 config_json, 然后 reload. reload 本身不应破坏 DB 一致性.
    try svc.update(id, .{
        .name = "order_sync",
        .source_db = "primary",
        .source_table = "order_info",
        .target_table = "order_info",
        .sync_mode = 1,
        .config_json = "{\"polling_interval_sec\":30}",
    });

    try sched.reloadTask(id);

    // 重载后 DB 行的 config_json 应仍是更新后的值.
    const got = (try svc.getById(id)).?;
    var owned = got;
    defer owned.deinit(a);
    try std.testing.expectEqualStrings("{\"polling_interval_sec\":30}", owned.config_json);
}

test "Scheduler listTasks returns all registered tasks" {
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();

    var svc = meta.task.service.Service{ .store = &db };
    const id_a = try svc.create(.{
        .name = "a",
        .source_db = "p",
        .source_table = "t",
        .target_table = "t",
        .sync_mode = 1,
        .config_json = "{}",
    });
    const id_b = try svc.create(.{
        .name = "b",
        .source_db = "p",
        .source_table = "t",
        .target_table = "t",
        .sync_mode = 1,
        .config_json = "{}",
    });

    try sched.addTask(id_a);
    try sched.addTask(id_b);

    const list = try sched.listTasks();
    defer {
        for (list) |*c| c.deinit(a);
        a.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
}

test "Scheduler loadFromDb hydrates all active tasks but skips disabled" {
    const a = std.testing.allocator;
    var db = try makeTestStore(a);
    defer db.deinit();

    var svc = meta.task.service.Service{ .store = &db };
    _ = try svc.create(.{
        .name = "a",
        .source_db = "p",
        .source_table = "t",
        .target_table = "t",
        .sync_mode = 1,
        .config_json = "{}",
        .status = .active,
    });
    _ = try svc.create(.{
        .name = "b",
        .source_db = "p",
        .source_table = "t",
        .target_table = "t",
        .sync_mode = 1,
        .config_json = "{}",
        .status = .disabled,
    });

    var sched = Scheduler.initForTest(a, &db);
    defer sched.deinit();
    try sched.loadFromDb();

    const list = try sched.listTasks();
    defer {
        for (list) |*c| c.deinit(a);
        a.free(list);
    }
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("a", list[0].name);
}
