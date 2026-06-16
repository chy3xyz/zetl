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
        self.tasks.deinit(self.allocator);
    }

    /// 启动一个任务 (从 task_id 加载配置)
    pub fn startTask(self: *Scheduler, task_id: i64) !void {
        const io = zfinal.io_instance.io;
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);

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

        // 2. 加载 datasource
        const ds = (try meta.datasource.Service.findById(self.store, self.allocator, task.datasource_id)) orelse {
            common.logger.err_("任务 {d} 绑定的数据源 {d} 不存在", .{ task_id, task.datasource_id });
            return error.DatasourceNotFound;
        };
        defer {
            var d = ds;
            d.deinit(self.allocator);
        }

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
        const src_pool = try zfinal.ConnectionPool.init(self.allocator, src_cfg, 1);
        const task_ptr = try self.allocator.create(runtime.SyncTask);
        errdefer self.allocator.destroy(task_ptr);
        task_ptr.* = try runtime.SyncTask.init(self.allocator, rcfg, ds, self.store, self.sink_pool, src_pool, src_host, src_db, src_user, src_pass);

        // 4. 启动线程
        try task_ptr.start();
        try self.tasks.put(task_id, task_ptr);

        // 5. 更新 task 状态为运行中
        try meta.task.Service.updateStatus(self.store, task_id, 1, null);
        common.logger.inf("任务 {d} ({s}) 启动成功", .{ task_id, task.task_name });
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
