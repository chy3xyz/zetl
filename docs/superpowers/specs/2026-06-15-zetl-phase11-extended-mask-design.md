# zetl Phase 11: 扩展 mask + 大小写不敏感 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V10
- **前置版本**：V10 (Phase 10: mask_phone + Phase 7b precision)
- **状态**：待实现

---

## 0. 目标

扩展 Phase 10 的 mask 机制, 覆盖更多客户数据脱敏场景:

1. **mask_email** — 邮箱字段脱敏 (`user@example.com` → `u***@example.com`)
2. **mask_id_card** — 身份证字段脱敏 (`110101199001011234` → `110101********1234`)
3. **大小写不敏感字段匹配** — 解决 Phase 10 文档中标注的 known limitation: `Phone` / `MOBILE` / `Tel` 之前不命中, 现在统一不敏感匹配
4. **`mask_all` 总开关** — 等价于 `mask_phone + mask_email + mask_id_card`

---

## 1. 不在本轮范围

- Phase 7c (BIT/ENUM/SET/GEOMETRY type 支持) — 低频, 推迟到 Phase 13
- 自定义正则 mask (`transform.mask_pattern = [{field_pattern: "...", mask: "..."}]`) — Phase 12
- 表达式引擎 (`transform.expression`) — Phase 12
- ai-recipes 英文翻译 — Phase 14

---

## 2. 架构与修改点

### 2.1 `TransformConfig` 新字段

```zig
pub const TransformConfig = struct {
    // ... 现有字段 ...
    mask_phone: bool = false,   // Phase 10
    mask_email: bool = false,   // NEW
    mask_id_card: bool = false, // NEW
    mask_all: bool = false,     // NEW: 等价于上面 3 个全开
    case_insensitive_fields: bool = true, // NEW: 默认 true, 字段名匹配忽略大小写
};
```

`mask_all = true` 时 process() 自动启用 phone/email/id_card 全部 mask.

### 2.2 `looksLikePhoneField` → `looksLikeMaskField` 通用化

把单一的 phone 检测重构成 "what kind of mask applies":

```zig
const MaskKind = enum { phone, email, id_card, none };

fn detectMaskKind(field_name: []const u8, cfg: TransformConfig, case_insensitive: bool) MaskKind {
    const haystack = if (case_insensitive) toLower(field_name) else field_name;
    // phone keywords: phone, mobile, tel
    // email keywords: email, mail
    // id_card keywords: id_card, idcard, id_no, idnum, identity
    if (cfg.mask_phone or cfg.mask_all) {
        if (containsAny(haystack, &.{"phone", "mobile", "tel"})) return .phone;
    }
    if (cfg.mask_email or cfg.mask_all) {
        if (containsAny(haystack, &.{"email", "mail"})) return .email;
    }
    if (cfg.mask_id_card or cfg.mask_all) {
        if (containsAny(haystack, &.{"id_card", "idcard", "id_no", "idnum", "identity"})) return .id_card;
    }
    return .none;
}
```

### 2.3 3 个 mask 函数

```zig
fn maskPhoneValue(allocator, value) !?[]u8 { ... }      // 已存在
fn maskEmailValue(allocator, value) !?[]u8 { ... }     // NEW: "a***@domain.com"
fn maskIdCardValue(allocator, value) !?[]u8 { ... }    // NEW: "110101********1234"
```

email 规则:
- 含 `@` 才处理
- 切到 `@`: local / `@` / domain
- local 第 2 位到倒数 1 位替换为 `*` (e.g., `alice@example.com` → `a****@example.com`)
- local ≤ 2 字符不处理 (避免过度脱敏)

id_card 规则:
- 中国二代身份证 18 位 (前 6 位地区 + 8 位生日 + 3 位顺序 + 1 位校验)
- 规则: 第 7-14 位 (生日) 替换为 `********`
- 非 18 位数字不处理

### 2.4 `maskPhoneIfNeeded` 重构为 `maskFieldIfNeeded`

合并 dispatch:

```zig
fn maskFieldIfNeeded(allocator, field_name, value, cfg, case_insensitive) !?[]u8 {
    const kind = detectMaskKind(field_name, cfg, case_insensitive);
    return switch (kind) {
        .phone => maskPhoneValue(allocator, value),
        .email => maskEmailValue(allocator, value),
        .id_card => maskIdCardValue(allocator, value),
        .none => null,
    };
}
```

### 2.5 `process()` 调用

process() 现在调 `maskFieldIfNeeded` 代替 `maskPhoneIfNeeded`, 把 `cfg.case_insensitive_fields` 传进去.

### 2.6 JSON 解析

`TransformConfig.initFromJson` 加 4 个新字段:

```zig
if (transform.get("mask_email")) |v| if (v == .bool) cfg.mask_email = v.bool;
if (transform.get("mask_id_card")) |v| if (v == .bool) cfg.mask_id_card = v.bool;
if (transform.get("mask_all")) |v| if (v == .bool) cfg.mask_all = v.bool;
if (transform.get("case_insensitive_fields")) |v| if (v == .bool) cfg.case_insensitive_fields = v.bool;
```

---

## 3. 数据流示例

### 3.1 email 脱敏

源 `user@example.com` → 目标 `u***@example.com`.

| input | output |
|-------|--------|
| `alice@example.com` | `a****@example.com` |
| `a@b.com` | `a@b.com` (local ≤ 2 字符) |
| `test.user@gmail.com` | `t********@gmail.com` |
| `not-an-email` | 不变 (不含 @) |

### 3.2 id_card 脱敏

源 `110101199001011234` → 目标 `110101********1234`.

| input | output |
|-------|--------|
| `110101199001011234` | `110101********1234` |
| `110101900101123` (15 位) | 不变 (非 18 位) |
| `abc1234567890123456` | 不变 (非纯数字) |
| `1234567890123456789` (19 位) | 不变 |

### 3.3 case-insensitive 字段匹配

```json
{"transform": {"mask_phone": true, "mask_email": true}}
```

| field name | value | output |
|------------|-------|--------|
| `phone` | `13800138000` | `138****8000` |
| `Phone` | `13800138000` | `138****8000` |
| `PHONE` | `13800138000` | `138****8000` |
| `mobile_NO` | `13800138000` | `138****8000` |
| `UserEmail` | `a@b.com` | `a@b.com` (≤ 2 chars local) |
| `EMAIL_ADDR` | `alice@example.com` | `a****@example.com` |

### 3.4 mask_all 简写

```json
{"transform": {"mask_all": true}}
```

等价于:

```json
{"transform": {"mask_phone": true, "mask_email": true, "mask_id_card": true}}
```

---

## 4. 测试策略

### 4.1 `maskEmailValue` 单元测试

- 正常 email → 中间替换
- 短 local (≤ 2) → 不变
- 无 @ → 不变
- 含多个 @ → 不变 (取第一个? Phase 11: 不处理, 不变)
- 大小写邮箱 (`Alice@Example.COM`) → 处理 (域名部分保留大小写)

### 4.2 `maskIdCardValue` 单元测试

- 18 位数字 → 中间 8 位替换
- 15 位 (旧版身份证) → 不变
- 19 位 → 不变
- 18 位含字母 → 不变

### 4.3 case-insensitive 集成测试

- `Phone` / `PHONE` / `phone` 都命中 phone mask
- `Email` / `EMAIL_ADDR` 都命中 email mask
- `IdCard` / `ID_CARD` 都命中 id_card mask

### 4.4 JSON 解析测试

- `mask_email: true` 解析到 cfg.mask_email
- `mask_id_card: true` 解析到 cfg.mask_id_card
- `mask_all: true` 解析到 cfg.mask_all
- `case_insensitive_fields: false` 解析到 cfg.case_insensitive_fields (默认 true)

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| email mask 把短 local 过度脱敏 | local ≤ 2 字符不处理 |
| id_card 检测误判 (其他 18 位数字字段) | 仅匹配 `id_card` / `idcard` / `id_no` / `idnum` / `identity` 子串, 不匹配纯 `id` (避免命中 `user_id` 等) |
| 大小写转换堆分配浪费 | 用 `std.ascii.lowerString(buf, name)` 栈 buffer (256 字节够) |
| `mask_all` 与 `mask_phone` 同时为 true 重复工作 | dispatch 一次, 不会重复 |
| Phase 10 测试用例破坏 (Phase 11 改了字段匹配逻辑) | `case_insensitive_fields` 默认 true 但仍兼容旧 case-sensitive 行为, Phase 10 测试用 lowercase 列名不受影响 |

---

## 6. 后续扩展 (Phase 12+)

- Phase 12: 自定义正则 mask (`transform.mask_pattern = [...]`)
- Phase 13: 表达式引擎 (`transform.expression = "..."`)
- Phase 14: ai-recipes 英文版
- Phase 15: Phase 7c (BIT/ENUM/SET/GEOMETRY)