# zetl Phase 6c: 正则替换 + 链式规则 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `NamingRule` with `regex_replace` (for `_tmp$` suffix stripping, prefix normalization, etc.) and add `applyNamingPipeline` so users can chain multiple rules like `camel_to_snake → regex_replace → add_prefix`.

**Architecture:** Add `regex_replace: RegexReplace` variant to `NamingRule` (pattern + replacement slices owned by allocator). Add `applyNamingPipeline(rules, source, allocator)` that chains rules. Change `Mapper.fromSchema` from `?NamingRule` to `[]const NamingRule` (empty = identity, single-rule convenience = `[rule]`). Update `TransformConfig` to keep `naming_rule: ?NamingRule` for backward compatibility but add `naming_rules: []const NamingRule` for pipeline. Update JSON parse to handle array form under `transform.naming_rules`.

**Tech Stack:** Zig (0.17 nightly), `std.Regex` for regex compilation + replace.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/transform/mapper.zig` | `RegexReplace` + `applyNamingPipeline` + new `fromSchema(rules: []NamingRule)` signature | Extend |
| `src/transform/engine.zig` | `TransformConfig.naming_rules` + JSON array parse + deinit regex slices | Extend |
| `src/engine/runtime.zig` | `RuntimeConfig.naming_rules` + pass to `initWithSchema` | Extend |
| `dev.md` | Document Phase 6c | Modify |

---

## Task 1: `RegexReplace` + `applyNamingPipeline`

**Files:**
- Modify: `src/transform/mapper.zig`
- Test: `src/transform/mapper.zig`

- [ ] **Step 1: Add failing tests**

Append to `src/transform/mapper.zig`:

```zig
test "applyNamingRule regex_replace strips _tmp suffix" {
    const a = std.testing.allocator;
    const rule: NamingRule = .{ .regex_replace = .{
        .pattern = "_tmp$",
        .replacement = "",
    } };
    const out = try applyNamingRule(rule, "order_tmp", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("order", out);
}

test "applyNamingRule regex_replace supports backref" {
    const a = std.testing.allocator;
    const rule: NamingRule = .{ .regex_replace = .{
        .pattern = "^(\\w+)_id$",
        .replacement = "$1_identifier",
    } };
    const out = try applyNamingRule(rule, "order_id", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("order_identifier", out);
}

test "applyNamingPipeline chains camel_to_snake then add_prefix" {
    const a = std.testing.allocator;
    const rules = [_]NamingRule{
        .camel_to_snake,
        .{ .add_prefix = "dt_" },
    };
    const out = try applyNamingPipeline(&rules, "orderId", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("dt_order_id", out);
}

test "applyNamingPipeline empty rules returns source copy" {
    const a = std.testing.allocator;
    const out = try applyNamingPipeline(&.{}, "orderId", a);
    defer a.free(out);
    try std.testing.expectEqualStrings("orderId", out);
}
```

- [ ] **Step 2: Run tests and confirm failure**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test -- --test-filter "applyNamingRule regex_replace"
```

Expected: FAIL.

- [ ] **Step 3: Implement `RegexReplace` and the new function**

Add `RegexReplace` struct and a `regex_replace` variant to the existing `NamingRule` union in `src/transform/mapper.zig`. Add a new `applyNamingPipeline` function:

```zig
pub const RegexReplace = struct {
    pattern: []const u8,     // allocator-owned
    replacement: []const u8, // allocator-owned (supports $1, $2 backrefs)
};

pub const NamingRule = union(enum) {
    identity,
    camel_to_snake,
    snake_to_camel,
    upper,
    lower,
    add_prefix: []const u8,
    strip_prefix: []const u8,
    regex_replace: RegexReplace,
};

fn regexReplace(allocator: std.mem.Allocator, source: []const u8, rr: RegexReplace) ![]const u8 {
    var regex = try std.Regex.compile(allocator, rr.pattern);
    defer regex.deinit();
    return regex.replace(allocator, source, rr.replacement);
}

pub fn applyNamingPipeline(rules: []const NamingRule, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);
    for (rules) |rule| {
        const next = try applyNamingRule(rule, current, allocator);
        allocator.free(current);
        current = next;
    }
    return current;
}
```

In the existing `applyNamingRule` switch, add the new branch:

```zig
.regex_replace => |rr| regexReplace(allocator, source, rr),
```

- [ ] **Step 4: Run tests**

```bash
zig build test -- --test-filter "applyNamingRule regex_replace"
zig test src/transform/mapper.zig
zig fmt --check src/transform/mapper.zig
```

Expected: 4 new tests pass, formatting OK.

- [ ] **Step 5: Commit**

```bash
git add src/transform/mapper.zig
git commit -m "feat(transform): add regex_replace variant + applyNamingPipeline"
```

---

## Task 2: `Mapper.fromSchema` accepts `[]const NamingRule`

**Files:**
- Modify: `src/transform/mapper.zig`

- [ ] **Step 1: Replace `fromSchema` signature**

Replace the existing `fromSchema` (3-arg) with a version that accepts `rules: []const NamingRule`. Empty rules = identity behavior (target = source). When rules are non-empty, run the pipeline per column.

```zig
pub fn fromSchema(
    allocator: std.mem.Allocator,
    columns: []const ColumnMeta,
    rules: []const NamingRule,
) !Mapper {
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
            .target = if (rules.len == 0)
                try allocator.dupe(u8, col.name)
            else
                try applyNamingPipeline(rules, col.name, allocator),
        };
    }
    return Mapper{ .allocator = allocator, .mappings = mappings };
}
```

- [ ] **Step 2: Update existing tests and `mergeOverrides` callers**

Find every call site of `Mapper.fromSchema` and change `null` / `.camel_to_snake` to either `&[_]NamingRule{}` (identity) or `&[_]NamingRule{.camel_to_snake}` (pipeline).

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -rn "Mapper.fromSchema" src/
```

For each existing test / caller:

- Identity behavior: replace `null` with `&[_]NamingRule{}`.
- Single rule: replace `.camel_to_snake` with `&[_]NamingRule{.camel_to_snake}`.

- [ ] **Step 3: Build**

```bash
zig build 2>&1 | head -10
zig build test 2>&1 | tail -5
zig fmt --check src/transform/mapper.zig
```

Expected: builds clean, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/transform/mapper.zig
git commit -m "feat(transform): Mapper.fromSchema accepts []NamingRule for pipeline"
```

---

## Task 3: `TransformConfig.naming_rules` + JSON array parse + deinit

**Files:**
- Modify: `src/transform/engine.zig`

- [ ] **Step 1: Add `naming_rules: []const NamingRule` field to `TransformConfig`**

Find the `TransformConfig` struct definition. Add a new field while keeping `naming_rule: ?NamingRule` for backward compatibility (Phase 6b tests / callers):

```zig
pub const TransformConfig = struct {
    // ... existing fields ...
    naming_rule: ?mapper_mod.NamingRule = null,
    naming_rules: []const mapper_mod.NamingRule = &.{},

    pub fn deinit(self: *TransformConfig, allocator: std.mem.Allocator) void {
        if (self.naming_rule) |rule| {
            switch (rule) {
                .add_prefix, .strip_prefix => |p| allocator.free(p),
                .regex_replace => |rr| {
                    allocator.free(rr.pattern);
                    allocator.free(rr.replacement);
                },
                else => {},
            }
        }
        for (self.naming_rules) |rule| {
            switch (rule) {
                .add_prefix, .strip_prefix => |p| allocator.free(p),
                .regex_replace => |rr| {
                    allocator.free(rr.pattern);
                    allocator.free(rr.replacement);
                },
                else => {},
            }
        }
    }
};
```

Also add a helper `dupNamingRules` that copies rules into a new slice (similar to the existing `dupNamingRule`):

```zig
pub fn dupNamingRules(allocator: std.mem.Allocator, src: []const mapper_mod.NamingRule) ![]const mapper_mod.NamingRule {
    const out = try allocator.alloc(mapper_mod.NamingRule, src.len);
    errdefer allocator.free(out);
    for (src, 0..) |rule, i| {
        out[i] = switch (rule) {
            .add_prefix, .strip_prefix => |p| .{ .add_prefix = try allocator.dupe(u8, p) }, // unsafe cast below
            .regex_replace => |rr| .{ .regex_replace = .{
                .pattern = try allocator.dupe(u8, rr.pattern),
                .replacement = try allocator.dupe(u8, rr.replacement),
            } },
            else => rule,
        };
    }
    return out;
}
```

> Note: the `add_prefix` / `strip_prefix` variants can't both share this single-arm cast; replace the placeholder with the correct variant matching the input. The implementer should write two arms (one for `add_prefix`, one for `strip_prefix`) that both `allocator.dupe` the payload.

- [ ] **Step 2: Add failing test for `naming_rules` JSON parse**

```zig
test "TransformConfig parses naming_rules array from json" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"transform":{"naming_rules":[
        \\  {"type":"camel_to_snake"},
        \\  {"type":"add_prefix","value":"dt_"}
        \\]}}
    , .{});
    defer parsed.deinit();

    const cfg = try TransformConfig.initFromJson(a, parsed.value);
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), cfg.naming_rules.len);
}

test "TransformConfig parses regex_replace naming_rule from json" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"transform":{"naming_rules":[
        \\  {"type":"regex_replace","pattern":"_tmp$","replacement":""}
        \\]}}
    , .{});
    defer parsed.deinit();

    const cfg = try TransformConfig.initFromJson(a, parsed.value);
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), cfg.naming_rules.len);
    switch (cfg.naming_rules[0]) {
        .regex_replace => |rr| {
            try std.testing.expectEqualStrings("_tmp$", rr.pattern);
            try std.testing.expectEqualStrings("", rr.replacement);
        },
        else => return error.UnexpectedRule,
    }
}
```

> Adapt `initFromJson` to whatever the existing entry point is called.

- [ ] **Step 3: Extend `parseNamingRule` for array form**

In `parseNamingRule`, accept either a single rule object/string (existing Phase 6b behavior) or an array of rules:

```zig
fn parseNamingRule(value: std.json.Value, allocator: std.mem.Allocator) std.json.ParseError!?[]const mapper_mod.NamingRule {
    return switch (value) {
        .array => |arr| {
            var out = try allocator.alloc(mapper_mod.NamingRule, arr.items.len);
            errdefer allocator.free(out);
            for (arr.items, 0..) |item, i| {
                out[i] = try parseSingleRule(item, allocator);
            }
            return out;
        },
        else => |single| blk: {
            const r = try parseSingleRule(single, allocator);
            // wrap single rule into 1-element array for uniform caller handling
            const out = try allocator.alloc(mapper_mod.NamingRule, 1);
            out[0] = r;
            break :blk out;
        },
    };
}

fn parseSingleRule(value: std.json.Value, allocator: std.mem.Allocator) std.json.ParseError!mapper_mod.NamingRule {
    return switch (value) {
        .string => |s| {
            if (std.mem.eql(u8, s, "identity")) return .identity;
            if (std.mem.eql(u8, s, "camel_to_snake")) return .camel_to_snake;
            if (std.mem.eql(u8, s, "snake_to_camel")) return .snake_to_camel;
            if (std.mem.eql(u8, s, "upper")) return .upper;
            if (std.mem.eql(u8, s, "lower")) return .lower;
            return error.InvalidConfig;
        },
        .object => |o| {
            const t = o.get("type") orelse return error.InvalidConfig;
            if (t != .string) return error.InvalidConfig;
            if (std.mem.eql(u8, t.string, "add_prefix")) {
                const v = o.get("value") orelse return error.InvalidConfig;
                if (v != .string) return error.InvalidConfig;
                return .{ .add_prefix = try allocator.dupe(u8, v.string) };
            }
            if (std.mem.eql(u8, t.string, "strip_prefix")) {
                const v = o.get("value") orelse return error.InvalidConfig;
                if (v != .string) return error.InvalidConfig;
                return .{ .strip_prefix = try allocator.dupe(u8, v.string) };
            }
            if (std.mem.eql(u8, t.string, "regex_replace")) {
                const p = o.get("pattern") orelse return error.InvalidConfig;
                const r = o.get("replacement") orelse return error.InvalidConfig;
                if (p != .string or r != .string) return error.InvalidConfig;
                return .{ .regex_replace = .{
                    .pattern = try allocator.dupe(u8, p.string),
                    .replacement = try allocator.dupe(u8, r.string),
                } };
            }
            return error.InvalidConfig;
        },
        else => return error.InvalidConfig,
    };
}
```

> If the existing `parseNamingRule` returned `?NamingRule` (Phase 6b), this task changes its signature to return `[]const NamingRule`. Update all existing call sites accordingly.

- [ ] **Step 4: Update `TransformConfig.init` (or `initFromJson`)**

Find the place where `naming_rule` is currently parsed. Replace with logic that:
1. Reads `transform.naming_rule` (single rule, string/object) — wraps into `[]NamingRule{...}`.
2. Reads `transform.naming_rules` (array) — parses each element.
3. If both present, `naming_rules` wins.
4. If neither, `naming_rules = &[_]NamingRule{}` (identity).

- [ ] **Step 5: Build and run tests**

```bash
zig build test -- --test-filter "TransformConfig"
zig fmt --check src/transform/engine.zig
```

Expected: 2 new tests pass, all existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/transform/engine.zig
git commit -m "feat(transform): TransformConfig.naming_rules array + JSON parse + deinit"
```

---

## Task 4: `TransformEngine.initWithSchema` accepts rules slice

**Files:**
- Modify: `src/transform/engine.zig`
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Update `initWithSchema` signature**

Replace:

```zig
pub fn initWithSchema(
    allocator: std.mem.Allocator,
    cfg: TransformConfig,
    source_columns: []const mapper_mod.ColumnMeta,
    rule: ?mapper_mod.NamingRule,
) !TransformEngine {
    var mp = try mapper_mod.Mapper.fromSchema(allocator, source_columns, rule);
    ...
}
```

with:

```zig
pub fn initWithSchema(
    allocator: std.mem.Allocator,
    cfg: TransformConfig,
    source_columns: []const mapper_mod.ColumnMeta,
    rules: []const mapper_mod.NamingRule,
) !TransformEngine {
    var mp = try mapper_mod.Mapper.fromSchema(allocator, source_columns, rules);
    ...
}
```

- [ ] **Step 2: Update `RuntimeConfig.naming_rule` to `naming_rules`**

In `src/engine/runtime.zig`, replace:

```zig
naming_rule: ?transform.mapper.NamingRule = null,
```

with:

```zig
naming_rules: []const transform.mapper.NamingRule = &.{},
```

- [ ] **Step 3: Update `SyncTask.init`**

Find the `tr_init:` block that builds the `engine_cfg` and calls `initWithSchema`. Change:

```zig
.naming_rule = cfg.naming_rule,
```

to:

```zig
.naming_rules = cfg.naming_rules,
```

And:

```zig
break :tr_init try transform.engine.TransformEngine.initWithSchema(a, engine_cfg, cols, cfg.naming_rule);
```

to:

```zig
break :tr_init try transform.engine.TransformEngine.initWithSchema(a, engine_cfg, cols, cfg.naming_rules);
```

- [ ] **Step 4: Build and run tests**

```bash
zig build 2>&1 | tail -10
zig build test 2>&1 | tail -5
zig fmt --check src/transform/engine.zig src/engine/runtime.zig
```

Expected: builds clean, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/transform/engine.zig src/engine/runtime.zig
git commit -m "feat(transform): initWithSchema + RuntimeConfig use []NamingRule for pipeline"
```

---

## Task 5: dev.md + final verification

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Add Phase 6c section**

In `dev.md`, after the Phase 6b section, add:

```
## Phase 6c: 正则替换 + 链式规则

`NamingRule` 新增 `regex_replace` 变体 + `applyNamingPipeline` 串联多个规则.

支持的规则:
- `regex_replace(pattern, replacement)` (`order_tmp` → 用 `{"pattern":"_tmp$","replacement":""}` → `order`)
- 链式规则: `NamingRule` 数组, 顺序应用, e.g. `[camel_to_snake, add_prefix("dt_")]` 把 `orderId` → `order_id` → `dt_order_id`

配置方式 (在 `config_json.transform.naming_rules`):
- 字符串简写: `"naming_rules": "camel_to_snake"` (单规则, 等价 `[camel_to_snake]`)
- 数组形式: `"naming_rules": [{"type":"camel_to_snake"}, {"type":"add_prefix","value":"dt_"}]`
- 单规则对象: `"naming_rules": {"type":"add_prefix","value":"dt_"}` (自动 wrap 成 1-element array)

regex_replace 支持 backref (`$1`, `$2` 等).
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
git add dev.md docs/superpowers/specs/2026-06-15-zetl-phase6c-regex-and-pipeline-design.md docs/superpowers/plans/2026-06-15-zetl-phase6c-regex-and-pipeline.md
git commit -m "docs: add Phase 6c section + commit design/plan docs"
```

If the design/plan docs were already committed (e.g., during brainstorming), drop them.

Report DONE when finished.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - RegexReplace struct → Task 1
  - regex_replace variant in NamingRule → Task 1
  - applyNamingPipeline → Task 1
  - 4 unit tests for new variants + pipeline → Task 1
  - Mapper.fromSchema accepts []NamingRule → Task 2
  - TransformConfig.naming_rules + JSON array parse → Task 3
  - deinit frees regex pattern/replacement → Task 3
  - TransformEngine.initWithSchema accepts rules slice → Task 4
  - RuntimeConfig.naming_rules + SyncTask wiring → Task 4
  - dev.md update → Task 5
- [ ] **No placeholders:** every step shows concrete code; `initFromJson` entry-point name is illustrative and adapted during implementation.
- [ ] **Type consistency:** `NamingRule`, `RegexReplace`, `applyNamingPipeline`, `naming_rules: []NamingRule`, `initWithSchema(rules: []NamingRule)` consistent across tasks.