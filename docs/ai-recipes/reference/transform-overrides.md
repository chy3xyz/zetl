# `field_mappings_json` 速查

## 语法

字符串化的 JSON 数组, 每项是一个 mapping:

```json
[
  {"source": "user_phone", "target": "phone"},
  {"source": "amount", "target": "order_total", "default": "0.00"},
  {"source": "status", "target": "is_active", "type": "bool"}
]
```

字段:
- `source` (必填): 源列名.
- `target` (必填): 目标列名.
- `default` (选填): 当源列 NULL 时的默认值.
- `type` (选填): 目标类型 (`string` / `int` / `float` / `bool` / `datetime`).

## 6 个常用例子

```text
1. 重命名: [{"source":"phone","target":"user_phone"}]
2. 默认值填充: [{"source":"remark","target":"remark","default":""}]
3. 类型转换: [{"source":"is_vip","target":"is_vip","type":"bool"}]
4. 跳过列 (不写就不会同步): []
5. 多个 override: [{"source":"a","target":"a"},{"source":"b","target":"B"}]
6. 配合 naming_rule (override 优先): [
     {"source":"id","target":"mall_id"},
     {"source":"mallId","target":"real_mall_id"}
   ]
```

## 与 `naming_rule` 关系

- `naming_rule` 是批量规则, 适用于所有列.
- `field_mappings_json` 是个例 override, 命中 source 的项**覆盖**自动规则生成的 target.
- 想跳过 `naming_rule` 的某些列, 在 `field_mappings_json` 里写 `target = source` 即可.

详见 `dev.md` Phase 6 section.

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

非 phone 字段 (`user_id`, `register_time` 等) 不变.
