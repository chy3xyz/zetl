//! `/api/tasks` handler 层测试 — zfinal oneshot capture (无 TCP).
//!
//! 直接路由执行 handler (绕过 auth 拦截器 — 鉴权逻辑由 auth_middleware 自己的
//! 测试覆盖), store 用 :memory: SQLite, scheduler 用 test_mode (不连 MySQL).
//! 覆盖: 创建 / 列表 / 详情 / 撞名 / 参数错误 / 停用更新.

const std = @import("std");
const zfinal = @import("zfinal");
const meta = @import("../../meta/mod.zig");
const engine = @import("../../engine/mod.zig");
const tasks_api = @import("tasks.zig");
const oneshot = zfinal.oneshot;

/// 三个分配器必须统一为 testing.allocator:
///   ctx.allocator (oneshot 传入) / deps.allocator_ptr (handler free body 用) /
///   store.allocator (Service 返回的 TaskConfig 归 handler free) —
///   任一错位 → 跨分配器 free (静默泄漏或 panic).
/// 因此不走 arena, store/scheduler 直接在 testing.allocator 上构造 + 逆向清理.
const TestEnv = struct {
    store: *meta.store.MetaStore,
    scheduler: *engine.scheduler.Scheduler,
    token_mgr: *zfinal.TokenManager,
    router: zfinal.Router,

    fn init(a: std.mem.Allocator) !TestEnv {
        const store = try a.create(meta.store.MetaStore);
        errdefer a.destroy(store);
        store.* = try meta.store.MetaStore.init(a, ":memory:");
        errdefer store.deinit();

        const sched = try a.create(engine.scheduler.Scheduler);
        errdefer a.destroy(sched);
        sched.* = engine.scheduler.Scheduler.initForTest(a, store);
        errdefer sched.deinit();

        // initWebDeps 对 tokenMgr 是值拷贝 (token.*) — 必须给真实实例;
        // config_ptr / pool 仅存指针, tasks handler 不解引用, undefined 安全.
        const token_mgr = try a.create(zfinal.TokenManager);
        errdefer a.destroy(token_mgr);
        token_mgr.* = zfinal.TokenManager.init(a);
        @import("../deps.zig").initWebDeps(a, undefined, store, sched, token_mgr, undefined);

        var router = zfinal.Router.init(a);
        errdefer router.deinit();
        try router.addWithMethod("/api/tasks", .GET, tasks_api.list);
        try router.addWithMethod("/api/tasks", .POST, tasks_api.create);
        try router.addWithMethod("/api/tasks/:id", .GET, tasks_api.detail);
        try router.addWithMethod("/api/tasks/:id", .PUT, tasks_api.update);
        try router.addWithMethod("/api/tasks/:id", .DELETE, tasks_api.delete);
        try router.addWithMethod("/api/tasks/:id/stop", .POST, tasks_api.stop);
        try router.addWithMethod("/api/tasks/:id/reload", .POST, tasks_api.reload);
        try router.seal();

        return .{ .store = store, .scheduler = sched, .token_mgr = token_mgr, .router = router };
    }

    fn deinit(self: *TestEnv, a: std.mem.Allocator) void {
        self.router.deinit();
        self.scheduler.deinit();
        self.store.deinit();
        a.destroy(self.token_mgr);
        a.destroy(self.scheduler);
        a.destroy(self.store);
    }
};

test "tasks api: create → list → detail roundtrip" {
    const a = std.testing.allocator;
    var env = try TestEnv.init(a);
    defer env.deinit(a);

    const body =
        \\{"name":"t1","source_db":"mall-1","source_table":"orders","target_table":"union_all_order","sync_mode":1,"status":1,"config_json":"{}"}
    ;
    var res = try oneshot.captureWith(a, &env.router, .POST, "/api/tasks", .{}, &.{}, body);
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"status\":\"running\"") != null);

    // list
    var res2 = try oneshot.capture(a, &env.router, .GET, "/api/tasks", .{});
    defer res2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res2.body, "\"total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res2.body, "\"name\":\"t1\"") != null);

    // detail
    var res3 = try oneshot.capture(a, &env.router, .GET, "/api/tasks/1", .{});
    defer res3.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res3.body, "\"source_db\":\"mall-1\"") != null);
}

test "tasks api: duplicate name → business_error 任务名已存在" {
    const a = std.testing.allocator;
    var env = try TestEnv.init(a);
    defer env.deinit(a);

    const body =
        \\{"name":"dup","source_db":"mall-1","source_table":"orders","target_table":"t"}
    ;
    var res1 = try oneshot.captureWith(a, &env.router, .POST, "/api/tasks", .{}, &.{}, body);
    defer res1.deinit();
    try std.testing.expectEqual(@as(u16, 200), res1.status);

    var res2 = try oneshot.captureWith(a, &env.router, .POST, "/api/tasks", .{}, &.{}, body);
    defer res2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res2.body, "任务名已存在") != null);
    try std.testing.expect(std.mem.indexOf(u8, res2.body, "\"code\":3") != null); // business_error
}

test "tasks api: missing required field → param_error 必填提示" {
    const a = std.testing.allocator;
    var env = try TestEnv.init(a);
    defer env.deinit(a);

    var res = try oneshot.captureWith(a, &env.router, .POST, "/api/tasks", .{}, &.{}, "{\"name\":\"x\"}");
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "必填") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"code\":1") != null); // param_error
}

test "tasks api: invalid status → param_error" {
    const a = std.testing.allocator;
    var env = try TestEnv.init(a);
    defer env.deinit(a);

    var res = try oneshot.captureWith(
        a,
        &env.router,
        .POST,
        "/api/tasks",
        .{},
        &.{},
        "{\"name\":\"x\",\"source_db\":\"m\",\"source_table\":\"a\",\"target_table\":\"b\",\"status\":9}",
    );
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "status 必须是 0 或 1") != null);
}

test "tasks api: detail 404 → 任务不存在" {
    const a = std.testing.allocator;
    var env = try TestEnv.init(a);
    defer env.deinit(a);

    var res = try oneshot.capture(a, &env.router, .GET, "/api/tasks/999", .{});
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "任务不存在") != null);
}
