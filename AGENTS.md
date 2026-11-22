# zetl — Agent Instructions

## 业务场景搭建

如果你的任务是 **为一个新的同步场景写 zetl 配置 JSON** (不是改 zetl 自身代码), 先读 `docs/ai-recipes/README.md` 的决策树. 通常读 1 个 recipe + 1-2 个 reference 就够.

如果你的任务是 **改 zetl 自身代码** (加新模块 / 修 bug / 加测试), 按下面的"构建"和"编码约定"继续.

## 项目概述

zetl 是一个基于 Zig 0.17.0 stable + zfinal v0.28.11 的多源 MySQL 数据归集 ETL 引擎。

- **框架**: zfinal v0.28.11 (`build.zig.zon` 用 `git+https` 固定 tag + commit, 升级时用 `zig fetch "git+https://github.com/chy3xyz/zfinal.git?ref=<tag>"` 取 hash 后手工补 `.url`/`.hash`; zent v0.78.0 经 zfinal 传递拉取)
- **编译器**: Zig 0.17.0 stable (zigup; `~/.zig` → `~/.local/share/zigup/0.17.0/files`; zfinal v0.28.1+ 要求 stable, dev.2151 时代已结束)
- **架构**: 6 大模块 — common/meta/cdc/transform/sink/engine/web
- **任务系统**: V5 `/api/tasks` (tasks_config 表) 为唯一任务系统 — legacy `/api/v1/task` (sync_task 表) 已于 2026-11-21 移除, 消费方 (UI/reconcile/monitor/metrics/bootstrap) 全部迁移; V5 stop 语义 = `POST /api/tasks/:id/stop` (停实例留配置) 或 `PUT status=0` (停用)
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
zfinal.DB.init(allocator, config)           // 单连接, 返回 *DB (堆分配) — 用完调 db.destroy() 而非 deinit()
zfinal.ConnectionPool.init(allocator, config, N)  // 连接池, 返回 *ConnectionPool
pool.acquire() / pool.release(conn)         // 获取/归还连接
```

### RowData 所有权
`transform.engine.freeRowData(allocator, &row)` — 释放 HashMap 内所有 key/value 并 deinit。必须对所有 process() 返回的 RowData 调用。

### V5 config_json 透传 (scheduler)
`/api/tasks` 的 `config_json` 支持键 (scheduler.parseV5Overrides, 失败降级默认 + warn):
`batch_size` / `field_mappings` (string|object) / `filter: {field,op,value}` /
`enable_commission_calc` / `transform.*` (naming_rules + mask 开关).
字符串借用自解析 arena, TransformEngine 在 SyncTask.init 内 dupe — arena 存活到 init 返回即可.

### PollerConfig
使用 `PollerConfig.fromSlices(host, port, user, pass, db, table, pk, ut, batch)` 创建，内部是 fixed-size buffers (`@splat(0)`)。

### 线程安全
- zfinal `ConnectionPool` 在主线程创建后、通过 `*ConnectionPool` 指针传入子线程。
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

## 自动建表与幂等

自动建表 (`ensureTargetTable`) 现在会追加 `UNIQUE KEY uk_zetl_mall_pk (mall_id, pk_column)`
(pk_column 默认 "id", 来自源表主键), 让 `INSERT ... ON DUPLICATE KEY UPDATE` 真正幂等 —
源行 UPDATE 后 re-sync 原位更新. pk 不在源列中时跳过唯一键 (幂等降级, warn 日志).
若业务唯一键不是主键 (如 uk(mall_id, order_no)), 需预建目标表.

## 已知问题

1. ~~**任务线程 MySQL 连接**~~ **已解决 (2026-11-21 实测)**:
   - 历史: Zig 0.17-dev (1567/1970) + 旧 zfinal 上, 主线程创建的 ConnectionPool 在子线程 acquire 报 `Lost connection at 'reading initial communication packet'`
   - 现状: zfinal v0.28.x pool 加固 + Zig 0.17.0 stable 后, 子线程 acquire/query/写入全部正常 (双 worker 并发实测通过)
   - 回归测试: `src/pool_mysql_live_test.zig` (env 门控), 运行方式:
     ```bash
     # 需本地 MySQL, 先建库: CREATE DATABASE zetl_live_test; 并建表 t_live (id INT PK, v VARCHAR(32))
     ZETL_LIVE_MYSQL=1 zig build -Ddriver_mysql=true test
     # 可用 ZETL_LIVE_MYSQL_HOST/PORT/USER/PASS/DB 覆盖默认 root@127.0.0.1:3306/zetl_live_test
     ```
2. **TokenManager validate() 死锁**: V2 绕过，logout 靠客户端丢 token + 服务端 TTL

## 测试

```
255 个单元测试 (zig build test / zig build -Ddriver_mysql=true test):
  transform (69) / cdc (47, 含 binlog decoder 22) / auth (26, 含 bootstrap admin 1)
  / engine (29, 含 V5 config_json 透传 6) / reconcile (19) / alarm (15)
  / web (16, 含 deps sweep 1)
  / sink (17, 含 DDL 唯一键 3) / meta (8) / audit (3) / main (2) / config (2) / common (2)
  / pool live (1, env 门控默认 SKIP)

SQLite + MySQL 双构建通过; live MySQL 测试需 ZETL_LIVE_MYSQL=1 (见已知问题 #1);
已知怪癖: 重建后首次 zig build test 可能打印一行 "failed command" 但退出码为 0
— 构建器对 run step 的显示噪音, 缓存命中后不再出现
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
