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

    pub fn init(allocator: std.mem.Allocator, store: *meta.store.MetaStore, sink_pool: *zfinal.ConnectionPool) Scheduler {
        return .{
            .allocator = allocator,
            .store = store,
            .sink_pool = sink_pool,
            .tasks = std.AutoHashMap(i64, *runtime.SyncTask).init(allocator),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task = entry.value_ptr.*;
            task.stop();
            task.deinit();
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
        const sync_mode = std.meta.stringToEnum(meta.task.SyncMode, task.sync_mode) orelse .cdc;
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
        const src_cfg = zfinal.DBConfig{.db_type=.mysql,.host=src_host,.port=ds.port,.database=src_db,.username=src_user,.password=src_pass};
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

        common.logger.inf("[graceful] 已向 {d} 个任务发送停止信号, 等待 {d}ms", .{count, timeout_ms});

        // 3. 软等待 - 简单 sleep 到 deadline. worker 线程在 is_running 变 false 后
        //    会在当前 batch 跑完后跳出 runFull 的 while 循环, 之后 runLoop 退出, 线程自然结束.
        const start_ms: i64 = nowMs();
        while (nowMs() - start_ms < @as(i64, @intCast(timeout_ms))) {
            std.Io.sleep(io, .fromMilliseconds(100), .real) catch break;
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
