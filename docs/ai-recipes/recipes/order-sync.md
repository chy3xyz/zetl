# Recipe: 订单同步 (mall_id 注入 + 佣金计算)

## 目标

把单套 PolarDB 商城的 `orders` 表同步到总归集库的 `union_all_order`, 自动注入 `mall_id` 并实时计算 `agent_commission` (5% 提成).

## 前置

- 源端 PolarDB 已开 binlog (`binlog_format=ROW`, `binlog_row_image=FULL`).
- 源端账号权限: `SELECT, REPLICATION SLAVE, REPLICATION CLIENT`.
- 目标库 `central.union_all_order` 不需要预先建表 (Phase 7 自动 CREATE TABLE IF NOT EXISTS).

## 源表 `mall_001.orders` 结构

```sql
CREATE TABLE orders (
  id            BIGINT       NOT NULL PRIMARY KEY,
  mall_id       VARCHAR(32)  NOT NULL,
  order_no      VARCHAR(64)  NOT NULL UNIQUE,
  agent_id      BIGINT       NULL,
  order_total   DECIMAL(10,2) NOT NULL,
  order_status  TINYINT      NOT NULL DEFAULT 0,
  pay_time      DATETIME     NULL,
  create_time   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

## 目标表 `central.union_all_order` 期望结构

```sql
CREATE TABLE union_all_order (
  id                BIGINT       NOT NULL PRIMARY KEY,
  mall_id           VARCHAR(32)  NOT NULL,
  order_no          VARCHAR(64)  NOT NULL,
  agent_id          BIGINT       NULL,
  order_total       DECIMAL(10,2) NOT NULL,
  agent_commission  DECIMAL(10,2) NULL,
  commission_rate   DECIMAL(5,4)  NULL,
  order_status      TINYINT      NOT NULL DEFAULT 0,
  pay_time          DATETIME     NULL,
  sync_time         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mall_order(mall_id, order_no)
);
```

## 完整 `config_json`

```json
{
  "name": "order-sync-from-mall-001",
  "sync_mode": "both",
  "source": {
    "host": "polar-001.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "orders",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "union_all_order"
  },
  "transform": {
    "commission": {
      "rate": 0.05,
      "amount_field": "order_total",
      "output_field": "agent_commission",
      "rate_field": "commission_rate"
    }
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 200
  }
}
```

## 字段解读

- `mall_id: "mall-001"` 自动追加到目标行, 与 order_no 组成联合唯一索引.
- `transform.commission.rate = 0.05`: 每行 `agent_commission = order_total * 0.05`.
- `sink.on_conflict = "replace"`: 重复订单 (mall_id+order_no) 覆盖更新.
- `sink.batch_size = 200`: 200 行一批写入, 适合 PolarDB 网络抖动场景.

## 验证步骤

1. 源 `orders` 插一行: `INSERT INTO orders VALUES (1, 'mall-001', 'O-2026-001', 100, 100.00, 1, NOW(), NOW());`
2. 等 ≤ 10 秒 (Phase 2 端到端延迟).
3. 目标查: `SELECT * FROM union_all_order WHERE order_no = 'O-2026-001';`
   - 期望 `mall_id = 'mall-001'`, `agent_commission = 5.00`, `commission_rate = 0.0500`.

## 常见变更

### 想用 7% 佣金

改 `transform.commission.rate` 为 `0.07`.

### 想加 update_time 过滤 (只同步已支付订单)

等 Phase 9 `transform.filter` 落地 (见 [dev.md](../../../dev.md) Phase 9).

### 想从 30 套 PolarDB 一起同步

看 [multi-source-aggregation.md](multi-source-aggregation.md).
