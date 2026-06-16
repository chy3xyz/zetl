//! Web 全局依赖 (仿 zfinal ruoyi-gen 模式)
//! 任何 handler 通过 import 这个模块拿 token/store/scheduler 引用

const std = @import("std");
const zfinal = @import("zfinal");
const config_mod = @import("../config.zig");
const meta = @import("../meta/mod.zig");
const engine = @import("../engine/mod.zig");
const io = zfinal.io_instance;

pub var pool: *zfinal.ConnectionPool = undefined;
pub var tokenMgr: zfinal.TokenManager = undefined;
pub var store_ptr: *meta.store.MetaStore = undefined;
pub var scheduler_ptr: *engine.scheduler.Scheduler = undefined;
pub var config_ptr: *config_mod.Config = undefined;
pub var allocator_ptr: std.mem.Allocator = undefined;

/// token → username 映射 (登录时填充, 权限中间件查询用)
/// 这是为了弥补 zfinal TokenManager 只存 token 不绑用户的缺陷.
/// 全局 StringHashMap + Mutex 保护. 在 login handler 中写入,
/// 在 permissionInterceptor 中读取.
pub var token_user_map: std.StringHashMap([]const u8) = undefined;
pub var token_user_mutex: std.Io.Mutex = std.Io.Mutex.init;

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
    token_user_map = std.StringHashMap([]const u8).init(allocator);
}

/// 记录 token 与 username 的绑定. login 成功后调用.
pub fn bindTokenToUser(token: []const u8, username: []const u8) !void {
    token_user_mutex.lock(io.io) catch return;
    defer token_user_mutex.unlock(io.io);

    // 如果 token 已有绑定, 释放旧 username
    if (token_user_map.fetchRemove(token)) |kv| {
        allocator_ptr.free(kv.key);
        allocator_ptr.free(kv.value);
    }
    const key_dup = try allocator_ptr.dupe(u8, token);
    errdefer allocator_ptr.free(key_dup);
    const val_dup = try allocator_ptr.dupe(u8, username);
    errdefer allocator_ptr.free(val_dup);
    try token_user_map.put(key_dup, val_dup);
}

/// 查询 token 对应的 username. 没找到返回 null.
pub fn getUsernameByToken(token: []const u8) ?[]const u8 {
    token_user_mutex.lock(io.io) catch return null;
    defer token_user_mutex.unlock(io.io);
    return token_user_map.get(token);
}

/// 解除 token 与 username 的绑定 (logout 时调用).
pub fn unbindToken(token: []const u8) void {
    token_user_mutex.lock(io.io) catch return;
    defer token_user_mutex.unlock(io.io);
    if (token_user_map.fetchRemove(token)) |kv| {
        allocator_ptr.free(kv.key);
        allocator_ptr.free(kv.value);
    }
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
