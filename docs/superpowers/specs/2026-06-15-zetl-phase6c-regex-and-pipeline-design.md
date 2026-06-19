# zetl Phase 6c: 正则替换 + 链式规则 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V6b
- **前置版本**：V6b naming rules（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

扩展 `NamingRule`，增加两类新规则：

1. **`regex_replace`**：基于 std.Regex 的字符串替换（常用场景：去 `_tmp` 后缀、统一前缀、清理测试遗留）。
2. **链式规则（pipeline）**：把多个规则串联应用，例如 `camel_to_snake → add_prefix("dt_")`。

设计要点：
- 复用一个 `[]NamingRule` 数组作为链式规则；用户可在 JSON 直接传 array（每项是规则）。
- JSON 简写：`"naming_rule": [...]` 表示数组，pipeline 是数组的语义别名。
- 复用 Phase 6b 的 `applyNamingRule` 入口，扩展 union 变体。

---

## 1. 不在本轮范围

- 自定义 Lua/JS 函数（保持纯 Zig）
- 跨表名转换（Phase 6d）
- 运行时切换规则
- 规则版本控制

---

## 2. 架构与修改点

### 2.1 `src/transform/mapper.zig` — 扩展 `NamingRule`

新增变体：

```zig
pub const NamingRule = union(enum) {
    // 已有 (Phase 6b)
    identity,
    camel_to_snake,
    snake_to_camel,
    upper,
    lower,
    add_prefix: []const u8,
    strip_prefix: []const u8,
    // 新增 (Phase 6c)
    regex_replace: RegexReplace,
    // pipeline: 数组形式, JSON 顶层传数组就视作 pipeline
    // 不新增 variant, 直接用 []NamingRule 表示
};

pub const RegexReplace = struct {
    pattern: []const u8,    // 正则 pattern (allocator-owned)
    replacement: []const u8, // 替换字符串 (allocator-owned, 支持 $1 / $2 等 backref)
};
```

### 2.2 `applyNamingRule` 新增 regex 分支

```zig
.regex_replace => |rr| regexReplace(allocator, source, rr),
```

`regexReplace` 用 `std.Regex.compile(allocator, rr.pattern)`，然后 `regex.replace(source, rr.replacement)`。

### 2.3 新增 `applyNamingPipeline`

```zig
/// 把多个规则顺序应用到 source 列名.
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

### 2.4 `Mapper.fromSchema` 支持 pipeline

新增 overload `fromSchemaWithPipeline`：

```zig
/// 用 pipeline (数组) 规则生成 mappings. 与 fromSchema(columns, rule) 类似但接受数组.
pub fn fromSchemaWithPipeline(
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
            .target = try applyNamingPipeline(rules, col.name, allocator),
        };
    }
    return Mapper{ .allocator = allocator, .mappings = mappings };
}
```

或保留单一 `fromSchema` 签名，把 `?NamingRule` 改成接受 `[]const NamingRule`（默认空数组 = identity）。

设计决定：**保留单一 `fromSchema`，把签名改成 `[]const NamingRule`**，默认空数组 = identity（与 Phase 6b 的 `null = identity` 等价）。

```zig
pub fn fromSchema(
    allocator: std.mem.Allocator,
    columns: []const ColumnMeta,
    rules: []const NamingRule,
) !Mapper {
    if (rules.len == 0) {
        // 与 Phase 6b identity 行为一致: target = source.
        return fromSchemaIdentity(allocator, columns);
    }
    // 否则逐列走 pipeline
    ...
}
```

### 2.5 `TransformConfig.naming_rules: []const NamingRule`

替换 `naming_rule: ?NamingRule`。`naming_rule_json` 字段保留为 JSON 字符串（向后兼容），新增 `parseNamingRulesFromJson` 解析为 `[]NamingRule`。

```zig
naming_rule: ?mapper_mod.NamingRule = null,        // Phase 6b 单规则 (兼容)
naming_rules_json: ?[]const u8 = null,             // Phase 6c JSON 字符串
```

`init` 解析 `naming_rules_json` 为 `[]NamingRule`；`initWithSchema` 优先使用 `naming_rules` (切片)，fallback 到 `naming_rule` 单个。

### 2.6 `parseNamingRule` 扩展

支持新对象格式：

```json
{"type": "regex_replace", "pattern": "_tmp$", "replacement": ""}
```

`regex_replace` 的 pattern 和 replacement slice 由 allocator 拥有；`TransformConfig.deinit` 释放。

### 2.7 JSON 数组形式

`config_json.transform.naming_rules` 可以是数组：

```json
{
  "transform": {
    "naming_rules": [
      {"type": "camel_to_snake"},
      {"type": "regex_replace", "pattern": "_tmp$", "replacement": ""},
      {"type": "add_prefix", "value": "dt_"}
    ]
  }
}
```

每项解析成 `NamingRule`，整个数组传给 `applyNamingPipeline`。

### 2.8 `SyncTask.init` 接受 rules 切片

`TransformConfig.initWithSchema(..., rules)` 接受 `[]const NamingRule`，默认从 `naming_rules_json` 解析。

---

## 3. 数据流示例

源列 `orderTmp` → pipeline：
1. `camel_to_snake`: `orderTmp` → `order_tmp`
2. `regex_replace` `{ pattern: "_tmp$", replacement: "" }`: → `order`
3. `add_prefix("dt_")`: → `dt_order`

最终映射：`orderTmp` → `dt_order`。

---

## 4. 测试策略

### 4.1 单元测试

- `regex_replace("_tmp$", "", "orderTmp")` → `"order"`
- `regex_replace("^id$", "identifier", "id")` → `"identifier"`
- `regex_replace` 含 backref：`"{ pattern: "^(\\w+)_id$", replacement: "$1_identifier" }` `"order_id"` → `"order_identifier"`
- `applyNamingPipeline([camel_to_snake, add_prefix("dt_")], "orderId")` → `"dt_order_id"`

### 4.2 JSON 解析测试

- `"naming_rules": [{"type": "regex_replace", "pattern": "...", "replacement": "..."}]` → 数组
- `"naming_rules": [{"type": "add_prefix", "value": "dt_"}]` → 数组
- `"naming_rule": "camel_to_snake"` → 单规则 (向后兼容)
- `"naming_rules": []` → 空数组 (identity 行为)

### 4.3 `TransformConfig.deinit` 测试

- `regex_replace` pattern 和 replacement slice 在 `deinit` 中被释放。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| regex compile 慢（每次调用重新编译） | 编译结果可缓存到 `TransformConfig`（Phase 6d 优化） |
| regex 语法错误（用户写错 pattern） | JSON 解析返回 `error.InvalidConfig`，任务启动失败 |
| backref 越界（`$5` 但只有 3 个 group） | `std.Regex` 自动报错，返回原 string |
| 用户传空 `naming_rules: []` | 等价 identity |

---

## 6. 后续扩展

- **Phase 6d**：regex 编译缓存 + 表名转换规则
- **Phase 6e**：链式规则可视化（Web UI）
- **Phase 6f**：内置规则库（snake_case / kebab-case / PascalCase）