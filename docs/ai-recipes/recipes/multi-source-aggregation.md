# Recipe: 多商城汇总 (30 套 PolarDB → 1 个中央库)

## 目标

30 套独立的 PolarDB 商城 (mall-001 到 mall-030), 各自有 `orders` 表, 全部汇总到中央 `central.union_all_order` (按 `mall_id` 区分).

## 实施方式

不要手写 30 份配置. 两步: 循环注册 30 个 datasource, 再循环创建 30 个 task.

## Step 1: 批量注册数据源 `bulk-datasource.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

TOKEN="<admin_token>"
ZETL_URL="http://127.0.0.1:18080"

for n in $(seq -w 1 30); do
  mall_id="mall-$(printf '%03d' $((10#$n)))"
  host="polar-${n}.local"

  curl -s -X POST "${ZETL_URL}/api/v1/datasource" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"mall_id\":\"${mall_id}\",\"host\":\"${host}\",\"port\":3306,\"db_name\":\"mall_001\",\"username\":\"etl\",\"password\":\"etl\"}"
  echo
done
```

## Step 2: 批量创建任务 `bulk-create.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

TOKEN="<admin_token>"
ZETL_URL="http://127.0.0.1:18080"

for n in $(seq -w 1 30); do
  mall_id="mall-$(printf '%03d' $((10#$n)))"

  # config_json 是嵌套 JSON 字符串 — 内层双引号要转义两次
  cj='{"batch_size": 200, "enable_commission_calc": true}'

  curl -s -X POST "${ZETL_URL}/api/tasks" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"order-sync-from-${mall_id}\",\"source_db\":\"${mall_id}\",\"source_table\":\"orders\",\"target_table\":\"union_all_order\",\"sync_mode\":3,\"status\":1,\"config_json\":\"${cj}\"}"
  echo
done
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

- 每个 task 的 `source_db` 指向同名 datasource (`mall-001` ... `mall-030`), datasource 的 `mall_id` 自动注入目标行.
- 30 个任务写到同一个 `union_all_order`, 通过注入的 `mall_id` 列区分.
- `UNIQUE KEY uk_mall_order(mall_id, order_no)` 保证不同 mall 的 order_no 互不冲突.
- 注意: zetl 对同名 `name` 任务未做唯一性约束校验 (仅 SQLite `UNIQUE` 兜底), 重复跑脚本前先清库或换 name.

## 性能建议

- 30 套 PolarDB 都在同一地域: zetl 单机 (4 核 8G) 可承载, 见 [PRD §5.1](../../../docs/zetl_prd.md) (单进程 ≥ 100 链路).
- `config_json.batch_size = 200` 在 PolarDB 写入场景是经验值, 大促可降到 50.

## 验证

1. 跑完 `bulk-create.sh` 后 `curl -H "Authorization: Bearer $TOKEN" "$ZETL_URL/api/tasks" | jq '.data.total'` → `30`.
2. 任选 2 套 mall 各插一行, 目标 `union_all_order` 应有 2 行, `mall_id` 字段不同.
