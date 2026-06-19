# Recipe: 多商城汇总 (30 套 PolarDB → 1 个中央库)

## 目标

30 套独立的 PolarDB 商城 (mall-001 到 mall-030), 各自有 `orders` 表, 全部汇总到中央 `central.union_all_order` (按 `mall_id` 区分).

## 实施方式

不要写 30 个配置文件. 用一个 shell 脚本循环生成 30 个 task, POST 给 zetl.

## 模板 `config_template.json`

```json
{
  "name": "order-sync-from-__MALL_ID__",
  "sync_mode": "both",
  "source": {
    "host": "polar-__N__.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "orders",
    "mall_id": "__MALL_ID__"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "union_all_order"
  },
  "transform": {
    "commission": {
      "rate": 0.05,
      "amount_field": "order_total"
    }
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 200
  }
}
```

## 生成脚本 `bulk-create.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

TOKEN="<admin_token>"
ZETL_URL="http://127.0.0.1:8080"

for n in $(seq -w 1 30); do
  mall_id="mall-$(printf '%03d' $((10#$n)))"

  config=$(sed \
    -e "s/__MALL_ID__/${mall_id}/g" \
    -e "s/__N__/${n}/g" \
    config_template.json)

  curl -s -X POST "${ZETL_URL}/api/tasks" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${config}"
  echo
done
```

## 字段解读

- `__MALL_ID__` / `__N__` 是占位符, `sed` 替换成 `mall-001` / `001` 等.
- 30 个任务全部 POST 到同一个 `target.union_all_order`, 通过 `mall_id` 区分.
- `UNIQUE KEY uk_mall_order(mall_id, order_no)` 保证不同 mall 的 order_no 互不冲突.

## 性能建议

- 30 套 PolarDB 都在同一地域: zetl 单机 (4 核 8G) 可承载, 见 [PRD §5.1](../../../docs/zetl_prd.md) (单进程 ≥ 100 链路).
- `sink.batch_size = 200` 在 PolarDB 写入场景是经验值, 大促可降到 50.

## 验证

1. 跑完 `bulk-create.sh` 后 `curl -H "Authorization: Bearer $TOKEN" $ZETL_URL/api/tasks | jq '. | length'` → `30`.
2. 任选 2 套 mall 各插一行, 目标 `union_all_order` 应有 2 行, `mall_id` 字段不同.
