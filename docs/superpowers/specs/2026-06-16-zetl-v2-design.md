# zetl V2 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-16
- **适用版本**：V2（运维闭环 + 可观测性 + 鉴权升级）
- **前置版本**：V1 核心同步闭环（已完成, 3567 行 Zig, 31 单测, 21 端点）
- **来源需求**：V1 spec §10 "后续路线" + PRD §1.4 "二期 Not Now" + V1 评估报告遗留
- **依赖框架**：zfinal v0.10.0（已升级）
- **状态**：V2 阶段规划, 待用户确认

---

## 0. 设计基线 (V1 → V2 演进)

V1 已完成核心数据通路 (cdc→transform→sink), V2 聚焦 **数据通路可控可观测**:

| 维度 | V1 状态 | V2 增量 |
|------|--------|---------|
| 数据通路 | 轮询 CDC, 字段映射, 幂等写入 | 保持 (P0 binlog 推 V3) |
| 数据质量 | 无主动校验 | 定时对账 + 增量 diff |
| 运维告警 | 无 | 规则引擎 + 通用 webhook (企业微信) |
| 操作审计 | 表建了, handler 没写 | 完整 operation_log + 审计查询 |
| 可观测性 | 简易监控接口 | Prometheus 指标 + 健康检查增强 |
| 鉴权 | 简易 token | 账号体系 + RBAC + bcrypt |
| 数据源 | MySQL only | 不扩展 (PG/MongoDB 推 V4) |
| 部署 | 单机单二进制 | 保持 (集群化推 V4) |

**关键决策 (本次规划确认)**：
- ❌ **真 binlog CDC 拆出 V3**: 用户暂未指定路线 (手写 vs 封装 C 库), 本轮投入风险大, 暂搁置
- ❌ **Kafka/MQ 不做**: 不在 V2 范围
- ❌ **PostgreSQL/MongoDB 不做**: 不在 V2 范围
- ✅ **对账是 V2 主战场**: 补齐运维闭环
- ✅ **多租户轻量化**: 账号表 + RBAC, 但不强求企业级 IdP

---

## 1. V2 阶段划分 (4 个, 共 6 周)

```
V2.0 (2 周): 对账核心     ─┐
V2.1 (1.5 周): 告警推送    ├─ 运维闭环
V2.2 (1 周): 可观测性      ┘
V2.3 (1.5 周): 鉴权升级     ─ 安全合规

每个阶段独立可发布, 完成后立即可部署生产
```

---

## 2. V2.0 - 对账核心 (2 周)

### 2.1 目标
补齐 V1 缺失的数据质量闭环, 通过定时对账主动发现源/目标库不一致

### 2.2 功能清单

| 编号 | 功能 | 优先级 |
|------|------|--------|
| F2.0.1 | Cron 调度 (zfinal CronPlugin) | P0 |
| F2.0.2 | 全量汇总对账 (订单数 + 金额) | P0 |
| F2.0.3 | 增量行级 diff (抽样) | P1 |
| F2.0.4 | 对账结果入 `reconcile_record` 表 | P0 |
| F2.0.5 | 对账 API: 手动触发 / 列表 / 详情 | P0 |
| F2.0.6 | 对账明细 CSV 导出 (90 天留存) | P2 |

### 2.3 Cron 配置 (`config.toml` 新增)
```toml
[reconcile]
# Cron 表达式 (默认凌晨 2 点)
schedule = "0 0 2 * * *"
# 抽样比例 (1.0 = 全量 diff, 0.1 = 10% 抽样)
sample_ratio = 0.1
# 差值告警阈值 (订单数)
diff_count_threshold = 5
# 差值告警阈值 (金额元)
diff_amount_threshold = 100.0
# 留存天数
retention_days = 90
```

### 2.4 核心 SQL

**全量汇总** (按 mall_id + 目标表):
```sql
-- 源库
SELECT COUNT(*) AS source_count, COALESCE(SUM(order_total), 0) AS source_amount
FROM `<source_table>` WHERE mall_id = ?;

-- 归集库
SELECT COUNT(*) AS target_count, COALESCE(SUM(order_total), 0) AS target_amount
FROM `<target_table>` WHERE mall_id = ?;
```

**增量 diff** (按 PK 抽样):
```sql
-- 双侧 LEFT JOIN, 找出字段不一致的行
SELECT s.id, s.mall_id, s.order_no, s.order_total AS src_total, t.order_total AS tgt_total
FROM `<source_table>` s LEFT JOIN `<target_table>` t
  ON s.mall_id = t.mall_id AND s.order_no = t.order_no
WHERE s.mall_id = ? AND ABS(s.order_total - t.order_total) > 0.01
LIMIT 1000;
```

### 2.5 数据结构 (已有, 启用)
```sql
-- V1 已建表, V2 启用
CREATE TABLE IF NOT EXISTS reconcile_record (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mall_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  source_count INTEGER NOT NULL,
  target_count INTEGER NOT NULL,
  diff_count INTEGER NOT NULL,
  source_amount REAL,
  target_amount REAL,
  diff_amount REAL,
  reconcile_time TEXT DEFAULT (datetime('now')),
  is_abnormal INTEGER NOT NULL DEFAULT 0
);
```

### 2.6 API 端点
| Method | Path | 说明 |
|--------|------|------|
| POST | `/api/v1/reconcile/run` | 手动触发对账 (按 mall_id) |
| GET  | `/api/v1/reconcile/list` | 对账记录列表 (分页, 可按 mall_id 过滤) |
| GET  | `/api/v1/reconcile/:id` | 单次对账详情 |
| GET  | `/api/v1/reconcile/:id/export` | 导出 CSV (90 天留存, 超出 410) |

### 2.7 文件结构
```
src/reconcile/                 # V2.0 新增模块
├── mod.zig
├── cron.zig                   # Cron 调度器注册
├── summary.zig                # 汇总对账
├── diff.zig                   # 增量 diff
├── csv_export.zig             # CSV 导出
└── handler.zig                # REST 端点
```

### 2.8 验收
- [ ] Cron 凌晨 2 点自动跑全量对账
- [ ] 手动 `/api/v1/reconcile/run` 触发 mall_001 对账, 10s 内返回记录 ID
- [ ] 异常对账 (`is_abnormal=1`) 自动触发告警 (留接口给 V2.1)
- [ ] CSV 导出可下载, 内容含明细
- [ ] 单测覆盖率 ≥ 70%

---

## 3. V2.1 - 告警推送 (1.5 周)

### 3.1 目标
实时发现任务异常, 推送告警到企业微信 (或通用 webhook)

### 3.2 功能清单

| 编号 | 功能 | 优先级 |
|------|------|--------|
| F2.1.1 | 告警规则配置 (CRUD, alarm_config 表启用) | P0 |
| F2.1.2 | 通用 webhook 客户端 (POST JSON) | P0 |
| F2.1.3 | 企业微信模板 (markdown 消息格式) | P0 |
| F2.1.4 | 触发器: 同步延迟 (默认 30s 预警 / 60s 告警) | P0 |
| F2.1.5 | 触发器: 任务异常 / 连接断开 | P0 |
| F2.1.6 | 触发器: 对账差值超标 (从 V2.0 接) | P1 |
| F2.1.7 | 告警测试 API (`POST /api/v1/alarm/test`) | P1 |
| F2.1.8 | 告警去重 + 冷却 (5min 内同类不重发) | P1 |

### 3.3 告警规则表 (V1 已建)
```sql
CREATE TABLE IF NOT EXISTS alarm_config (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  alarm_type TEXT NOT NULL,    -- delay_over / task_fail / reconcile_diff
  threshold TEXT,              -- JSON: {"warning_s": 30, "alert_s": 60}
  webhook_url TEXT NOT NULL,
  is_enabled INTEGER NOT NULL DEFAULT 1
);
```

### 3.4 企业微信消息模板
```markdown
## ⚠️ zetl 告警 - {alarm_type}

**任务**: #{task_id} {task_name}
**触发时间**: {timestamp}
**当前值**: {current_value}
**阈值**: {threshold}

> {description}

---
[查看详情]({dashboard_url})
```

### 3.5 核心 API
| Method | Path | 说明 |
|--------|------|------|
| GET    | `/api/v1/alarm/config` | 告警规则列表 |
| POST   | `/api/v1/alarm/config` | 新增规则 |
| PUT    | `/api/v1/alarm/config/:id` | 修改 |
| DELETE | `/api/v1/alarm/config/:id` | 删除 |
| POST   | `/api/v1/alarm/test` | 测试推送 |
| GET    | `/api/v1/alarm/history` | 推送历史 (新增表) |

### 3.6 文件结构
```
src/alarm/                     # V2.1 新增模块 (V1 common/alarm.zig 仅 stub, 升级)
├── mod.zig
├── rule.zig                   # 规则 CRUD
├── trigger.zig                # 触发器 (延迟 / 异常 / 对账)
├── webhook.zig                # 通用 HTTP POST 客户端
├── wechat.zig                 # 企业微信模板渲染
└── history.zig                # 推送历史
```

### 3.7 验收
- [ ] 任务延迟超 30s 触发 warning webhook
- [ ] 任务崩溃触发 fail webhook
- [ ] 同一告警 5min 内不重发
- [ ] 告警测试 API 可推送 markdown 消息
- [ ] 告警历史可查询

---

## 4. V2.2 - 可观测性 + 审计 (1 周)

### 4.1 目标
为运维提供可量化的指标 + 完整的操作审计链路

### 4.2 功能清单

| 编号 | 功能 | 优先级 |
|------|------|--------|
| F2.2.1 | Prometheus 指标导出 (`/metrics`) | P0 |
| F2.2.2 | 健康检查增强 (`/health/live` `/health/ready`) | P0 |
| F2.2.3 | 操作审计 handler (V1 表已建) | P0 |
| F2.2.4 | 审计 API: 列表 / 按操作人过滤 / 按时间范围 | P1 |
| F2.2.5 | 慢任务指标 (per-task 处理耗时 P50/P99) | P2 |

### 4.3 Prometheus 指标
```
# HELP zetl_task_total Total number of sync tasks
# TYPE zetl_task_total gauge
zetl_task_total{status="running"} 5
zetl_task_total{status="error"} 1

# HELP zetl_task_rows_total Total rows synced
# TYPE zetl_task_rows_total counter
zetl_task_rows_total{task_id="1",result="success"} 1234567
zetl_task_rows_total{task_id="1",result="fail"} 3

# HELP zetl_task_duration_seconds Sync batch duration
# TYPE zetl_task_duration_seconds histogram
zetl_task_duration_seconds_bucket{task_id="1",le="0.1"} 100
zetl_task_duration_seconds_bucket{task_id="1",le="1.0"} 950
zetl_task_duration_seconds_bucket{task_id="1",le="10"} 999

# HELP zetl_pool_connections MySQL pool connections
# TYPE zetl_pool_connections gauge
zetl_pool_connections{pool="sink",state="active"} 3
zetl_pool_connections{pool="sink",state="idle"} 5
```

### 4.4 操作审计 (V1 表已有)
```sql
CREATE TABLE IF NOT EXISTS operation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  operator TEXT NOT NULL,    -- 用户名 (V2 接入后是真实账号)
  op_type TEXT NOT NULL,     -- create/update/delete/start/stop/login
  op_target TEXT NOT NULL,   -- 数据源 ID / 任务 ID
  op_detail TEXT,            -- JSON 操作前后内容
  ip TEXT,                   -- 客户端 IP
  created_at TEXT DEFAULT (datetime('now'))
);
```

### 4.5 核心 API
| Method | Path | 说明 |
|--------|------|------|
| GET | `/metrics` | Prometheus 文本格式 |
| GET | `/health/live` | 进程存活 (始终 200) |
| GET | `/health/ready` | 就绪 (DB 可连 + 无 critical 任务异常) |
| GET | `/api/v1/audit/list` | 审计列表 |
| GET | `/api/v1/audit/export` | 审计 CSV 导出 |

### 4.6 文件结构
```
src/metrics/                   # V2.2 新增
├── mod.zig
├── prometheus.zig             # 指标导出
├── registry.zig               # 全局指标注册
src/audit/                     # V2.2 新增
├── mod.zig
├── handler.zig                # 审计 API
└── interceptor.zig            # 自动记录操作 (web 拦截器)
```

### 4.7 验收
- [ ] `/metrics` 返回 Prometheus 标准格式
- [ ] `/health/ready` 在 MySQL 不可连时返回 503
- [ ] 所有 datasource/task 修改自动写 operation_log
- [ ] 审计列表可按时间 + 操作人过滤

---

## 5. V2.3 - 鉴权升级 (1.5 周)

### 5.1 目标
从 V1 硬编码 admin 升级为完整账号体系 + RBAC

### 5.2 功能清单

| 编号 | 功能 | 优先级 |
|------|------|--------|
| F2.3.1 | user/role/permission 表 + 初始化脚本 | P0 |
| F2.3.2 | bcrypt 密码哈希存储 | P0 |
| F2.3.3 | 登录 API 支持 user 表 (迁移 admin/admin123) | P0 |
| F2.3.4 | RBAC 中间件 (admin / operator / viewer) | P0 |
| F2.3.5 | 用户管理 API (CRUD) | P1 |
| F2.3.6 | 角色分配 API | P1 |
| F2.3.7 | 密码修改 / 强制重置 | P1 |

### 5.3 数据模型
```sql
-- 角色
CREATE TABLE IF NOT EXISTS role (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  role_name TEXT NOT NULL UNIQUE,  -- admin / operator / viewer
  description TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

-- 用户
CREATE TABLE IF NOT EXISTS user (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,  -- bcrypt
  display_name TEXT,
  email TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  must_change_password INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  last_login_at TEXT
);

-- 用户-角色
CREATE TABLE IF NOT EXISTS user_role (
  user_id INTEGER NOT NULL,
  role_id INTEGER NOT NULL,
  PRIMARY KEY (user_id, role_id),
  FOREIGN KEY (user_id) REFERENCES user(id),
  FOREIGN KEY (role_id) REFERENCES role(id)
);

-- 角色-权限 (permission 是字符串, 如 "datasource:create")
CREATE TABLE IF NOT EXISTS role_permission (
  role_id INTEGER NOT NULL,
  permission TEXT NOT NULL,  -- "*" 表示通配
  PRIMARY KEY (role_id, permission),
  FOREIGN KEY (role_id) REFERENCES role(id)
);
```

### 5.4 角色定义 (V2.3 默认)
| 角色 | 权限 |
|------|------|
| admin | `*` (所有) |
| operator | `datasource:*`, `task:*`, `reconcile:run`, `alarm:*` |
| viewer | `datasource:read`, `task:read`, `monitor:read`, `reconcile:read`, `audit:read` |

### 5.5 RBAC 中间件
```zig
// 路由装饰器风格
try app.postWithInterceptors("/api/v1/datasource", datasource.create, &.{
    rbacInterceptor("datasource:create"),
});

// 中间件检查当前 token 对应的 user 是否有该权限
// 无权限 → 403 + 审计日志
```

### 5.6 核心 API
| Method | Path | 权限 | 说明 |
|--------|------|------|------|
| GET    | `/api/v1/user` | user:read | 用户列表 |
| POST   | `/api/v1/user` | user:create | 新增 |
| PUT    | `/api/v1/user/:id` | user:update | 修改 |
| DELETE | `/api/v1/user/:id` | user:delete | 删除 |
| POST   | `/api/v1/user/:id/reset-password` | user:update | 重置 |
| GET    | `/api/v1/role` | role:read | 角色列表 |
| POST   | `/api/v1/role/:id/assign` | role:assign | 分配用户角色 |

### 5.7 文件结构
```
src/auth/                      # V2.3 重大扩展 (V1 web/auth_middleware.zig 仅 stub)
├── mod.zig
├── user.zig                   # 用户 Model + Service
├── role.zig                   # 角色 Model + Service
├── bcrypt.zig                 # 密码哈希
├── rbac.zig                   # 权限检查
├── jwt.zig                    # 升级到真 JWT (可选, V1 是 random token)
└── handler.zig                # 用户管理 API
```

### 5.8 数据迁移
- V1 默认 admin/admin123 自动迁移到 user 表 (首次启动检测)
- 已有的 token 全部失效, 需重新登录

### 5.9 验收
- [ ] admin / operator / viewer 三个角色测试通过
- [ ] 无权限访问 → 403
- [ ] 密码 bcrypt 存储, 不能明文
- [ ] 用户管理 API 可用
- [ ] V1 admin 账号自动迁移

---

## 6. 数据流变化总览

### V1 数据流
```
源 MySQL ─(轮询)─> RowEvent ─> TransformEngine ─> MySqlSink ─> 归集 MySQL
                       │
                       └─> sync_position (位点)
```

### V2 数据流 (新增部分)
```
                  ┌─ V2.0 对账 ─────────┐
源 MySQL ────────>├─ 汇总 / 抽样 diff   ├──> reconcile_record
                  └─────────────────────┘
                            │
                            ├ 差值超标 ─> V2.1 告警
                            └─ CSV 导出

V1 任务运行时 ──────────> V2.1 触发器
  - 延迟超 30s ────────────>  warning webhook
  - 任务异常 ─────────────>  fail webhook

所有 API 调用 ──────────> V2.2 审计 (operation_log)

Web 容器 / 业务指标 ─────> V2.2 Prometheus `/metrics`

用户登录 ───────────────> V2.3 user 表 + bcrypt + RBAC
```

---

## 7. 兼容性 & 升级路径

### 数据库迁移
- V1 → V2.0: 启用已有 `reconcile_record` / `operation_log` 表 (无 schema 变更)
- V2.0 → V2.1: 新增 `alarm_history` 表
- V2.1 → V2.2: 新增 `user` / `role` / `user_role` / `role_permission` 表
- V2.2 → V2.3: V1 默认 admin 自动迁移到 user 表

### API 兼容性
- V1 API 全部保留, 行为不变
- V2 新增的 API 走 `/api/v1/v2/*` 路径前缀, 避免命名冲突
- 鉴权升级 (V2.3) 是一次性 breaking change: 旧 token 全部失效

### 部署升级
```bash
# V1 → V2.0 升级步骤
1. 停服
2. 拉新代码 + 编译 (zig build -Ddriver_mysql=true)
3. 启动 (自动迁移 SQLite 元数据表, V1 数据全保留)
4. 配 config.toml 新增 [reconcile] 段
5. 验证
```

---

## 8. 验收标准 (V2 整体)

### V2.0 验收
- [ ] Cron 凌晨 2 点自动跑对账
- [ ] 手动触发对账 API 可用
- [ ] 差值超标自动写 `is_abnormal=1`
- [ ] CSV 导出可下载

### V2.1 验收
- [ ] 告警规则 CRUD 可用
- [ ] 任务异常 → 5min 内 webhook 推送
- [ ] 同一告警 5min 冷却
- [ ] 告警历史可查询

### V2.2 验收
- [ ] `/metrics` Prometheus 格式正确
- [ ] `/health/ready` 503 当 MySQL 不可连
- [ ] 所有写操作自动审计

### V2.3 验收
- [ ] admin / operator / viewer 三角色可登录
- [ ] 无权限操作 → 403
- [ ] 密码 bcrypt 存储
- [ ] V1 admin 自动迁移

### V2 整体 (PRD §8 验收对齐)
1. **每日自动对账, 差值异常推送企业微信告警** ✅ (V2.0 + V2.1)
2. **Web 控制台可查看所有任务状态、延迟、日志, 操作留痕** ✅ (V2.2)
3. **手动中断网络 10 分钟后恢复, 数据自动续传** - V1 已支持, V2 强化告警
4. **重启服务后同步位点正确** - V1 已支持, V2 加审计
5. **单任务配置错误崩溃, 不影响其他 29 条任务** - V1 已支持, V2 加 Prometheus 告警

---

## 9. V2 进度跟踪

| 阶段 | 周期 | 状态 | 主要交付 |
|------|------|------|----------|
| V2.0 | 2 周 | ⏸ 待开始 | 对账核心 (Cron + 汇总 + 增量 diff + CSV) |
| V2.1 | 1.5 周 | ⏸ 待开始 | 告警 (规则 + webhook + 企业微信 + 冷却) |
| V2.2 | 1 周 | ⏸ 待开始 | 可观测性 (Prometheus + 审计 + 健康检查) |
| V2.3 | 1.5 周 | ⏸ 待开始 | 鉴权 (user/role + bcrypt + RBAC) |

---

## 10. V2 后路线 (V3+ 候选)

按 spec §10 + PRD §1.4 整理:

- **V3 - 真 binlog CDC**: 用户确定路线后实施 (手写协议 vs 封装 C 库)
- **V4 - 多源支持**: PostgreSQL / MongoDB / API 源
- **V4 - 集群化**: 多节点协调, 主备切换
- **V4 - Kafka/MQ**: 引入消息队列做削峰

V2 推进时不预设 V3+ 方案, 每个版本独立 shippable.
