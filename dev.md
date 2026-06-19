# zetl 开发笔记

## 日志

### 2026-06-15
- 初始 V1 spec 完成 (PRD/imp/ard)
- V1 设计文档 (2026-06-16-zetl-v1-design.md)

### 2026-06-16
- V1 核心同步闭环实现 (3567 行)
- V2 三个阶段完成 (4934 行)
  - V2.0: 对账 (reconcile)
  - V2.1: 告警 + Prometheus + 审计
  - V2.2: 鉴权升级 (user/role/RBAC)
- zfinal 升级 0.8.1 → 0.10.6, 修复 task thread MySQL 连接问题
- 全量 + 增量 (update_time 轮询) 闭环跑通
- 任务默认 sync_mode 改为 `both` (先全量后增量)

## 架构决策

1. **元数据 SQLite + 业务 MySQL** — 元数据量小(< 100 数据源), 单文件便于备份
2. **手写 Model/Service** — 不用 zfinal 生成器, 表结构固定
3. **单二进制部署** — @embedFile 前端, 无外部文件依赖
4. **伪 CDC** — V1/V2 用轮询 (主键分页 + update_time), 真 binlog 留 V3
5. **主线程创建 Pool → 传入子线程** — zfinal v0.10.4 API 支持, 堆分配字符串

## 依赖版本

| 依赖 | 版本 |
|------|------|
| Zig | 0.17.0-dev.813 |
| zfinal | 0.10.6 |
| MySQL | 8.4 (macOS Homebrew) |
| SQLite | 3 (系统自带) |

## 端点统计

- 公开: 9 个
- 受保护: 24 个
- 总计: 33 个

## 测试覆盖

- 单元测试: 32 个
- SQLite 构建: ✅
- MySQL 构建: ✅
- E2E (全量同步): ✅
- E2E (全量 → 增量同步): ✅

## 性能参考 (V2, MySQL 8.4, M1 Pro)

- 全量同步: 10 行/5ms (批大小 5)
- 增量同步: 2 行/1s 轮询周期
- API 延迟: < 5ms (本地回环), start task ~20ms
- 内存: ~8MB (空闲), ~20MB (4 任务运行)
- 二进制: 3.8MB

## 已知限制

- **伪 CDC → 真 CDC**: V1/V2 基于 `update_time` 轮询; V3 新增真 binlog CDC (`sync_mode=binlog/both`), 可感知物理删除. 已落地为 phase 1, 详见 docs/superpowers/specs/2026-06-16-zetl-v3-binlog-cdc-design.md.
- **V3 binlog parser phase 3**: 已支持 DATETIME / DATETIME2 / NEWDECIMAL / BLOB / TEXT / JSON / VARCHAR (≤255 已支持, 新增 >255 双字节长度) / DATE / YEAR / TIME / TIME2 / TIMESTAMP / TIMESTAMP2 / FLOAT / DOUBLE 解码. 不支持 BIT / ENUM / SET / GEOMETRY, 这些列返回 `error.UnsupportedType`. 已支持自动剥离 4 字节 CRC32 校验和 (`binlog_checksum=NONE` 不再是必须). SHOW MASTER STATUS 在 MySQL 8.0.22+ 改为 SHOW BINARY LOG STATUS.
- **优雅停机**: ✅ zfinal v0.10.8 已修复; SIGTERM/SIGINT 可在 ~3s 内完成停机, 无 panic, 无泄漏.

## 稳定性修复 (Stability)

- `SyncTask.state` 是 `TaskStatus` enum (pending / running / success / @"error"), 取代之前的 `is_running / is_finished / status: i32` 三字段, 状态转换在编译期可检查.
- `SyncTask.start()` 通过 CAS retry 实现, 重复调用返回 `error.AlreadyRunning`.
- `SyncTask.stop()` 翻转 `should_stop` 标志 + join, 不修改 `state` (由 runLoop 退出时根据自身结果置 success / @"error").
- `SyncTask.deinit()` 幂等: `_deinit_done` 原子标志保证多次调用只生效一次.
- ConnectionPool 双重 deinit 已通过 `_pool_deinit_done` 原子标志保护 (zfinal 内部引用计数是后续优化).

## 动态任务管理 (Phase 5)

任务定义存储在 `tasks_config` 表中 (DDL 在 `src/meta/store.zig::createAllTables()`).

HTTP API:
- `GET /api/tasks`           列出所有任务
- `POST /api/tasks`          创建任务 (body = TaskConfig JSON)
- `GET /api/tasks/{id}`      查看单个任务
- `PUT /api/tasks/{id}`      更新任务 (active 时自动 reload)
- `DELETE /api/tasks/{id}`   删除任务 (active 时先 stop)
- `POST /api/tasks/{id}/reload`  强制重载

启动时 `Scheduler.loadFromDb()` 自动加载所有 `status=active` 任务.

详见 `docs/superpowers/specs/2026-06-15-zetl-config-dynamic-tasks-design.md`.
