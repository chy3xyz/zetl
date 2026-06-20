# zetl Phase 10: Phase 7b precision + mask_phone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `transform.mask_phone = true` shortcut AND auto-detect VARCHAR length / DECIMAL precision from `SHOW COLUMNS` so `buildCreateTable` generates accurate DDL (Phase 7b). Also fix outdated ai-recipes docs that mark filter as "待实现" (it's already shipped).

**Architecture:** (1) `ColumnMeta` gains optional `length: ?u16`, `precision: ?u8`, `scale: ?u8` fields. (2) `parseMySqlTypeString` returns a `ParsedType` struct with these. (3) `mySqlTypeName` formats dynamic strings via stack `BoundedArray`. (4) `TransformConfig.mask_phone: bool` triggers field-name matching + middle-digit masking in `process()`. (5) Docs catch-up.

**Tech Stack:** Zig 0.17, std.BoundedArray, zfinal MySQL pool.

---

## File Structure

| File | Change |
|------|--------|
| `src/transform/mapper.zig` | Extend `ColumnMeta` (length/precision/scale) |
| `src/engine/runtime.zig` | `parseMySqlTypeString` returns `ParsedType`, `fetchSourceColumns` fills precision |
| `src/sink/schema_ddl.zig` | `mySqlTypeName(col_type, length, precision, scale)` dynamic format |
| `src/transform/engine.zig` | `TransformConfig.mask_phone`, `process()` mask logic |
| `src/meta/task.zig` | JSON parse `transform.mask_phone` |
| `docs/ai-recipes/recipes/order-sync.md` | filter docs (it's already shipped) |
| `docs/ai-recipes/recipes/user-sync.md` | mask_phone docs |
| `docs/ai-recipes/reference/transform-overrides.md` | mention mask_phone shortcut |
| `docs/ai-recipes/reference/sink-ddl.md` | remove "Phase 7b 待实现" caveat |
| `dev.md` | Phase 10 section |

---

## Task 1: ColumnMeta + parseMySqlTypeString returns ParsedType

**Files:**
- Modify: `src/transform/mapper.zig`
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Extend `ColumnMeta` in `src/transform/mapper.zig`**

Find the existing struct (around line 16):

```zig
pub const ColumnMeta = struct {
    name: []const u8,
    type: u8 = 0,
};
```

Replace with:

```zig
pub const ColumnMeta = struct {
    name: []const u8,
    /// MySQL 类型常量字节 (来自 protocol / SHOW COLUMNS 解析).
    type: u8 = 0,
    /// VARCHAR/CHAR 字符数 (来自 `varchar(N)` / `char(N)` 部分).
    length: ?u16 = null,
    /// DECIMAL precision (来自 `decimal(P,S)` 部分).
    precision: ?u8 = null,
    /// DECIMAL scale (来自 `decimal(P,S)` 部分).
    scale: ?u8 = null,
};
```

- [ ] **Step 2: Replace `parseMySqlTypeString` in `src/engine/runtime.zig`**

Find the existing function (around line 473-504, returns `u8`). Replace with:

```zig
const ParsedType = struct {
    type_byte: u8,
    length: ?u16 = null,
    precision: ?u8 = null,
    scale: ?u8 = null,
};

/// 解析 SHOW COLUMNS 返回的 Type 字符串 (如 "int(11) unsigned", "varchar(255)", "decimal(10,2)", "datetime")
/// 返回 ParsedType 含类型字节 + 可选 length / precision / scale.
/// 未知类型返回 `{ .type_byte = 0xff, ... }` (建表时 fallback TEXT).
fn parseMySqlTypeString(type_str: []const u8) ParsedType {
    var end: usize = 0;
    while (end < type_str.len and type_str[end] != '(' and type_str[end] != ' ') : (end += 1) {}
    const keyword = type_str[0..end];

    var parsed: ParsedType = .{
        .type_byte = switch (keyword) {
            "tinyint" => 0x01,
            "smallint" => 0x02,
            "int" => 0x03,
            "mediumint" => 0x09,
            "bigint" => 0x08,
            "float" => 0x04,
            "double" => 0x05,
            "decimal" => 0xf6,
            "date" => 0x0a,
            "time" => 0x0b,
            "datetime" => 0x12,
            "timestamp" => 0x11,
            "year" => 0x0d,
            "varchar" => 0x0f,
            "char" => 0xfe,
            "text", "tinytext", "mediumtext", "longtext" => 0xfd,
            "blob", "tinyblob", "mediumblob", "longblob" => 0xfc,
            "json" => 0xf5,
            else => 0xff,
        },
    };

    // 解析括号内的参数 (可能 "N" 或 "P,S")
    if (end < type_str.len and type_str[end] == '(') {
        const close = std.mem.indexOfScalarPos(u8, type_str, end + 1, ')') orelse return parsed;
        const inner = type_str[end + 1 .. close];
        if (std.mem.indexOfScalar(u8, inner, ',')) |comma| {
            // "P,S" → precision, scale (DECIMAL)
            if (std.fmt.parseInt(u8, std.mem.trim(u8, inner[0..comma], &std.ascii.whitespace), 10)) |p| {
                parsed.precision = p;
            } else |_| {}
            if (std.fmt.parseInt(u8, std.mem.trim(u8, inner[comma + 1 ..], &std.ascii.whitespace), 10)) |s| {
                parsed.scale = s;
            } else |_| {}
        } else {
            // "N" → length (VARCHAR/CHAR)
            if (std.fmt.parseInt(u16, std.mem.trim(u8, inner, &std.ascii.whitespace), 10)) |n| {
                parsed.length = n;
            } else |_| {}
        }
    }

    return parsed;
}
```

- [ ] **Step 3: Update `fetchSourceColumns` to use new return type**

Find the call site around line 461:

```zig
const type_byte = parseMySqlTypeString(type_str);
try list.append(self.allocator, .{
    .name = try self.allocator.dupe(u8, field_name),
    .type = type_byte,
});
```

Replace with:

```zig
const parsed_type = parseMySqlTypeString(type_str);
try list.append(self.allocator, .{
    .name = try self.allocator.dupe(u8, field_name),
    .type = parsed_type.type_byte,
    .length = parsed_type.length,
    .precision = parsed_type.precision,
    .scale = parsed_type.scale,
});
```

- [ ] **Step 4: Add unit tests for `parseMySqlTypeString`**

Append at the end of `src/engine/runtime.zig`:

```zig
test "parseMySqlTypeString parses int(N) unsigned" {
    const p = parseMySqlTypeString("int(11) unsigned");
    try std.testing.expectEqual(@as(u8, 0x03), p.type_byte);
    try std.testing.expectEqual(@as(?u16, 11), p.length);
}

test "parseMySqlTypeString parses varchar(N)" {
    const p = parseMySqlTypeString("varchar(64)");
    try std.testing.expectEqual(@as(u8, 0x0f), p.type_byte);
    try std.testing.expectEqual(@as(?u16, 64), p.length);
}

test "parseMySqlTypeString parses decimal(P,S)" {
    const p = parseMySqlTypeString("decimal(10,2)");
    try std.testing.expectEqual(@as(u8, 0xf6), p.type_byte);
    try std.testing.expectEqual(@as(?u8, 10), p.precision);
    try std.testing.expectEqual(@as(?u8, 2), p.scale);
    try std.testing.expect(p.length == null);
}

test "parseMySqlTypeString parses plain datetime without length" {
    const p = parseMySqlTypeString("datetime");
    try std.testing.expectEqual(@as(u8, 0x12), p.type_byte);
    try std.testing.expect(p.length == null);
    try std.testing.expect(p.precision == null);
}

test "parseMySqlTypeString returns 0xff for unknown" {
    const p = parseMySqlTypeString("geometry");
    try std.testing.expectEqual(@as(u8, 0xff), p.type_byte);
}
```

- [ ] **Step 5: Build and run tests**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/mapper.zig src/engine/runtime.zig
zig build test -- --test-filter "parseMySqlTypeString"
```

Expected: 5 new tests pass, formatting OK.

- [ ] **Step 6: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add src/transform/mapper.zig src/engine/runtime.zig
git commit -m "feat(transform): ColumnMeta + parseMySqlTypeString returns ParsedType with length/precision/scale"
```

---

## Task 2: schema_ddl precision-aware mySqlTypeName

**Files:**
- Modify: `src/sink/schema_ddl.zig`

- [ ] **Step 1: Replace `mySqlTypeName` with length/precision-aware version**

Find `mySqlTypeName` (around line 17-41). Replace with a version that takes the new args and uses `std.BoundedArray`:

```zig
/// MySQL 类型常量 → 字符串. type 来自 mapper.ColumnMeta.type.
/// `length` 用于 VARCHAR(N), `precision`+`scale` 用于 DECIMAL(P,S). 不提供时用默认值 (255 / 18,4).
/// 返回的 slice 是栈 buffer (`type_buf`), caller 必须在调用后立刻用, 不要长期持有.
const TypeNameBuf = std.BoundedArray(u8, 32);

fn mySqlTypeName(
    col_type: u8,
    length: ?u16,
    precision: ?u8,
    scale: ?u8,
    type_buf: *TypeNameBuf,
) []const u8 {
    const writer = type_buf.writer();
    switch (col_type) {
        0x01 => writer.writeAll("TINYINT") catch unreachable,
        0x02 => writer.writeAll("SMALLINT") catch unreachable,
        0x03 => writer.writeAll("INT") catch unreachable,
        0x09 => writer.writeAll("MEDIUMINT") catch unreachable,
        0x08 => writer.writeAll("BIGINT") catch unreachable,
        0x04 => writer.writeAll("FLOAT") catch unreachable,
        0x05 => writer.writeAll("DOUBLE") catch unreachable,
        0x00, 0xf6 => {
            // DECIMAL(precision, scale) — use provided or default (18, 4)
            const p = precision orelse 18;
            const s = scale orelse 4;
            writer.print("DECIMAL({d},{d})", .{ p, s }) catch unreachable;
        },
        0x0a => writer.writeAll("DATE") catch unreachable,
        0x0b => writer.writeAll("TIME") catch unreachable,
        0x0c => writer.writeAll("DATETIME") catch unreachable,
        0x12 => writer.writeAll("DATETIME(6)") catch unreachable,
        0x07 => writer.writeAll("TIMESTAMP") catch unreachable,
        0x11 => writer.writeAll("TIMESTAMP(6)") catch unreachable,
        0x0d => writer.writeAll("YEAR") catch unreachable,
        0x0f => {
            // VARCHAR(length) — use provided or default 255
            const n = length orelse 255;
            writer.print("VARCHAR({d})", .{n}) catch unreachable;
        },
        0xfe => writer.writeAll("CHAR(1)") catch unreachable,
        0xfc => writer.writeAll("BLOB") catch unreachable,
        0xfd => writer.writeAll("TEXT") catch unreachable,
        0xf5 => writer.writeAll("JSON") catch unreachable,
        else => writer.writeAll("TEXT") catch unreachable,
    }
    return type_buf.buffer[0..type_buf.len()];
}
```

- [ ] **Step 2: Update `buildCreateTable` to pass new args**

Find `buildCreateTable` (around line 53-90). Change the column loop to allocate one `TypeNameBuf` per column (or reuse across iterations):

```zig
for (columns) |col| {
    const quoted = try quoteIdentifier(allocator, col.name);
    errdefer allocator.free(quoted);

    var type_buf: TypeNameBuf = .{};
    const type_name = mySqlTypeName(col.type, col.length, col.precision, col.scale, &type_buf);

    const part = try std.fmt.allocPrint(allocator, "    {s} {s}", .{ quoted, type_name });
    try col_parts.append(allocator, part);
}
```

- [ ] **Step 3: Update existing tests in `schema_ddl.zig`**

Find existing tests that pass `.{ .name = "id", .type = 0x03 }` (line 94-100 area). Update them so the test still asserts basic format but uses the new signature. Adapt each call site of `buildCreateTable` (in tests and runtime) similarly.

- [ ] **Step 4: Add a precision-aware test**

```zig
test "buildCreateTable uses VARCHAR(N) from ColumnMeta.length" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "id", .type = 0x08 },
        .{ .name = "order_no", .type = 0x0f, .length = 32 },
    };
    const ddl = try buildCreateTable(a, "orders", &cols, .{});
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`order_no` VARCHAR(32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "VARCHAR(255)") == null);
}

test "buildCreateTable uses DECIMAL(P,S) from ColumnMeta" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "amount", .type = 0xf6, .precision = 10, .scale = 2 },
    };
    const ddl = try buildCreateTable(a, "orders", &cols, .{});
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`amount` DECIMAL(10,2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "DECIMAL(18,4)") == null);
}
```

- [ ] **Step 5: Build and run tests**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/sink/schema_ddl.zig
zig build test -- --test-filter "buildCreateTable"
```

Expected: 2 new tests pass; existing tests still pass (after adapting their `ColumnMeta` literals if needed).

- [ ] **Step 6: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add src/sink/schema_ddl.zig
git commit -m "feat(sink): schema_ddl uses ColumnMeta.length/precision/scale for accurate DDL"
```

---

## Task 3: TransformConfig.mask_phone + process() mask

**Files:**
- Modify: `src/transform/engine.zig`

- [ ] **Step 1: Add `mask_phone` field to `TransformConfig`**

Find the struct (around line 30-50). Add a new field:

```zig
pub const TransformConfig = struct {
    // ... 现有字段 ...
    mask_phone: bool = false,  // NEW: 自动脱敏 phone/mobile/tel 字段中间 4 位
    // ... 现有字段 ...
};
```

- [ ] **Step 2: Add `maskPhoneIfNeeded` helper**

Find a good place to add this helper (near `process`):

```zig
/// 如果 cfg.mask_phone 为 true 且 field_name 看起来像手机号字段 (含 "phone", "mobile", "tel" 子串, 大小写不敏感),
/// 且 value 是 ≥ 7 位数字, 把中间 4 位替换成 "****". 返回新值 (caller 负责 free).
/// 不满足条件返回 null (表示不修改).
fn maskPhoneIfNeeded(allocator: std.mem.Allocator, field_name: []const u8, value: []const u8, cfg: TransformConfig) !?[]u8 {
    if (!cfg.mask_phone) return null;
    if (!looksLikePhoneField(field_name)) return null;
    if (value.len < 7) return null;
    if (!isAllDigits(value)) return null;

    // 中间 4 位替换: "13800138000" -> "138****8000"
    const prefix_len = (value.len - 4) / 2;
    const suffix_start = prefix_len + 4;
    return std.fmt.allocPrint(allocator, "{s}****{s}", .{ value[0..prefix_len], value[suffix_start..] });
}

fn looksLikePhoneField(name: []const u8) bool {
    const lower = std.ascii.lowerString;  // helper — see implementation note below
    _ = lower;
    // case-insensitive substring match
    if (std.mem.indexOf(u8, name, "phone") != null) return true;
    if (std.mem.indexOf(u8, name, "mobile") != null) return true;
    if (std.mem.indexOf(u8, name, "tel") != null) return true;
    return false;
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}
```

> Note: `looksLikePhoneField` is case-sensitive. For Phase 10 simplicity we accept "Phone" / "MOBILE" misses (typical MySQL column names are already lowercase). Document in the dev.md section.

- [ ] **Step 3: Wire into `process()`**

Find the field-processing loop in `TransformEngine.process()`. After each field is written to the output `RowData`, if `cfg.mask_phone`, replace the value:

```zig
// after writing field to output:
if (cfg.mask_phone) {
    if (try maskPhoneIfNeeded(allocator, field_name, output_value, cfg)) |masked| {
        // free original, replace with masked
        allocator.free(output_value);
        output_value = masked;
    }
}
```

Adjust to match the actual structure of `process()` — read the file and adapt.

- [ ] **Step 4: Add tests**

```zig
test "maskPhoneIfNeeded masks middle 4 digits" {
    const a = std.testing.allocator;
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_phone = true };
    const masked = try maskPhoneIfNeeded(a, "phone", "13800138000", cfg);
    try std.testing.expect(masked != null);
    defer a.free(masked.?);
    try std.testing.expectEqualStrings("138****8000", masked.?);
}

test "maskPhoneIfNeeded leaves non-phone fields alone" {
    const a = std.testing.allocator;
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_phone = true };
    try std.testing.expect((try maskPhoneIfNeeded(a, "user_id", "12345", cfg)) == null);
}

test "maskPhoneIfNeeded leaves too-short values alone" {
    const a = std.testing.allocator;
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_phone = true };
    try std.testing.expect((try maskPhoneIfNeeded(a, "phone", "12345", cfg)) == null);
}

test "maskPhoneIfNeeded disabled when mask_phone=false" {
    const a = std.testing.allocator;
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t" };
    try std.testing.expect((try maskPhoneIfNeeded(a, "phone", "13800138000", cfg)) == null);
}
```

- [ ] **Step 5: Build and run tests**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/engine.zig
zig build test -- --test-filter "maskPhone"
```

Expected: 4 new tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add src/transform/engine.zig
git commit -m "feat(transform): TransformConfig.mask_phone + automatic middle-digit masking"
```

---

## Task 4: TaskConfig JSON parse mask_phone

**Files:**
- Modify: `src/meta/task.zig` (or wherever TaskConfig is parsed from JSON — find by grep)

- [ ] **Step 1: Find TaskConfig JSON parser**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -rn "transform.commission\|parseFromJson\|TaskConfig" src/meta/ src/web/ | head -10
```

- [ ] **Step 2: Add mask_phone parse**

Find the `transform` parsing block. Add mask_phone alongside commission / field_mappings_json / naming_rule:

```zig
// inside transform object parse:
if (transform_obj.get("mask_phone")) |mp| {
    if (mp == .bool) cfg.transform.mask_phone = mp.bool;
}
```

> Adjust naming to match the existing parser convention (e.g., it may use `naming_rule` field name directly on TaskConfig struct, or unpack to TransformConfig).

- [ ] **Step 3: Add a round-trip test**

```zig
test "TaskConfig JSON parses transform.mask_phone" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"transform":{"mask_phone":true,"commission":{"rate":0.05,"amount_field":"order_total"}}}
    , .{});
    defer parsed.deinit();

    var cfg = try TaskConfig.fromJson(a, parsed.value);
    defer cfg.deinit(a);
    try std.testing.expect(cfg.transform.mask_phone == true);
}
```

> Adapt to actual `TaskConfig.fromJson` signature and field path.

- [ ] **Step 4: Build and run**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test -- --test-filter "mask_phone"
zig fmt --check <modified files>
```

Expected: test passes.

- [ ] **Step 5: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add src/meta/task.zig  # or wherever the parser lives
git commit -m "feat(meta): TaskConfig JSON parses transform.mask_phone"
```

---

## Task 5: ai-recipes filter docs fix + mask_phone docs

**Files:**
- Modify: `docs/ai-recipes/recipes/order-sync.md`
- Modify: `docs/ai-recipes/recipes/user-sync.md`
- Modify: `docs/ai-recipes/reference/transform-overrides.md`
- Modify: `docs/ai-recipes/reference/sink-ddl.md`

- [ ] **Step 1: Fix `order-sync.md` filter doc**

Find the line "等 Phase 9 `transform.filter` 落地 (见 [dev.md](../../../dev.md) Phase 9)." Replace with:

```markdown
### 想加 update_time 过滤 (只同步已支付订单)

用 V1 已有的 `transform.filter_field` + `filter_op` + `filter_value`:

```json
{
  "transform": {
    "filter_field": "order_status",
    "filter_op": "gte",
    "filter_value": "1"
  }
}
```

`filter_op` 取值: `eq, ne, gt, gte, lt, lte`. 详见 [dev.md](../../../dev.md) "稳定性修复" section.
```
```

- [ ] **Step 2: Fix `user-sync.md` mask_phone doc**

Find the "Phase 9 简化版 (未来)" section. Replace the placeholder block with the real current behavior:

```markdown
## mask_phone 简写 (Phase 10 起)

新加 `transform.mask_phone: true` 自动识别 `phone` / `mobile` / `tel` 字段, 把 ≥ 7 位数字中间 4 位替换成 `****`:

```json
{
  "transform": {
    "mask_phone": true
  }
}
```

`phone = "13800138000"` → `phone = "138****8000"`.

非 phone 字段 (`user_id`, `register_time` 等) 不变. 与 `field_mappings_json` 不冲突 (override 优先).

完整 config_json:

```json
{
  "name": "user-sync-from-mall-001",
  "sync_mode": "both",
  "source": {"host":"...","port":3306,"user":"etl","password":"<encrypted>","db":"mall_001","table":"users","mall_id":"mall-001"},
  "target": {"host":"...","port":3306,"user":"etl","password":"<encrypted>","db":"central","table":"union_all_user"},
  "transform": {
    "mask_phone": true
  },
  "sink": {"on_conflict": "replace", "batch_size": 500}
}
```
```

Replace the old "完整 config_json" block too (the one using `field_mappings_json: "[{\"source\":\"phone\",\"target\":\"phone\",\"default\":\"****\"}]"`) with the new mask_phone version.

- [ ] **Step 3: Update `transform-overrides.md`**

Add a new section after the existing 6 examples:

```markdown
## 快捷开关

### `transform.mask_phone = true` (Phase 10 起)

替代手写 `field_mappings_json` 来脱敏手机号. 自动识别字段名包含 `phone` / `mobile` / `tel` 的列, 把 ≥ 7 位数字值的中间 4 位替换成 `****`.

```json
{
  "transform": {
    "mask_phone": true
  }
}
```

例: `phone = "13800138000"` → `"138****8000"`. 与 `field_mappings_json` 不冲突 (override 优先).
```

- [ ] **Step 4: Update `sink-ddl.md`**

Find "## 已知限制解除 (Phase 7b, 待实现)" and replace with:

```markdown
## Phase 7b: 自动 precision (Phase 10 起已实现)

`buildCreateTable` 现在从 `ColumnMeta.length` / `.precision` / `.scale` 生成精确 DDL:

- `VARCHAR(N)` 保留源长度 (不再强制 255)
- `DECIMAL(P,S)` 保留源 precision/scale (不再强制 18,4)
- `CHAR(N)` 保留源长度
- 没有 length/precision 的类型仍走默认 (255 / 18,4)

详见 [dev.md](../../../dev.md) Phase 7b section.
```

- [ ] **Step 5: Verify**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -rn "Phase 9 落地\|Phase 7b, 待实现\|Phase 9 待实现" docs/ai-recipes/
```

Expected: no matches (all outdated references replaced).

- [ ] **Step 6: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/
git commit -m "docs(ai-recipes): filter docs fix + mask_phone + Phase 7b implemented"
```

---

## Task 6: dev.md Phase 10 section + final verify

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Add Phase 10 section**

Find the end of Phase 9b section. Append:

```markdown
## Phase 10: Phase 7b precision + mask_phone

落地 ai-recipes 中两个标为"待实现"的功能, 让文档与代码 100% 对齐.

### Phase 7b: 自动 VARCHAR(N) / DECIMAL(P,S)

`ColumnMeta` 扩展为带 `length: ?u16` / `precision: ?u8` / `scale: ?u8`.

- `parseMySqlTypeString` 返回 `ParsedType` 结构体, 解析 `int(11)` / `varchar(64)` / `decimal(10,2)` 括号内的数字.
- `fetchSourceColumns` 把 length/precision/scale 填进 `ColumnMeta`.
- `mySqlTypeName` 接受 length/precision/scale 参数, 通过栈 `BoundedArray` 生成精确类型字符串.
- `buildCreateTable` 用真实长度/精度生成 DDL, 不再强制 `VARCHAR(255)`.

效果: 源 `order_no VARCHAR(32)` → 目标 `\`order_no\` VARCHAR(32)`, 不再退化为 `VARCHAR(255)`.

### `transform.mask_phone = true`

`TransformConfig.mask_phone: bool` 简写, 在 `process()` 中识别字段名含 `phone` / `mobile` / `tel` 的列, 把 ≥ 7 位数字值的中间 4 位替换成 `****`:

- `phone = "13800138000"` → `"138****8000"`
- 非 phone 字段 (`user_id`, `register_time`) 不变
- 与 `field_mappings_json` 不冲突 (override 优先)
- 字段名匹配是大小写敏感 (Phase 11 改成 case-insensitive)

### ai-recipes 文档修正

- `order-sync.md` filter 说明: 不再标"Phase 9 待实现", 给真实 `filter_field/filter_op/filter_value` JSON 例子
- `user-sync.md` mask_phone: 用 `transform.mask_phone = true` 替代 `field_mappings_json` 手工脱敏
- `transform-overrides.md`: 新增"快捷开关"section 解释 mask_phone
- `sink-ddl.md`: 删除"Phase 7b 待实现"section, 改为"已实现"说明
```

- [ ] **Step 2: Run all tests + format check**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/mapper.zig src/engine/runtime.zig src/sink/schema_ddl.zig src/transform/engine.zig
zig build test 2>&1 | tail -3
```

Expected: no leaked memory, all tests pass (213+ tests).

- [ ] **Step 3: Commit design/plan + dev.md**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add dev.md docs/superpowers/specs/2026-06-15-zetl-phase10-precision-mask-design.md docs/superpowers/plans/2026-06-15-zetl-phase10-precision-mask.md
git commit -m "docs: Phase 10 section + commit design/plan"
```

- [ ] **Step 4: Push + create PR**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git checkout -b feat/v10-precision-mask
git push -u origin feat/v10-precision-mask
gh pr create --title "V10 Phase 7b precision + mask_phone" --body "$(cat <<'EOF'
## Summary
- `ColumnMeta` 扩展 length/precision/scale, `buildCreateTable` 用真实 VARCHAR(N) / DECIMAL(P,S)
- `transform.mask_phone = true` 自动脱敏 phone/mobile/tel 字段
- ai-recipes 文档修正 (filter 已实现, mask_phone 已实现, Phase 7b 已实现)

## Test Plan
- [x] parseMySqlTypeString 解析 int/varchar/decimal/datetime (5 测试)
- [x] buildCreateTable 用 length/precision (2 测试)
- [x] maskPhoneIfNeeded 中间 4 位替换 (4 测试)
- [x] ai-recipes 无"待实现"标注
EOF
)"
```

- [ ] **Step 5: Squash-merge + cleanup**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
gh pr merge --squash --delete-branch
git checkout main
git pull --ff-only
git log --oneline -3
```

Report DONE.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - ColumnMeta extends length/precision/scale → Task 1 Step 1
  - parseMySqlTypeString returns ParsedType → Task 1 Step 2
  - 5 parseMySqlTypeString tests → Task 1 Step 4
  - mySqlTypeName accepts length/precision/scale + buildCreateTable uses them → Task 2 Steps 1-2
  - 2 buildCreateTable precision tests → Task 2 Step 4
  - fetchSourceColumns fills precision → Task 1 Step 3
  - TransformConfig.mask_phone + process mask → Task 3 Steps 1-3
  - 4 maskPhoneIfNeeded tests → Task 3 Step 4
  - TaskConfig JSON parse mask_phone → Task 4
  - ai-recipes filter docs fix → Task 5 Step 1
  - ai-recipes mask_phone docs → Task 5 Step 2
  - transform-overrides.md mask_phone shortcut → Task 5 Step 3
  - sink-ddl.md Phase 7b implemented → Task 5 Step 4
  - dev.md Phase 10 section → Task 6 Step 1
- [ ] **No placeholders:** all code blocks shown; `looksLikePhoneField` case-sensitive is documented as known limitation.
- [ ] **Type consistency:** `ColumnMeta.length: ?u16`, `precision: ?u8`, `scale: ?u8` consistent across mapper.zig, schema_ddl.zig, runtime.zig. `mask_phone: bool` consistent across engine.zig and TaskConfig.