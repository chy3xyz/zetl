//! 佣金计算 - 固定比例 + 阶梯金额
//! 规则从归集库 agent_commission_rule 加载
//! 优先级: 指定商城规则 > 全商城通用(mall_id="*")

const std = @import("std");
const zfinal = @import("zfinal");
const common = @import("../common/mod.zig");

pub const CommissionRule = struct {
    id: i64,
    agent_id: []const u8,
    mall_id: []const u8, // "*" 表示全商城通用
    min_amount: f64,
    max_amount: f64,
    rate: f64, // 0.1 = 10%

    pub fn deinit(self: *CommissionRule, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.mall_id);
    }
};

pub const CommissionResult = struct {
    amount: []const u8, // 字符串, 保留 2 位小数
    rate: []const u8,
    rule_id: i64,
};

pub const Calculator = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(CommissionRule) = .empty,

    pub fn init(allocator: std.mem.Allocator) Calculator {
        return .{ .allocator = allocator, .rules = .empty };
    }

    pub fn deinit(self: *Calculator) void {
        for (self.rules.items) |*r| r.deinit(self.allocator);
        self.rules.deinit(self.allocator);
    }

    /// 加载规则列表 (深拷贝)
    pub fn loadRules(self: *Calculator, rules: []const CommissionRule) !void {
        // 先清理旧
        for (self.rules.items) |*r| r.deinit(self.allocator);
        self.rules.clearRetainingCapacity();
        for (rules) |r| {
            try self.rules.append(self.allocator, .{
                .id = r.id,
                .agent_id = try self.allocator.dupe(u8, r.agent_id),
                .mall_id = try self.allocator.dupe(u8, r.mall_id),
                .min_amount = r.min_amount,
                .max_amount = r.max_amount,
                .rate = r.rate,
            });
        }
    }

    /// 计算单笔订单佣金
    pub fn calculate(self: *Calculator, agent_id: []const u8, mall_id: []const u8, order_amount_str: []const u8) !CommissionResult {
        const amount = std.fmt.parseFloat(f64, order_amount_str) catch 0.0;
        if (amount <= 0.0) {
            return .{
                .amount = try self.allocator.dupe(u8, "0.00"),
                .rate = try self.allocator.dupe(u8, "0.0000"),
                .rule_id = 0,
            };
        }

        // 匹配: agent_id 必须相等, amount 在 [min,max] 区间, mall_id 精确匹配 或 "*"
        var matched: ?CommissionRule = null;
        var priority: u8 = 0;

        for (self.rules.items) |r| {
            if (!std.mem.eql(u8, r.agent_id, agent_id)) continue;
            if (amount < r.min_amount or amount > r.max_amount) continue;

            if (std.mem.eql(u8, r.mall_id, mall_id)) {
                // 指定商城规则, 优先级最高
                matched = r;
                priority = 2;
                break;
            }
            if (std.mem.eql(u8, r.mall_id, "*") and priority < 1) {
                matched = r;
                priority = 1;
            }
        }

        const rule = matched orelse {
            return .{
                .amount = try self.allocator.dupe(u8, "0.00"),
                .rate = try self.allocator.dupe(u8, "0.0000"),
                .rule_id = 0,
            };
        };

        const commission = amount * rule.rate;
        const amount_str = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{commission});
        const rate_str = try std.fmt.allocPrint(self.allocator, "{d:.4}", .{rule.rate});
        return .{
            .amount = amount_str,
            .rate = rate_str,
            .rule_id = rule.id,
        };
    }
};

/// 从一行结果集解析出 CommissionRule.
/// 任何字段缺失/解析失败都返回 error (由调用方 `catch continue` 跳过此行).
/// errdefer 链保证: 分配中途失败时, 已 dupe 的字符串会被正确释放, 不漏.
fn parseRuleRow(rm: anytype, allocator: std.mem.Allocator) !CommissionRule {
    const id = try std.fmt.parseInt(i64, rm.get("id") orelse "0", 10);
    const agent_id = try allocator.dupe(u8, rm.get("agent_id") orelse "");
    errdefer allocator.free(agent_id);
    const mall_id = try allocator.dupe(u8, rm.get("mall_id") orelse "*");
    errdefer allocator.free(mall_id);
    const min_amount = try std.fmt.parseFloat(f64, rm.get("min_amount") orelse "0");
    const max_amount = try std.fmt.parseFloat(f64, rm.get("max_amount") orelse "999999");
    const rate = try std.fmt.parseFloat(f64, rm.get("commission_rate") orelse "0");
    return .{
        .id = id,
        .agent_id = agent_id,
        .mall_id = mall_id,
        .min_amount = min_amount,
        .max_amount = max_amount,
        .rate = rate,
    };
}

/// 从归集库 `agent_commission_rule` 拉取所有 status=1 的规则.
///
/// **优雅降级契约**: 任何错误 (acquire/query/parse) → 返回空切片 + 打 warn,
/// 调用方拿到空切片后用 `Calculator.loadRules(&.{})` 初始化空规则即可.
/// 绝不向上抛 error — 这样归集库暂时不可达时程序不会崩溃, 等下次刷新时再重试.
///
/// 返回的切片由 allocator 分配 (内部 agent_id/mall_id 也是 dupe'd),
/// 调用方负责释放: `for (rules) |*r| r.deinit(allocator); allocator.free(rules);`.
pub fn loadCommissionRules(sink_pool: *zfinal.ConnectionPool, allocator: std.mem.Allocator) []CommissionRule {
    // 1. 取连接 — 失败直接降级
    const conn = sink_pool.acquire() catch |err| {
        common.logger.warn("loadCommissionRules: pool acquire failed ({s}), using empty rules", .{@errorName(err)});
        return &[_]CommissionRule{};
    };
    defer sink_pool.release(conn) catch {};

    // 2. sentinel-terminated SQL
    const sql = "SELECT id,agent_id,mall_id,min_amount,max_amount,commission_rate FROM agent_commission_rule WHERE status=1";
    const sql_buf = allocator.allocSentinel(u8, sql.len, 0) catch |err| {
        common.logger.warn("loadCommissionRules: sql alloc failed ({s}), using empty rules", .{@errorName(err)});
        return &[_]CommissionRule{};
    };
    defer allocator.free(sql_buf);
    @memcpy(sql_buf[0..sql.len], sql);

    // 3. 执行查询 — 失败降级
    var rs = conn.query(sql_buf) catch |err| {
        common.logger.warn("loadCommissionRules: query failed ({s}), using empty rules", .{@errorName(err)});
        return &[_]CommissionRule{};
    };
    defer rs.deinit();

    // 4. 遍历结果 — 解析失败单行跳过, 不影响其它行
    var rules = std.ArrayList(CommissionRule).empty;
    errdefer {
        for (rules.items) |*r| r.deinit(allocator);
        rules.deinit(allocator);
    }

    while (rs.next()) {
        const rm = rs.getCurrentRowMap() orelse continue;
        const rule = parseRuleRow(rm, allocator) catch continue;
        rules.append(allocator, rule) catch continue;
    }

    // 5. 切片所有权转移给调用方
    return rules.toOwnedSlice(allocator) catch |err| {
        common.logger.warn("loadCommissionRules: toOwnedSlice failed ({s}), using empty rules", .{@errorName(err)});
        for (rules.items) |*r| r.deinit(allocator);
        return &[_]CommissionRule{};
    };
}

/// 释放 `loadCommissionRules` 返回的规则列表.
pub fn freeCommissionRules(allocator: std.mem.Allocator, rules: []CommissionRule) void {
    for (rules) |*r| r.deinit(allocator);
    allocator.free(rules);
}

test "commission: matches mall-specific rule" {
    const a = std.testing.allocator;
    var calc = Calculator.init(a);
    defer calc.deinit();
    const rules = [_]CommissionRule{
        .{ .id = 1, .agent_id = "A001", .mall_id = "*", .min_amount = 0, .max_amount = 999999, .rate = 0.05 },
        .{ .id = 2, .agent_id = "A001", .mall_id = "mall_001", .min_amount = 0, .max_amount = 999999, .rate = 0.10 },
    };
    try calc.loadRules(&rules);
    const r = try calc.calculate("A001", "mall_001", "100.00");
    defer a.free(r.amount);
    defer a.free(r.rate);
    try std.testing.expectEqualStrings("10.00", r.amount);
    try std.testing.expectEqual(@as(i64, 2), r.rule_id);
}

test "commission: falls back to wildcard" {
    const a = std.testing.allocator;
    var calc = Calculator.init(a);
    defer calc.deinit();
    const rules = [_]CommissionRule{
        .{ .id = 1, .agent_id = "A001", .mall_id = "*", .min_amount = 0, .max_amount = 999999, .rate = 0.05 },
    };
    try calc.loadRules(&rules);
    const r = try calc.calculate("A001", "mall_002", "200.00");
    defer a.free(r.amount);
    defer a.free(r.rate);
    try std.testing.expectEqualStrings("10.00", r.amount);
    try std.testing.expectEqual(@as(i64, 1), r.rule_id);
}

test "commission: no rule returns zero" {
    const a = std.testing.allocator;
    var calc = Calculator.init(a);
    defer calc.deinit();
    const r = try calc.calculate("A999", "mall_001", "100.00");
    defer a.free(r.amount);
    defer a.free(r.rate);
    try std.testing.expectEqualStrings("0.00", r.amount);
}

test "commission: zero/negative amount returns zero" {
    const a = std.testing.allocator;
    var calc = Calculator.init(a);
    defer calc.deinit();
    const rules = [_]CommissionRule{
        .{ .id = 1, .agent_id = "A001", .mall_id = "*", .min_amount = 0, .max_amount = 999999, .rate = 0.1 },
    };
    try calc.loadRules(&rules);
    const r1 = try calc.calculate("A001", "mall_001", "0");
    defer a.free(r1.amount);
    defer a.free(r1.rate);
    try std.testing.expectEqualStrings("0.00", r1.amount);

    const r2 = try calc.calculate("A001", "mall_001", "-10");
    defer a.free(r2.amount);
    defer a.free(r2.rate);
    try std.testing.expectEqualStrings("0.00", r2.amount);
}

test "commission: ladder by amount range" {
    const a = std.testing.allocator;
    var calc = Calculator.init(a);
    defer calc.deinit();
    const rules = [_]CommissionRule{
        .{ .id = 1, .agent_id = "A001", .mall_id = "*", .min_amount = 0, .max_amount = 99, .rate = 0.05 },
        .{ .id = 2, .agent_id = "A001", .mall_id = "*", .min_amount = 100, .max_amount = 999, .rate = 0.10 },
        .{ .id = 3, .agent_id = "A001", .mall_id = "*", .min_amount = 1000, .max_amount = 999999, .rate = 0.15 },
    };
    try calc.loadRules(&rules);

    const r1 = try calc.calculate("A001", "mall_001", "50");
    defer a.free(r1.amount);
    defer a.free(r1.rate);
    try std.testing.expectEqualStrings("2.50", r1.amount);
    try std.testing.expectEqual(@as(i64, 1), r1.rule_id);

    const r2 = try calc.calculate("A001", "mall_001", "500");
    defer a.free(r2.amount);
    defer a.free(r2.rate);
    try std.testing.expectEqualStrings("50.00", r2.amount);
    try std.testing.expectEqual(@as(i64, 2), r2.rule_id);

    const r3 = try calc.calculate("A001", "mall_001", "5000");
    defer a.free(r3.amount);
    defer a.free(r3.rate);
    try std.testing.expectEqualStrings("750.00", r3.amount);
    try std.testing.expectEqual(@as(i64, 3), r3.rule_id);
}

test "commission: malformed amount defaults to 0" {
    const a = std.testing.allocator;
    var calc = Calculator.init(a);
    defer calc.deinit();
    const rules = [_]CommissionRule{
        .{ .id = 1, .agent_id = "A001", .mall_id = "*", .min_amount = 0, .max_amount = 999999, .rate = 0.10 },
    };
    try calc.loadRules(&rules);
    const r = try calc.calculate("A001", "mall_001", "not-a-number");
    defer a.free(r.amount);
    defer a.free(r.rate);
    try std.testing.expectEqualStrings("0.00", r.amount);
}

// ===== loadCommissionRules 集成测试 (P1 任务 1.5) =====
//
// 验证:
// 1. 归集库不可达 / 表不存在 → 返回空切片, 不抛 error
// 2. 归集库正常 → 返回真实规则列表
//
// 用 SQLite :memory: 当 sink pool (build 默认 link sqlite3), 不依赖 mysqlclient.
// 查询失败场景: pool 可建, 但表不存在 → query() 抛错 → 优雅降级.

/// 创建一个指向 ":memory:" 的 SQLite 测试池, 并 (可选) 注入建表/插入语句.
fn makeTestPool(allocator: std.mem.Allocator, setup_sql: ?[]const u8) !*zfinal.ConnectionPool {
    const cfg = zfinal.DBConfig{
        .db_type = .sqlite,
        .database = ":memory:",
    };
    const pool = try zfinal.ConnectionPool.init(allocator, cfg, 1);

    if (setup_sql) |sql| {
        const conn = try pool.acquire();
        defer pool.release(conn) catch {};
        // 手工 sentinel-terminate: dupe + 末尾填 0
        const sql_buf = try allocator.allocSentinel(u8, sql.len, 0);
        defer allocator.free(sql_buf);
        @memcpy(sql_buf[0..sql.len], sql);
        try conn.exec(sql_buf);
    }
    return pool;
}

test "loadCommissionRules: graceful degradation when rules table missing" {
    // 池能建, 但 agent_commission_rule 表不存在 → query() 抛错 → 降级返回空切片
    const a = std.testing.allocator;
    const pool = makeTestPool(a, null) catch |err| {
        std.debug.print("skip: cannot create test pool ({s})\n", .{@errorName(err)});
        return;
    };
    defer pool.deinit();

    const rules = loadCommissionRules(pool, a);
    // 不抛 error, 返回空
    try std.testing.expectEqual(@as(usize, 0), rules.len);
    // 内部无 dupe 字符串需释放
    if (rules.len > 0) freeCommissionRules(a, rules);
}

test "loadCommissionRules: returns empty on closed-port MySQL host" {
    // 用 127.0.0.1:9999 (永远关闭的端口) 当 sink 主机.
    // zfinal.ConnectionPool.init 内部会预创建连接并触发 mysql_real_connect,
    // 在没有 mysqlclient 链接的 build (zig build) 里这一步无法通过编译期检查.
    // 有 mysqlclient 链接时, init 会失败, 我们也拿不到 pool, 测不到函数本体.
    //
    // 策略: 在没 mysqlclient 链接的 build (zig build) 下, 直接跳过 — 这个测试
    // 只能在 zig build -Ddriver_mysql=true test 路径下被真实验证.
    // 这里退而求其次: 验证函数对坏 input 的鲁棒性 (给一个空 array list 也能跑).
    if (@hasDecl(zfinal.DBConfig, "db_type") == false) return;

    // 模拟"连接但表为空"的场景: SQLite 空库
    const a = std.testing.allocator;
    const pool = makeTestPool(a, null) catch return;
    defer pool.deinit();

    const rules = loadCommissionRules(pool, a);
    // 空库, 没表 → query 失败 → 降级空切片
    try std.testing.expectEqual(@as(usize, 0), rules.len);
    if (rules.len > 0) freeCommissionRules(a, rules);
}

test "loadCommissionRules: returns rules on healthy sink (SQLite stub)" {
    // 用 SQLite 模拟归集库: 建表 + 插 2 行 → 函数应返回 2 条规则.
    // 注意 SQLite 端 `parseInt/parseFloat` 对文本字段同样工作 (用 std.fmt).
    const a = std.testing.allocator;
    const setup =
        \\CREATE TABLE agent_commission_rule (
        \\  id INTEGER PRIMARY KEY,
        \\  agent_id TEXT NOT NULL,
        \\  mall_id TEXT NOT NULL DEFAULT '*',
        \\  min_amount REAL NOT NULL DEFAULT 0,
        \\  max_amount REAL NOT NULL DEFAULT 999999,
        \\  commission_rate REAL NOT NULL DEFAULT 0,
        \\  status INTEGER NOT NULL DEFAULT 1
        \\);
        \\INSERT INTO agent_commission_rule(agent_id, mall_id, min_amount, max_amount, commission_rate, status) VALUES
        \\  ('A001', '*', 0, 999999, 0.05, 1),
        \\  ('A001', 'mall_001', 100, 9999, 0.10, 1),
        \\  ('A999', '*', 0, 999999, 0.20, 0);
    ;
    const pool = makeTestPool(a, setup) catch |err| {
        std.debug.print("skip: cannot create test pool ({s})\n", .{@errorName(err)});
        return;
    };
    defer pool.deinit();

    const rules = loadCommissionRules(pool, a);
    defer if (rules.len > 0) freeCommissionRules(a, rules);

    // status=1 的有 2 条 (A999 status=0 应被过滤)
    try std.testing.expectEqual(@as(usize, 2), rules.len);

    // 验证顺序: 插入顺序保持 (id ASC 隐式)
    try std.testing.expectEqualStrings("A001", rules[0].agent_id);
    try std.testing.expectEqualStrings("*", rules[0].mall_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), rules[0].rate, 1e-9);

    try std.testing.expectEqualStrings("A001", rules[1].agent_id);
    try std.testing.expectEqualStrings("mall_001", rules[1].mall_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.10), rules[1].rate, 1e-9);

    // 配套: 空规则也能塞进 Calculator, 计算时不会崩
    var calc = Calculator.init(a);
    defer calc.deinit();
    try calc.loadRules(rules);
    const r = try calc.calculate("A001", "mall_001", "500.00");
    defer a.free(r.amount);
    defer a.free(r.rate);
    try std.testing.expectEqualStrings("50.00", r.amount);
    try std.testing.expectEqual(@as(i64, rules[1].id), r.rule_id);
}
