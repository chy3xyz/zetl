# Quickstart: 5 分钟跑通最小链路

假设你已经有一对 PolarDB MySQL 库 (源 + 目标), 想用 zetl 把源 `orders` 表同步到目标.

## Step 1: 准备 JSON

保存下面 JSON 到 `/tmp/order-task.json`:

```json
{
  "name": "quickstart-order",
  "sync_mode": "polling",
  "source": {
    "host": "127.0.0.1", "port": 3306,
    "user": "etl", "password": "etl",
    "db": "mall_001", "table": "orders",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "127.0.0.1", "port": 3306,
    "user": "etl", "password": "etl",
    "db": "central", "table": "union_all_order"
  }
}
```

## Step 2: POST 给 zetl

```bash
curl -X POST http://127.0.0.1:8080/api/tasks \
  -H "Authorization: Bearer <admin_token>" \
  -H "Content-Type: application/json" \
  --data @/tmp/order-task.json
```

返回 `201 Created` + 任务 JSON.

## Step 3: 查看任务列表

```bash
curl -H "Authorization: Bearer <admin_token>" \
  http://127.0.0.1:8080/api/tasks
```

找到刚才创建的任务, 复制 `id`.

## Step 4: 启动任务

```bash
curl -X POST http://127.0.0.1:8080/api/tasks/<id>/reload \
  -H "Authorization: Bearer <admin_token>"
```

## Step 5: 验证

往源 `orders` 表插一行, 等 1 秒, 在目标 `union_all_order` 看到同样的行 (带 mall_id).

## 下一步

- 加上 `transform.commission` 做佣金计算 → [recipes/order-sync.md](recipes/order-sync.md)
- 加上 `transform.naming_rule` 做列名转换 → [reference/transform-naming.md](reference/transform-naming.md)
- 多套库并发同步 → [recipes/multi-source-aggregation.md](recipes/multi-source-aggregation.md)
