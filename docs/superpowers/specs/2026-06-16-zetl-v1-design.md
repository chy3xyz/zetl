# zetl V1 设计文档

- **项目代号**：zETL（基于 Zig 0.17 + zfinal 的多源 MySQL 数据归集 ETL 引擎）
- **设计日期**：2026-06-16
- **适用版本**：V1（核心同步闭环）
- **来源需求**：`docs/zetl_prd.md`（PRD）、`docs/imp.md`（核心模块实现参考）、`docs/ard.md`（架构与建表）
- **依赖框架**：zfinal（本地路径 `../../zig_ws/zfinal`，Zig 0.17 AI 极速开发框架）
- **状态**：已确认架构方案 A，待用户 review 本文档后进入实现计划

---

## 0. 设计基线（本次 brainstorming 已确认的决策）

本次设计基于三个用户确认的范围决策，是后续所有内容的基线：

| 决策点 | 选择 | 影响 |
|--------|------|------|
| CDC binlog 深度 | **轮询增量 + 位点（伪 CDC）** | 不实现 binlog 复制协议；用 zfinal 现有 MySQL 客户端按 `update_time`/自增主键轮询，位点记录最后同步点。真 binlog 留作 V2 |
| 数据库布局 | **元数据 SQLite + 业务 MySQL** | 元数据（datasource/task/position）用 SQLite 文件；源库 + 归集库用本地 MySQL。完全贴合 PRD 与 imp.md，zfinal 原生双 DB 能力直接用 |
| V1 交付范围 | **核心同步闭环** | 数据源管理 + CDC 全量/增量 + ETL 转换 + 幂等写入 + 断点续传 + 基础 Web 控制台。对账/告警/Cron 留作下一周期 |

**架构方案**：方案 A —— 纯 zfinal 应用 + 手写 ETL 核心。

- 复用 zfinal：`DB`/`ConnectionPool`/`MySQLDB` 驱动/`Model`/`Validator`/`Logger`/`Metrics`/`CronPlugin`/路由 + `Context`
- 手写 zfinal 不提供的能力：轮询 CDC、ETL 转换流水线、幂等批量 Sink
- 元数据层手写（表少且结构固定，手写比生成器 `.gen.zig` 重新生成模式更清晰）

**不在 V1 范围**（明确排除，避免范围蔓延）：binlog 复制协议、分布式集群、Kafka/MQ、PostgreSQL 源、多租户、自动对账、企业微信告警推送、操作审计、CSV 导出、定时 Cron 全量对账。

---

## 1. 整体架构与模块划分

zetl 是一个 **zfinal 应用**，单二进制部署。

### 1.1 进程拓扑（单进程）

```
主线程:    zfinal HTTP 服务 (Web 控制台 API + @embedFile 前端)
任务线程:  每个启用的同步任务一条独立线程跑 SyncTask.run() 循环
           (全量初始化 → 增量轮询),任务隔离,单任务崩溃不影响其他
后台线程:  定时刷盘位点 + 指标采集 (周期性 flush)
```

- 任务隔离靠线程边界：每个 `SyncTask` 独立持有自己的源库连接、归集库连接、转换引擎、Sink 实例，互不共享可变状态。
- 全局共享只读/线程安全：归集库连接池、元数据 SQLite（zfinal DB 内部线程安全）、Token/限流器。

### 1.2 数据流

```
源 MySQL 商城库
   │  Poller: SELECT 分批 (主键分页全量 / update_time>位点 增量)
   ▼
RowEvent (统一行事件: op + table + 字段map)
   │  TransformEngine: 字段映射 + 注入(mall_id,sync_time,source_type)
   │                   + 数据清洗(脱敏/去空格) + 佣金计算 + 过滤
   ▼
RowData (目标行)
   │  MySqlSink: 攒批 → INSERT...ON DUPLICATE KEY UPDATE (幂等)
   ▼
归集 MySQL 库 (union_all_order 等)
   ↕  位点: 每批更新到 SQLite sync_position 表
```

### 1.3 目录结构

贴合 imp.md 分层，但放在 zfinal 应用范式下：

```
zetl/
├── build.zig              # 构建:依赖本地 zfinal,链接 sqlite3 + mysqlclient(driver_mysql=true)
├── build.zig.zon          # .path = "../../zig_ws/zfinal"
├── config.toml            # 运行配置
├── schema.sql             # 元数据(SQLite) + 业务表(MySQL)建表
├── src/
│   ├── main.zig           # 入口:初始化 DB池/调度器/Web,io_instance.init
│   ├── deps.zig           # 全局共享:pool/tokenMgr/rateLimiter (仿 ruoyi-gen)
│   ├── config.zig         # TOML 配置加载
│   ├── meta/              # 元数据层 (SQLite)
│   │   ├── store.zig      # SQLite DB 初始化 + 建表
│   │   ├── datasource.zig # datasource 表 Model/Service
│   │   ├── task.zig       # sync_task 表 Model/Service
│   │   └── position.zig   # sync_position 表 (断点续传)
│   ├── cdc/               # 采集层
│   │   ├── poller.zig     # 轮询增量/全量采集器 (用 zfinal.MySQLDB)
│   │   └── event.zig      # 统一 RowEvent 结构
│   ├── transform/         # ETL 转换引擎
│   │   ├── engine.zig     # 转换流水线
│   │   ├── mapper.zig     # 字段映射/注入
│   │   └── commission.zig # 佣金计算
│   ├── sink/              # 写入层
│   │   └── mysql_sink.zig # 幂等批量 INSERT...ON DUPLICATE KEY
│   ├── engine/            # 任务运行时与调度
│   │   ├── runtime.zig    # SyncTask: 串起 cdc→transform→sink
│   │   └── scheduler.zig  # 多任务线程管理 + start/stop
│   ├── web/               # Web 控制台
│   │   ├── routes.zig     # /api/v1 路由注册
│   │   └── handler/       # datasource/task/monitor 各 handler
│   ├── common/
│   │   ├── crypto.zig     # 密码加密存储
│   │   └── alarm.zig      # 告警 (本期留接口,下周期实现)
│   └── assets/            # 前端 (编译期 @embedFile)
└── test/                  # 集成测试
```

---

## 2. 数据库设计

按 ard.md 建表脚本，分两部分。开发环境用本地 MySQL（libmysqlclient 已确认可用）。

### 2.1 元数据库（SQLite，单文件 `zetl_meta.db`）

V1 用到的 4 张表（PRD 中 alarm_config/operation_log/reconcile_record 属于下周期模块，本期建表预留但不开业务逻辑）：

- **datasource**：数据源配置（id, mall_id[UNIQUE], ds_type, host, port, db_name, username, password[加密], remark, status, created_at, updated_at）
- **sync_task**：同步任务（id, task_name, datasource_id[FK], source_table, target_table, sync_mode[full/cdc/both], field_mappings[JSON], filter_condition, batch_size, status[0停止/1运行/2异常], last_run_time, created_at）
- **sync_position**：同步位点（task_id[PK/FK], last_pk[全量游标], last_update_time[增量游标], last_event_time, updated_at）。**注意**：伪 CDC 不用 binlog_file/gtid_set，改用 `last_pk`(全量) + `last_update_time`(增量) 两个游标。
- **runtime_metrics**：运行时指标（task_id, today_rows, success_count, fail_count, last_error, updated_at）—— 内存态为主，定期落盘，用于监控大盘。

### 2.2 业务归集库（MySQL）

严格按 ard.md §1.1。V1 聚焦 `union_all_order`（全渠道订单归集表），其唯一索引 `uk_mall_order(mall_id, order_no)` 是幂等写入的基石。`union_all_user`、`error_order`、`agent_commission_rule` 建表齐全，佣金计算从 `agent_commission_rule` 读规则。

- **union_all_order**：唯一键 `uk_mall_order(mall_id, order_no)`
- **union_all_user**：唯一键 `uk_mall_user(mall_id, user_id)`
- **error_order**：脏数据表（转换失败/写入失败分流写入）
- **agent_commission_rule**：代理商阶梯佣金规则（commission_rate, min_amount, max_amount）

### 2.3 双 DB 在 zfinal 中的接入

```text
元数据: var meta_db = try zfinal.DB.init(allocator, zfinal.DBConfig.sqlite("zetl_meta.db"));
归集库: var sink_pool = zfinal.ConnectionPool.init(allocator, zfinal.DBConfig.mysql(...), N);
源库:   每任务按 datasource 配置即时建 zfinal.MySQLDB 连接 (走 mysql.zig 驱动)
```

构建：`zig build -Ddriver_mysql=true`，链接 `sqlite3`（系统库）+ `mysqlclient`。

---

## 3. 各模块详细设计

### 3.1 采集层（cdc/）

**统一行事件**（`cdc/event.zig`）：
```zig
pub const RowOp = enum { insert, update, delete };
pub const RowEvent = struct {
    op: RowOp,
    table: []const u8,
    database: []const u8,
    fields: std.StringHashMap([]const u8),  // 字段名→值(字符串)
    timestamp: i64,
};
```
（相比 imp.md 简化：去掉了 before/after 双 map，轮询模式只需 after 即可判定 op；删除事件按软删 `is_delete=1` 处理。）

**轮询采集器**（`cdc/poller.zig`）—— 核心逻辑：
- **全量阶段**（位点为初始）：`SELECT * FROM src WHERE id > ?last_pk ORDER BY id LIMIT batch`，主键游标翻页，不锁表。每批产生 RowEvent(op=insert)。
- **增量阶段**（全量完成后）：`SELECT * FROM src WHERE update_time > ?last_ts ORDER BY update_time LIMIT batch`，按 `update_time` 游标轮询。轮询间隔可配（默认 1s）。判定 op：归集库已存在该主键→update，否则→insert。
- **删除处理**：伪 CDC 无法捕获物理删除，V1 默认软删除场景：源库 `is_delete` 字段变化由增量轮询自然同步（设 `is_delete=1`）。物理删除不支持（文档明示限制）。
- **位点推进**：每批成功写入归集库后，更新 sync_position（last_pk / last_update_time）。
- **限速**：全量阶段可配 sleep，避免打满源库。

**zfinal 复用点**：`MySQLDB.connect`/`query`/`queryParams`/`SqlParam`；不新建连接层。

### 3.2 转换层（transform/）

**转换流水线**（`transform/engine.zig`）：输入 RowEvent → 输出 RowData（目标行）或脏数据错误。处理顺序：
1. **常量注入**：`mall_id`（任务绑定）、`sync_time`（当前时间）、`source_type`（数据源类型）
2. **字段映射**：按 task.field_mappings（JSON：`[{source,target,default}]`）映射，类型转换/空值填充
3. **数据清洗**：手机号/身份证脱敏、字符串去空格、日期格式统一
4. **佣金计算**：若 `enable_commission_calc`，调 `commission.calculate(agent_id, mall_id, order_total)`
5. **过滤**：按 filter_condition（如 `order_status > 0`）判定，不通过→FilterSkip（不计入脏数据，静默跳过）
6. 任一步异常（字段缺失等）→ 返回脏数据错误，写入 error_order

**字段映射器**（`transform/mapper.zig`）：从 sync_task.field_mappings JSON 解析为 `[]FieldMapping`，提供 `map(source_row) → target_row`。

**佣金计算**（`transform/commission.zig`）：基本沿用 imp.md §2.2 的 `CommissionCalculator` —— 支持固定比例 + 阶梯金额，优先级「指定商城规则 > 全商城通用（mall_id="*"）」。规则从归集库 `agent_commission_rule` 加载，缓存到内存（启动 + 定时刷新）。

### 3.3 写入层（sink/）

**幂等批量 Sink**（`sink/mysql_sink.zig`）：基本沿用 imp.md §2.3 的 `MySqlSink`：
- `append(row)`：攒入 batch_buffer，达 `batch_size` 自动 flush
- `flush()`：构造 `INSERT INTO ... VALUES (...),(...) ON DUPLICATE KEY UPDATE <非唯一键=VALUES(非唯一键)>`，一条语句写整批
- **ConflictStrategy**：ignore / update（默认）/ error
- **幂等基石**：归集库 `uk_mall_order(mall_id, order_no)` 唯一索引
- **脏数据分流**：flush 失败的行 → 写 error_order（带 raw_data 快照 + error_msg）
- **限流**：可配目标端最大 QPS（简单 sleep 节流）

**zfinal 复用点**：用 `sink_pool`（zfinal ConnectionPool）取连接 → `MySQLDB.exec`（注意：批量 SQL 用 `exec` 而非 `execParams`，因为列数动态；需对值做 SQL 转义防注入——V1 实现一个简单 `escapeString`）。

### 3.4 元数据层（meta/）

手写 Model/Service（不跑 zf 生成器，结构固定且少）：
- **store.zig**：`MetaStore.init(allocator, sqlite_path)` → 建所有元数据表（IF NOT EXISTS）
- **datasource.zig / task.zig**：`zfinal.Model(Datasource, "datasource")` 风格的 struct + Service（findById/findAll/listPage/insert/update/delete/count）。密码字段加解密在 Service 层做（存密、读明）。
- **position.zig**：`load(task_id)` / `save(pos)` / `delete(task_id)`。save 用 `INSERT ... ON CONFLICT(task_id) DO UPDATE`（SQLite 语法）。

**zfinal 复用点**：`zfinal.Model`、`zfinal.DB`（SQLite）、`SqlParam`、`Page`。

### 3.5 引擎运行时（engine/）

**SyncTask**（`engine/runtime.zig`）：一个同步任务的运行实体。
```zig
pub const SyncTask = struct {
    task_cfg: TaskConfig,
    src_db: zfinal.MySQLDB,        // 源库连接(任务独占)
    sink: MySqlSink,               // 归集库写入(走 sink_pool)
    transformer: TransformEngine,
    pos: SyncPosition,             // 内存位点,定期刷盘
    metrics: TaskMetrics,          // 本任务指标
    is_running: std.atomic.Value(bool),
    fn run() void { /* 全量→增量循环,每批 cdc→transform→sink */ }
    fn stop() void { is_running.store(false); }
};
```

**Scheduler**（`engine/scheduler.zig`）：
- `startTask(id)`：加载 task_cfg + datasource → 建 SyncTask → `std.Thread.spawn` 跑 `run` → 存入 `tasks: AutoHashMap(id, *SyncTask)`
- `stopTask(id)`：设 is_running=false，join 线程，刷盘位点
- `startAllEnabled()`：启动时拉取所有 status=1 的任务
- 故障隔离：run() 内部 try/catch，异常→标记 status=2 + 记 last_error，不 panic 整个进程

### 3.6 Web 控制台（web/）

**统一响应**（imp.md §1.1）：`{code, msg, data}`，错误码 0/1/2/3/5。统一前缀 `/api/v1`。

**V1 接口（对齐 imp.md §1.2-1.4）**：

数据源管理（`handler/datasource.zig`）：
- `POST   /api/v1/datasource` 新增（含连通性 + binlog 配置校验）
- `POST   /api/v1/datasource/test` 测试连通性
- `GET    /api/v1/datasource/list` 分页列表
- `DELETE /api/v1/datasource/:id` 删除（已绑定任务不可删）

同步任务（`handler/task.zig`）：
- `POST   /api/v1/task` 创建
- `POST   /api/v1/task/:id/start` / `stop` 启停
- `GET    /api/v1/task/:id` 详情（含当前位点、延迟、今日条数）
- `GET    /api/v1/task/list` 列表
- `DELETE /api/v1/task/:id` 删除（停止态才可删，清位点）

监控大盘（`handler/monitor.zig`）：
- `GET /api/v1/monitor/overview` 全局概览（运行任务数/异常数/今日同步行数/平均延迟/数据源数）
- `GET /api/v1/monitor/task/:id` 单任务实时指标

**鉴权**：V1 用 `zfinal.TokenManager` 做简易 token 校验（admin 账号登录发 token，`Authorization: Bearer`）。账号密码加密存（V1 可硬编码 admin + 配置密码，下周期做账号管理）。

**zfinal 复用点**：`ZFinal`/`RouteGroup`/`Context`（renderJson/getPara/getPathParam/renderHtml）、`Validator`、`TokenManager`、`CORSInterceptor`、`StaticHandler`。

### 3.7 前端（assets/）

无构建方案：HTMX + Alpine.js + Tailwind（CDN 或本地嵌入）。仿 zfinal `htmx-admin-demo` 模式。
- 左侧导航 + 右侧内容区：数据源 / 任务 / 监控 三大菜单（对账/告警下周期）
- 数据源列表页（表格 + 测试连接 + 新增表单）、任务配置页（字段映射 + 佣金开关 + 过滤条件）、监控大盘（任务状态总览 + 单任务延迟）
- 静态资源编译期 `@embedFile` 嵌入二进制，单文件部署

---

## 4. zfinal 复用清单（核心，呼应"利用好框架"）

| 能力 | zfinal 提供 | zetl 用法 |
|------|------------|----------|
| HTTP 服务/路由 | `ZFinal`/`RouteGroup`/`Context` | Web 控制台全部 API |
| SQLite | `DB`+`DBConfig.sqlite` | 元数据库 |
| MySQL | `MySQLDB` 驱动（`-Ddriver_mysql=true`） | 源库查询 + 归集库写入 |
| 连接池 | `ConnectionPool` | 归集库 sink_pool |
| ORM | `Model(T,"table")` | 元数据表 datasource/task |
| 参数化查询 | `SqlParam`/`execParams`/`queryParams` | 所有 DB 操作 |
| 校验 | `Validator` | 数据源/任务表单校验 |
| 日志 | `Logger`/`initGlobalLogger` | 全局日志 |
| 指标 | `Metrics` | 监控大盘数据源 |
| Token/鉴权 | `TokenManager`/`createTokenInterceptor` | API 鉴权 |
| 限流 | `RateLimitHandler` | 公开接口限流 |
| CORS | `CORSInterceptor` | 全局拦截器 |
| 静态资源 | `StaticHandler`/`@embedFile` | 前端嵌入 |
| 全局 Io | `io_instance` | main.zig 初始化 |

**手写（zfinal 不提供）**：轮询 CDC 循环、ETL 转换流水线、佣金计算、幂等批量 Sink SQL 构造、任务线程调度、密码加密。

---

## 5. 构建与运行

### 5.1 build.zig.zon
```zon
.{
    .name = .zetl,
    .version = "0.1.0",
    .fingerprint = 0x...,  # 注: 实际值由 `zig` 首次构建自动生成,无需手填
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .zfinal = .{ .path = "../../zig_ws/zfinal" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "config.toml", "schema.sql", "assets" },
}
```

### 5.2 build.zig 要点
- 依赖 zfinal，传 `driver_mysql=true`
- exe_mod.link_libc = true
- 链接 `sqlite3`（系统库）+ `mysqlclient`（随 driver_mysql）

### 5.3 运行
```bash
zig build -Ddriver_mysql=true       # 编译
zig build run -Ddriver_mysql=true   # 运行,默认 :8080
./zetl start -c config.toml         # 单二进制启动
```

### 5.4 开发环境数据库准备
- 本地 MySQL 已装（libmysqlclient 可用）。建归集库 `zetl_sink` + 执行 ard.md §1.1 建表
- 元数据 SQLite 首次运行自动建表（store.zig IF NOT EXISTS）

---

## 6. 错误处理与可靠性（V1）

- **不丢**：每批数据「写入归集库成功」后才推进位点；位点先于下一批查询更新
- **不重**：幂等靠 `ON DUPLICATE KEY UPDATE` + 归集库唯一索引；重复推送不产生重复行
- **断点续传**：服务重启从 sync_position 加载 last_pk/last_update_time 继续
- **故障重试**：源库/归集库瞬时错误 → 指数退避重试（max 3 次）；超限→脏数据表 + 标记任务异常
- **任务隔离**：单任务异常只影响自身（status=2），不影响其他任务与 Web 服务
- **优雅停机**：捕获 SIGINT/SIGTERM，停所有任务线程，刷盘最终位点

---

## 7. 测试策略

- **单元测试**：佣金计算、字段映射、批量 SQL 构造、位点序列化、密码加解密
- **集成测试**：本地 MySQL 起一个源库 schema + 归集库 schema，跑全量→增量闭环，验证幂等（重复写入不重复）+ 断点续传（中途重启续传）
- **验证命令**：`zig build test`（编译期 + 单元），集成测试连本地 MySQL

---

## 8. V1 验收标准（核心闭环）

对齐 PRD §8.1 的可裁剪子集：
1. 可通过 Web/API 接入 1 套 MySQL 数据源，配置订单同步任务
2. 全量初始化历史订单无丢失无重复，完成后自动切增量轮询
3. 源库订单新增/修改，轮询周期内同步到归集库，字段映射与佣金计算准确
4. 基于 `mall_id + order_no` 幂等写入，重复推送不产生重复
5. 重启服务后从位点续传，无需重新全量
6. Web 控制台可查看所有任务状态、今日同步条数、当前位点/延迟
7. 单任务配置错误崩溃，不影响其他任务运行

---

## 9. 已知限制（V1，文档明示）

- **伪 CDC**：不捕获物理删除；增量靠轮询有秒级延迟（非 binlog 真实时）；轮询对源库有周期性查询压力（可配限速）
- 无自动对账、无企业微信告警、无操作审计、无 CSV 导出、无定时 Cron 全量
- 鉴权为简易 token（单 admin 账号），无多用户/角色权限
- 单机部署，无集群高可用

---

## 10. 后续路线（V2+，不在本期）

- 真 binlog CDC（COM_BINLOG_DUMP_GTID 复制协议 + 事件解析）
- 定时对账（CronPlugin）+ 企业微信告警推送 + 操作审计
- 账号权限体系（管理员/只读运维）
- 批量 Excel 导入数据源
- 连接器插件化（PostgreSQL/Kafka）

---

## 附录 A：与 imp.md / ard.md 的差异说明

| 点 | imp.md/ard.md | 本设计 | 原因 |
|----|--------------|--------|------|
| CDC | binlog 复制协议 | 轮询伪 CDC | 用户范围决策；zfinal 无 binlog 能力 |
| sync_position | binlog_file/gtid_set | last_pk + last_update_time | 伪 CDC 游标语义 |
| RowEvent | before/after 双 map | 单 after map | 轮询只需 after；省内存 |
| 进程模型 | "异步IO/协程" | 每任务一线程 | Zig 0.17 无成熟协程；线程模型简单可靠，任务隔离清晰 |
| 元数据代码 | 未指定生成方式 | 手写 Model/Service | 结构固定且少，手写清晰 |

---

## 附录 B：关键复用参照（zfinal 源码位置）

- DB/ORM：`zfinal/src/db/db.zig`、`model.zig`、`pool.zig`、`sql_param.zig`、`pagination.zig`；doc：`zfinal/doc/db.md`
- MySQL 驱动：`zfinal/src/db/drivers/mysql.zig`（`MySQLDB.connect/exec/execParams/query/queryParams`）
- Web：`zfinal/src/core/zfinal.zig`（ZFinal/RouteGroup）、`context.zig`、`router.zig`
- 应用范式参照：`zfinal/examples/blog`（routes/controller/model 三层）、`examples/ruoyi-gen`（deps.zig 全局共享 + 模块注册）、`examples/htmx-admin-demo`（@embedFile 前端）
- 公共 API 全表：`zfinal/src/main.zig`
