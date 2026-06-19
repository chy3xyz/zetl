# zetl Phase 6b: 列名重命名规则 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3 + V6
- **前置版本**：V6 transform automation（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

在 Phase 6 的 identity + override 之上，新增 **列名转换规则**，让用户配置 source 列名到 target 列名的自动转换，无需手写每条映射。

支持的规则：
- `Identity`（默认，已实现）：`order_id` → `order_id`
- `CamelToSnake`：`orderId` → `order_id`
- `SnakeToCamel`：`order_id` → `orderId`
- `Upper`：`order_id` → `ORDER_ID`
- `Lower`：`OrderId` → `orderid`
- `AddPrefix(prefix)`：`id` → `dt_id`
- `StripPrefix(prefix)`：`dt_order_id` → `order_id`

---

## 1. 不在本轮范围

- 正则替换（如 `s/_tmp$//`）—— 后续 Phase 6c
- 链式规则（如 `Lower + AddPrefix`）—— 用户 override 可替代
- 自定义函数/回调

---

## 2. 架构与修改点

### 2.1 `src/transform/mapper.zig`

新增 `NamingRule` 枚举 + `applyNamingRule` 函数：

```zig
pub const NamingRule = union(enum) {
    identity,
    camel_to_snake,
    snake_to_camel,
    upper,
    lower,
    add_prefix: []const u8,
    strip_prefix: []const u8,
};

/// 把一个 source 列名按规则转成 target 列名.
/// 调用方负责 prefix slice 生命周期 (建议长期存储).
pub fn applyNamingRule(rule: NamingRule, source: []const u8, allocator: std.mem.Allocator) ![]const u8;
```

`applyNamingRule` 实现：
- `identity`: 复制 source。
- `camel_to_snake`: 在大写字母前插入 `_`，全转小写。
- `snake_to_camel`: 把 `_x` 转 `X`。
- `upper` / `lower`: 全转换。
- `add_prefix(prefix)`: 复制 `prefix + source`。
- `strip_prefix(prefix)`: 如果 source 以 prefix 开头, 去掉 prefix; 否则返回 source 原样。

### 2.2 修改 `Mapper.fromSchema`

`Mapper.fromSchema` 接受可选 `rule: ?NamingRule` 参数。默认 identity 行为不变；如果提供 rule，则 `target = applyNamingRule(rule, source, allocator)`。

### 2.3 修改 `TransformConfig` (在 `src/transform/engine.zig`)

新增 `naming_rule: ?mapper.NamingRule = null` 字段。

### 2.4 修改 `TransformEngine.initWithSchema`

`initWithSchema` 接受 `naming_rule` 参数。如果提供，传给 `Mapper.fromSchema`。

### 2.5 修改 `TransformConfig` JSON 解析

`field_mappings_json` 现在支持扩展字段：

```json
{
  "transform": {
    "type": "passthrough",
    "naming_rule": "camel_to_snake"
  }
}
```

或者 add_prefix 形式：

```json
{
  "transform": {
    "type": "passthrough",
    "naming_rule": { "type": "add_prefix", "value": "dt_" }
  }
}
```

`TransformConfig.initFromJson` 解析 `naming_rule` 字符串（identity / camel_to_snake / snake_to_camel / upper / lower）或带 value 的对象（add_prefix / strip_prefix）。

### 2.6 `SyncTask.init` 读取 `naming_rule`

`TaskConfig.config_json` 中的 `transform.naming_rule` 字段被解析并传给 `TransformEngine.initWithSchema`。

---

## 3. 数据流示例

源库 `Order` 表（camelCase 列名）：
```
orderId  INT
paidAt   DATETIME
```

任务配置：

```json
{
  "source_db": "primary",
  "source_table": "Order",
  "target_table": "order",
  "sync_mode": 1,
  "config_json": "{\"transform\":{\"type\":\"passthrough\",\"naming_rule\":\"camel_to_snake\"}}"
}
```

`SyncTask.init` 启动：
1. `fetchSourceColumns` → `[{name:"orderId",type:0x03}, {name:"paidAt",type:0x0c}]`
2. `TransformEngine.initWithSchema(rule=camel_to_snake)` 
3. `Mapper.fromSchema` 用 `applyNamingRule(camel_to_snake, "orderId")` → `target="order_id"`

输出映射：
```
orderId  → order_id
paidAt   → paid_at
```

用户也可以用 add_prefix：

```json
"naming_rule": { "type": "add_prefix", "value": "dt_" }
```

```
orderId → dt_orderId
```

---

## 4. 测试策略

### 4.1 `applyNamingRule` 单元测试

- `identity("order_id")` = `"order_id"`
- `camel_to_snake("orderId")` = `"order_id"`
- `camel_to_snake("userID")` = `"user_i_d"`（注意：连续大写字母边界处理）
- `snake_to_camel("order_id")` = `"orderId"`
- `upper("foo")` = `"FOO"`
- `lower("FOO")` = `"foo"`
- `add_prefix("dt_", "id")` = `"dt_id"`
- `strip_prefix("dt_", "dt_id")` = `"id"`
- `strip_prefix("dt_", "id")` = `"id"`（不匹配，返回原样）

### 4.2 `Mapper.fromSchema` 集成测试

- `fromSchema` with `rule=camel_to_snake` 生成 snake_case mappings。
- `fromSchema` with `rule=identity`（默认）保持原行为。

### 4.3 `TransformConfig` JSON 解析

- 字符串 `"camel_to_snake"` → `naming_rule = .camel_to_snake`
- 对象 `{type:"add_prefix",value:"dt_"}` → `naming_rule = .add_prefix("dt_")`
- 缺失字段 → `null`

### 4.4 集成测试

- `SyncTask` 启动时 naming_rule 从 `TaskConfig.config_json` 解析并传递。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| 连续大写字母边界（如 `userID`） | 在第一个大写前插 `_`，简单规则覆盖 90% 场景 |
| 命名规则导致列名冲突 | 用户 override 可手动指定 |
| 用户配置 naming_rule 但同时提供完整 mappings | mappings 优先级 > 自动命名（已实现于 Phase 6 mergeOverrides） |
| add_prefix 的 prefix 包含非法字符（如空格） | 不校验，留给下游 MySQL DDL 报错 |

---

## 6. 后续扩展

- **Phase 6c**：正则替换 + 链式规则
- **Phase 6d**：表名转换规则（与列名独立）
- **Phase 6e**：运行时切换规则