# Quickstart: 5 分钟跑通最小链路

假设你已经有一套源 MySQL 库 (商城业务库) 和一个归集库, 想把源 `orders` 表同步到归集库.

前提: zetl 已启动 (默认端口 `18080`, 见 `config.toml`), 且 `[meta]` 引导账号可用.

## Step 1: 登录拿 token

```bash
TOKEN=$(curl -sS -X POST http://127.0.0.1:18080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | jq -r '.data.token')
```

## Step 2: 注册数据源

任务通过 `source_db` 关联一个已注册的 datasource (mall_id 是数据源的标识):

```bash
curl -X POST http://127.0.0.1:18080/api/v1/datasource \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "mall_id": "mall-001",
    "host": "127.0.0.1", "port": 3306,
    "db_name": "mall_001",
    "username": "etl", "password": "etl"
  }'
```

## Step 3: 创建任务

**`/api/tasks` 的 body 是扁平结构**, 源端连接信息不在 body 里 (走 Step 2 的 datasource),
转换规则放在嵌套 JSON **字符串** `config_json` 里:

```bash
cat > /tmp/order-task.json <<'EOF'
{
  "name": "quickstart-order",
  "source_db": "mall-001",
  "source_table": "orders",
  "target_table": "union_all_order",
  "sync_mode": 1,
  "status": 1,
  "config_json": "{\"batch_size\": 500, \"filter\": {\"field\": \"amount\", \"op\": \"gte\", \"value\": \"0\"}}"
}
EOF

curl -X POST http://127.0.0.1:18080/api/tasks \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/order-task.json
```

成功响应 (信封 `{code, msg, data}`, `code=0` 即成功):

- `{"code":0,"msg":"success","data":{"id":1,"status":"running"}}` — 已落库并已启动
- `{"code":0,"msg":"success","data":{"id":1,"status":"stored_only","scheduler_error":"..."}}` — 已落库但启动失败
  (常见原因: datasource 不存在 / 源库连不上), 修复后 `POST /api/tasks/{id}/reload` 重试

`sync_mode` 取值: `0=full` (仅全量) / `1=poll` (全量+update_time 轮询增量) / `2=binlog` (真 CDC) / `3=both` (全量后切 binlog, 推荐).
`status`: `1=active` (创建即启动) / `0=disabled` (仅保存, 不启动).

## Step 4: 查看任务

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:18080/api/tasks?status=1" | jq '.data.list'
```

## Step 5: 验证

往源 `orders` 表插一行, 等一个轮询周期 (`[engine] incremental_poll_ms`, 默认 1s), 在归集库 `union_all_order`
看到同样的行, 且带 `mall_id` 列 (值为 datasource 的 `mall_id`, 由 TransformEngine 自动注入).

## 下一步

- 佣金计算 → [recipes/order-sync.md](recipes/order-sync.md)
- 脱敏 → [recipes/user-sync.md](recipes/user-sync.md)
- 列名转换 → [recipes/product-sync.md](recipes/product-sync.md) / [reference/transform-naming.md](reference/transform-naming.md)
- 多套库汇总 → [recipes/multi-source-aggregation.md](recipes/multi-source-aggregation.md)
