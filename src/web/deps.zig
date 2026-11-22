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

/// token → username 绑定 (登录时填充, 权限中间件查询用)
/// 这是为了弥补 zfinal TokenManager 只存 token 不绑用户的缺陷.
/// 全局 StringHashMap + Mutex 保护. 在 login handler 中写入,
/// 在 permissionInterceptor 中读取.
/// 带 bound_at: 未显式 logout 的绑定由 bindTokenToUser 机会式清扫
/// (token TTL 1h, 清扫阈值取 2 倍安全余量), 避免长期运行内存缓慢增长.
pub const TokenBinding = struct {
    username: []const u8,
    bound_at_ms: i64,
};
pub var token_user_map: std.StringHashMap(TokenBinding) = undefined;
pub var token_user_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// 清扫周期 (ms): bindTokenToUser 时距上次清扫超过该值则触发一轮.
pub const TOKEN_SWEEP_INTERVAL_MS: i64 = 10 * 60 * 1000;
/// 绑定存活阈值 (ms): token 服务端 TTL 1h 的 2 倍, 活跃会话不会被误清.
pub const TOKEN_BINDING_TTL_MS: i64 = 2 * 60 * 60 * 1000;
var last_token_sweep_ms: i64 = 0;

/// 清扫过期绑定 (caller 已持锁). 返回清除条数. 独立出 map/now 参数以便单测.
pub fn sweepExpiredBindingsLocked(map: *std.StringHashMap(TokenBinding), a: std.mem.Allocator, now_ms: i64) usize {
    var expired_keys: [256][]const u8 = undefined;
    var n: usize = 0;
    var it = map.iterator();
    while (it.next()) |e| {
        if (now_ms - e.value_ptr.bound_at_ms > TOKEN_BINDING_TTL_MS and n < expired_keys.len) {
            expired_keys[n] = e.key_ptr.*;
            n += 1;
        }
    }
    for (expired_keys[0..n]) |k| {
        if (map.fetchRemove(k)) |kv| {
            a.free(kv.key);
            a.free(kv.value.username);
        }
    }
    return n;
}

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
    token_user_map = std.StringHashMap(TokenBinding).init(allocator);
}

/// 记录 token 与 username 的绑定. login 成功后调用.
pub fn bindTokenToUser(token: []const u8, username: []const u8) !void {
    token_user_mutex.lock(io.io) catch return;
    defer token_user_mutex.unlock(io.io);

    const now_ms = std.Io.Clock.now(.real, io.io).toMilliseconds();
    // 机会式清扫: 距上次清扫超过周期则清除过期绑定 (未 logout 的 token 不残留)
    if (now_ms - last_token_sweep_ms > TOKEN_SWEEP_INTERVAL_MS) {
        last_token_sweep_ms = now_ms;
        _ = sweepExpiredBindingsLocked(&token_user_map, allocator_ptr, now_ms);
    }

    // 如果 token 已有绑定, 释放旧 username
    if (token_user_map.fetchRemove(token)) |kv| {
        allocator_ptr.free(kv.key);
        allocator_ptr.free(kv.value.username);
    }
    const key_dup = try allocator_ptr.dupe(u8, token);
    errdefer allocator_ptr.free(key_dup);
    const val_dup = try allocator_ptr.dupe(u8, username);
    errdefer allocator_ptr.free(val_dup);
    try token_user_map.put(key_dup, .{ .username = val_dup, .bound_at_ms = now_ms });
}

/// 查询 token 对应的 username. 没找到返回 null.
pub fn getUsernameByToken(token: []const u8) ?[]const u8 {
    token_user_mutex.lock(io.io) catch return null;
    defer token_user_mutex.unlock(io.io);
    if (token_user_map.get(token)) |b| return b.username;
    return null;
}

/// 解除 token 与 username 的绑定 (logout 时调用).
pub fn unbindToken(token: []const u8) void {
    token_user_mutex.lock(io.io) catch return;
    defer token_user_mutex.unlock(io.io);
    if (token_user_map.fetchRemove(token)) |kv| {
        allocator_ptr.free(kv.key);
        allocator_ptr.free(kv.value.username);
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

test "sweepExpiredBindingsLocked removes only expired bindings" {
    const a = std.testing.allocator;
    var map = std.StringHashMap(TokenBinding).init(a);
    defer map.deinit();

    const now: i64 = 1_000_000_000;
    const fresh_tok = try a.dupe(u8, "fresh");
    const fresh_user = try a.dupe(u8, "alice");
    try map.put(fresh_tok, .{ .username = fresh_user, .bound_at_ms = now });
    const old_tok = try a.dupe(u8, "stale");
    const old_user = try a.dupe(u8, "bob");
    try map.put(old_tok, .{ .username = old_user, .bound_at_ms = now - TOKEN_BINDING_TTL_MS - 1 });

    const removed = sweepExpiredBindingsLocked(&map, a, now);
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expect(map.contains("fresh"));
    try std.testing.expect(!map.contains("stale"));
    try std.testing.expectEqualStrings("alice", map.get("fresh").?.username);

    // HashMap.deinit 不释放 key/value — 手动取出释放 (stale 对已由 sweep 释放)
    if (map.fetchRemove("fresh")) |kv| {
        a.free(kv.key);
        a.free(kv.value.username);
    }
}
