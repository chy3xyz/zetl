# zetl 开发笔记

## 日志

### 2026-11-21 (5): 任务系统收敛 — V5 /api/tasks 为唯一 (legacy /api/v1/task 移除)
- 决策: 保留 V5 (tasks_config 表, config_json 透传, 动态管理), 删除 legacy
  /api/v1/task (sync_task 表) — 两套任务系统双轨维护成本高.
- **V5 能力补齐**: `POST /api/tasks/:id/stop` (停实例留配置, scheduler.stopTaskById);
  reloadTask 增加 status=disabled 分支 (停用 = stop + 不启动, 修复 disabled 任务
  reload 后照样启动的缺口); PUT /api/tasks/:id 按 status 分支.
- **消费方迁移**: UI 任务页 (表单字段 source_db/嵌套 config_json/启停按钮),
  reconcile cron (getById + findByMallId, 原 datasource_id 关联), monitor.taskMetrics,
  metrics.globalOverview (running=active, error=fail_count>0), main 启动只调 loadFromDb,
  store FK 指向 tasks_config, datasource.hasTaskBinding 按 mall_id 关联.
- **删除**: legacy 6 端点 + web/handler/task.zig + V1 SyncTask model/Service +
  scheduler.startTask/stopTask/bootstrapAll + sync_task 建表 DDL (runtime markError
  不再回写 sync_task, 失败态由 runtime_metrics 承载).
- 端点 37 → 32. 测试 256 → 255 (-startTask 测试, V1 Service 测试随删除).
- **全生命周期 E2E**: create(running) → stop(stopped) → update status=0(disabled)
  → update status=1(reloaded) → overview/monitor V5 统计正确 → sink 同步正常.
- 遗留: reconcile run 端点 ({mall_id, table_name} 路径) 在 E2E 中 ExecFailed —
  存量问题 (本轮未触碰该路径), 待单独排查.

### 2026-11-21 (4): 自动建表幂等唯一键 + 死字段清理
- **自动建表追加 `UNIQUE KEY uk_zetl_mall_pk (mall_id, pk_column)`**: 之前自动
  创建的目标表没有任何唯一键, sink 的 INSERT ... ON DUPLICATE KEY UPDATE 无法
  去重 — 源行 UPDATE (update_time 刷新) 后 re-sync 会重复插入. 现在 DDL 按源
  主键 (cfg.pk_column) 生成唯一键; pk 不在源列中则跳过 (幂等降级, 与现有
  ensureTargetTable warn 语义一致). live E2E 实测: UPDATE re-sync 原位更新,
  行数不增.
- **移除 `TransformConfig.filter_condition` 死字段**: 该字段被 store/dupe/free
  但 process() 从不消费 (生效过滤路径是 filter_field/op/value). RuntimeConfig
  侧字段保留 (legacy API 兼容), 注释已注明 inert.
- 测试 253 → 256 (+唯一键 3); 双构建全绿.

### 2026-11-21 (3): AI 速搭文档对齐真实 API + 三个存量 bug 修复
- **ai-recipes 全面重写**: quickstart / 00-schema 顶层 / 4 个 recipes / api-tasks
  全部对齐真实 API (扁平请求体 + config_json 嵌套字符串 / 响应信封 {code,msg,data} /
  创建即启动 running|stored_only / 端口 18080); 之前教 AI 写的 source/target/sink
  子对象结构根本不被 API 接受. transform-naming/overrides 补嵌套位置说明.
- **quickstart 文档按步实测** (本地 MySQL 全链路): 登录→注册数据源→建任务→
  全量+增量同步→sink 行数一致. 实测过程中暴露并修复三个**存量 bug**:
  1. `runtime.start()` CAS 语义写反: cmpxchgStrong 返回 null=成功, 原代码把成功
     当失败继续循环, 第二圈读到刚写入的 .running → 必然返回 AlreadyRunning —
     **所有任务都启动不了** (旧 E2E 靠手工预建表掩盖).
  2. `fetchSourceColumns` 用 `_sh`(host) 当表名 → SHOW COLUMNS 恒失败 →
     自动建表/自动列映射全废. 改为 cfg.source_table.
  3. `buildCreateTable` 缺治理列 → sink flush 的 INSERT (含 mall_id/sync_type/
     sync_time/is_delete/source_*) 首次增量必报 Unknown column. DDL 追加治理列,
     与 flush 列集对齐.
- **bootstrap admin 修复**: 全新部署时引导账号只存在于 config, RBAC 中间件按
  user 表校验 → 登录成功但受保护端点全 403. 新增
  `auth.user.ensureBootstrapAdmin` (幂等: 建 user + 绑 admin 角色), main 启动时注入.
- 测试 252 → 253 (+ensureBootstrapAdmin); SQLite + MySQL 双构建全绿.

### 2026-11-21 (2): V5 config_json 透传 + 调度器重构
- **config_json 透传落地** (scheduler.zig TODO Phase 6): V5 动态任务现在支持
  batch_size / field_mappings (string|object|array) / filter {field,op,value} /
  enable_commission_calc / transform.* (naming_rules + mask 开关); 解析失败
  warn + 回退默认 (与 commission 降级哲学一致). RuntimeConfig 相应扩展
  filter_field/op/value + mask 字段, SyncTask.init 全部转发给 TransformEngine.
- **提取 buildSyncTask 公共函数** (TODO 落地): addTask(V5)/reloadTask 两处
  重复构造收口; 顺带修复 "SyncTask.init 失败泄漏 src_pool + 字符串" 的老限制.
- **token_user_map TTL 清扫**: 绑定带 bound_at_ms, bindTokenToUser 机会式
  清扫 (>10min 周期, TTL 2h = token TTL 1h 的 2 倍), 未 logout 的绑定不再常驻内存.
- 发现并标注: `TransformConfig.filter_condition` 是 engine 死字段 (生效路径
  是 filter_field/op/value 数值比较); V5 config_json 的 filter 走生效路径.
- **ai-recipes 文档漂移修正**: 00-task-config-schema.md 顶层结构与实际 API
  不符 (source/target/sink/schedule 为规划未实现), 已加实现状态声明 +
  已实现 config_json 词汇表; recipes 全量对齐真实 API 留待后续.
- 单元测试 244 → 252 (scheduler 透传 6 + deps sweep 1); 双构建全绿.

### 2026-11-21
- zfinal v0.27.0 → v0.28.11, Zig 0.17.0-dev.1970 → **0.17.0 stable** (v0.27.1 钉 dev.2151, v0.28.1 起 stable; zent v0.31.0 → v0.78.0 经传递拉取)
- zetl 主代码零改动通过 (v0.28 公开 API 未变; pool 内部重构 mutex_init 移除)
- **已知问题 #1 (子线程 MySQL acquire `Lost connection`) 实测已修复**: 新增
  `src/pool_mysql_live_test.zig` env 门控 live 测试 (`ZETL_LIVE_MYSQL=1 zig build -Ddriver_mysql=true test`),
  双 worker 子线程并发 acquire + query + upsert 实测通过
- 修复 `/api/v1/auth/me`: RBAC 用户现在返回真实用户名 (原来恒返回 config 引导账号 admin)
- 0.17.0 stable API 备忘: `std.process.hasEnvVarConstant/getEnvVarOwned` 已移除, live 测试门控改用 `std.c.getenv` (与 zfinal 同款模式)

### 2026-09-17 (2): 源码结构整理
- **HTTP handler 统一收口到 `web/handler/`**: `web/api/tasks.zig` → `handler/tasks.zig`;
  domain 模块的 4 个 handler 移入 (`alarm/audit/reconcile/handler.zig` → `web/handler/`),
  `auth/handler.zig` (V2.2) 合并进 `web/handler/auth.zig` (V1), `loginV2` 更名 `login`.
  规则从此单一: **domain 模块只放业务逻辑, HTTP 全在 web/handler/**.
- **消除 `meta/task.zig` + `meta/task/` 文件/目录同名共存** → `meta/task/mod.zig`
  (V1 sync_task model + re-export V5 config/service).
- **删除死代码**: `common/alarm.zig` (V1 占位 stub, 无路由无测试);
  `web/handler/auth.zig` 的 V1 静态 `login` (未路由, login fallback 分支完全覆盖其逻辑).
- 移动均用 `git mv` 保留历史; 删除空 `test/` 目录.
- 纯移动/改名/删死码, 无行为变更; SQLite + MySQL 双构建 243/243 测试通过.

### 2026-09-17
- zfinal v0.25.0 → v0.27.0, 依赖从本地 path 切换为 `build.zig.zon` git+https 固定 tag + commit + hash
- Zig 0.17.0-dev.1567 → 0.17.0-dev.1970 (zfinal v0.26.1+ 要求 1970: `io.operate(.net_write)` 取代被移除的 `Io.VTable.netWrite`)
- zetl 源码零改动通过 (v0.27 的 `DB.affectedRows` 改 `!i64`, zetl 无调用点; 1970 `@hasDecl` 可见性感知只影响 `renderPage` 用户, zetl 未用)
- 升级流程沉淀: `zig fetch "git+https://...?ref=<tag>"` 取 hash (不要 `--save`, dev 编译器会把 git URL 写进 `.path`), 手工补 `.url`/`.hash`
- SQLite + MySQL 双构建 243/243 测试通过

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

### 2026-11-23: reconcile 修复 (4 层 bug 剥洋葱)
E2E 实测对账路径, 逐层暴露并修复:
1. **run handler 拿 sink_pool 冒充源库** (代码注释自曝的 TODO): 按 mall_id 反查
   datasource, 真实构造源库 pool (与 cron 同模式).
2. **ConnectionPool double-destroy**: pool.deinit 内部自毁, handler/cron 的
   `destroy(src_pool)` 再炸一次 → panic. 两处同修 (zfinal 自毁契约 —
   AGENTS.md 数据库 API 约定已注明 deinit 即销毁).
3. **源/汇表名混用**: reconcileAsync 单 table_name 双边用 — 源是 orders,
   汇是 union_all_order. 拆 source_table/target_table; handler 从 tasks_config
   反查 source_table (source_db=mall_id), cron 透传.
4. **源侧 SQL 语义两连**: (a) 源业务表没有 mall_id 治理列 — filter_mall 开关,
   源侧整表统计 (一个 datasource 即一个 mall), 汇侧按 mall_id 过滤;
   (b) `$1` 占位符在 MySQL 查询路径无效 (queryParams 走 stmt 需 `?`,
   插值需字面量) — 沿用 poller 的字面量插值风格.
- 金额列可配: `ReconcileConfig.amount_column` (默认 order_total) +
  `[reconcile]` 配置段 + run 请求体可选 amount_column.
- Live E2E: 一致场景 diff=0 (金额双边 349.5); 停任务后源多插一行 →
  diff_count=1/diff_amount=11 (阈值内 is_abnormal=false, 符合配置语义);
  记录落库; 无 panic. 测试 255 (255+live skip), 双构建全绿.

### 2026-11-23 (2): name 唯一性友好错误 + handler 层测试 (oneshot capture)
- **tasks_config 撞名**: create/update 前置 findByName 预检 → business_error
  "任务名已存在" (此前撞 SQLite UNIQUE 报 system_error 不可读); update 场景
  findByName 命中必须是本 id (改名碰撞检测).
- **handler 层测试落地**: `web/handler/tasks_http_test.zig` 用 zfinal
  `oneshot.capture` (无 TCP, Router.execute + capture ctx), 5 个用例覆盖
  create→list→detail / 撞名 / 缺字段 / 非法 status / 404.
- **上游 zfinal 补丁** (acf2257, 已推送): capture 模式预置空 query_params —
  此前 getPara* 会读 undefined req 直接段错误; zetl pin 从 v0.28.11 tag
  前移到该 commit.
- **测试环境三分配器铁律**: ctx.allocator / deps.allocator_ptr /
  store.allocator 必须同一 allocator (handler free body 与 Service 返回的
  TaskConfig), 否则跨分配器 free → 静默泄漏或 "free of invalid memory" panic.
  TestEnv 因此放弃 arena, 全 testing.allocator + errdefer 逆向清理.
- 测试 256 → 262 (handler 层 5 + findByName 2); 双构建全绿零泄漏.

## 架构决策

1. **元数据 SQLite + 业务 MySQL** — 元数据量小(< 100 数据源), 单文件便于备份
2. **手写 Model/Service** — 不用 zfinal 生成器, 表结构固定
3. **单二进制部署** — @embedFile 前端, 无外部文件依赖
4. **伪 CDC** — V1/V2 用轮询 (主键分页 + update_time), 真 binlog 留 V3
5. **主线程创建 Pool → 传入子线程** — zfinal `*ConnectionPool` API, 堆分配字符串

## 依赖版本

| 依赖 | 版本 |
|------|------|
| Zig | 0.17.0-dev.1970+67f39b551 (zigup; zfinal v0.26.1+ 最低要求) |
| zfinal | 0.27.0 (git+https 固定 tag, 见 build.zig.zon) |
| zent | 0.31.0 (经 zfinal 传递拉取) |
| MySQL | 8.4 (macOS Homebrew) |
| SQLite | 3 (系统自带) |

## 端点统计

- 公开: 9 个
- 受保护: 24 个
- 总计: 33 个

## 测试覆盖

- 单元测试: 243 个 (transform 69 / cdc 47 / auth 25 / engine 22 / reconcile 19 / web 15 / alarm 15 / sink 14 / meta 8 / audit 3 / main 2 / config 2 / common 2)
- SQLite 构建: ✅
- MySQL 构建: ✅
- E2E (全量同步): ✅
- E2E (全量 → 增量同步): ✅

## 性能参考 (V2, MySQL 8.4, M1 Pro)

- 全量同步: 10 行/5ms (批大小 5)
- 增量同步: 2 行/1s 轮询周期
- API 延迟: < 5ms (本地回环), start task ~20ms
- 内存: ~8MB (空闲), ~20MB (4 任务运行)
- 二进制: 3.8MB (zfinal v0.27 时代 ReleaseSafe ≈ 4.8MB, Debug ≈ 10MB)

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

## Phase 6: transform 自动化

`Mapper` 支持基于 source schema 自动生成默认列映射 (identity), 用户可在 `field_mappings_json` 中覆盖特定列的 target / default / type.

- `Mapper.fromSchema(allocator, []ColumnMeta)`: 从 source 列元数据生成 N 个 identity mappings.
- `Mapper.mergeOverrides(allocator, user_json)`: 应用用户 override, 命中 source 的项替换 target/default/type, 未命中的额外 mapping 追加.
- `TransformEngine.initWithSchema(...)`: 新入口, 调 fromSchema 后 mergeOverrides.
- `SyncTask.runFull` 启动时通过 `SHOW COLUMNS FROM <table>` 获取 source 列名, 自动使用 `initWithSchema`.
- binlog 路径继续使用 parser 的现有列名 ("c0", "c1", ...); 真实列名映射留 Phase 6b (TABLE_MAP metadata).

## Phase 6b: 列名重命名规则

`Mapper` 支持基于 `NamingRule` 自动转换列名, 用户无需手工写 `field_mappings_json`.

支持的规则:
- `identity` (默认, 与 Phase 6 一致)
- `camel_to_snake` (`orderId` → `order_id`)
- `snake_to_camel` (`order_id` → `orderId`)
- `upper` (`foo` → `FOO`)
- `lower` (`FOO` → `foo`)
- `add_prefix(prefix)` (`id` → `dt_id`)
- `strip_prefix(prefix)` (`dt_id` → `id`)

配置方式 (在 `config_json.transform.naming_rule`):
- 字符串: `"naming_rule": "camel_to_snake"`
- 对象: `"naming_rule": {"type": "add_prefix", "value": "dt_"}`

用户 `field_mappings_json` 中的 override 仍优先于自动命名 (Phase 6 mergeOverrides 行为保留).

## Phase 6c: 正则替换 + 链式规则

`NamingRule` 新增 `regex_replace` 变体 + `applyNamingPipeline` 串联多个规则.

支持的规则:
- `regex_replace(pattern, replacement)` (`order_tmp` -> 用 `{"pattern":"_tmp$","replacement":""}` -> `order`)
- 链式规则: `NamingRule` 数组, 顺序应用, e.g. `[camel_to_snake, add_prefix("dt_")]` 把 `orderId` -> `order_id` -> `dt_order_id`

配置方式 (在 `config_json.transform.naming_rules`):
- 数组形式: `"naming_rules": [{"type":"camel_to_snake"}, {"type":"add_prefix","value":"dt_"}]`
- 单规则字符串: `"naming_rule": "camel_to_snake"` (向后兼容 Phase 6b)
- 单规则对象: `"naming_rules": {"type":"add_prefix","value":"dt_"}` (自动 wrap 成 1-element array)

regex_replace 支持 backref (`$1`, `$2` 等).

## Phase 7: sink 自动化

`MySqlSink.ensureTargetTable` 自动通过 `CREATE TABLE IF NOT EXISTS` 创建 target_table, 用户添加新表同步时无需手工建表.

- `src/sink/schema_ddl.zig::buildCreateTable` 从 `[]ColumnMeta` 生成 DDL, 类型字节 → MySQL 类型字符串映射 (21 种类型 + TEXT 兜底).
- `MySqlSink.ensureTargetTable` 执行 DDL, 表已存在时幂等 (IF NOT EXISTS).
- `SyncTask.init` 在 `initWithSchema` 之后调用 `ensureTargetTable`; 失败时 warn + 继续 (假设 target 表已存在).
- 默认 charset utf8mb4 + engine InnoDB; target_db 可选.
- binlog / poll 路径自动复用 Phase 6 的 source schema.
- 已知限制: VARCHAR / CHAR 长度、DECIMAL precision/scale 用默认值; 后续 Phase 7b 支持从 source metadata 推断.

## Phase 9: AI 速搭文档

新增 `docs/ai-recipes/` 文档树, 面向 AI 编程代理, 让 AI 在 5 分钟内为一个新业务场景写出可运行的 `config_json`.

- `README.md` — 决策树 (订单/用户/商品/多源/自定义)
- `00-task-config-schema.md` — 完整 TaskConfig 字段参考
- `01-quickstart.md` — 5 行 JSON 最小链路
- `recipes/` — 4 个场景模板 (order/user/product/multi-source)
- `reference/` — 4 个速查手册 (naming/overrides/sink/api)

`AGENTS.md` 顶部新增指针: 业务场景搭建先看 `docs/ai-recipes/`, 改 zetl 自身代码按原有约定.

无代码变更. 仅 markdown.

## Phase 9b: 完善

- 修复 Phase 6c 留下的 2 个测试内存泄漏 (`parseNamingRule handles object form add_prefix/strip_prefix`): 加 `defer freeRule(a, rule)`, `zig build test` 从 "2 leaked" → "0 leaked".
- README.md 新增"面向 AI 业务场景搭建"section, 链接到 `docs/ai-recipes/` 决策树, 让新用户能发现 AI 速搭文档.

## Phase 10: Phase 7b precision + mask_phone

落地 ai-recipes 中两个标为"待实现"的功能, 让文档与代码 100% 对齐.

### Phase 7b: 自动 VARCHAR(N) / DECIMAL(P,S)

`ColumnMeta` 扩展为带 `length: ?u16` / `precision: ?u8` / `scale: ?u8`.

- `parseMySqlTypeString` 返回 `ParsedType` 结构体, 解析 `int(11)` / `varchar(64)` / `decimal(10,2)` 括号内的数字.
- `fetchSourceColumns` 把 length/precision/scale 填进 `ColumnMeta`.
- `mySqlTypeName` 接受 length/precision/scale 参数, 通过栈 buffer (`[32]u8`) 生成精确类型字符串.
- `buildCreateTable` 用真实长度/精度生成 DDL, 不再强制 `VARCHAR(255)`.

效果: 源 `order_no VARCHAR(32)` → 目标 `` `order_no` VARCHAR(32) ``, 不再退化为 `VARCHAR(255)`.

### `transform.mask_phone = true`

`TransformConfig.mask_phone: bool` 简写, 在 `process()` 中识别字段名含 `phone` / `mobile` / `tel` 的列, 把 ≥ 7 位数字值的中间 4 位替换成 `****`:

- `phone = "13800138000"` → `"138****8000"`
- 非 phone 字段 (`user_id`, `register_time`) 不变
- 与 `field_mappings_json` 不冲突 (override 优先)
- 字段名匹配是大小写敏感 (Phase 11 改成 case-insensitive)
- `TransformConfig.initFromJson` 解析 `transform.mask_phone: bool`

### ai-recipes 文档修正

- `order-sync.md` filter 说明: 不再标"Phase 9 待实现", 给真实 `filter_field/filter_op/filter_value` JSON 例子
- `user-sync.md` mask_phone: 用 `transform.mask_phone = true` 替代 `field_mappings_json` 手工脱敏
- `transform-overrides.md`: 新增"快捷开关"section 解释 mask_phone
- `sink-ddl.md`: 删除"Phase 7b 待实现"section, 改为"已实现"说明

## Phase 8: 鉴权覆盖 (Auth coverage)

Phase 5 引入的 `/api/tasks/*` 端点此前**绕过鉴权中间件** (注释 "暂不鉴权"). Phase 8 修复这个安全漏洞: 给 6 个端点加 `authInterceptor` + `permissionInterceptor`, 与 V1 `/api/v1/task/*` 对齐.

- `/api/tasks` (GET)         需要 `task:read`
- `/api/tasks` (POST)        需要 `task:write`
- `/api/tasks/:id` (GET)     需要 `task:read`
- `/api/tasks/:id` (PUT)     需要 `task:write`
- `/api/tasks/:id` (DELETE)  需要 `task:delete`
- `/api/tasks/:id/reload` (POST) 需要 `task:start`

无 token → 401; 携带 viewer token 但缺少权限 → 403; admin/operator token → 200/201.

新增单元测试覆盖 `isPublicPath` 的公开/私有路径判定.

## Phase 11: 扩展 mask + 大小写不敏感

扩展 Phase 10 的 mask 机制, 覆盖 email 和身份证号, 修复 case-sensitive 限制.

### 新增 mask 类型

- `transform.mask_email = true` — 邮箱字段脱敏 (`alice@example.com` → `a****@example.com`).
  - 切到 `@`, local-part 除首字符外全部替换为 `*`. local ≤ 2 字符不变 (避免过度脱敏).
  - 仅识别字段名含 `email` / `mail` 的列.
- `transform.mask_id_card = true` — 18 位身份证号脱敏 (`110101199001011234` → `110101********1234`).
  - 仅识别字段名含 `id_card` / `idcard` / `id_no` / `idnum` / `identity` 的列 (不命中 `user_id`).
  - 非 18 位纯数字不变.

### 简写开关

- `transform.mask_all = true` — 等价于 `mask_phone + mask_email + mask_id_card` 全开.

### 大小写不敏感

- 新增 `case_insensitive_fields: bool = true` (默认 true) 控制字段名匹配是否忽略大小写.
- `Phone` / `PHONE` / `phone` 都命中 phone mask.
- 设 `false` 可恢复 Phase 10 的 case-sensitive 行为.

### dispatch 重构

`maskPhoneIfNeeded` 重构为 `maskFieldIfNeeded` + `detectMaskKind` enum dispatch.
