# zetl Phase 8: 鉴权覆盖 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V5 + Phase 6/7
- **前置版本**：Phase 7 sink automation（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

修复 Phase 5 引入的安全漏洞：

**当前状态**：`/api/tasks/*` 端点（V5 Phase 5 Task 5 添加）在 `src/web/routes.zig` 中使用 `app.get / app.post / app.put / app.delete` 直接注册（line 89-95），**完全绕过鉴权中间件**。注释明确写"暂不鉴权"。这意味着任何能访问 HTTP 端口的人都可以创建/修改/删除/重载同步任务。

**目标**：
1. 给 `/api/tasks/*` 端点加鉴权 + RBAC 权限校验，与 V1 `/api/v1/task/*` 端点对齐。
2. 保留 V1 `/api/v1/task/*` 端点的存在（向后兼容），但新客户端应使用 V5 `/api/tasks/*`。
3. 统一权限命名（`task:read` / `task:write` / `task:delete` / `task:start` / `task:stop`）。

本轮 **不** 涉及：
- 前端 UI 改进（已有 `src/assets/index.html`，Phase 8b 处理）
- 鉴权本身重新设计（RBAC 已存在）
- 弃用 V1 `/api/v1/task/*`（向后兼容保留）

---

## 1. 不在本轮范围

- 新增 Web UI 组件 / 重构前端
- 新增 API 端点
- 鉴权方案切换（JWT / OAuth）
- 跨服务 SSO / LDAP
- 审计日志（Phase 9 计划）

---

## 2. 架构与修改点

### 2.1 鉴权覆盖矩阵

`/api/tasks/*` 端点的权限映射：

| 端点 | HTTP 方法 | 权限 | 角色 |
|------|-----------|------|------|
| `/api/tasks` | GET | `task:read` | viewer+ |
| `/api/tasks` | POST | `task:write` | admin+ |
| `/api/tasks/:id` | GET | `task:read` | viewer+ |
| `/api/tasks/:id` | PUT | `task:write` | admin+ |
| `/api/tasks/:id` | DELETE | `task:delete` | admin |
| `/api/tasks/:id/reload` | POST | `task:start` (复用) 或新增 `task:reload` | admin |

### 2.2 `src/web/routes.zig` 修改

替换 line 89-95 的 6 个无鉴权端点：

```zig
    // V5 Phase 5 Task 5: 动态任务管理 /api/tasks (Phase 8: 加鉴权)
    const task_read_intc_v5 = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:read") };
    const task_write_intc_v5 = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:write") };
    const task_delete_intc_v5 = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:delete") };
    const task_reload_intc_v5 = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:start") };
    try app.getWithInterceptors("/api/tasks", tasks_api.list, &task_read_intc_v5);
    try app.postWithInterceptors("/api/tasks", tasks_api.create, &task_write_intc_v5);
    try app.getWithInterceptors("/api/tasks/:id", tasks_api.detail, &task_read_intc_v5);
    try app.putWithInterceptors("/api/tasks/:id", tasks_api.update, &task_write_intc_v5);
    try app.deleteWithInterceptors("/api/tasks/:id", tasks_api.delete, &task_delete_intc_v5);
    try app.postWithInterceptors("/api/tasks/:id/reload", tasks_api.reload, &task_reload_intc_v5);
```

### 2.3 `src/auth/rbac.zig` 确认

检查 RBAC 表是否定义了 `task:read` / `task:write` / `task:delete` / `task:start`。如果 `task:start` 已存在但 `task:read / task:write` 不存在，需要新增。

预期：`task:start` / `task:stop` 已在 V1 RBAC 中定义（用于 `/api/v1/task/:id/start` 和 `/stop`）。`task:read` / `task:write` / `task:delete` 大概率也已在 V1 的 `/api/v1/task/*` 注册中定义（如 `task_read_intc`）。本任务不需要新增 RBAC permissions，只复用现有。

### 2.4 配置更新

`config.zig` 中如果存在 `auth.disable_for_paths` 配置项，确认 `/api/tasks` 不在该列表中。本任务不修改配置项。

---

## 3. 数据流

**修复前**：
```
HTTP POST /api/tasks
  → 直接路由到 tasks_api.create
  → 调用 Service.create + Scheduler.addTask
  → 任意客户端可创建任务
```

**修复后**：
```
HTTP POST /api/tasks
  → authInterceptor 检查 Bearer Token
  → permissionInterceptor("task:write") 检查权限
  → 通过则路由到 tasks_api.create
  → 未通过则返回 401/403
```

---

## 4. 测试策略

### 4.1 单元测试

`src/web/auth_middleware.zig` 或新测试文件 `src/web/routes_test.zig`：

- `isPublicPath("/api/tasks")` 返回 false。
- 未携带 token 调用 `/api/tasks` 返回 401。
- 携带 viewer 角色 token 调用 `POST /api/tasks` 返回 403（permission denied）。
- 携带 admin 角色 token 调用 `POST /api/tasks` 返回 201（假设 payload 合法）。

### 4.2 集成测试

启动 web server，模拟三种 token（无 token / viewer / admin），对 `/api/tasks` CRUD 操作，验证响应码：
- 无 token → 401
- viewer + GET → 200
- viewer + POST → 403
- admin + GET → 200
- admin + POST → 201/200
- admin + DELETE → 200
- 非 admin + DELETE → 403

### 4.3 回归测试

确认现有 189 tests 仍通过：鉴权中间件变更不应影响已鉴权的 V1 API。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| 现有调用方使用 `/api/tasks` 但携带 admin token？ | 通过 dev.md / CHANGELOG 通知；保留 2 周过渡期 |
| RBAC 表缺失 `task:write` 权限 | 在 `rbac.zig` 中新增；admin / operator 角色默认绑定 |
| `permissionInterceptor` 不支持新权限字符串 | 检查 `rbac.zig` 是否使用 hashmap 查表（应该支持） |
| 修改后部分依赖 `/api/tasks` 的脚本失效 | 在 web 启动日志中输出"如未鉴权请配置 token" |

---

## 6. 后续扩展

- **Phase 8b**：Web UI（`src/assets/index.html`）新增任务管理面板（列表 / 创建表单 / 编辑表单 / 重载按钮 / 删除确认）
- **Phase 8c**：API 文档（OpenAPI / Swagger）
- **Phase 8d**：JWT 替代 Bearer Token
- **Phase 9**：审计日志、SSO