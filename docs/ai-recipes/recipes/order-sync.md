# Recipe: 订单同步 (mall_id 注入 + 佣金计算)

## 目标

把单套 PolarDB 商城的 `orders` 表同步到总归集库的 `union_all_order`, 自动注入 `mall_id` 并实时计算 `agent_commission` (5% 提成).

## 前置

- 先注册 datasource: `POST /api/v1/datasource`, `mall_id: "mall-001"` 指向 `mall_001` 库 (登录 → 注册流程见 [01-quickstart.md](../01-quickstart.md)).
- binlog 模式 (`sync_mode: 2/3`) 要求源端开 binlog (`binlog_format=ROW`, `binlog_row_image=FULL`) 且账号有 `REPLICATION SLAVE, REPLICATION CLIENT` 权限.
- 目标库 `union_all_order` 不需要预先建表 (Phase 7 自动 CREATE TABLE IF NOT EXISTS).
- 佣金计算需要归集库有 `agent_commission_rule` 表 (结构见下文 "佣金规则表").

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

## 请求体 (`POST /api/tasks`)

```bash
curl -X POST http://127.0.0.1:18080/api/tasks \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "name": "order-sync-from-mall-001",
    "source_db": "mall-001",
    "source_table": "orders",
    "target_table": "union_all_order",
    "sync_mode": 3,
    "status": 1,
    "config_json": "{\"batch_size\": 200, \"enable_commission_calc\": true}"
  }'
```

- `source_db: "mall-001"` → 关联 datasource, 其 `mall_id` 自动注入每行 (与 order_no 组成归集侧唯一键).
- `sync_mode: 3` (both) = 全量初始化后自动切 binlog 增量.
- `config_json.enable_commission_calc: true` 启用佣金计算 — 规则不是写死在配置里,
  而是从归集库 `agent_commission_rule` 表动态加载 (status=1 的规则), 不可达时降级空规则并 5min 自动重试.

## 佣金规则表 (归集库)

```sql
CREATE TABLE IF NOT EXISTS agent_commission_rule (
  id              INT PRIMARY KEY AUTO_INCREMENT,
  agent_id        VARCHAR(64)  NOT NULL,
  mall_id         VARCHAR(32)  NOT NULL,
  min_amount      DECIMAL(10,2) NOT NULL,
  max_amount      DECIMAL(10,2) NOT NULL,
  commission_rate DECIMAL(5,4)  NOT NULL,
  status          INT NOT NULL DEFAULT 1
);
```

计算逻辑 (硬编码字段名, 无需配置): 取行内 `order_total` 金额 + `agent_id`, 按
`(mall_id, agent_id, min_amount <= order_total < max_amount)` 匹配区间费率,
输出 `agent_commission` (金额) 与 `commission_rate` (费率) 两列. 未匹配到规则时两列为空.

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

用 V1 已有的 `transform.filter_field` + `filter_op` + `filter_value`:

```json
{
  "transform": {
    "filter_field": "order_status",
    "filter_op": "gte",
    "filter_value": "1"
  }
}
```

`filter_op` 取值: `eq, ne, gt, gte, lt, lte`. 详见 [dev.md](../../../dev.md) "稳定性修复" section.

### 想从 30 套 PolarDB 一起同步

看 [multi-source-aggregation.md](multi-source-aggregation.md).
