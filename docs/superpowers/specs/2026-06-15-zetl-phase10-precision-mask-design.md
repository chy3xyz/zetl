# zetl Phase 10: Phase 7b 自动 precision + mask_phone 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V9b
- **前置版本**：V9b (Phase 9b ai-recipes + 内存泄漏修复)
- **状态**：待实现

---

## 0. 目标

落地 ai-recipes 中标注为 "待实现" 的 3 个特性:

1. **Phase 7b: 自动 precision/length** — 从 `SHOW COLUMNS` 解析 `VARCHAR(N)` / `DECIMAL(P,S)`, `buildCreateTable` 用真实长度/精度生成 DDL (不再是 `VARCHAR(255)` 兜底).
2. **transform.mask_phone = true** — `TransformConfig` 新增 boolean 简写, `process()` 自动识别 `phone` / `mobile` / `tel` 字段并脱敏为 `138****8000`.
3. **ai-recipes/order-sync.md filter 文档修正** — filter 功能实际上已在 V1 实现 (`filter_field` + `filter_op` + `filter_value`), ai-recipes 误标为 "Phase 9 待实现", 改为使用说明.

---

## 1. 不在本轮范围

- i18n / 英文翻译
- Phase 7c (BIT/ENUM/SET/GEOMETRY 支持)
- 复杂表达式引擎 (`mask_email`, `mask_id_card` 等任意函数)
- Web UI 增强

---

## 2. 架构与修改点

### 2.1 `src/transform/mapper.zig` — `ColumnMeta` 扩展

```zig
pub const ColumnMeta = struct {
    name: []const u8,
    /// MySQL 类型常量字节 (来自 protocol / SHOW COLUMNS 解析).
    type: u8 = 0,
    /// VARCHAR/CHAR 字符数 (来自 SHOW COLUMNS 的 `varchar(N)` 部分).
    length: ?u16 = null,
    /// DECIMAL precision (来自 SHOW COLUMNS 的 `decimal(P,S)` 部分).
    precision: ?u8 = null,
    /// DECIMAL scale (来自 SHOW COLUMNS 的 `decimal(P,S)` 部分).
    scale: ?u8 = null,
};
```

### 2.2 `src/engine/runtime.zig::parseMySqlTypeString` 改为返回结构体

新版本:

```zig
const ParsedType = struct {
    type_byte: u8,
    length: ?u16 = null,
    precision: ?u8 = null,
    scale: ?u8 = null,
};

fn parseMySqlTypeString(type_str: []const u8) ParsedType {
    // 解析 "int(11) unsigned" / "varchar(255)" / "decimal(10,2)" / "datetime"
    // 算法: 
    //   1. 切到 '(' 前的关键字
    //   2. 若有 '(...)': 括号内可能 "N" 或 "P,S"
    //   3. 把数字解析进 length / precision / scale
    // ...
}
```

保持 `0xff` (unknown) 行为不变 (由 schema_ddl 兜底 TEXT).

### 2.3 `src/sink/schema_ddl.zig::mySqlTypeName` 接受 precision/length 提示

```zig
fn mySqlTypeName(
    col_type: u8,
    length: ?u16,
    precision: ?u8,
    scale: ?u8,
) []const u8 {
    return switch (col_type) {
        0x0f => if (length) |n| ... format "VARCHAR({d})",
        0xf6 => if (precision and scale) |p, s| ... format "DECIMAL({d},{d})",
        // 其余同 Phase 7
        ...
    };
}
```

由于返回 string literal 不够灵活, 改为返回 `[]const u8` 由 caller 通过静态 `buf` 复用 (避免 alloc).

### 2.4 `src/sink/schema_ddl.zig::buildCreateTable` 接受新 ColumnMeta

调用 `mySqlTypeName(col.type, col.length, col.precision, col.scale)` 生成精确类型字符串.

### 2.5 `TransformConfig.mask_phone` 简写

```zig
pub const TransformConfig = struct {
    // ... 已有字段 ...
    mask_phone: bool = false,  // NEW
    // ... 已有字段 ...
};
```

### 2.6 `TransformEngine.process` 检测 phone 字段并脱敏

在 process() 主循环里, 当 `cfg.mask_phone == true` 且字段名匹配 `phone|mobile|tel` (case-insensitive), 且值是 ≥ 7 位数字字符串, 把中间 4 位替换成 `****`:

```zig
// 例: "13800138000" -> "138****8000"
```

字段匹配规则: 包含 `phone`, `mobile`, `tel` 任一子串的列名 (避免 false positive).

### 2.7 `SyncTask.fetchSourceColumns` 填 precision/length

```zig
const parsed = parseMySqlTypeString(type_str);
try list.append(self.allocator, .{
    .name = try self.allocator.dupe(u8, field_name),
    .type = parsed.type_byte,
    .length = parsed.length,
    .precision = parsed.precision,
    .scale = parsed.scale,
});
```

### 2.8 `TaskConfig` JSON 字段

`transform.mask_phone: bool` 加入 `TaskConfig` 的 JSON 解析 (在 `meta/task.zig`).

---

## 3. 数据流示例

### 3.1 Phase 7b: 自动 precision

源表:
```sql
CREATE TABLE orders (
  id           BIGINT        NOT NULL,
  order_no     VARCHAR(32)   NOT NULL,
  amount       DECIMAL(10,2) NOT NULL,
  product_name VARCHAR(255)  NOT NULL
);
```

`SHOW COLUMNS FROM orders` 返回:
```
Field        Type
id           bigint(20)
order_no     varchar(32)
amount       decimal(10,2)
product_name varchar(255)
```

`parseMySqlTypeString` 解析后:
- `bigint(20)` → `{ type_byte: 0x08, length: null, precision: null, scale: null }`
- `varchar(32)` → `{ type_byte: 0x0f, length: 32, ... }`
- `decimal(10,2)` → `{ type_byte: 0xf6, length: null, precision: 10, scale: 2 }`

`buildCreateTable` 生成:
```sql
CREATE TABLE IF NOT EXISTS `orders` (
    `id` BIGINT,
    `order_no` VARCHAR(32),
    `amount` DECIMAL(10,2),
    `product_name` VARCHAR(255)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

(对比 Phase 7: `order_no` 之前会是 `VARCHAR(255)`, 失去长度约束.)

### 3.2 mask_phone

config_json:
```json
{
  "transform": {
    "mask_phone": true
  }
}
```

源行: `phone = "13800138000"`, 目标: `phone = "138****8000"`.

字段匹配 (case-insensitive): `phone`, `mobile`, `tel`, `user_phone`, `mobile_no`, `telephone` 全部命中.

非手机号字段 (`user_id`, `register_time`) 不动.

---

## 4. 测试策略

### 4.1 `parseMySqlTypeString` 单元测试

- `"int(11)"` → `{ type_byte: 0x03, length: 11 }`
- `"int(11) unsigned"` → `{ type_byte: 0x03, length: 11 }`
- `"varchar(255)"` → `{ type_byte: 0x0f, length: 255 }`
- `"varchar(64)"` → `{ type_byte: 0x0f, length: 64 }`
- `"decimal(10,2)"` → `{ type_byte: 0xf6, precision: 10, scale: 2 }`
- `"datetime"` → `{ type_byte: 0x12, length: null }`
- `"json"` → `{ type_byte: 0xf5, length: null }`

### 4.2 `buildCreateTable` precision 测试

- cols 含 `VARCHAR(32)` → DDL 含 `VARCHAR(32)`, 不含 `VARCHAR(255)`
- cols 含 `DECIMAL(10,2)` → DDL 含 `DECIMAL(10,2)`, 不含 `DECIMAL(18,4)` (Phase 7 兜底)

### 4.3 `mask_phone` 测试

- `cfg.mask_phone = true`, 字段 `phone = "13800138000"` → 输出 `"138****8000"`
- `cfg.mask_phone = true`, 字段 `user_id = "12345"` → 不变
- `cfg.mask_phone = true`, 字段 `mobile = "12345"` (5 位) → 不变 (太短)
- `cfg.mask_phone = false`, 字段 `phone = "13800138000"` → 不变

### 4.4 ai-recipes/order-sync.md filter 修正

- 把"等 Phase 9 transform.filter 落地"改为实际使用 filter 的 JSON 例子.

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| `parseMySqlTypeString` 解析失败 (非法格式) | 返回 `length = null, precision = null`, 走默认值 (向后兼容) |
| `mySqlTypeName` 返回 dynamic string 需要 allocator | 用栈 buffer (`std.BoundedArray(u8, 32)`) 避免 alloc |
| `mask_phone` 误识别 | 只匹配 `phone` / `mobile` / `tel` 子串, 不支持任意正则 (Phase 11 扩展) |
| `mask_phone` 与 `field_mappings_json` 冲突 | `field_mappings_json` override 优先, mask_phone 仅作用于未 override 的字段 |
| ColumnMeta 字段扩展破坏 ABI | Zig struct 字段有默认值, 旧 call site 不会编译失败 |

---

## 6. 后续扩展 (Phase 11+)

- Phase 11: Phase 7c (BIT/ENUM/SET/GEOMETRY 支持)
- Phase 12: mask_email / mask_id_card (基于 `mask_phone` 抽象)
- Phase 13: 完整表达式引擎 (`transform.expression = "..."`)