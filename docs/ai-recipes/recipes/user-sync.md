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

## mask_phone 简写 (Phase 10 起)

新加 `transform.mask_phone: true` 自动识别 `phone` / `mobile` / `tel` 字段, 把 ≥ 7 位数字中间 4 位替换成 `****`:

```json
{
  "transform": {
    "mask_phone": true
  }
}
```

`phone = "13800138000"` → `phone = "138****8000"`.

非 phone 字段 (`user_id`, `register_time` 等) 不变. 与 `field_mappings_json` 不冲突 (override 优先).

完整 config_json:

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
    "mask_phone": true
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 500
  }
}
```

## 验证步骤

1. 源 `users` 插一行: `INSERT INTO users VALUES (1, '13800138000', NOW(), 100);`
2. 目标查: `SELECT phone FROM union_all_user WHERE id = 1;`
   - 期望 `phone = '138****8000'`.

## 已知限制

- `transform.mask_phone` 字段名匹配是大小写敏感 (Phase 11 改成 case-insensitive).
- 子串 `tel` 会命中 `hotel`, `platform` 等无关列, 属于 Phase 10 的 best-effort 简化.
