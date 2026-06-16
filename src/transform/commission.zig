//! 佣金计算 - 固定比例 + 阶梯金额
//! 规则从归集库 agent_commission_rule 加载
//! 优先级: 指定商城规则 > 全商城通用(mall_id="*")

const std = @import("std");

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
