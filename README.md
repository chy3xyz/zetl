# zetl — 多源 MySQL 数据归集 ETL 引擎

**基于 Zig 0.17 + [zfinal](https://github.com/zfinal-org/zfinal) 框架的轻量 ETL 引擎**

[![Zig](https://img.shields.io/badge/Zig-0.17-orange)](https://ziglang.org)
[![zfinal](https://img.shields.io/badge/zfinal-v0.10.4-blue)](https://github.com/zfinal-org/zfinal)

## 特性 (V2)

- **单二进制部署** — 3.8 MB, 包含 Web UI + REST API + ETL 引擎
- **多源 MySQL 归集** — 多个商城/业务库 → 统一归集库
- **伪 CDC 轮询** — 主键分页全量 + update_time 增量
- **字段映射 + 佣金计算** — JSON 配置化, 阶梯佣金规则
- **幂等写入** — INSERT...ON DUPLICATE KEY UPDATE
- **定时对账** — Cron 凌晨 2 点 + 增量 diff + CSV 导出
- **告警推送** — 通用 webhook + 企业微信 Markdown, 5min 冷却
- **Prometheus 指标** — /metrics, /health/live, /health/ready
- **操作审计** — 所有写操作自动记录
- **RBAC 鉴权** — admin/operator/viewer 三角色, SHA256+salt
- **HTMX + Alpine.js UI** — 单 HTML @embedFile

## 快速开始

```bash
# 编译 (仅 SQLite 模式, 不连 MySQL)
zig build

# 编译 + 链接 MySQL (需要 libmysqlclient)
zig build -Ddriver_mysql=true

# 运行
./zig-out/bin/zetl

# 测试
zig build test
```

## 配置

编辑 `config.toml`:

```toml
[server]
port = 18080

[sink]
host = "127.0.0.1"
port = 3306
database = "zetl_sink"
username = "root"
password = ""
pool_size = 8
batch_size = 1000

[meta]
sqlite_path = "zetl_meta.db"

[engine]
full_sync_sleep_ms = 100
incremental_poll_ms = 2000

[log]
level = "info"
```

## API 端点 (33 个)

```
公开:
  GET  /health               健康检查
  GET  /health/live          存活探针
  GET  /health/ready         就绪探针
  GET  /metrics              Prometheus 指标
  GET  /                     管理 UI
  POST /api/v1/auth/login    登录
  POST /api/v1/auth/logout   登出

受保护 (Bearer Token):
  GET  /api/v1/auth/me               当前用户
  POST /api/v1/datasource            创建数据源
  GET  /api/v1/datasource/list       数据源列表
  POST /api/v1/datasource/test       测试连接
  DELETE /api/v1/datasource/:id      删除数据源
  POST /api/v1/task                  创建同步任务
  GET  /api/v1/task/list             任务列表
  GET  /api/v1/task/:id              任务详情
  POST /api/v1/task/:id/start        启动任务
  POST /api/v1/task/:id/stop         停止任务
  DELETE /api/v1/task/:id            删除任务
  GET  /api/v1/monitor/overview      监控概览
  GET  /api/v1/monitor/task/:id      任务指标
  POST /api/v1/reconcile/run         手动对账
  GET  /api/v1/reconcile/list        对账记录
  GET  /api/v1/reconcile/:id         对账详情
  GET  /api/v1/alarm/config          告警规则
  POST /api/v1/alarm/config          创建规则
  DELETE /api/v1/alarm/config/:id    删除规则
  POST /api/v1/alarm/test            测试告警
  GET  /api/v1/audit/list            审计日志
  GET  /api/v1/user                  用户列表
  POST /api/v1/user                  创建用户
  GET  /api/v1/role                  角色列表
```

## E2E 测试

```bash
# 建测试库
mysql -u root -e "CREATE DATABASE IF NOT EXISTS zetl_source; CREATE DATABASE IF NOT EXISTS zetl_sink;"
mysql -u root zetl_source < schema_source.sql
mysql -u root zetl_sink < schema.sql

# 启动 zetl
./zig-out/bin/zetl &

# 注册数据源 + 创建任务 + 启动
TOKEN=$(curl -sS -X POST -d '{"username":"admin","password":"admin123"}' \
  http://127.0.0.1:18080/api/v1/auth/login | jq -r '.data.token')
curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"mall_id":"mall_001",...}' \
  http://127.0.0.1:18080/api/v1/datasource
curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"task_name":"订单同步",...}' \
  http://127.0.0.1:18080/api/v1/task
curl -X POST -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:18080/api/v1/task/1/start

# 验证
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18080/api/v1/monitor/overview
```

## 项目结构

```
src/
├── main.zig                入口
├── config.zig              TOML 配置解析
├── common/                 日志/加密/告警
├── meta/                   元数据 (SQLite)
│   ├── store.zig           建表
│   ├── datasource.zig      数据源 CRUD
│   ├── task.zig            任务 CRUD
│   ├── position.zig        位点管理
│   └── metrics.zig         运行时指标
├── cdc/                    采集器
│   ├── event.zig           RowEvent
│   └── poller.zig          伪 CDC 轮询
├── transform/              转换
│   ├── mapper.zig          字段映射
│   ├── commission.zig      佣金计算
│   └── engine.zig          流水线
├── sink/
│   └── mysql_sink.zig      幂等批量写入
├── engine/
│   ├── runtime.zig         任务运行时
│   └── scheduler.zig       多任务调度
├── web/                    Web 层
│   ├── routes.zig          路由注册
│   ├── deps.zig            全局依赖
│   ├── auth_middleware.zig 鉴权中间件
│   ├── response.zig        统一响应
│   └── handler/            各模块 handler
├── reconcile/              V2.0 对账
├── alarm/                  V2.1 告警
├── metrics/                Prometheus
├── audit/                  V2.2 审计
├── auth/                   V2.2 鉴权升级
└── assets/
    └── index.html          管理 UI
```

## 依赖

- [zfinal](https://github.com/zfinal-org/zfinal) v0.10.4 — Web 框架, DB 驱动, Token 管理
- Zig 0.17 — 编译器和标准库
- MySQL 8.x — 归集库 (需要 libmysqlclient)
- SQLite 3 — 元数据库 (系统自带)

## 许可

MIT
