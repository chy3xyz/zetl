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

## 完整 `config_json`

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
    "field_mappings_json": "[{\"source\":\"phone\",\"target\":\"phone\",\"default\":\"****\"}]"
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 500
  }
}
```

## 字段解读

- `transform.field_mappings_json`: 当前仅支持字段重命名 + 默认值填充; 手机号脱敏请用下方的 `mask_phone` 简写.
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

## 验证步骤

1. 源 `users` 插一行: `INSERT INTO users VALUES (1, '13800138000', NOW(), 100);`
2. 目标查: `SELECT phone FROM union_all_user WHERE id = 1;`
   - 期望 `phone = '138****8000'`.

## 已知限制

- 子串 `tel` 会命中 `hotel`, `platform` 等无关列, 属于 best-effort 简化.
