## 一、数据库建表SQL脚本
### 1.1 目标归集库（MySQL/PolarDB）业务表
用于存储所有商城归集后的订单、用户、佣金数据，直接对接代理商总后台查询。

```sql
-- 1. 全渠道订单归集表
CREATE TABLE `union_all_order` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `mall_id` varchar(32) NOT NULL COMMENT '商城唯一编码，数据隔离核心字段',
  `order_no` varchar(64) NOT NULL COMMENT '原商城订单号',
  `agent_id` varchar(32) DEFAULT NULL COMMENT '绑定代理商ID',
  `order_total` decimal(12,2) NOT NULL DEFAULT '0.00' COMMENT '订单实付金额',
  `agent_commission` decimal(12,2) NOT NULL DEFAULT '0.00' COMMENT '代理商佣金',
  `commission_rate` decimal(6,4) NOT NULL DEFAULT '0.0000' COMMENT '分佣比例',
  `order_status` tinyint NOT NULL DEFAULT '0' COMMENT '订单状态：0待支付1已支付2已完成3已取消',
  `pay_time` datetime DEFAULT NULL COMMENT '支付时间',
  `source_create_time` datetime NOT NULL COMMENT '源库订单创建时间',
  `source_update_time` datetime NOT NULL COMMENT '源库订单更新时间',
  `sync_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'ETL同步入库时间',
  `sync_type` tinyint NOT NULL DEFAULT '1' COMMENT '同步类型：1CDC实时 2全量初始化',
  `is_delete` tinyint NOT NULL DEFAULT '0' COMMENT '软删除标记 0正常 1已删除',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_mall_order` (`mall_id`,`order_no`) COMMENT '幂等去重唯一索引',
  KEY `idx_agent_id` (`agent_id`),
  KEY `idx_pay_time` (`pay_time`),
  KEY `idx_sync_time` (`sync_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='全渠道订单归集表';

-- 2. 全渠道用户归集表
CREATE TABLE `union_all_user` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `mall_id` varchar(32) NOT NULL COMMENT '商城编码',
  `user_id` varchar(64) NOT NULL COMMENT '源库用户ID',
  `agent_id` varchar(32) DEFAULT NULL COMMENT '绑定代理商ID',
  `phone` varchar(32) DEFAULT NULL COMMENT '脱敏手机号',
  `nickname` varchar(64) DEFAULT NULL,
  `register_time` datetime DEFAULT NULL COMMENT '注册时间',
  `sync_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `is_delete` tinyint NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_mall_user` (`mall_id`,`user_id`),
  KEY `idx_agent_id` (`agent_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='全渠道用户归集表';

-- 3. 异常脏数据表
CREATE TABLE `error_order` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `mall_id` varchar(32) NOT NULL,
  `order_no` varchar(64) NOT NULL,
  `raw_data` json DEFAULT NULL COMMENT '原始数据快照',
  `error_type` varchar(32) NOT NULL COMMENT '错误类型：字段缺失/佣金规则缺失/写入失败',
  `error_msg` varchar(512) DEFAULT NULL COMMENT '错误详情',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `retry_count` tinyint NOT NULL DEFAULT '0' COMMENT '重试次数',
  `is_resolved` tinyint NOT NULL DEFAULT '0' COMMENT '是否已处理',
  PRIMARY KEY (`id`),
  KEY `idx_mall_id` (`mall_id`),
  KEY `idx_create_time` (`create_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='同步异常脏数据表';

-- 4. 代理商佣金规则表（ETL计算依赖）
CREATE TABLE `agent_commission_rule` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `agent_id` varchar(32) NOT NULL,
  `mall_id` varchar(32) NOT NULL DEFAULT '*' COMMENT '*表示全商城通用',
  `commission_rate` decimal(6,4) NOT NULL COMMENT '基础分佣比例',
  `min_amount` decimal(12,2) NOT NULL DEFAULT '0.00' COMMENT '阶梯最低金额',
  `max_amount` decimal(12,2) NOT NULL DEFAULT '999999.00' COMMENT '阶梯最高金额',
  `status` tinyint NOT NULL DEFAULT '1',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_agent_mall` (`agent_id`,`mall_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='代理商阶梯佣金规则表';
```

### 1.2 系统元数据库（SQLite 内置，单文件存储）
存储ZigETL自身的数据源、任务、位点、告警、对账记录，无需额外部署数据库。

```sql
-- 1. 数据源配置表
CREATE TABLE datasource (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mall_id TEXT NOT NULL UNIQUE,
  ds_type TEXT NOT NULL DEFAULT 'mysql', -- mysql/polardb
  host TEXT NOT NULL,
  port INTEGER NOT NULL DEFAULT 3306,
  db_name TEXT NOT NULL,
  username TEXT NOT NULL,
  password TEXT NOT NULL, -- AES加密存储
  remark TEXT,
  status INTEGER NOT NULL DEFAULT 1, -- 1正常 0停用
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 2. 同步任务表
CREATE TABLE sync_task (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_name TEXT NOT NULL,
  datasource_id INTEGER NOT NULL,
  source_table TEXT NOT NULL, -- 源表名
  target_table TEXT NOT NULL, -- 目标表名
  sync_mode TEXT NOT NULL DEFAULT 'cdc', -- full全量/cdc增量/both混合
  transform_config TEXT, -- JSON格式转换规则
  filter_condition TEXT, -- 过滤SQL条件
  batch_size INTEGER NOT NULL DEFAULT 1000,
  status INTEGER NOT NULL DEFAULT 0, -- 0停止 1运行中 2异常
  last_run_time DATETIME,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (datasource_id) REFERENCES datasource(id)
);

-- 3. 同步位点表（CDC断点续传核心）
CREATE TABLE sync_position (
  task_id INTEGER PRIMARY KEY,
  binlog_file TEXT,
  binlog_pos INTEGER,
  gtid_set TEXT, -- GTID模式优先
  last_event_time DATETIME,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (task_id) REFERENCES sync_task(id)
);

-- 4. 告警配置表
CREATE TABLE alarm_config (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  alarm_type TEXT NOT NULL, -- task_fail/delay_over/balance_diff
  threshold TEXT, -- 阈值配置JSON
  webhook_url TEXT NOT NULL,
  is_enabled INTEGER NOT NULL DEFAULT 1
);

-- 5. 操作审计日志
CREATE TABLE operation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  operator TEXT NOT NULL,
  op_type TEXT NOT NULL, -- create/update/delete/start/stop
  op_target TEXT NOT NULL,
  op_detail TEXT,
  ip TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 6. 对账记录表
CREATE TABLE reconcile_record (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mall_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  source_count INTEGER NOT NULL,
  target_count INTEGER NOT NULL,
  diff_count INTEGER NOT NULL,
  source_amount REAL,
  target_amount REAL,
  diff_amount REAL,
  reconcile_time DATETIME DEFAULT CURRENT_TIMESTAMP,
  is_abnormal INTEGER NOT NULL DEFAULT 0
);
```

---

## 二、Zig 0.17 核心模块代码架构设计
### 2.1 项目目录结构
遵循Zig标准项目结构，模块化拆分，单二进制编译交付。
```
zetl/
├── build.zig              # 构建配置
├── config.toml            # 运行配置文件
├── src/
│   ├── main.zig           # 程序入口，全局初始化
│   ├── common/            # 公共基础组件
│   │   ├── allocator.zig  # 内存池/ Arena分配器封装
│   │   ├── logger.zig     # 分级日志
│   │   ├── crypto.zig     # AES加解密（密码存储）
│   │   └── alarm.zig      # 企业微信告警客户端
│   ├── cdc/               # CDC采集层
│   │   ├── mysql.zig      # MySQL binlog采集器
│   │   ├── position.zig   # 位点管理
│   │   └── event.zig      # binlog事件结构体
│   ├── transform/         # ETL转换引擎
│   │   ├── engine.zig     # 转换流水线核心
│   │   ├── mapper.zig     # 字段映射
│   │   ├── expression.zig # 表达式计算引擎
│   │   └── commission.zig # 佣金计算业务组件
│   ├── sink/              # 数据写入层
│   │   ├── mysql_sink.zig # MySQL批量写入器
│   │   └── idempotent.zig # 幂等处理
│   ├── meta/              # 元数据与调度
│   │   ├── sqlite_store.zig # SQLite元数据存储
│   │   ├── scheduler.zig  # 定时调度器（Cron）
│   │   └── reconcile.zig  # 自动对账逻辑
│   └── web/               # Web管理控制台
│       ├── server.zig     # HTTP服务
│       ├── router.zig     # 路由定义
│       ├── handler/       # 接口处理函数
│       └── static/        # 前端静态资源（编译期嵌入）
└── assets/
    └── web/               # HTMX+Alpine.js+tailwind.css前端页面
```

### 2.2 核心模块代码骨架与设计
#### 1. 主入口与全局运行时
核心设计：单进程多任务并行，全局内存池复用，无GC，优雅启停。
```zig
// src/main.zig
const std = @import("std");
const common = @import("common");
const cdc = @import("cdc");
const sink = @import("sink");
const meta = @import("meta");
const web = @import("web");

// 全局配置
pub const Config = struct {
    port: u16 = 8080,
    sqlite_path: []const u8 = "zig-etl.db",
    max_tasks: usize = 100,
    log_level: std.log.Level = .info,
};

pub fn main() !void {
    // 1. 初始化内存分配器：使用Arena + 通用分配器双层管理，减少碎片
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. 加载配置、初始化日志
    const config = try loadConfig(allocator, "config.toml");
    try common.Logger.init(allocator, config.log_level);
    defer common.Logger.deinit();

    // 3. 初始化元数据存储（SQLite）
    var store = try meta.SqliteStore.init(allocator, config.sqlite_path);
    defer store.deinit();

    // 4. 初始化全局任务调度器
    var scheduler = try meta.Scheduler.init(allocator, &store);
    defer scheduler.deinit();

    // 5. 启动所有已启用的同步任务
    try scheduler.startAllTasks();

    // 6. 启动Web控制台服务
    var web_server = try web.Server.init(allocator, config.port, &store, &scheduler);
    defer web_server.deinit();

    std.log.info("ZigETL 服务启动成功，监听端口: {}", .{config.port});
    
    // 阻塞运行，接收信号优雅退出
    try web_server.run();
}
```

#### 2. CDC采集模块（MySQL Binlog）
核心设计：全量+增量无缝切换，位点持久化，单任务独立连接，故障隔离。
```zig
// src/cdc/mysql.zig
const std = @import("std");
const event = @import("event.zig");
const position = @import("position.zig");
const EventCallback = *const fn (row: event.RowEvent) anyerror!void;

pub const MySqlCdc = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    username: []const u8,
    password: []const u8,
    database: []const u8,
    table: []const u8,
    pos: position.SyncPosition,
    callback: EventCallback,
    is_running: bool,

    // 初始化CDC采集器
    pub fn init(allocator: std.mem.Allocator, config: CdcConfig, callback: EventCallback) !MySqlCdc {
        return .{
            .allocator = allocator,
            .host = config.host,
            .port = config.port,
            .username = config.username,
            .password = config.password,
            .database = config.database,
            .table = config.table,
            .pos = config.initial_pos,
            .callback = callback,
            .is_running = false,
        };
    }

    // 启动同步：先全量后自动切增量
    pub fn start(self: *MySqlCdc) !void {
        self.is_running = true;
        // 1. 全量初始化阶段：分批拉取历史数据，不锁表
        if (self.pos.isInitial()) {
            try self.fullSync();
        }
        // 2. 增量CDC阶段：建立binlog连接，实时解析事件
        try self.startBinlogStream();
    }

    // 全量同步：主键分页拉取，避免大表锁表
    fn fullSync(self: *MySqlCdc) !void {
        var last_id: i64 = 0;
        const batch_size = 1000;
        while (self.is_running) {
            const rows = try self.queryBatch(last_id, batch_size);
            if (rows.len == 0) break;
            
            for (rows) |row| {
                try self.callback(.{ .op = .insert, .data = row });
                last_id = row.id;
            }
            // 位点同步更新，中断后可续传
            try self.pos.updateFullSyncPos(last_id);
        }
    }

    // binlog实时流解析
    fn startBinlogStream(self: *MySqlCdc) !void {
        // 建立MySQL复制连接，发送COM_BINLOG_DUMP命令
        var conn = try self.connectReplication();
        defer conn.close();

        while (self.is_running) {
            const binlog_event = try conn.nextEvent();
            // 解析ROW_EVENT，转换为统一行事件
            const row_event = try event.parseBinlogEvent(binlog_event, self.allocator);
            // 回调交给转换引擎
            try self.callback(row_event);
            // 更新位点
            try self.pos.updateBinlogPos(binlog_event.log_pos, binlog_event.gtid);
        }
    }

    // 优雅停止
    pub fn stop(self: *MySqlCdc) void {
        self.is_running = false;
    }
};
```

#### 3. ETL转换引擎
核心设计：流水线式处理，零拷贝字段映射，编译期优化表达式，脏数据自动分流。
```zig
// src/transform/engine.zig
const std = @import("std");
const commission = @import("commission.zig");

pub const RowData = std.StringHashMap([]const u8);

pub const TransformEngine = struct {
    allocator: std.mem.Allocator,
    field_mappings: []const FieldMapping, // 源字段->目标字段
    compute_rules: []const ComputeRule,   // 计算字段规则
    filter_expr: ?[]const u8,             // 过滤条件
    mall_id: []const u8,                  // 固定注入的商城编码

    pub const FieldMapping = struct {
        source_field: []const u8,
        target_field: []const u8,
        type_convert: ?FieldType = null,
        default_value: ?[]const u8 = null,
    };

    pub const ComputeRule = struct {
        target_field: []const u8,
        expression: []const u8,
    };

    // 处理单行数据，返回转换后的数据，错误则标记为脏数据
    pub fn process(self: *TransformEngine, source_row: RowData) !RowData {
        var target_row = RowData.init(self.allocator);
        errdefer target_row.deinit();

        // 1. 固定注入系统字段
        try target_row.put("mall_id", self.mall_id);
        try target_row.put("sync_time", try getCurrentTimeStr(self.allocator));

        // 2. 字段映射与类型转换
        for (self.field_mappings) |mapping| {
            const value = source_row.get(mapping.source_field) orelse mapping.default_value orelse return error.FieldMissing;
            const converted = try convertType(value, mapping.type_convert);
            try target_row.put(mapping.target_field, converted);
        }

        // 3. 业务计算：佣金计算
        if (source_row.get("order_total")) |amount| {
            const agent_id = source_row.get("agent_id") orelse "";
            const comm = try commission.calculate(self.allocator, agent_id, self.mall_id, amount);
            try target_row.put("agent_commission", comm.amount);
            try target_row.put("commission_rate", comm.rate);
        }

        // 4. 数据过滤
        if (self.filter_expr) |expr| {
            const pass = try evalFilter(expr, source_row);
            if (!pass) return error.FilterSkip;
        }

        return target_row;
    }
};
```

#### 4. MySQL Sink写入模块
核心设计：攒批提交、连接池复用、幂等冲突处理，最大化写入吞吐。
```zig
// src/sink/mysql_sink.zig
const std = @import("std");

pub const MySqlSink = struct {
    allocator: std.mem.Allocator,
    conn_pool: *DbConnectionPool,
    target_table: []const u8,
    batch_buffer: std.ArrayList(RowData),
    batch_size: usize = 1000,
    flush_interval_ms: u64 = 1000,
    conflict_strategy: ConflictStrategy = .update_on_duplicate,

    pub const ConflictStrategy = enum {
        ignore, // 冲突忽略
        update_on_duplicate, // 冲突覆盖
        error, // 冲突报错
    };

    // 追加单条数据，攒够批量自动刷盘
    pub fn append(self: *MySqlSink, row: RowData) !void {
        try self.batch_buffer.append(row);
        if (self.batch_buffer.items.len >= self.batch_size) {
            try self.flush();
        }
    }

    // 批量刷入数据库
    pub fn flush(self: *MySqlSink) !void {
        if (self.batch_buffer.items.len == 0) return;
        defer self.batch_buffer.clearRetainingCapacity();

        const conn = try self.conn_pool.get();
        defer self.conn_pool.release(conn);

        // 构造 INSERT ... ON DUPLICATE KEY UPDATE 批量语句
        const sql = try buildBatchInsertSql(
            self.allocator,
            self.target_table,
            self.batch_buffer.items,
            self.conflict_strategy
        );
        defer self.allocator.free(sql);

        try conn.exec(sql);
        std.log.debug("批量写入 {} 行到表 {}", .{self.batch_buffer.items.len, self.target_table});
    }

    // 定时刷盘协程，避免小批量数据久等
    pub fn startFlushLoop(self: *MySqlSink) !void {
        while (true) {
            std.time.sleep(self.flush_interval_ms * std.time.ns_per_ms);
            self.flush() catch |err| {
                std.log.err("定时刷盘失败: {}", .{err});
            };
        }
    }
};
```

#### 5. 元数据与调度模块
核心设计：SQLite单文件存储，Cron定时调度，任务状态机管理，对账自动执行。
```zig
// src/meta/scheduler.zig
const std = @import("std");
const cdc = @import("../cdc");
const transform = @import("../transform");
const sink = @import("../sink");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    store: *SqliteStore,
    tasks: std.AutoHashMap(usize, *SyncTaskRuntime),
    cron_engine: CronEngine,

    pub const SyncTaskRuntime = struct {
        task_id: usize,
        cdc_collector: cdc.MySqlCdc,
        transform_engine: transform.TransformEngine,
        mysql_sink: sink.MySqlSink,
        status: TaskStatus,
        thread: ?std.Thread = null,
    };

    // 启动所有已启用的任务，每个任务独立线程运行
    pub fn startAllTasks(self: *Scheduler) !void {
        const task_list = try self.store.listEnabledTasks();
        for (task_list) |task_cfg| {
            try self.startTask(task_cfg);
        }
        // 启动定时对账Cron
        try self.cron_engine.addJob("0 0 2 * * *", self.reconcileAllMalls);
        try self.cron_engine.start();
    }

    // 单任务启动：独立线程，故障隔离
    fn startTask(self: *Scheduler, config: TaskConfig) !void {
        const runtime = try self.allocator.create(SyncTaskRuntime);
        errdefer self.allocator.destroy(runtime);

        // 初始化CDC采集器 -> 转换引擎 -> Sink写入器 流水线
        runtime.cdc_collector = try cdc.MySqlCdc.init(...);
        runtime.transform_engine = try transform.TransformEngine.init(...);
        runtime.mysql_sink = try sink.MySqlSink.init(...);

        // 绑定回调：CDC事件 -> 转换 -> 写入
        const callback = struct {
            fn onRow(row: event.RowEvent) anyerror!void {
                const transformed = runtime.transform_engine.process(row.data) catch |err| {
                    // 脏数据写入错误表
                    try runtime.mysql_sink.writeError(row.data, err);
                    return;
                };
                try runtime.mysql_sink.append(transformed);
            }
        }.onRow;
        runtime.cdc_collector.callback = callback;

        // 独立线程运行任务
        runtime.thread = try std.Thread.spawn(.{}, cdc.MySqlCdc.start, .{&runtime.cdc_collector});
        try self.tasks.put(config.id, runtime);
    }
};
```

### 2.3 Zig 专属核心设计要点
1. **内存池复用**：批量数据使用Arena分配器，处理完一批次一次性释放，完全避免内存碎片，长期运行无内存泄漏。
2. **单任务线程隔离**：每个同步任务独立线程运行，单任务崩溃不影响其他任务，符合Zig无共享状态并发模型。
3. **零拷贝数据流转**：binlog事件解析、字段映射全程复用内存切片，避免频繁字符串拷贝，最大化吞吐。
4. **编译期优化**：常用转换规则、表达式在编译期生成专用代码，运行时无解释器开销。
5. **单文件部署**：前端静态资源通过`@embedFile`编译期嵌入二进制，部署仅需一个可执行文件+一个配置文件。

核心模块设计 见 @imp.md
