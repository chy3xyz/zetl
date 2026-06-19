# Naming Rule 速查 (Phase 6b / 6c)

## 单规则形式 (`naming_rule`)

```
"naming_rule": "identity"           // 不变
"naming_rule": "camel_to_snake"     // orderId → order_id
"naming_rule": "snake_to_camel"     // order_id → orderId
"naming_rule": "upper"              // foo → FOO
"naming_rule": "lower"              // FOO → foo
"naming_rule": {"type":"add_prefix","value":"dt_"}   // id → dt_id
"naming_rule": {"type":"strip_prefix","value":"dt_"} // dt_id → id
"naming_rule": {"type":"regex_replace","pattern":"_tmp$","replacement":""}  // order_tmp → order
```

## 链式规则 (`naming_rules`, Phase 6c)

```json
{
  "naming_rules": [
    {"type": "camel_to_snake"},
    {"type": "regex_replace", "pattern": "_tmp$", "replacement": ""},
    {"type": "add_prefix", "value": "dt_"}
  ]
}
```

`orderId` → `order_id` → `order` → `dt_order`.

空数组 `[]` = `identity`.

## 已知限制

- `camel_to_snake` 对 `userIDNumber` 返回 `user_i_d_number` (连续大写处理是 best-effort, 90% 覆盖).
- regex_replace 是 zetl 内置 mini 引擎, 不支持 `*?` (lazy quantifier) / 环视 / `\d` 简写 (用 `[0-9]` 替代).

详见 `dev.md` Phase 6b / 6c section.
