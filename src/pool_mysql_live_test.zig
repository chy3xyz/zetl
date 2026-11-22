//! 真实 MySQL 连接池 live 测试 (env 门控).
//!
//! 历史: 2026-06 起 aarch64-macos + Zig 0.17-dev 上, 主线程创建的
//! ConnectionPool 在**子线程 acquire** 路径报
//! `Lost connection at 'reading initial communication packet'`
//! (线程局部存储 × mysql C 库交互问题, 详见 AGENTS.md 已知问题 #1).
//! zfinal v0.28.x 对 pool 并发做了大幅加固; 本测试用于回归验证该路径.
//!
//! 运行方式 (需要本地 MySQL):
//!   ZETL_LIVE_MYSQL=1 zig build -Ddriver_mysql=true test
//! 未设 ZETL_LIVE_MYSQL 或驱动未启用时自动跳过, 不影响常规 CI.
//!
//! 连接参数 (默认 root@127.0.0.1:3306/zetl_live_test, 库需预先创建):
//!   ZETL_LIVE_MYSQL_HOST / ZETL_LIVE_MYSQL_PORT / ZETL_LIVE_MYSQL_USER /
//!   ZETL_LIVE_MYSQL_PASS / ZETL_LIVE_MYSQL_DB

const std = @import("std");
const zfinal = @import("zfinal");

/// 0.17.0 移除了 std.process.hasEnvVarConstant / getEnvVarOwned 的便捷形态,
/// zetl 已链 libc, 直接用 std.c.getenv (与 zfinal 自身 live 测试同款模式).
fn envOr(key: [:0]const u8, default: []const u8) []const u8 {
    const v = std.c.getenv(key.ptr) orelse return default;
    return std.mem.span(v);
}

test "live mysql: child-thread pool acquire + query + write (known issue #1 regression)" {
    // 门控: 未显式要求时跳过 (常规单测环境没有 MySQL).
    if (std.c.getenv("ZETL_LIVE_MYSQL") == null) return error.SkipZigTest;

    const a = std.testing.allocator;
    const host = envOr("ZETL_LIVE_MYSQL_HOST", "127.0.0.1");
    const user = envOr("ZETL_LIVE_MYSQL_USER", "root");
    const pass = envOr("ZETL_LIVE_MYSQL_PASS", "");
    const db_name = envOr("ZETL_LIVE_MYSQL_DB", "zetl_live_test");
    const port_str = envOr("ZETL_LIVE_MYSQL_PORT", "3306");
    const port = std.fmt.parseInt(u16, port_str, 10) catch 3306;

    const cfg = zfinal.DBConfig{
        .db_type = .mysql,
        .host = host,
        .port = port,
        .database = db_name,
        .username = user,
        .password = pass,
    };

    // 已知问题 #1 的触发条件: pool 在主线程创建, 子线程 acquire.
    const pool = try zfinal.ConnectionPool.init(a, cfg, 2);
    defer pool.deinit();

    const Worker = struct {
        fn run(p: *zfinal.ConnectionPool, wid: u64) !void {
            const conn = try p.acquire();
            defer p.release(conn) catch {};
            // SELECT 1 — 只读路径
            var r = try conn.query("SELECT 1");
            defer r.deinit();
            try std.testing.expect(r.next());
            // INSERT — 写路径 (幂等 upsert, 便于重复运行)
            var buf: [128]u8 = undefined;
            const sql = try std.fmt.bufPrintSentinel(
                &buf,
                "INSERT INTO t_live (id, v) VALUES ({d}, 'worker-{d}') ON DUPLICATE KEY UPDATE v=VALUES(v)",
                .{ wid, wid },
                0,
            );
            try conn.exec(sql);
        }
    };

    var t1 = try std.Thread.spawn(.{}, Worker.run, .{ pool, @as(u64, 1) });
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{ pool, @as(u64, 2) });
    t1.join();
    t2.join();

    // 子线程写入结果可从主线程读到
    const conn = try pool.acquire();
    defer pool.release(conn) catch {};
    var r = try conn.query("SELECT COUNT(*) FROM t_live");
    defer r.deinit();
    try std.testing.expect(r.next());
    const cnt = (try r.currentRow().?.getInt(0)) orelse 0;
    try std.testing.expect(cnt >= 2);
}
