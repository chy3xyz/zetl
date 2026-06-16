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

- **伪 CDC**: V1/V2 基于 `update_time` 轮询, 非真实 binlog; 物理删除无法感知, 源表需用 `is_delete=1` 软删除才会同步为删除.
- **优雅停机**: ✅ zfinal v0.10.8 已修复; SIGTERM/SIGINT 可在 ~3s 内完成停机, 无 panic, 无泄漏.
