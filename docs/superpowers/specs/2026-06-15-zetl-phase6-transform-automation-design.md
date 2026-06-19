# zetl Phase 6: transform 自动化 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3 + V5
- **前置版本**：V5 config-dynamic-tasks + Stability fixes（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

把 `Mapper` 从"用户手工配置"升级为 **基于 source schema 自动生成默认映射 + 用户覆盖**：

1. `Mapper.fromSchema(allocator, source_columns)` 从 source 表列元数据自动生成 identity 映射（列名 → 列名）。
2. `Mapper.mergeOverrides(allocator, user_json)` 解析用户在 `field_mappings_json` 中的覆盖规则并合并。
3. `TransformConfig.init` / `TransformEngine.init` 在已有 source schema 时自动调用以上两个步骤。
4. 用户覆盖格式不变：仍是 `field_mappings_json` 数组，按 source 列名匹配。

本轮 **不** 处理列名重命名规则（camelCase → snake_case 等高级派生），仅做 identity 映射 + 用户覆盖。

---

## 1. 不在本轮范围

- 列名重命名 / 大小写转换（Phase 6b 扩展）
- 数据类型自动转换（已有 `type_convert` 字段，Phase 6 不变）
- 字段过滤（保留 source 中不在 target 的列；或反之）
- 嵌套结构 / JSON 字段自动展开

---

## 2. 架构与修改点

### 2.1 `src/transform/mapper.zig`

#### 2.1.1 新增 `ColumnMeta` 结构

```zig
pub const ColumnMeta = struct {
    name: []const u8,        // source 列名, 如 "order_id" / "c0"
    type: u8 = 0,            // MySQL 类型常量 (可选)
};
```

#### 2.1.2 新增 `Mapper.fromSchema`

```zig
/// 从 source 列元数据生成 identity 映射. 保留 source 列名作为 target.
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

#### 2.1.3 新增 `Mapper.mergeOverrides`

```zig
/// 在已有 mappings 基础上, 用 user_json 中的覆盖项替换同 source 的 mapping.
/// user_json 格式与 fromJson 相同: [{"source": "...", "target": "...", "default": "...", "type": "..."}]
pub fn mergeOverrides(self: *Mapper, allocator: std.mem.Allocator, user_json: []const u8) !void {
    if (user_json.len == 0) return;
    var override_mapper = try fromJson(allocator, user_json);
    defer override_mapper.deinit();

    // 构建 source → override mapping 索引
    var idx: std.StringHashMap(usize) = .empty;
    defer idx.deinit(allocator);
    for (override_mapper.mappings, 0..) |m, i| {
        try idx.put(m.source, i);
    }

    // 对每个 auto mapping 检查 override; 命中则替换 target/default/type
    for (self.mappings) |*auto_m| {
        if (idx.get(auto_m.source)) |ov_idx| {
            const ov = override_mapper.mappings[ov_idx];
            // 释放旧的 target
            allocator.free(auto_m.target);
            auto_m.target = try allocator.dupe(u8, ov.target);
            // default / type 仅在 override 提供时更新
            if (auto_m.default_value) |d| allocator.free(d);
            auto_m.default_value = null;
            if (ov.default_value) |d| auto_m.default_value = try allocator.dupe(u8, d);
            if (auto_m.type_convert) |t| allocator.free(t);
            auto_m.type_convert = null;
            if (ov.type_convert) |t| auto_m.type_convert = try allocator.dupe(u8, t);
        }
    }

    // 收集 user_json 中没有对应 auto source 的项, 作为额外 mapping 追加 (例如用户引入了
    // source 中不存在的常量列)
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
            try self.mappings = appendMapping(self.allocator, self.mappings, new_m);
        }
    }
}

fn appendMapping(a: std.mem.Allocator, list: []FieldMapping, m: FieldMapping) ![]FieldMapping {
    const new_list = try a.realloc(list, list.len + 1);
    new_list[list.len] = m;
    return new_list;
}
```

### 2.2 `src/transform/engine.zig`

`TransformConfig` 已有 `field_mappings_json` 字段。`TransformEngine.init` 需要从 source schema 获取 `ColumnMeta` 后调用 `Mapper.fromSchema` + `mergeOverrides`。

设计要点：
- 新增 `ColumnMeta` 来源：从 `runtime.zig::SyncTask.runFull/runIncremental` 入口处的 `binlog` 解析器或 `runFull` 的 `SELECT * FROM ... LIMIT 0` 获得。
- `TransformEngine.init` 接受额外参数 `source_columns: []const mapper.ColumnMeta`，先调 `fromSchema`，再调 `mergeOverrides(self.cfg.field_mappings_json)`。
- 用户不提供 `field_mappings_json`（空字符串）时，`mergeOverrides` 是 no-op，使用 identity 默认映射。

### 2.3 `src/engine/runtime.zig`

`SyncTask.runFull` 在做 `SELECT *` 前先 `SHOW COLUMNS FROM <source_table>` 拿到列名 + 类型，转换为 `ColumnMeta`，传给 `TransformEngine.init`。这部分修改可能涉及新增一个 helper：

```zig
fn fetchSourceColumns(self: *SyncTask) ![]mapper.ColumnMeta {
    const sql = try std.fmt.allocPrint(self.allocator, "SHOW COLUMNS FROM `{s}`", .{self._sh});
    defer self.allocator.free(sql);
    // 执行 query, 解析每一行 (Field, Type, Null, Key, Default, Extra)
    // 提取 Field 名称, Type 转 u8 (可选).
    ...
}
```

`SyncTask.runIncremental` (binlog) 路径下，列名可从 `TABLE_MAP_EVENT.column_types` + `column_metadata` 中已有的 `column_names` 获得（如果有）或复用 parser 的列名。

本轮 Phase 6 只覆盖 `runFull` 的 source schema 获取，binlog 路径继续使用 parser 的现有列名（"c0" / "c1" / ...）。

---

## 3. 数据流示例

源库表 `order_info`：

```
order_id  INT PRIMARY KEY
paid_at   DATETIME
amount    DECIMAL(18,4)
```

`runFull` 启动时：

```
SHOW COLUMNS FROM order_info
-> [
    {name="order_id",  type=...},
    {name="paid_at",   type=...},
    {name="amount",    type=...},
   ]

Mapper.fromSchema([order_id, paid_at, amount])
-> Mapper {
     mappings: [
       {source="order_id",  target="order_id"},
       {source="paid_at",   target="paid_at"},
       {source="amount",    target="amount"},
     ],
   }

field_mappings_json (用户配置):
[{"source":"order_id", "target":"id"}]

Mapper.mergeOverrides(...)
-> Mapper {
     mappings: [
       {source="order_id",  target="id"},
       {source="paid_at",   target="paid_at"},
       {source="amount",    target="amount"},
     ],
   }
```

用户覆盖命中后，`target="id"` 替换了默认的 `target="order_id"`。

---

## 4. 测试策略

### 4.1 `mapper.zig` 单元测试

- `Mapper.fromSchema` 接受 `[]ColumnMeta`，生成 N 个 identity mappings。
- `Mapper.mergeOverrides` 用 user_json 替换对应 source 的 target/default/type。
- `mergeOverrides` 接受空字符串 → no-op。
- `mergeOverrides` 追加 user-only mappings（source 中不存在的列）。
- `deinit` 释放所有 allocations（包括 mergeOverrides 添加的）。

### 4.2 `engine.zig` 集成测试

- `TransformEngine.init` 不提供 source_columns → 退化为原有 `Mapper.fromJson(field_mappings_json)` 行为。
- `TransformEngine.init` 提供 source_columns + 空 field_mappings_json → identity 映射。
- `TransformEngine.init` 提供 source_columns + 用户 override → identity + 覆盖。

### 4.3 错误路径

- `fromSchema` 在 OOM 时 errdefer 释放已分配 mapping。
- `mergeOverrides` 在 user_json 解析失败时返回 `error.InvalidConfig`，已有 mappings 不变。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| 旧调用方没传 source_columns | `fromSchema` 不可用时退化为 `fromJson(field_mappings_json)` 行为；保持向后兼容 |
| `SHOW COLUMNS` 慢 | 可加 meta.store 缓存（Phase 6b）；本轮每次启动一次查询 |
| binlog 路径列名不一致（"c0" 而非 "order_id"） | 本轮 binlog 路径不变；Phase 6b 通过 TABLE_MAP metadata 推断 |
| `fromSchema` 与 `fromJson` 行为不一致 | 测试覆盖两种入口；用户只能走新入口 |

---

## 6. 后续扩展

- Phase 6b：列名重命名规则（camelCase → snake_case，加前缀 `dt_` 等）
- Phase 6c：source_columns 缓存（meta.store.task_schema_cache 表）
- Phase 6d：binlog TABLE_MAP metadata 提供更准确列名