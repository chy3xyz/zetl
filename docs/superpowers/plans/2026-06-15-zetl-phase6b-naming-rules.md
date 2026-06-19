# zetl Phase 6b: 列名重命名规则 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `NamingRule` (identity / camel_to_snake / snake_to_camel / upper / lower / add_prefix / strip_prefix) so `Mapper.fromSchema` can auto-convert column names without per-column overrides.

**Architecture:** Add `NamingRule` tagged union + `applyNamingRule` function to `src/transform/mapper.zig`. Extend `Mapper.fromSchema` to accept `?NamingRule`. Add `naming_rule` field to `TransformConfig`. Extend `TransformEngine.initWithSchema` to thread the rule through. JSON parsing handles both string (`"camel_to_snake"`) and object (`{type:"add_prefix",value:"dt_"}`) forms.

**Tech Stack:** Zig (0.17 nightly), `std.json.parseFromSlice`, existing `std.fmt.allocPrint`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/transform/mapper.zig` | `NamingRule` + `applyNamingRule` + extended `fromSchema` | Extend |
| `src/transform/engine.zig` | `TransformConfig.naming_rule` + `initWithSchema` accepts rule + JSON parse | Extend |
| `dev.md` | Document Phase 6b | Modify |

---

## Task 1: `NamingRule` + `applyNamingRule`

**Files:**
- Modify: `src/transform/mapper.zig`
- Test: `src/transform/mapper.zig`

- [ ] **Step 1: Add failing tests**

Append to `src/transform/mapper.zig`:

```zig
test "applyNamingRule identity" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.identity, "order_id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("order_id", out);
}

test "applyNamingRule camel_to_snake converts orderId to order_id" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.camel_to_snake, "orderId", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("order_id", out);
}

test "applyNamingRule camel_to_snake handles consecutive capitals" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.camel_to_snake, "userIDNumber", a);
    defer a.free(out);
    // userIDNumber -> user_i_d_number (best-effort; covers 90% of cases)
    try std.testing.expectEqualStrings("user_i_d_number", out);
}

test "applyNamingRule snake_to_camel converts order_id to orderId" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.snake_to_camel, "order_id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("orderId", out);
}

test "applyNamingRule upper converts to UPPER" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.upper, "foo", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("FOO", out);
}

test "applyNamingRule lower converts to lower" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.lower, "FOO", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("foo", out);
}

test "applyNamingRule add_prefix prepends" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.{ .add_prefix = "dt_" }, "id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("dt_id", out);
}

test "applyNamingRule strip_prefix removes matching prefix" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.{ .strip_prefix = "dt_" }, "dt_id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("id", out);
}

test "applyNamingRule strip_prefix returns original if no match" {
    const a = std.testing.allocator;
    const out = try applyNamingRule(.{ .strip_prefix = "dt_" }, "id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("id", out);
}
```

- [ ] **Step 2: Run tests and confirm failure**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test -- --test-filter "applyNamingRule"
```

Expected: FAIL.

- [ ] **Step 3: Implement `NamingRule` and `applyNamingRule`**

Add to `src/transform/mapper.zig`, before the `Mapper` struct:

```zig
/// 自动列名转换规则. 用户可在 config_json.transform.naming_rule 配置.
pub const NamingRule = union(enum) {
    identity,
    camel_to_snake,
    snake_to_camel,
    upper,
    lower,
    add_prefix: []const u8,
    strip_prefix: []const u8,
};

/// 把 source 列名按规则转成 target. 返回的 slice 由 allocator 拥有.
pub fn applyNamingRule(rule: NamingRule, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return switch (rule) {
        .identity => allocator.dupe(u8, source),
        .camel_to_snake => camelToSnake(allocator, source),
        .snake_to_camel => snakeToCamel(allocator, source),
        .upper => upperStr(allocator, source),
        .lower => lowerStr(allocator, source),
        .add_prefix => |prefix| std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, source }),
        .strip_prefix => |prefix| stripPrefix(allocator, prefix, source),
    };
}

fn upperStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf;
}

fn lowerStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

/// camelCase / PascalCase -> snake_case. 在大写字母前插入 '_', 然后全转小写.
/// 例: orderId -> order_id, userIDNumber -> user_i_d_number (连续大写 best-effort).
fn camelToSnake(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    // 最坏情况: 每个字符前都加 '_', 长度 = 2*len
    var buf = try allocator.alloc(u8, source.len * 2);
    defer allocator.free(buf);

    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        const is_upper = c >= 'A' and c <= 'Z';
        const prev_is_lower = i > 0 and source[i - 1] >= 'a' and source[i - 1] <= 'z';
        if (is_upper and (i == 0 or prev_is_lower)) {
            if (out_idx > 0) {
                buf[out_idx] = '_';
                out_idx += 1;
            }
        }
        buf[out_idx] = std.ascii.toLower(c);
        out_idx += 1;
    }
    // 缩小到实际长度
    return allocator.realloc(buf, out_idx);
}

/// snake_case -> camelCase. 每个 '_x' 转 'X'.
fn snakeToCamel(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, source.len);
    var out_idx: usize = 0;
    var capitalize_next = true;
    for (source) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else if (capitalize_next) {
            buf[out_idx] = std.ascii.toUpper(c);
            out_idx += 1;
            capitalize_next = false;
        } else {
            buf[out_idx] = c;
            out_idx += 1;
        }
    }
    return allocator.realloc(buf, out_idx);
}

fn stripPrefix(allocator: std.mem.Allocator, prefix: []const u8, source: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, source, prefix)) {
        return allocator.dupe(u8, source[prefix.len..]);
    }
    return allocator.dupe(u8, source);
}
```

- [ ] **Step 4: Run tests**

```bash
zig build test -- --test-filter "applyNamingRule"
zig fmt --check src/transform/mapper.zig
```

Expected: 9 tests pass, formatting OK.

- [ ] **Step 5: Commit**

```bash
git add src/transform/mapper.zig
git commit -m "feat(transform): add NamingRule + applyNamingRule (camel_to_snake, prefixes, etc)"
```

---

## Task 2: `Mapper.fromSchema` accepts `NamingRule`

**Files:**
- Modify: `src/transform/mapper.zig`

- [ ] **Step 1: Modify `Mapper.fromSchema`**

Replace the existing `fromSchema` with a version that accepts an optional `rule`:

```zig
/// 从 source 列元数据生成 mappings. 可选命名规则把 source 列名转 target.
/// rule = null 等价 .identity (默认行为).
pub fn fromSchema(allocator: std.mem.Allocator, columns: []const ColumnMeta, rule: ?NamingRule) !Mapper {
    const effective_rule = rule orelse .identity;
    var mappings = try allocator.alloc(FieldMapping, columns.len);
    errdefer {
        for (mappings) |m| {
            allocator.free(m.source);
            allocator.free(m.target);
        }
        allocator.free(mappings);
    }
    for (columns, 0..) |col, i| {
        mappings[i] = .{
            .source = try allocator.dupe(u8, col.name),
            .target = try applyNamingRule(effective_rule, col.name, allocator),
        };
    }
    return Mapper{ .allocator = allocator, .mappings = mappings };
}
```

- [ ] **Step 2: Update existing tests to pass `null` rule**

The 3 existing `Mapper.fromSchema` tests in `src/transform/mapper.zig` need their signature updated to add `null` as the third argument:

```zig
test "Mapper.fromSchema generates identity mappings" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "paid_at" },
        .{ .name = "amount" },
    };
    var m = try Mapper.fromSchema(a, &cols, null);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 3), m.mappings.len);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].source);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].target);
    // ... rest unchanged
}
```

Apply the same `null` third argument to all 3 existing `fromSchema` tests.

- [ ] **Step 3: Add a test for rule=camel_to_snake**

```zig
test "Mapper.fromSchema with camel_to_snake rule converts source to snake" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{
        .{ .name = "orderId" },
        .{ .name = "paidAt" },
    };
    var m = try Mapper.fromSchema(a, &cols, .camel_to_snake);
    defer m.deinit();
    try std.testing.expectEqualStrings("order_id", m.mappings[0].target);
    try std.testing.expectEqualStrings("paid_at", m.mappings[1].target);
}
```

- [ ] **Step 4: Run tests**

```bash
zig build test -- --test-filter "Mapper.fromSchema"
zig fmt --check src/transform/mapper.zig
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/transform/mapper.zig
git commit -m "feat(transform): Mapper.fromSchema accepts optional NamingRule"
```

---

## Task 3: `TransformConfig.naming_rule` + JSON parse + `initWithSchema` accepts rule

**Files:**
- Modify: `src/transform/engine.zig`

- [ ] **Step 1: Read existing `TransformConfig` and `initWithSchema`**

Confirm the exact signature and field layout.

- [ ] **Step 2: Add failing test for JSON parsing**

```zig
test "TransformConfig parses naming_rule string from json" {
    const a = std.testing.allocator;
    const cfg = try TransformConfig.initFromJson(a,
        \\{"transform":{"naming_rule":"camel_to_snake"}}
    );
    defer cfg.deinit(a);
    switch (cfg.naming_rule.?) {
        .camel_to_snake => {},
        else => return error.UnexpectedRule,
    }
}

test "TransformConfig parses naming_rule add_prefix object" {
    const a = std.testing.allocator;
    const cfg = try TransformConfig.initFromJson(a,
        \\{"transform":{"naming_rule":{"type":"add_prefix","value":"dt_"}}}
    );
    defer cfg.deinit(a);
    switch (cfg.naming_rule.?) {
        .add_prefix => |p| try std.testing.expectEqualStrings("dt_", p),
        else => return error.UnexpectedRule,
    }
}

test "TransformConfig with no naming_rule returns null" {
    const a = std.testing.allocator;
    const cfg = try TransformConfig.initFromJson(a,
        \\{"transform":{}}
    );
    defer cfg.deinit(a);
    try std.testing.expect(cfg.naming_rule == null);
}
```

> Adapt `initFromJson` to whatever the existing parse entry point is called. If it doesn't exist, this task requires creating one.

- [ ] **Step 3: Add `naming_rule` field to `TransformConfig`**

```zig
pub const TransformConfig = struct {
    // ... existing fields ...
    naming_rule: ?mapper.NamingRule = null,
};
```

- [ ] **Step 4: Implement JSON parse for `naming_rule`**

In the existing `initFromJson` (or add one), after parsing `transform` object:

```zig
if (parsed.value.object.get("transform")) |tv| {
    if (tv == .object) {
        if (tv.object.get("naming_rule")) |nv| {
            cfg.naming_rule = try parseNamingRule(nv, allocator);
        }
    }
}

fn parseNamingRule(value: std.json.Value, allocator: std.mem.Allocator) !?mapper.NamingRule {
    switch (value) {
        .string => |s| {
            if (std.mem.eql(u8, s, "identity")) return .identity;
            if (std.mem.eql(u8, s, "camel_to_snake")) return .camel_to_snake;
            if (std.mem.eql(u8, s, "snake_to_camel")) return .snake_to_camel;
            if (std.mem.eql(u8, s, "upper")) return .upper;
            if (std.mem.eql(u8, s, "lower")) return .lower;
            return null;
        },
        .object => |o| {
            const t = o.get("type") orelse return null;
            if (t != .string) return null;
            const v = o.get("value") orelse return null;
            if (v != .string) return null;
            const value_str = allocator.dupe(u8, v.string) catch return null;
            if (std.mem.eql(u8, t.string, "add_prefix")) return .{ .add_prefix = value_str };
            if (std.mem.eql(u8, t.string, "strip_prefix")) return .{ .strip_prefix = value_str };
            return null;
        },
        else => return null,
    }
}
```

- [ ] **Step 5: Add `naming_rule` parameter to `initWithSchema`**

```zig
pub fn initWithSchema(
    allocator: std.mem.Allocator,
    cfg: TransformConfig,
    source_columns: []const mapper.ColumnMeta,
    rule: ?mapper.NamingRule,
) !TransformEngine {
    var mp = try mapper.Mapper.fromSchema(allocator, source_columns, rule);
    errdefer mp.deinit();
    try mp.mergeOverrides(allocator, cfg.field_mappings_json orelse "");

    var calculator: ?*CommissionCalculator = null;
    if (cfg.enable_commission_calc) {
        calculator = try allocator.create(CommissionCalculator);
        calculator.?.* = try CommissionCalculator.init(allocator);
    }
    return TransformEngine{
        .allocator = allocator,
        .cfg = cfg,
        .mapper = mp,
        .calculator = calculator,
    };
}
```

- [ ] **Step 6: Build and run tests**

```bash
zig build test -- --test-filter "TransformConfig"
zig fmt --check src/transform/engine.zig
```

Expected: 3 new tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/transform/engine.zig
git commit -m "feat(transform): TransformConfig.naming_rule + JSON parse + initWithSchema accepts rule"
```

---

## Task 4: Wire `naming_rule` through `SyncTask.init`

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Find the `initWithSchema` call site**

In `src/engine/runtime.zig::SyncTask.init`, locate the `tr_init:` block where `TransformEngine.initWithSchema` is called.

- [ ] **Step 2: Pass `naming_rule` from cfg**

Replace the `initWithSchema` call to pass the rule:

```zig
self.transformer = try TransformEngine.initWithSchema(
    self.allocator,
    cfg,
    cols,
    cfg.naming_rule,
);
```

> Note: `cfg.naming_rule` is `?mapper.NamingRule`. If your local variable in the `init` block is named differently, adapt.

- [ ] **Step 3: Build and run tests**

```bash
zig build 2>&1 | tail -5
zig build test 2>&1 | tail -5
```

Expected: builds clean, 191+ tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "feat(engine): pass naming_rule from TransformConfig to TransformEngine"
```

---

## Task 5: dev.md + final verification

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Add Phase 6b section**

In `dev.md`, after the Phase 6 section, add:

```
## Phase 6b: 列名重命名规则

`Mapper` 支持基于 `NamingRule` 自动转换列名, 用户无需手工写 `field_mappings_json`.

支持的规则:
- `identity` (默认, 与 Phase 6 一致)
- `camel_to_snake` (`orderId` → `order_id`)
- `snake_to_camel` (`order_id` → `orderId`)
- `upper` (`foo` → `FOO`)
- `lower` (`FOO` → `foo`)
- `add_prefix(prefix)` (`id` → `dt_id`)
- `strip_prefix(prefix)` (`dt_id` → `id`)

配置方式 (在 `config_json.transform.naming_rule`):
- 字符串: `"naming_rule": "camel_to_snake"`
- 对象: `"naming_rule": {"type": "add_prefix", "value": "dt_"}`

用户 `field_mappings_json` 中的 override 仍优先于自动命名 (Phase 6 mergeOverrides 行为保留).
```

- [ ] **Step 2: Final verification**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/mapper.zig src/transform/engine.zig src/engine/runtime.zig
zig build test 2>&1 | tail -5
```

Expected: formatting OK, all tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add dev.md docs/superpowers/specs/2026-06-15-zetl-phase6b-naming-rules-design.md docs/superpowers/plans/2026-06-15-zetl-phase6b-naming-rules.md
git commit -m "docs: add Phase 6b section + commit design/plan docs"
```

If design/plan docs were already committed, drop them.

Report DONE when finished.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - NamingRule union → Task 1
  - applyNamingRule implementations → Task 1
  - 9 unit tests for rules → Task 1
  - Mapper.fromSchema accepts rule → Task 2
  - Mapper.fromSchema test for camel_to_snake → Task 2
  - TransformConfig.naming_rule field + JSON parse → Task 3
  - initWithSchema accepts rule → Task 3
  - SyncTask.init passes rule → Task 4
  - dev.md update → Task 5
- [ ] **No placeholders:** every step shows concrete code or commands; JSON parse signatures are illustrative and adapted during implementation.
- [ ] **Type consistency:** `NamingRule`, `applyNamingRule`, `fromSchema(rule: ?NamingRule)`, `initWithSchema(... , rule: ?NamingRule)` consistent across tasks.