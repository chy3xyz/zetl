# Recipe: 用户同步 (mall_id + 手机号脱敏)

## 目标

把单套 PolarDB 商城的 `users` 表同步到总归集库的 `union_all_user`, 自动追加 `mall_id`, 并把 `phone` 字段从 `13800138000` 脱敏成 `138****8000`.

## 前置

- 同 order-sync 基础前置.
- 脱敏规则硬编码在 `transform` 中 (Phase 9 计划支持自定义表达式).

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

- `transform.field_mappings_json`: 当前仅支持字段重命名 + 默认值填充; 手机号脱敏是 V6 已知限制, 落地到 Phase 9 (`transform.mask_phone = true` 简写).
- `batch_size = 500`: 用户表无金额计算, 可放大批量.

## Phase 9 简化版 (未来)

Phase 9 落地后, `config_json` 简化成:

```json
{
  "transform": {
    "mask_phone": true
  }
}
```

届时本文档会更新. 详见 [dev.md](../../dev.md) Phase 9.

## 验证步骤

1. 源 `users` 插一行: `INSERT INTO users VALUES (1, '13800138000', NOW(), 100);`
2. 目标查: `SELECT phone FROM union_all_user WHERE id = 1;`
   - 期望 `phone = '****'` (Phase 9 落地后) 或保留原始 (Phase 6c 当前).

## 已知限制

- 当前 `field_mappings_json` 不支持表达式, 脱敏在目标端 SQL 层做 (见 `reference/sink-ddl.md`).
