//! Web 全局依赖 (仿 zfinal ruoyi-gen 模式)
//! 任何 handler 通过 import 这个模块拿 token/store/scheduler 引用

const std = @import("std");
const zfinal = @import("zfinal");
const config_mod = @import("../config.zig");
const meta = @import("../meta/mod.zig");
const engine = @import("../engine/mod.zig");

pub var pool: *zfinal.ConnectionPool = undefined;
pub var tokenMgr: zfinal.TokenManager = undefined;
pub var store_ptr: *meta.store.MetaStore = undefined;
pub var scheduler_ptr: *engine.scheduler.Scheduler = undefined;
pub var config_ptr: *config_mod.Config = undefined;
pub var allocator_ptr: std.mem.Allocator = undefined;

/// 初始化 Web 全局依赖 (在 main() 注册路由前调用一次)
pub fn initWebDeps(
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    store: *meta.store.MetaStore,
    scheduler: *engine.scheduler.Scheduler,
    token: *zfinal.TokenManager,
    sink_pool: *zfinal.ConnectionPool,
) void {
    allocator_ptr = allocator;
    config_ptr = cfg;
    store_ptr = store;
    scheduler_ptr = scheduler;
    tokenMgr = token.*;
    pool = sink_pool;
}

/// 初始化归集库连接池 (与 main 共享)
pub fn initSinkPool(allocator: std.mem.Allocator, cfg: config_mod.Config) !*zfinal.ConnectionPool {
    const host_z = try allocSentinel(allocator, cfg.sink.host);
    defer allocator.free(host_z);
    const db_z = try allocSentinel(allocator, cfg.sink.database);
    defer allocator.free(db_z);
    const user_z = try allocSentinel(allocator, cfg.sink.username);
    defer allocator.free(user_z);
    const pass_z = try allocSentinel(allocator, cfg.sink.password);
    defer allocator.free(pass_z);

    const db_cfg = zfinal.DBConfig{
        .db_type = .mysql,
        .host = host_z,
        .port = cfg.sink.port,
        .database = db_z,
        .username = user_z,
        .password = pass_z,
        .max_connections = cfg.sink.pool_size,
    };

    return try zfinal.ConnectionPool.init(allocator, db_cfg, cfg.sink.pool_size);
}

fn allocSentinel(allocator: std.mem.Allocator, src: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, src.len + 1);
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0];
}
