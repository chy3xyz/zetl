# zetl Phase 11: 扩展 mask + 大小写不敏感 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend Phase 10's `mask_phone` with `mask_email` / `mask_id_card` / `mask_all` shortcuts and fix the case-sensitive field-name matching limitation documented in Phase 10.

**Architecture:** (1) Add 4 new bool fields to `TransformConfig`: `mask_email`, `mask_id_card`, `mask_all`, `case_insensitive_fields` (default true). (2) Refactor `maskPhoneIfNeeded` → `maskFieldIfNeeded` that dispatches to `MaskKind` (phone/email/id_card/none) based on the field name. (3) Implement `maskEmailValue` (replace local-part middle chars) and `maskIdCardValue` (mask middle 8 digits of 18-digit ID). (4) Parse the new JSON keys in `initFromJson`.

**Tech Stack:** Zig 0.17, std.ascii.lowerString for case-insensitive matching, std.fmt.allocPrint for masked output.

---

## File Structure

| File | Change |
|------|--------|
| `src/transform/engine.zig` | 4 new TransformConfig fields, 2 new mask functions, refactored dispatch, JSON parse, tests |
| `docs/ai-recipes/recipes/user-sync.md` | new mask_email / mask_id_card examples |
| `docs/ai-recipes/reference/transform-overrides.md` | new "快捷开关" entries for mask_email / mask_id_card / mask_all |
| `dev.md` | Phase 11 section |

---

## Task 1: `maskEmailValue` helper + tests

**Files:**
- Modify: `src/transform/engine.zig`

- [ ] **Step 1: Add failing tests**

Append to `src/transform/engine.zig`:

```zig
test "maskEmailValue masks local-part middle" {
    const a = std.testing.allocator;
    const masked = try maskEmailValue(a, "alice@example.com");
    try std.testing.expect(masked != null);
    defer a.free(masked.?);
    try std.testing.expectEqualStrings("a****@example.com", masked.?);
}

test "maskEmailValue masks long local-part correctly" {
    const a = std.testing.allocator;
    const masked = try maskEmailValue(a, "test.user@gmail.com");
    try std.testing.expect(masked != null);
    defer a.free(masked.?);
    try std.testing.expectEqualStrings("t********@gmail.com", masked.?);
}

test "maskEmailValue leaves short local alone" {
    const a = std.testing.allocator;
    try std.testing.expect((try maskEmailValue(a, "a@b.com")) == null);
    try std.testing.expect((try maskEmailValue(a, "ab@example.com")) == null);
}

test "maskEmailValue leaves non-email alone" {
    const a = std.testing.allocator;
    try std.testing.expect((try maskEmailValue(a, "not-an-email")) == null);
    try std.testing.expect((try maskEmailValue(a, "a@@b.com")) == null);
}
```

- [ ] **Step 2: Implement `maskEmailValue`**

Add a new helper function (near `maskPhoneIfNeeded`):

```zig
/// 邮箱脱敏: 切到 '@', local-part 中间字符替换为 '*'.
/// 例: "alice@example.com" -> "a****@example.com".
/// 条件: 恰好一个 '@', local 部分 > 2 字符. 不满足返回 null (不修改).
fn maskEmailValue(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return null;
    // 只接受恰好一个 '@'
    if (std.mem.indexOfScalarPos(u8, value, at + 1, '@') != null) return null;
    const local = value[0..at];
    const domain = value[at..];
    if (local.len <= 2) return null; // 短 local 不过度脱敏
    // local[0] + (local.len - 2) 个 '*' + local[last] + domain
    const stars: usize = local.len - 2;
    var buf: [256]u8 = undefined;
    if (local.len + stars + domain.len > buf.len) return null; // 过长 fallback
    const slice = try allocator.alloc(u8, local.len + stars + domain.len);
    @memcpy(slice[0..1], local[0..1]);
    for (0..stars) |i| slice[1 + i] = '*';
    @memcpy(slice[1 + stars .. 1 + stars + 1], local[local.len - 1 ..][0..1]);
    @memcpy(slice[1 + stars + 1 ..][0..domain.len], domain);
    _ = buf; // silence unused warning if any
    return slice;
}
```

- [ ] **Step 3: Build and run tests**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/engine.zig
zig build test -- --test-filter "maskEmail"
```

Expected: 4 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/transform/engine.zig
git commit -m "feat(transform): maskEmailValue local-part middle masking"
```

---

## Task 2: `maskIdCardValue` helper + tests

**Files:**
- Modify: `src/transform/engine.zig`

- [ ] **Step 1: Add failing tests**

```zig
test "maskIdCardValue masks middle 8 digits" {
    const a = std.testing.allocator;
    const masked = try maskIdCardValue(a, "110101199001011234");
    try std.testing.expect(masked != null);
    defer a.free(masked.?);
    try std.testing.expectEqualStrings("110101********1234", masked.?);
}

test "maskIdCardValue leaves 15-digit old IDs alone" {
    const a = std.testing.allocator;
    try std.testing.expect((try maskIdCardValue(a, "110101900101123")) == null);
}

test "maskIdCardValue leaves non-18-digit alone" {
    const a = std.testing.allocator;
    try std.testing.expect((try maskIdCardValue(a, "1234567890123456789")) == null); // 19 位
    try std.testing.expect((try maskIdCardValue(a, "")) == null);
}

test "maskIdCardValue leaves non-digits alone" {
    const a = std.testing.allocator;
    try std.testing.expect((try maskIdCardValue(a, "11010119900101123X")) == null);
}
```

- [ ] **Step 2: Implement `maskIdCardValue`**

```zig
/// 身份证号脱敏: 18 位数字 (中国二代证) 把第 7-14 位 (生日) 替换为 '*'.
/// 例: "110101199001011234" -> "110101********1234".
/// 非 18 位纯数字返回 null.
fn maskIdCardValue(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (value.len != 18) return null;
    if (!isAllDigits(value)) return null;
    // 前 6 位 + 8 个 '*' + 后 4 位 = 18 位
    var buf: [18]u8 = undefined;
    @memcpy(buf[0..6], value[0..6]);
    for (6..14) |i| buf[i] = '*';
    @memcpy(buf[14..18], value[14..18]);
    return allocator.dupe(u8, &buf);
}
```

- [ ] **Step 3: Build and run**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/engine.zig
zig build test -- --test-filter "maskIdCard"
```

Expected: 4 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/transform/engine.zig
git commit -m "feat(transform): maskIdCardValue 18-digit ID middle 8-digit masking"
```

---

## Task 3: Refactor dispatch — `detectMaskKind` + `maskFieldIfNeeded` + case-insensitive

**Files:**
- Modify: `src/transform/engine.zig`

- [ ] **Step 1: Add `MaskKind` enum and `detectMaskKind`**

```zig
const MaskKind = enum { phone, email, id_card, none };

/// 决定一个字段是否需要 mask + 用哪种 mask. 大小写不敏感由 cfg.case_insensitive_fields 控制 (默认 true).
fn detectMaskKind(field_name: []const u8, cfg: TransformConfig) MaskKind {
    const name = blk: {
        if (!cfg.case_insensitive_fields) break :blk field_name;
        var lower_buf: [256]u8 = undefined;
        const lower = std.ascii.lowerString(&lower_buf, field_name);
        break :blk lower;
    };
    const is_phone_enabled = cfg.mask_phone or cfg.mask_all;
    const is_email_enabled = cfg.mask_email or cfg.mask_all;
    const is_id_enabled = cfg.mask_id_card or cfg.mask_all;

    if (is_phone_enabled) {
        if (std.mem.indexOf(u8, name, "phone") != null) return .phone;
        if (std.mem.indexOf(u8, name, "mobile") != null) return .phone;
        if (std.mem.indexOf(u8, name, "tel") != null) return .phone;
    }
    if (is_email_enabled) {
        if (std.mem.indexOf(u8, name, "email") != null) return .email;
        if (std.mem.indexOf(u8, name, "mail") != null) return .email;
    }
    if (is_id_enabled) {
        if (std.mem.indexOf(u8, name, "id_card") != null) return .id_card;
        if (std.mem.indexOf(u8, name, "idcard") != null) return .id_card;
        if (std.mem.indexOf(u8, name, "id_no") != null) return .id_card;
        if (std.mem.indexOf(u8, name, "idnum") != null) return .id_card;
        if (std.mem.indexOf(u8, name, "identity") != null) return .id_card;
    }
    return .none;
}
```

- [ ] **Step 2: Add `maskFieldIfNeeded` dispatch helper**

```zig
/// Phase 11 unified mask dispatcher. 检测字段名 → 调对应 mask 函数.
fn maskFieldIfNeeded(allocator: std.mem.Allocator, field_name: []const u8, value: []const u8, cfg: TransformConfig) !?[]u8 {
    const kind = detectMaskKind(field_name, cfg);
    return switch (kind) {
        .phone => maskPhoneValue(allocator, value),
        .email => maskEmailValue(allocator, value),
        .id_card => maskIdCardValue(allocator, value),
        .none => null,
    };
}

/// Phase 10 内部用的 helper (原 maskPhoneIfNeeded).
fn maskPhoneValue(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (value.len < 7) return null;
    if (!isAllDigits(value)) return null;
    const prefix_len = (value.len - 4) / 2;
    const suffix_start = prefix_len + 4;
    return std.fmt.allocPrint(allocator, "{s}****{s}", .{ value[0..prefix_len], value[suffix_start..] });
}
```

> Note: the existing `maskPhoneIfNeeded` from Phase 10 should be renamed to `maskPhoneValue` and the cfg check moves up to `maskFieldIfNeeded`. If the existing code structure makes this rename awkward, keep the existing `maskPhoneIfNeeded` function and just add `maskFieldIfNeeded` on top that calls it after the kind check. Adapt the plan to actual code structure.

- [ ] **Step 3: Update `process()` to call `maskFieldIfNeeded` instead of `maskPhoneIfNeeded`**

Find the existing call site (added in Phase 10):

```zig
if (self.cfg.mask_phone) {
    // ... existing two-pass mask logic ...
}
```

Replace the inner call from `maskPhoneIfNeeded` to `maskFieldIfNeeded`. The two-pass logic over `target` HashMap stays; only the helper changes.

- [ ] **Step 4: Add tests for `detectMaskKind` + `maskFieldIfNeeded`**

```zig
test "detectMaskKind matches phone case-insensitively" {
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_phone = true };
    try std.testing.expectEqual(MaskKind.phone, detectMaskKind("Phone", cfg));
    try std.testing.expectEqual(MaskKind.phone, detectMaskKind("PHONE", cfg));
    try std.testing.expectEqual(MaskKind.phone, detectMaskKind("mobile_NO", cfg));
    try std.testing.expectEqual(MaskKind.none, detectMaskKind("user_id", cfg));
}

test "detectMaskKind matches email" {
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_email = true };
    try std.testing.expectEqual(MaskKind.email, detectMaskKind("email", cfg));
    try std.testing.expectEqual(MaskKind.email, detectMaskKind("USER_EMAIL", cfg));
}

test "detectMaskKind matches id_card" {
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_id_card = true };
    try std.testing.expectEqual(MaskKind.id_card, detectMaskKind("id_card", cfg));
    try std.testing.expectEqual(MaskKind.id_card, detectMaskKind("IDCardNo", cfg));
    try std.testing.expectEqual(MaskKind.none, detectMaskKind("user_id", cfg)); // 避免误命中
}

test "mask_all enables all three kinds" {
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_all = true };
    try std.testing.expectEqual(MaskKind.phone, detectMaskKind("phone", cfg));
    try std.testing.expectEqual(MaskKind.email, detectMaskKind("email", cfg));
    try std.testing.expectEqual(MaskKind.id_card, detectMaskKind("id_card", cfg));
}

test "case_insensitive_fields=false reverts to case-sensitive" {
    const cfg: TransformConfig = .{ .mall_id = "m", .source_type = "t", .mask_phone = true, .case_insensitive_fields = false };
    try std.testing.expectEqual(MaskKind.phone, detectMaskKind("phone", cfg));
    try std.testing.expectEqual(MaskKind.none, detectMaskKind("Phone", cfg));
}
```

- [ ] **Step 5: Build and run**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/engine.zig
zig build test -- --test-filter "detectMaskKind\|maskFieldIfNeeded\|maskIdCard\|maskEmail"
```

Expected: all old maskPhone tests still pass + new tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/transform/engine.zig
git commit -m "feat(transform): detectMaskKind + maskFieldIfNeeded dispatch + case-insensitive field matching"
```

---

## Task 4: TransformConfig 4 new fields + JSON parse + tests

**Files:**
- Modify: `src/transform/engine.zig`

- [ ] **Step 1: Add 4 new fields to TransformConfig**

```zig
pub const TransformConfig = struct {
    // ... existing ...
    mask_phone: bool = false,
    /// Phase 11: 自动脱敏 email 字段 (u***@example.com).
    mask_email: bool = false,
    /// Phase 11: 自动脱敏 18 位身份证号 (110101********1234).
    mask_id_card: bool = false,
    /// Phase 11: 等价于 mask_phone + mask_email + mask_id_card 全开.
    mask_all: bool = false,
    /// Phase 11: 字段名匹配是否忽略大小写. 默认 true.
    case_insensitive_fields: bool = true,
    // ... existing ...
};
```

- [ ] **Step 2: Parse new JSON keys in `initFromJson`**

Find the existing `if (transform.get("mask_phone")) |mp| ...` block (added in Phase 10 Task 4) and add after it:

```zig
if (transform.get("mask_email")) |v| {
    if (v == .bool) cfg.mask_email = v.bool;
}
if (transform.get("mask_id_card")) |v| {
    if (v == .bool) cfg.mask_id_card = v.bool;
}
if (transform.get("mask_all")) |v| {
    if (v == .bool) cfg.mask_all = v.bool;
}
if (transform.get("case_insensitive_fields")) |v| {
    if (v == .bool) cfg.case_insensitive_fields = v.bool;
}
```

- [ ] **Step 3: Add JSON parse tests**

```zig
test "TransformConfig parses transform.mask_email from json" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"transform":{"mask_email":true}}
    , .{});
    defer parsed.deinit();

    const cfg = try TransformConfig.initFromJson(a, parsed.value);
    defer cfg.deinit(a);
    try std.testing.expect(cfg.mask_email == true);
    try std.testing.expect(cfg.mask_phone == false);
}

test "TransformConfig parses transform.mask_id_card from json" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"transform":{"mask_id_card":true}}
    , .{});
    defer parsed.deinit();

    const cfg = try TransformConfig.initFromJson(a, parsed.value);
    defer cfg.deinit(a);
    try std.testing.expect(cfg.mask_id_card == true);
}

test "TransformConfig parses transform.mask_all from json" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"transform":{"mask_all":true}}
    , .{});
    defer parsed.deinit();

    const cfg = try TransformConfig.initFromJson(a, parsed.value);
    defer cfg.deinit(a);
    try std.testing.expect(cfg.mask_all == true);
    // mask_all 应等价于启用 phone/email/id_card
    try std.testing.expectEqual(MaskKind.phone, detectMaskKind("phone", cfg));
    try std.testing.expectEqual(MaskKind.email, detectMaskKind("email", cfg));
    try std.testing.expectEqual(MaskKind.id_card, detectMaskKind("id_card", cfg));
}

test "TransformConfig case_insensitive_fields defaults to true" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"transform":{}}
    , .{});
    defer parsed.deinit();

    const cfg = try TransformConfig.initFromJson(a, parsed.value);
    defer cfg.deinit(a);
    try std.testing.expect(cfg.case_insensitive_fields == true);
}
```

- [ ] **Step 4: Build and run**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/engine.zig
zig build test -- --test-filter "parses transform.mask\|case_insensitive_fields defaults"
```

Expected: 4 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/transform/engine.zig
git commit -m "feat(transform): TransformConfig mask_email/mask_id_card/mask_all/case_insensitive_fields + JSON parse"
```

---

## Task 5: ai-recipes + dev.md + final verify

**Files:**
- Modify: `docs/ai-recipes/recipes/user-sync.md`
- Modify: `docs/ai-recipes/reference/transform-overrides.md`
- Modify: `dev.md`

- [ ] **Step 1: Update `user-sync.md` with new mask examples**

Find the "## mask_phone 简写 (Phase 10 起)" section in `user-sync.md`. Replace it with an extended section that includes email and id_card:

```markdown
## mask 快捷开关 (Phase 10/11)

支持 4 种 mask:

- `transform.mask_phone = true` — 脱敏 phone/mobile/tel 字段 (中间 4 位换 `****`)
- `transform.mask_email = true` — 脱敏 email 字段 (local-part 中间换 `*`)
- `transform.mask_id_card = true` — 脱敏 id_card/idcard/id_no/identity 字段 (中间 8 位换 `*`)
- `transform.mask_all = true` — 等价于上面 3 个全开

### 字段匹配规则

- 默认大小写不敏感 (`case_insensitive_fields: true`): `Phone` / `PHONE` / `phone` 都命中
- 字段名匹配是子串 (含 `phone` / `mobile` / `tel` 等关键词)
- id_card 不会误命中 `user_id` (要求 `id_card` / `idcard` / `id_no` / `idnum` / `identity` 子串)

### 完整 user-sync config_json (含 mask_all)

```json
{
  "name": "user-sync-from-mall-001",
  "sync_mode": "both",
  "source": {
    "host": "polar-001.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "users",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "union_all_user"
  },
  "transform": {
    "mask_all": true
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 500
  }
}
```

`phone = "13800138000"` → `"138****8000"`, `email = "alice@example.com"` → `"a****@example.com"`, `id_card = "110101199001011234"` → `"110101********1234"`.
```

- [ ] **Step 2: Update `transform-overrides.md` with new shortcuts**

Find the existing "## 快捷开关" section (added in Phase 10). Append to it:

```markdown
### `transform.mask_email = true` (Phase 11 起)

脱敏 email 字段 (`u***@example.com`). 自动识别字段名含 `email` / `mail` 的列.

```json
{"transform": {"mask_email": true}}
```

例: `email = "alice@example.com"` → `"a****@example.com"`. local-part ≤ 2 字符不变 (避免过度脱敏).

### `transform.mask_id_card = true` (Phase 11 起)

脱敏 18 位身份证号 (前 6 + `********` + 后 4). 自动识别字段名含 `id_card` / `idcard` / `id_no` / `idnum` / `identity` 的列 (避免误命中 `user_id`).

```json
{"transform": {"mask_id_card": true}}
```

例: `id_card = "110101199001011234"` → `"110101********1234"`. 非 18 位纯数字不变.

### `transform.mask_all = true` (Phase 11 起)

等价于同时启用 `mask_phone` / `mask_email` / `mask_id_card`. 适合"先全部脱敏, 再 field_mappings_json 还原部分字段"的场景.

```json
{"transform": {"mask_all": true}}
```
```

- [ ] **Step 3: Add Phase 11 section to dev.md**

Append after the Phase 10 section:

```markdown
## Phase 11: 扩展 mask + 大小写不敏感

扩展 Phase 10 的 mask 机制, 覆盖 email 和身份证号, 修复 case-sensitive 限制.

### 新增 mask 类型

- `transform.mask_email = true` — 邮箱字段脱敏 (`alice@example.com` → `a****@example.com`).
  - 切到 `@`, local-part 中间字符换 `*`. local ≤ 2 字符不变 (避免过度脱敏).
  - 仅识别字段名含 `email` / `mail` 的列.
- `transform.mask_id_card = true` — 18 位身份证号脱敏 (`110101199001011234` → `110101********1234`).
  - 仅识别字段名含 `id_card` / `idcard` / `id_no` / `idnum` / `identity` 的列 (不命中 `user_id`).
  - 非 18 位纯数字不变.

### 简写开关

- `transform.mask_all = true` — 等价于 `mask_phone + mask_email + mask_id_card` 全开.

### 大小写不敏感

- 新增 `case_insensitive_fields: bool = true` (默认 true) 控制字段名匹配是否忽略大小写.
- `Phone` / `PHONE` / `phone` 都命中 phone mask.
- 设 `false` 可恢复 Phase 10 的 case-sensitive 行为.

### dispatch 重构

`maskPhoneIfNeeded` 重构为 `maskFieldIfNeeded` + `detectMaskKind` enum dispatch.
```

- [ ] **Step 4: Run all tests + format check**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/transform/engine.zig
find .zig-cache -name "test" -type f | xargs ls -lt | head -1 | awk '{print $NF}' | xargs -I{} "{} 2>&1 | tail -3"
```

Expected: `All NNN tests passed.` (where NNN ≥ 224 + 13 new = 237). No leaked memory.

- [ ] **Step 5: Commit design/plan + dev.md + ai-recipes**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add dev.md docs/ai-recipes/ docs/superpowers/specs/2026-06-15-zetl-phase11-extended-mask-design.md docs/superpowers/plans/2026-06-15-zetl-phase11-extended-mask.md
git commit -m "docs: Phase 11 section + ai-recipes + commit design/plan"
```

- [ ] **Step 6: Push + create PR**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git checkout -b feat/v11-extended-mask
git push -u origin feat/v11-extended-mask
gh pr create --title "V11 extended mask + case-insensitive" --body "$(cat <<'EOF'
## Summary
- mask_email (alice@example.com → a****@example.com)
- mask_id_card (18 位身份证 → 中间 8 位 ****** )
- mask_all 简写 (等价于上面 3 个全开)
- case_insensitive_fields (默认 true, 解决 Phase 10 known limitation)

## Test Plan
- [x] maskEmailValue 4 测试 (正常/短 local/无 @/多个 @)
- [x] maskIdCardValue 4 测试 (18 位/15 位/19 位/含字母)
- [x] detectMaskKind 5 测试 (phone/email/id_card + 大小写 + case_insensitive_fields=false)
- [x] TransformConfig JSON 4 测试 (mask_email/mask_id_card/mask_all/case_insensitive_fields)
- [x] ai-recipes 无"待实现"标注
- [x] zig fmt --check clean
EOF
)"
```

- [ ] **Step 7: Squash-merge + cleanup**

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
  - mask_email helper + 4 tests → Task 1
  - mask_id_card helper + 4 tests → Task 2
  - MaskKind enum + detectMaskKind → Task 3 Step 1
  - maskFieldIfNeeded dispatch + case-insensitive via std.ascii.lowerString → Task 3 Step 2
  - process() uses maskFieldIfNeeded → Task 3 Step 3
  - 5 detectMaskKind tests (phone/email/id_card/case-insensitive toggle) → Task 3 Step 4
  - 4 TransformConfig JSON parse tests → Task 4 Step 3
  - ai-recipes updates → Task 5 Steps 1-2
  - dev.md Phase 11 → Task 5 Step 3
- [ ] **No placeholders:** all code shown; Phase 10's `maskPhoneIfNeeded` rename may need adaptation based on existing code structure.
- [ ] **Type consistency:** `MaskKind` enum, `maskFieldIfNeeded(... cfg: TransformConfig)`, `TransformConfig.{mask_email, mask_id_card, mask_all, case_insensitive_fields: bool}` consistent across all tasks.