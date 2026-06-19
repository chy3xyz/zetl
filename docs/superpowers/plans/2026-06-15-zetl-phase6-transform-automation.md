# zetl Phase 6: transform 自动化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-generate default `Mapper.mappings` from source schema (identity), then merge user overrides from `field_mappings_json`. Source-schema discovery via `SHOW COLUMNS FROM <table>` for `runFull`. Binlog path keeps existing column naming.

**Architecture:** Add `ColumnMeta` struct + `Mapper.fromSchema` to `src/transform/mapper.zig`; add `Mapper.mergeOverrides` for user JSON overrides. `TransformEngine.init` accepts `source_columns` and uses `fromSchema + mergeOverrides`. `SyncTask` adds `fetchSourceColumns` that runs `SHOW COLUMNS` and wires the result into `TransformEngine.init` at the start of `runFull`.

**Tech Stack:** Zig (0.17 nightly), existing `std.json.parseFromSlice`, MySQL via zfinal.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/transform/mapper.zig` | Field mapping with auto + overrides | Extend |
| `src/transform/engine.zig` | TransformEngine accepts `source_columns` | Extend |
| `src/engine/runtime.zig` | SyncTask fetches source columns + wires them into TransformEngine | Extend |

---

## Task 1: `ColumnMeta` struct + `Mapper.fromSchema`

**Files:**
- Modify: `src/transform/mapper.zig`
- Test: `src/transform/mapper.zig`

- [ ] **Step 1: Add failing test**

Append to `src/transform/mapper.zig`:

```zig
test "Mapper.fromSchema generates identity mappings" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "paid_at" },
        .{ .name = "amount" },
    };
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 3), m.mappings.len);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].source);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].target);
    try std.testing.expectEqualStrings("paid_at", m.mappings[1].source);
    try std.testing.expectEqualStrings("paid_at", m.mappings[1].target);
    try std.testing.expectEqualStrings("amount", m.mappings[2].source);
    try std.testing.expectEqualStrings("amount", m.mappings[2].target);
}
```

- [ ] **Step 2: Run test to confirm failure**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test -- --test-filter "Mapper.fromSchema"
```

Expected: FAIL because `ColumnMeta` and `Mapper.fromSchema` don't exist yet.

- [ ] **Step 3: Implement `ColumnMeta` and `Mapper.fromSchema`**

Add to `src/transform/mapper.zig` (just below the `FieldMapping` struct, around line 13):

```zig
/// Source schema 列元数据, 用于自动生成默认映射.
pub const ColumnMeta = struct {
    name: []const u8,
    /// MySQL 类型常量 (可选, 暂未使用).
    type: u8 = 0,
};
```

Add `Mapper.fromSchema` (alongside `fromJson`):

```zig
/// 从 source 列元数据生成 identity 映射 (列名 == 列名).
pub fn fromSchema(allocator: std.mem.Allocator, columns: []const ColumnMeta) !Mapper {
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
            .target = try allocator.dupe(u8, col.name),
        };
    }
    return Mapper{ .allocator = allocator, .mappings = mappings };
}
```

- [ ] **Step 4: Run test to confirm it passes**

```bash
zig build test -- --test-filter "Mapper.fromSchema"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/transform/mapper.zig
git commit -m "feat(transform): add ColumnMeta and Mapper.fromSchema"
```

---

## Task 2: `Mapper.mergeOverrides`

**Files:**
- Modify: `src/transform/mapper.zig`
- Test: `src/transform/mapper.zig`

- [ ] **Step 1: Add failing tests**

Append to `src/transform/mapper.zig`:

```zig
test "Mapper.mergeOverrides replaces target for matching source" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "paid_at" },
    };
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();

    try m.mergeOverrides(a,
        \\[{"source":"order_id","target":"id"}]
    );

    try std.testing.expectEqual(@as(usize, 2), m.mappings.len);
    try std.testing.expectEqualStrings("order_id", m.mappings[0].source);
    try std.testing.expectEqualStrings("id", m.mappings[0].target);
    try std.testing.expectEqualStrings("paid_at", m.mappings[1].target);
}

test "Mapper.mergeOverrides with empty json is no-op" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{.{ .name = "x" }};
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();
    try m.mergeOverrides(a, "");
    try std.testing.expectEqual(@as(usize, 1), m.mappings.len);
    try std.testing.expectEqualStrings("x", m.mappings[0].target);
}

test "Mapper.mergeOverrides appends user-only mappings" {
    const a = std.testing.allocator;
    const cols = [_]ColumnMeta{.{ .name = "x" }};
    var m = try Mapper.fromSchema(a, &cols);
    defer m.deinit();

    try m.mergeOverrides(a,
        \\[{"source":"x","target":"y"},{"source":"z","target":"z_out"}]
    );

    try std.testing.expectEqual(@as(usize, 2), m.mappings.len);
    try std.testing.expectEqualStrings("x", m.mappings[0].source);
    try std.testing.expectEqualStrings("y", m.mappings[0].target);
    try std.testing.expectEqualStrings("z", m.mappings[1].source);
    try std.testing.expectEqualStrings("z_out", m.mappings[1].target);
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
zig build test -- --test-filter "Mapper.mergeOverrides"
```

Expected: FAIL because `mergeOverrides` doesn't exist.

- [ ] **Step 3: Implement `Mapper.mergeOverrides`**

Add to `src/transform/mapper.zig`:

```zig
/// 用 user_json 中的覆盖项替换同 source 的 mapping.
/// user_json 格式与 fromJson 相同: [{"source": "...", "target": "...", "default": "...", "type": "..."}]
/// 已有的 auto mappings 中, 命中 source 的项的 target / default / type 被替换.
/// user_json 中 source 不在 auto 里的项作为额外 mapping 追加.
pub fn mergeOverrides(self: *Mapper, allocator: std.mem.Allocator, user_json: []const u8) !void {
    if (user_json.len == 0) return;
    var override_mapper = try fromJson(allocator, user_json);
    defer override_mapper.deinit();

    var idx: std.StringHashMap(usize) = .empty;
    defer idx.deinit(allocator);
    for (override_mapper.mappings, 0..) |m, i| {
        try idx.put(m.source, i);
    }

    for (self.mappings) |*auto_m| {
        if (idx.get(auto_m.source)) |ov_idx| {
            const ov = override_mapper.mappings[ov_idx];
            allocator.free(auto_m.target);
            auto_m.target = try allocator.dupe(u8, ov.target);
            if (auto_m.default_value) |d| allocator.free(d);
            auto_m.default_value = null;
            if (ov.default_value) |d| auto_m.default_value = try allocator.dupe(u8, d);
            if (auto_m.type_convert) |t| allocator.free(t);
            auto_m.type_convert = null;
            if (ov.type_convert) |t| auto_m.type_convert = try allocator.dupe(u8, t);
        }
    }

    for (override_mapper.mappings) |ov| {
        var found = false;
        for (self.mappings) |auto_m| {
            if (std.mem.eql(u8, auto_m.source, ov.source)) {
                found = true;
                break;
            }
        }
        if (!found) {
            var new_m: FieldMapping = .{
                .source = try allocator.dupe(u8, ov.source),
                .target = try allocator.dupe(u8, ov.target),
            };
            if (ov.default_value) |d| new_m.default_value = try allocator.dupe(u8, d);
            if (ov.type_convert) |t| new_m.type_convert = try allocator.dupe(u8, t);
            const new_list = try allocator.realloc(self.mappings, self.mappings.len + 1);
            new_list[self.mappings.len] = new_m;
            self.mappings = new_list;
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
zig build test -- --test-filter "Mapper.mergeOverrides"
zig fmt --check src/transform/mapper.zig
```

Expected: 3 new tests pass, formatting OK.

- [ ] **Step 5: Commit**

```bash
git add src/transform/mapper.zig
git commit -m "feat(transform): add Mapper.mergeOverrides for user field_mappings_json"
```

---

## Task 3: `TransformEngine.init` accepts `source_columns`

**Files:**
- Modify: `src/transform/engine.zig`
- Test: `src/transform/engine.zig`

- [ ] **Step 1: Read existing `TransformEngine.init`**

Read `src/transform/engine.zig` to find the existing `TransformEngine.init` signature and `Mapper` setup. Adapt the steps below to the actual code.

- [ ] **Step 2: Add failing test**

Append to `src/transform/engine.zig`:

```zig
test "TransformEngine.init with empty source_columns uses field_mappings_json" {
    const a = std.testing.allocator;
    const cfg = transform_config.TransformConfig{
        .field_mappings_json = "[]",
    };
    var eng = try TransformEngine.init(a, cfg);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 0), eng.mapper.mappings.len);
}

test "TransformEngine.init with source_columns generates identity mappings" {
    const a = std.testing.allocator;
    const cfg = transform_config.TransformConfig{
        .field_mappings_json = "",
    };
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "amount" },
    };
    var eng = try TransformEngine.initWithSchema(a, cfg, &cols);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 2), eng.mapper.mappings.len);
    try std.testing.expectEqualStrings("order_id", eng.mapper.mappings[0].source);
    try std.testing.expectEqualStrings("order_id", eng.mapper.mappings[0].target);
}

test "TransformEngine.initWithSchema merges user overrides" {
    const a = std.testing.allocator;
    const cfg = transform_config.TransformConfig{
        .field_mappings_json = \\[{"source":"order_id","target":"id"}],
    };
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "order_id" },
        .{ .name = "amount" },
    };
    var eng = try TransformEngine.initWithSchema(a, cfg, &cols);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 2), eng.mapper.mappings.len);
    try std.testing.expectEqualStrings("id", eng.mapper.mappings[0].target);
}
```

> Adapt the import paths and the actual function name (`initWithSchema`) if the existing code differs. The key requirement: a new entry point that takes `[]const mapper.ColumnMeta`.

- [ ] **Step 3: Run tests to confirm failure**

```bash
zig build test -- --test-filter "TransformEngine.init"
```

Expected: FAIL because `initWithSchema` doesn't exist.

- [ ] **Step 4: Implement `TransformEngine.initWithSchema`**

In `src/transform/engine.zig`, add:

```zig
/// 带 source schema 的 init. 先 fromSchema 生成 identity 映射, 再 mergeOverrides 应用用户覆盖.
pub fn initWithSchema(
    allocator: std.mem.Allocator,
    cfg: TransformConfig,
    source_columns: []const mapper.ColumnMeta,
) !TransformEngine {
    var mapper = try mapper.Mapper.fromSchema(allocator, source_columns);
    errdefer mapper.deinit();

    try mapper.mergeOverrides(allocator, cfg.field_mappings_json);

    // Calculator 配置 (与 init 行为一致)
    var calculator: ?*calc.CommissionCalculator = null;
    if (cfg.enable_commission_calc) {
        calculator = try allocator.create(calc.CommissionCalculator);
        calculator.?.* = try calc.CommissionCalculator.init(allocator);
    }

    return TransformEngine{
        .allocator = allocator,
        .cfg = cfg,
        .mapper = mapper,
        .calculator = calculator,
    };
}
```

> Adapt to the existing `init` body. The new function reuses existing Calculator setup if `enable_commission_calc` is true; otherwise calculator stays null.

- [ ] **Step 5: Run tests**

```bash
zig build test -- --test-filter "TransformEngine"
zig fmt --check src/transform/engine.zig
```

Expected: tests pass, formatting OK.

- [ ] **Step 6: Commit**

```bash
git add src/transform/engine.zig
git commit -m "feat(transform): add TransformEngine.initWithSchema for source-column-driven mappings"
```

---

## Task 4: `SyncTask.fetchSourceColumns` helper

**Files:**
- Modify: `src/engine/runtime.zig`
- Test: `src/engine/runtime.zig`

- [ ] **Step 1: Add the helper method**

In `src/engine/runtime.zig`, add a new method on `SyncTask`:

```zig
/// 通过 SHOW COLUMNS FROM <table> 获取 source 列名, 转 ColumnMeta 列表.
/// 调用方负责 deinit 返回的 slice (free 每个 name + free slice).
fn fetchSourceColumns(self: *SyncTask) ![]mapper.ColumnMeta {
    const sql = try std.fmt.allocPrint(self.allocator, "SHOW COLUMNS FROM `{s}`", .{self._sh});
    defer self.allocator.free(sql);

    const result = try self.src_pool.query(sql);
    defer result.deinit();

    var cols = try self.allocator.alloc(mapper.ColumnMeta, result.rowCount());
    errdefer self.allocator.free(cols);

    var i: usize = 0;
    while (try result.next()) {
        const row = result.currentRowMap() orelse break;
        const field_name = row.get("Field") orelse return error.MissingColumnName;
        cols[i] = .{
            .name = try self.allocator.dupe(u8, field_name),
        };
        i += 1;
    }
    // shrink if fewer rows than initially allocated
    if (i < cols.len) {
        const shrunk = try self.allocator.realloc(cols, i);
        return shrunk;
    }
    return cols;
}
```

> Adapt SQL execution / row extraction to the actual zfinal API used in `runtime.zig` (likely `self.src_pool.query(...)` or similar). Read an existing query in `runFull` for reference.

- [ ] **Step 2: Build to confirm it compiles**

```bash
zig build 2>&1 | head -20
```

Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "feat(engine): add SyncTask.fetchSourceColumns via SHOW COLUMNS"
```

---

## Task 5: Wire `fetchSourceColumns` into `runFull`

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Find the `runFull` start**

Read `src/engine/runtime.zig` to find where `runFull` initializes the transformer. Currently it likely uses `TransformEngine.init(cfg)`. Add a new path that, when source schema discovery succeeds, uses `initWithSchema`.

- [ ] **Step 2: Replace transformer initialization**

Find the block in `runFull` that does:

```zig
self.transformer = try TransformEngine.init(self.allocator, cfg);
```

Replace with:

```zig
// 尝试从 source 表获取列元数据, 用于自动生成映射.
const cols = self.fetchSourceColumns() catch |err| {
    common.logger.warn("[task {d}] fetchSourceColumns 失败, 退化为手工映射: {s}", .{ self.cfg.task_id, @errorName(err) });
    self.transformer = try TransformEngine.init(self.allocator, cfg);
    return;
};
defer for (cols) |c| self.allocator.free(c.name);
defer self.allocator.free(cols);

self.transformer = try TransformEngine.initWithSchema(self.allocator, cfg, cols);
```

> Adapt to the actual code path. The key: if `fetchSourceColumns` succeeds, use `initWithSchema`; otherwise fall back to the existing `init`.

- [ ] **Step 3: Build and run tests**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build 2>&1 | head -20
zig build test 2>&1 | tail -5
```

Expected: builds clean, all 180+ tests still pass.

- [ ] **Step 4: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "feat(engine): wire fetchSourceColumns into runFull"
```

---

## Task 6: Update dev.md + final verification

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Add Phase 6 section to dev.md**

In `dev.md`, add:

```
## Phase 6: transform 自动化

`Mapper` 支持基于 source schema 自动生成默认列映射 (identity), 用户可在 `field_mappings_json` 中覆盖特定列的 target / default / type.

- `Mapper.fromSchema(allocator, []ColumnMeta)`: 从 source 列元数据生成 N 个 identity mappings.
- `Mapper.mergeOverrides(allocator, user_json)`: 应用用户 override, 命中 source 的项替换 target/default/type, 未命中的额外 mapping 追加.
- `TransformEngine.initWithSchema(...)`: 新入口, 调 fromSchema 后 mergeOverrides.
- `SyncTask.runFull` 启动时通过 `SHOW COLUMNS FROM <table>` 获取 source 列名, 自动使用 `initWithSchema`.
- binlog 路径继续使用 parser 的现有列名 ("c0", "c1", ...); 真实列名映射留 Phase 6b (TABLE_MAP metadata).
```

- [ ] **Step 2: Final verification**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/mapper.zig src/transform/engine.zig src/engine/runtime.zig
zig build test 2>&1 | tail -5
```

Expected: formatting OK, all tests pass.

- [ ] **Step 3: Commit the design/plan docs (if not yet committed) and dev.md**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add dev.md docs/superpowers/specs/2026-06-15-zetl-phase6-transform-automation-design.md docs/superpowers/plans/2026-06-15-zetl-phase6-transform-automation.md
git commit -m "docs: add Phase 6 section + commit design/plan docs"
```

If the design/plan docs were already committed in a previous commit (e.g., during brainstorming), drop them.

Report DONE when finished.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - ColumnMeta → Task 1
  - fromSchema → Task 1
  - mergeOverrides → Task 2
  - TransformEngine.initWithSchema → Task 3
  - fetchSourceColumns via SHOW COLUMNS → Task 4
  - runFull wiring → Task 5
  - dev.md update → Task 6
- [ ] **No placeholders:** every step shows concrete code or commands; SQL execution and TransformEngine.init signatures are illustrative and adapted during implementation by reading the existing code.
- [ ] **Type consistency:** ColumnMeta, FieldMapping, Mapper, TransformEngine, SyncTask types consistent across tasks.