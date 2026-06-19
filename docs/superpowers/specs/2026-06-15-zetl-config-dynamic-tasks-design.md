# zetl 配置系统 + 动态任务管理 设计文档（Phase 5）

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3
- **前置版本**：V3 binlog CDC Phase 3（已合并到 main）+ 长期路线图扩展性第一步
- **状态**：待实现

---

## 0. 本轮目标

把当前**编译期固定**的 `SyncTask` 升级为 **DB 驱动 + 运行时 CRUD**：

1. 任务定义存储在 `meta.store` 的 `tasks_config` 表中。
2. HTTP API 提供任务 CRUD + reload。
3. Scheduler 启动时从 DB 加载 active 任务；运行时支持 `addTask / removeTask / reloadTask / listTasks`。
4. 用户通过 Web/CLI 操作，无需重启服务。

本轮 **不** 实现 transform / sink 自动生成（留给 Phase 6 / 7）。`config_json` 暂仅支持 `passthrough` transform。

---

## 1. 不在本轮范围

- transform 自动生成（基于列类型生成规则）
- sink 自动建表（基于 source schema）
- Web UI 改进（task 表单、模板）
- 任务模板化、批量创建
- 热轮询 DB 变更（手动 reload 已足够）
- 任务版本控制 / 历史回滚
- 多源 DB（一个源 → 多个目标）

---

## 2. 数据模型

### 2.1 `tasks_config` 表（新增）

```sql
CREATE TABLE tasks_config (
    id            INTEGER PRIMARY KEY,             -- 与 task_status.id 共用 (人工约定)
    name          TEXT NOT NULL UNIQUE,
    source_db     TEXT NOT NULL,                   -- 源库标识, 与 src_pool host 匹配
    source_table  TEXT NOT NULL,
    target_table  TEXT NOT NULL,
    sync_mode     INTEGER NOT NULL,                -- 0=full, 1=poll, 2=binlog, 3=both
    config_json   TEXT NOT NULL DEFAULT '{}',
    status        INTEGER NOT NULL DEFAULT 1,      -- 0=disabled, 1=active
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);
CREATE INDEX idx_tasks_status ON tasks_config(status);
```

`id` 与 `task_status.id` 关联；`task_status` 保留为运行时状态。

### 2.2 `config_json` schema

```jsonc
{
    "polling_interval_sec": 60,
    "batch_size": 500,
    "enable_commission_calc": true,
    "transform": { "type": "passthrough" },
    "sink":     { "type": "mysql", "target_db": "analytics" },
    "filter":   { "where": "status = 1" }
}
```

`TaskConfig` 结构体包含以上所有字段。`config_json` 解析失败 → `error.InvalidConfig`。

---

## 3. 架构修改

### 3.1 `src/meta/task/`

新增/扩展 `service.zig`：

```zig
pub const TaskActiveStatus = enum { disabled = 0, active = 1 };

pub const TaskConfig = struct {
    id: i64,
    name: []const u8,
    source_db: []const u8,
    source_table: []const u8,
    target_table: []const u8,
    sync_mode: SyncMode,
    config_json: []const u8,                  // 原始 JSON, 留给上层解析
    status: TaskActiveStatus,
    created_at: i64,
    updated_at: i64,
};

pub const Service = struct {
    pub fn create(self, cfg: TaskConfig) !i64;
    pub fn getById(self, id: i64) !?TaskConfig;
    pub fn list(self, filter: ?TaskActiveStatus) ![]TaskConfig;
    pub fn update(self, id: i64, cfg: TaskConfig) !void;
    pub fn delete(self, id: i64) !void;
    pub fn setStatus(self, id: i64, status: TaskActiveStatus) !void;
};
```

`Service.init` 在现有 schema 之上自动创建 `tasks_config` 表（如果不存在）。

### 3.2 `src/engine/scheduler.zig`

新增方法：

```zig
pub fn addTask(self: *Scheduler, cfg: TaskConfig) !void
pub fn removeTask(self: *Scheduler, id: i64) !void
pub fn reloadTask(self: *Scheduler, id: i64) !void
pub fn listTasks(self: *Scheduler) ![]TaskConfig
```

并发安全：
- `Scheduler` 内部新增 `mutex: std.Thread.Mutex`。
- `tasks: HashMap(i64, *SyncTask)` 在锁内增删。
- 任务线程不持锁；与外部状态通过 atomic 交互。

`loadFromDb()`：
- 启动时从 `tasks_config` 查询所有 `status=active` 任务，依次 `addTask`。
- `addTask` 失败的任务记日志并跳过，不阻塞整体启动。

`reloadTask` 实现策略：
1. 在锁外 stop + deinit 旧 SyncTask。
2. 用新 cfg 实例化新 SyncTask。
3. 在锁内替换 map 中的指针并 start。
4. 如果 start 失败，恢复旧 task（如果还存在）或标记 error。

### 3.3 `src/web/`

新增 `src/web/api/tasks.zig`：

| Method | Path | 说明 |
|---|---|---|
| `GET /api/tasks` | 列出所有任务（带运行时状态） |
| `POST /api/tasks` | 创建任务（body = TaskConfig JSON） |
| `GET /api/tasks/{id}` | 查看单个任务 |
| `PUT /api/tasks/{id}` | 更新任务（active 时自动 reload） |
| `DELETE /api/tasks/{id}` | 删除任务（active 时先 stop） |
| `POST /api/tasks/{id}/reload` | 强制重载 |

请求示例：

```json
POST /api/tasks
{
    "name": "order_info_sync",
    "source_db": "primary",
    "source_table": "order_info",
    "target_table": "order_info",
    "sync_mode": 2,
    "config_json": "{\"polling_interval_sec\":60}"
}
```

返回 201 / 200 时附带 `{"id": <i64>, "status": "running|pending|error"}`。

错误路径：
- 400：JSON 解析失败 / 字段缺失
- 404：任务不存在
- 409：name 冲突
- 500：DB / scheduler 失败

### 3.4 启动流程更新

`main.zig`：

```zig
const sched = Scheduler.init(allocator, store, pool, src_pool, ...);
defer sched.deinit();

// 新增: 从 DB 加载任务
sched.loadFromDb() catch |err| {
    logger.warn("loadFromDb failed: {s}", .{@errorName(err)});
};

// 启动 web server (HTTP API)
// ...
```

---

## 4. 数据流

### 4.1 创建任务

```
HTTP POST /api/tasks
   ↓
Web handler 解析 body → TaskConfig
   ↓
Service.create(cfg) → 返回 id
   ↓
Scheduler.addTask(cfg) → 实例化 SyncTask → start
   ↓
SyncTask.runLoop → 启动 full / poll / binlog
   ↓
Service.setStatus(id, active) / TaskStatusService.updateStatus(id, running)
```

### 4.2 更新任务

```
HTTP PUT /api/tasks/{id}
   ↓
Service.update(id, cfg)
   ↓
Scheduler.reloadTask(id)
   ↓
stop old → deinit old → create new → start new
   ↓
Service.update 返回成功时, 旧 task 已被替换
```

### 4.3 删除任务

```
HTTP DELETE /api/tasks/{id}
   ↓
Scheduler.removeTask(id) → stop + deinit
   ↓
Service.delete(id) → DELETE FROM tasks_config
```

---

## 5. 测试策略

### 5.1 单元测试

- `meta.task.Service` CRUD：使用临时 SQLite 库，create / get / list / update / delete 覆盖。
- `TaskConfig.config_json` 解码往返：`"{}"` ↔ 默认字段。
- `TaskConfig.sync_mode` 枚举映射。
- `Scheduler.addTask / removeTask / reloadTask`：使用 mock pool（不实际连接 MySQL）。

### 5.2 集成测试

- 启动 scheduler → 加载 2 个 active 任务 → `listTasks` 返回 2 个，运行时状态为 `running`。
- `POST /api/tasks` 创建任务 → DB insert 1 行 → scheduler list 增加。
- `DELETE /api/tasks/{id}` → DB 减少 1 行 → scheduler list 减少。
- `PUT /api/tasks/{id}` 修改 `config_json.polling_interval_sec` → reload 后 SyncTask 用新值运行。

### 5.3 错误路径

- `addTask` 失败（pool 创建失败）：回滚 DB 删除对应行。
- `reloadTask` 失败（start 新 task 失败）：返回 500，旧 task 已被 stop → task 进入 error 状态。
- 重复 addTask 相同 name：DB UNIQUE 约束触发 → 返回 conflict。

---

## 6. 风险与回退

| 风险 | 应对 |
|------|------|
| 多客户端并发 addTask | Scheduler 锁 + DB UNIQUE 约束 |
| reloadTask 中 task 处于"停止"瞬时不可用 | 锁内 stop+replace 原子切换 |
| `config_json` 字段扩展，旧行无该字段 | 解码时使用默认值（`serde_json` 风格） |
| 任务 id 与 task_status.id 不匹配 | 启动时校验，错误任务跳过 |
| DB schema 升级（旧库无 `tasks_config`） | `Service.init` 用 `CREATE TABLE IF NOT EXISTS` |
| HTTP API 鉴权 | 本轮不做（假设内部网络），Phase 8 加 |

---

## 7. 后续路线图

- **Phase 6**：transform 自动化（基于源 schema 自动生成规则）
- **Phase 7**：sink 自动化（基于 source schema 自动建目标表）
- **Phase 8**：Web UI 改进 + 鉴权 + 任务模板化
- **Phase 9**：多源 DB、任务版本控制