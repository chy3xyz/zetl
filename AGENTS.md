# zetl — Agent Instructions

## 业务场景搭建

如果你的任务是 **为一个新的同步场景写 zetl 配置 JSON** (不是改 zetl 自身代码), 先读 `docs/ai-recipes/README.md` 的决策树. 通常读 1 个 recipe + 1-2 个 reference 就够.

如果你的任务是 **改 zetl 自身代码** (加新模块 / 修 bug / 加测试), 按下面的"构建"和"编码约定"继续.

## 项目概述

zetl 是一个基于 Zig 0.17 + zfinal v0.10.4 的多源 MySQL 数据归集 ETL 引擎。

- **框架**: zfinal 0.10.4 (Web + DB + Token 管理)
- **编译器**: Zig 0.17-dev.813
- **架构**: 6 大模块 — common/meta/cdc/transform/sink/engine/web
- **V2 新增**: reconcile / alarm / metrics / audit / auth (共 13 模块)

## 构建

```bash
# SQLite 模式 (单元测试, 单测)
zig build

# MySQL 模式 (完整构建, 需要 libmysqlclient)
zig build -Ddriver_mysql=true

# 运行所有测试
zig build test
zig build -Ddriver_mysql=true test

# 运行
zig build run -Ddriver_mysql=true
# 或
./zig-out/bin/zetl
```

## 编码约定

### 核心 API (zfinal)
```zig
// 路由注册
app.get(path, handler)           // 无鉴权
app.getWithInterceptors(path, handler, &interceptors)  // 带拦截器

// 上下文操作
ctx.renderJson(data)             // 序列化任意类型到 JSON
ctx.parseJsonBody(T)             // 解析请求体
ctx.getPathParam("id")           // 路径参数
ctx.getHeader("Authorization")   // 请求头

// 数据库
zfinal.DB.init(allocator, config)           // 单连接
zfinal.ConnectionPool.init(allocator, config, N)  // 连接池 (v0.10.4 返回 *ConnectionPool)
pool.acquire() / pool.release(conn)         // 获取/归还连接
```

### RowData 所有权
`transform.engine.freeRowData(allocator, &row)` — 释放 HashMap 内所有 key/value 并 deinit。必须对所有 process() 返回的 RowData 调用。

### PollerConfig
使用 `PollerConfig.fromSlices(host, port, user, pass, db, table, pk, ut, batch)` 创建，内部是 fixed-size buffers (`@splat(0)`)。

### 线程安全
- zfinal `ConnectionPool` 在主线程创建后、通过 `*ConnectionPool` 指针传入子线程 — v0.10.4 API。
- **池的 DBConfig 字符串必须堆分配**（不能引用栈），由 `SyncTask._sh/_sd/_su/_sp` 持有寿命。

### 字符串寿命
```zig
// ❌ 错误: 栈 buffer, startTask 返回后失效
var buf: [64]u8 = undefined;
const cfg = .{ .host = buf[0..len:0] }; // 指向栈

// ✅ 正确: 堆分配, SyncTask 持有
const host = try allocator.dupe(u8, ds.host);
const cfg = .{ .host = host }; // 指向堆
```

## 数据流

```
源 MySQL ─→ Poller(主键分页/update_time) ─→ RowEvent
  ─→ TransformEngine(字段映射+常量+过滤+佣金) ─→ RowData
  ─→ MySqlSink(批量 INSERT...ON DUPLICATE KEY) ─→ 归集 MySQL
```

## 已知问题

1. **任务线程 MySQL 连接** (`Lost connection at 'reading initial communication packet'`):
   - `DB.init` 在子线程首行可用，但从 `ConnectionPool.acquire` 路径失败
   - 主线程 API (testConnection) 100% 可靠
   - 原因: Zig 0.17-dev 在 aarch64-macos 上的线程局部存储与 mysql C 库交互问题
   - 进度: zfinal v0.10.4 修复了 mutex 拷贝 (#1), 但 acquire 路径仍有问题

2. **TokenManager validate() 死锁**: V2 绕过，logout 靠客户端丢 token + 服务端 TTL

## 测试

```
71 个单元测试覆盖:
  crypto (2) / mapper (5) / commission (9, 含 loadCommissionRules 3 个) / engine (2)
  sink (10) / meta (1) / poller (1) / web (1) / config (2, 含 reconcile 段)
  auth/role/bcrypt/user (新增) / alarm / reconcile (9 个 cron 新增) / audit / main (2)

SQLite + MySQL 双构建通过
```

## P1 任务 1.5: 归集库不可达优雅降级 (2026-06)

佣金规则加载 (`transform.commission.loadCommissionRules`) 设计为**绝不抛 error**:
- 归集库不可达 / 表不存在 / 解析失败 → 打 warn + 返回空切片
- `engine.runtime.SyncTask` 新增 `last_rules_loaded_at: std.atomic.Value(i64)` +
  `rules_max_age_sec: i64 = 300` (5 min), 由 `reloadRulesIfStale()` 触发 stale-retry
- 等归集库恢复后, 下次同步周期 (≤5 min) 自动重新拉取

新测试:
- `loadCommissionRules: graceful degradation when rules table missing` — pool OK, 表不存在 → 降级空
- `loadCommissionRules: returns empty on closed-port MySQL host` — 文档化 unreachable 场景
- `loadCommissionRules: returns rules on healthy sink (SQLite stub)` — 正常 path

## P1 任务 1.2: 对账 Cron 调度 (2026-06)

`src/reconcile/cron.zig` 实现了**进程内轻量级线程化 cron** (不依赖 zfinal CronPlugin, 它会拉起 MySQL):
- `CronConfig` (enabled / cron_expr / poll_interval_s) + `config.Config.ReconcileConfig` 双向转换
- 解析支持 `@hourly` / `@daily` / `@weekly` / `@monthly` / `@yearly` 简写 + 5 字段标准 cron
  (字段仅支持 `*` 与单数字; 其他语法 → `error.InvalidCronExpression`)
- `CronSchedule` 是位图表示的 5 字段时间表, `matches(timestamp)` 按 minute 粒度判断
- `init()` 启动 `std.Thread.spawn` 后台线程, 周期 `poll_interval_s` (默认 60s) 检查
- `last_fire_minute` 原子去重, 避免同分钟多次触发; 启动时初始化为当前分钟, 避免开机立即 fire
- `runNow(ctx, task_id)` 手动触发 (供测试 / API)
- `deinit()` 设 `running=false` → join 线程 → 释放堆字符串

`[reconcile]` 配置段 (新增, 可选, 无则用默认值):
```toml
[reconcile]
enabled = true
cron_expr = "0 2 * * *"   # @daily / @weekly / 5 字段
poll_interval_s = 60
```

调用流程 (在 `src/main.zig` 启动 web 前注入):
```zig
const cron_cfg = reconcile.cron.CronConfig.fromReconcileConfig(cfg.reconcile);
const cron_ctx = reconcile.cron.init(allocator, scheduler, &store, cron_cfg) catch ...;
defer cron_ctx.deinit();   // 进程退出时优雅停机
```

新测试 (9 个):
- `cron parse @daily / @hourly / @weekly / @monthly` — 简写解析
- `cron parse 5-field` — 标准 5 字段 + 越界拒绝
- `cron parse invalid` — 非数字 / 字段数错 / 值越界
- `cron matches at midnight UTC` — 已知 epoch 命中 / 漏命中
- `cron matches at specific minute` — `30 14 * * *` 命中 14:30
- `cron fromReconcileConfig` — Config → CronConfig 转换
