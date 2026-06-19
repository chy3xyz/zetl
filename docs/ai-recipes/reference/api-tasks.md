# `/api/tasks/*` REST API

## 端点 (Phase 5 + Phase 8)

| Method | Path | 权限 | 说明 |
|--------|------|------|------|
| GET | `/api/tasks` | `task:read` | 列出所有任务 |
| GET | `/api/tasks/{id}` | `task:read` | 查看单个任务 |
| POST | `/api/tasks` | `task:write` | 创建任务 |
| PUT | `/api/tasks/{id}` | `task:write` | 更新任务 (active 时自动 reload) |
| DELETE | `/api/tasks/{id}` | `task:delete` | 删除任务 (active 时先 stop) |
| POST | `/api/tasks/{id}/reload` | `task:start` | 强制重载 |

## Auth

所有端点都需要 Bearer token:

```bash
curl -H "Authorization: Bearer <token>" http://127.0.0.1:8080/api/tasks
```

- 无 token → `401 Unauthorized`
- viewer token 但缺少权限 → `403 Forbidden`
- admin/operator token → `200/201`

## 例子

### 列出所有任务

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8080/api/tasks | jq '.'
```

### 创建任务

```bash
curl -X POST http://127.0.0.1:8080/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/order-task.json
```

返回 `201 Created` + `{"id": 42, ...}`.

### 启动任务

```bash
curl -X POST http://127.0.0.1:8080/api/tasks/42/reload \
  -H "Authorization: Bearer $TOKEN"
```

### 删除任务

```bash
curl -X DELETE http://127.0.0.1:8080/api/tasks/42 \
  -H "Authorization: Bearer $TOKEN"
```

详见 `dev.md` Phase 5 + Phase 8 section.
