# `/api/tasks/*` REST API

## 端点 (Phase 5 + Phase 8; 2026-11-21 起为唯一任务系统, legacy /api/v1/task 已移除)

| Method | Path | 权限 | 说明 |
|--------|------|------|------|
| GET | `/api/tasks` | `task:read` | 列出所有任务 |
| GET | `/api/tasks/{id}` | `task:read` | 查看单个任务 |
| POST | `/api/tasks` | `task:write` | 创建任务 |
| PUT | `/api/tasks/{id}` | `task:write` | 更新任务 (active 时自动 reload) |
| DELETE | `/api/tasks/{id}` | `task:delete` | 删除任务 (active 时先 stop) |
| POST | `/api/tasks/{id}/reload` | `task:start` | 强制重载 |

## Auth

所有端点都需要 Bearer token (登录 `POST /api/v1/auth/login` 获取, 见 [01-quickstart.md](../01-quickstart.md)):

```bash
curl -H "Authorization: Bearer <token>" http://127.0.0.1:18080/api/tasks
```

- 无 token → `401` (`{"code":2,...}`)
- token 有效但权限不足 (如 viewer 调 write 端点) → `403` (`{"code":2,...}`)
- admin/operator → `200`

## 例子

### 列出所有任务

响应信封统一为 `{"code":0,"msg":"success","data":...}`:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:18080/api/tasks | jq '.data.total, .data.list[0]'
```

支持 `?status=1` (仅 active) / `?status=0` (仅 disabled) 过滤.

### 创建任务

```bash
curl -X POST http://127.0.0.1:18080/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/order-task.json
```

创建即启动 (`status=1` 时). 返回两种形态:

- `.data.status == "running"` — 落库且调度成功
- `.data.status == "stored_only"` + `.data.scheduler_error` — 落库但启动失败 (数据源不存在/连不上等),
  修复后 reload 重试. 请求体结构见 [00-task-config-schema.md](../00-task-config-schema.md).

### 启动 / 重载任务

`reload` = 用 tasks_config 里最新配置重建任务 (先 stop 旧实例再按新 config_json 启动):

```bash
curl -X POST http://127.0.0.1:18080/api/tasks/42/reload \
  -H "Authorization: Bearer $TOKEN"
```

### 删除任务

```bash
curl -X DELETE http://127.0.0.1:18080/api/tasks/42 \
  -H "Authorization: Bearer $TOKEN"
```

active 任务先 stop 再删; `PUT /api/tasks/42` 更新时若任务在跑也会自动 reload 新配置.

### 错误响应

```json
{"code":1,"msg":"name/source_db/source_table/target_table 必填"}
```

`code`: `0=success / 1=param_error / 2=permission_denied / 3=business_error / 5=system_error`.

新增 `POST /api/tasks/{id}/stop` (停实例留配置); `PUT` 传 `status:0` 即停用.
