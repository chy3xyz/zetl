# Recipe: 用户同步 (mall_id + 手机号脱敏)

## 目标

把单套 PolarDB 商城的 `users` 表同步到总归集库的 `union_all_user`, 自动追加 `mall_id`, 并把 `phone` 字段从 `13800138000` 脱敏成 `138****8000`.

## 前置

- 同 order-sync 基础前置.
- 脱敏规则硬编码在 `transform.mask_phone = true` 中 (Phase 11 计划支持自定义表达式).

## 源表 `mall_001.users` 结构

```sql
CREATE TABLE users (
  id            BIGINT       NOT NULL PRIMARY KEY,
  phone         VARCHAR(20)  NOT NULL,
  register_time DATETIME     NOT NULL,
  agent_id      BIGINT       NULL
);
```

## 目标表 `central.union_all_user` 期望结构

```sql
CREATE TABLE union_all_user (
  id            BIGINT       NOT NULL PRIMARY KEY,
  mall_id       VARCHAR(32)  NOT NULL,
  phone         VARCHAR(20)  NOT NULL,    -- 脱敏后
  register_time DATETIME     NOT NULL,
  agent_id      BIGINT       NULL,
  sync_time     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mall_user(mall_id, id)
);
```

## 请求体 (`POST /api/tasks`)

```bash
curl -X POST http://127.0.0.1:18080/api/tasks \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "name": "user-sync-from-mall-001",
    "source_db": "mall-001",
    "source_table": "users",
    "target_table": "union_all_user",
    "sync_mode": 1,
    "status": 1,
    "config_json": "{\"batch_size\": 500, \"transform\": {\"mask_all\": true}}"
  }'
```

- `sync_mode: 1` (poll) = 全量 + update_time 轮询增量 (用户表无 binlog 需求时最简单).
- `config_json.transform.mask_all: true` = mask_phone + mask_email + mask_id_card 全开.

## 字段解读

- `config_json.field_mappings`: 覆盖映射 (重命名/默认值); 手机号脱敏请用下方的 `mask_phone` 简写.
- `batch_size = 500`: 用户表无金额计算, 可放大批量.

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

`mask_phone` / `mask_email` / `mask_id_card` 可单独开关 (写在 `config_json.transform` 内).
`phone = "13800138000"` → `"138****8000"`, `email = "alice@example.com"` → `"a****@example.com"`, `id_card = "110101199001011234"` → `"110101********1234"`.

## 验证步骤

1. 源 `users` 插一行: `INSERT INTO users VALUES (1, '13800138000', NOW(), 100);`
2. 目标查: `SELECT phone FROM union_all_user WHERE id = 1;`
   - 期望 `phone = '138****8000'`.

## 已知限制

- 子串 `tel` 会命中 `hotel`, `platform` 等无关列, 属于 best-effort 简化.
