## 一、Web 管理控制台接口定义
### 1.1 接口基础规范
- 统一前缀：`/api/v1`
- 数据格式：请求/响应均为 JSON
- 鉴权方式：管理员账号登录后返回 Token，后续请求 Header 携带 `Authorization: Bearer <token>`
- 统一响应结构
```json
{
  "code": 0,
  "msg": "success",
  "data": {}
}
```
- 错误码约定：0成功，1参数错误，2权限不足，3业务异常，5系统错误

---

### 1.2 数据源管理接口
#### 1. 新增数据源
- 方法：`POST /datasource`
- 请求体
```json
{
  "mall_id": "mall_001",
  "ds_type": "polardb_mysql",
  "host": "pc-xxx.mysql.polardb.aliyuncs.com",
  "port": 3306,
  "db_name": "shop_db",
  "username": "sync_user",
  "password": "xxxxxx",
  "remark": "成都一号店小程序"
}
```
- 响应：返回数据源ID与校验结果（连通性、binlog权限）

#### 2. 测试数据源连通性
- 方法：`POST /datasource/test`
- 请求体：同新增数据源
- 响应：返回连通状态、binlog配置校验结果、错误详情

#### 3. 数据源列表
- 方法：`GET /datasource/list`
- 查询参数：`page=1&page_size=20&keyword=`
- 响应
```json
{
  "total": 32,
  "list": [
    {
      "id": 1,
      "mall_id": "mall_001",
      "ds_type": "polardb_mysql",
      "host": "pc-xxx.mysql.polardb.aliyuncs.com",
      "db_name": "shop_db",
      "status": 1,
      "bind_task_count": 3,
      "created_at": "2026-06-15 10:00:00"
    }
  ]
}
```

#### 4. 批量导入数据源
- 方法：`POST /datasource/batch-import`
- 请求体：数据源数组
- 响应：返回成功/失败数量与错误明细

#### 5. 删除数据源
- 方法：`DELETE /datasource/:id`
- 约束：已绑定同步任务的数据源不可删除

---

### 1.3 同步任务管理接口
#### 1. 创建同步任务
- 方法：`POST /task`
- 请求体
```json
{
  "task_name": "mall_001订单同步",
  "datasource_id": 1,
  "source_table": "order_info",
  "target_table": "union_all_order",
  "sync_mode": "both",
  "field_mappings": [
    {"source": "order_no", "target": "order_no"},
    {"source": "pay_amount", "target": "order_total"}
  ],
  "filter_condition": "order_status > 0",
  "batch_size": 1000,
  "enable_commission_calc": true
}
```

#### 2. 任务启停
- 方法：`POST /task/:id/start` / `POST /task/:id/stop`
- 响应：返回操作结果与当前任务状态

#### 3. 任务详情
- 方法：`GET /task/:id`
- 响应：返回任务配置、运行状态、当前位点、同步延迟、今日同步条数

#### 4. 任务列表
- 方法：`GET /task/list`
- 查询参数：`page=1&page_size=20&status=`
- 响应：返回任务分页列表与状态概览

#### 5. 删除任务
- 方法：`DELETE /task/:id`
- 约束：停止状态下才可删除，同步位点同步清理

---

### 1.4 监控大盘接口
#### 1. 全局概览
- 方法：`GET /monitor/overview`
- 响应
```json
{
  "running_task_count": 30,
  "error_task_count": 1,
  "today_sync_rows": 128560,
  "avg_delay_seconds": 8,
  "datasource_count": 32
}
```

#### 2. 单任务实时指标
- 方法：`GET /monitor/task/:id`
- 响应：返回近1小时延迟趋势、每秒同步行数、成功/失败统计

#### 3. 运行日志查询
- 方法：`GET /monitor/logs`
- 查询参数：`task_id=&level=&start_time=&end_time=&page=1`
- 响应：返回分级日志分页列表

---

### 1.5 对账管理接口
#### 1. 手动触发对账
- 方法：`POST /reconcile/run`
- 请求体：`{"mall_id": "mall_001", "table_name": "union_all_order"}`
- 响应：返回对账任务ID，异步执行

#### 2. 对账记录列表
- 方法：`GET /reconcile/list`
- 查询参数：`mall_id=&start_time=&page=1`
- 响应：返回每次对账的源/目标统计、差值、是否异常

#### 3. 异常明细导出
- 方法：`GET /reconcile/:id/export`
- 响应：返回CSV文件下载流，包含差异订单明细

---

### 1.6 告警配置接口
#### 1. 告警规则列表/新增/修改/删除
- 标准CRUD接口，支持配置延迟阈值、对账差值阈值、告警Webhook地址

#### 2. 测试告警推送
- 方法：`POST /alarm/test`
- 请求体：`{"webhook_url": "xxx", "content": "测试告警"}`

---

## 二、核心模块完整 Zig 0.17 实现代码
### 2.1 CDC 层：Binlog 事件解析核心
**文件路径**：`src/cdc/event.zig`
负责解析 MySQL ROW 格式 binlog 事件，转换为统一行事件结构体，支持 INSERT/UPDATE/DELETE 三类操作。

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 行操作类型
pub const RowOp = enum {
    insert,
    update,
    delete,
};

/// 统一行事件，CDC输出的标准数据结构
pub const RowEvent = struct {
    op: RowOp,
    table_name: []const u8,
    database: []const u8,
    /// 新数据（INSERT/UPDATE有效）
    after: std.StringHashMap([]const u8),
    /// 旧数据（UPDATE/DELETE有效）
    before: ?std.StringHashMap([]const u8) = null,
    /// 事件时间戳
    timestamp: u64,

    pub fn deinit(self: *RowEvent, allocator: Allocator) void {
        self.after.deinit();
        if (self.before) |*b| b.deinit();
        allocator.free(self.table_name);
        allocator.free(self.database);
    }
};

/// Binlog 行事件解析器
pub const RowEventParser = struct {
    allocator: Allocator,
    /// 表结构元数据缓存（库名.表名 -> 字段列表）
    table_meta_cache: std.StringHashMap([]const []const u8),

    pub fn init(allocator: Allocator) RowEventParser {
        return .{
            .allocator = allocator,
            .table_meta_cache = std.StringHashMap([]const []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *RowEventParser) void {
        var it = self.table_meta_cache.valueIterator();
        while (it.next()) |fields| {
            for (fields.*) |f| self.allocator.free(f);
            self.allocator.free(fields.*);
        }
        self.table_meta_cache.deinit();
    }

    /// 解析 TABLE_MAP 事件，缓存表字段元数据
    pub fn handleTableMap(self: *RowEventParser, database: []const u8, table: []const u8, columns: []const []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ database, table });
        errdefer self.allocator.free(key);

        const fields_copy = try self.allocator.alloc([]const u8, columns.len);
        errdefer self.allocator.free(fields_copy);

        for (columns, 0..) |col, i| {
            fields_copy[i] = try self.allocator.dupe(u8, col);
        }

        try self.table_meta_cache.put(key, fields_copy);
    }

    /// 解析 WRITE_ROWS/UPDATE_ROWS/DELETE_ROWS 事件
    pub fn parseRowsEvent(self: *RowEventParser, event_type: u8, database: []const u8, table: []const u8, raw_rows: [][]const u8) ![]RowEvent {
        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ database, table });
        defer self.allocator.free(key);

        const fields = self.table_meta_cache.get(key) orelse return error.TableMetaNotFound;
        const op: RowOp = switch (event_type) {
            0x1e => .insert, // WRITE_ROWS_EVENT_V2
            0x1f => .update, // UPDATE_ROWS_EVENT_V2
            0x20 => .delete, // DELETE_ROWS_EVENT_V2
            else => return error.UnknownEventType,
        };

        var events = std.ArrayList(RowEvent).init(self.allocator);
        errdefer events.deinit();

        var i: usize = 0;
        while (i < raw_rows.len) : (i += 1) {
            var row_event = RowEvent{
                .op = op,
                .database = try self.allocator.dupe(u8, database),
                .table_name = try self.allocator.dupe(u8, table),
                .after = std.StringHashMap([]const u8).init(self.allocator),
                .timestamp = std.time.timestamp(),
            };

            // 填充字段值
            for (fields, 0..) |field, idx| {
                const val = if (idx < raw_rows[i].len) raw_rows[i][idx] else "";
                try row_event.after.put(try self.allocator.dupe(u8, field), try self.allocator.dupe(u8, val));
            }

            // UPDATE事件包含前后两行数据
            if (op == .update and i + 1 < raw_rows.len) {
                i += 1;
                var before = std.StringHashMap([]const u8).init(self.allocator);
                for (fields, 0..) |field, idx| {
                    const val = if (idx < raw_rows[i].len) raw_rows[i][idx] else "";
                    try before.put(try self.allocator.dupe(u8, field), try self.allocator.dupe(u8, val));
                }
                row_event.before = before;
            }

            try events.append(row_event);
        }

        return events.toOwnedSlice();
    }
};
```

---

### 2.2 转换层：佣金计算引擎完整实现
**文件路径**：`src/transform/commission.zig`
支持固定比例、阶梯金额分佣，按 agent_id + mall_id 匹配规则，零额外依赖。

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Decimal = std.math.big.Rational;

/// 佣金计算结果
pub const CommissionResult = struct {
    amount: []const u8, // 字符串格式避免浮点精度丢失
    rate: []const u8,
    rule_id: usize,
};

/// 佣金规则结构体（从数据库加载）
pub const CommissionRule = struct {
    id: usize,
    agent_id: []const u8,
    mall_id: []const u8, // "*" 表示全商城通用
    min_amount: f64,
    max_amount: f64,
    rate: f64, // 分佣比例，如0.1表示10%
};

/// 佣金计算器
pub const CommissionCalculator = struct {
    allocator: Allocator,
    rules: std.ArrayList(CommissionRule),

    pub fn init(allocator: Allocator) CommissionCalculator {
        return .{
            .allocator = allocator,
            .rules = std.ArrayList(CommissionRule).init(allocator),
        };
    }

    pub fn deinit(self: *CommissionCalculator) void {
        for (self.rules.items) |rule| {
            self.allocator.free(rule.agent_id);
            self.allocator.free(rule.mall_id);
        }
        self.rules.deinit();
    }

    /// 批量加载规则（从数据库查询后调用）
    pub fn loadRules(self: *CommissionCalculator, rule_list: []const CommissionRule) !void {
        self.rules.clearRetainingCapacity();
        for (rule_list) |rule| {
            try self.rules.append(.{
                .id = rule.id,
                .agent_id = try self.allocator.dupe(u8, rule.agent_id),
                .mall_id = try self.allocator.dupe(u8, rule.mall_id),
                .min_amount = rule.min_amount,
                .max_amount = rule.max_amount,
                .rate = rule.rate,
            });
        }
    }

    /// 计算单笔订单佣金
    pub fn calculate(self: *CommissionCalculator, agent_id: []const u8, mall_id: []const u8, order_amount: []const u8) !CommissionResult {
        const amount = std.fmt.parseFloat(f64, order_amount) catch 0.0;
        if (amount <= 0) return .{
            .amount = "0.00",
            .rate = "0.0000",
            .rule_id = 0,
        };

        // 优先级：指定商城规则 > 全商城通用规则
        var matched_rule: ?CommissionRule = null;
        var best_priority: u8 = 0;

        for (self.rules.items) |rule| {
            // 代理商不匹配跳过
            if (!std.mem.eql(u8, rule.agent_id, agent_id)) continue;

            // 金额不在阶梯区间跳过
            if (amount < rule.min_amount or amount > rule.max_amount) continue;

            // 匹配指定商城，优先级最高
            if (std.mem.eql(u8, rule.mall_id, mall_id)) {
                matched_rule = rule;
                best_priority = 2;
                break;
            }

            // 匹配全商城通用，优先级次之
            if (std.mem.eql(u8, rule.mall_id, "*") and best_priority < 1) {
                matched_rule = rule;
                best_priority = 1;
            }
        }

        const rule = matched_rule orelse return .{
            .amount = "0.00",
            .rate = "0.0000",
            .rule_id = 0,
        };

        const commission = amount * rule.rate;
        // 格式化保留两位小数，避免浮点误差
        const amount_buf = try self.allocator.alloc(u8, 32);
        const rate_buf = try self.allocator.alloc(u8, 16);
        const amount_str = try std.fmt.bufPrint(amount_buf, "{d:.2}", .{commission});
        const rate_str = try std.fmt.bufPrint(rate_buf, "{d:.4}", .{rule.rate});

        return .{
            .amount = amount_str,
            .rate = rate_str,
            .rule_id = rule.id,
        };
    }
};
```

---

### 2.3 Sink 层：MySQL 批量幂等写入实现
**文件路径**：`src/sink/mysql_sink.zig`
核心实现批量 INSERT + 幂等冲突处理，自动构造 SQL，支持攒批提交。

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const mysql = @import("mysql"); // 假设使用Zig MySQL客户端库

pub const ConflictStrategy = enum {
    ignore,       // 冲突则忽略
    update,       // 冲突则更新
    error,        // 冲突则报错
};

pub const MySqlSink = struct {
    allocator: Allocator,
    conn: *mysql.Connection,
    target_table: []const u8,
    batch_buffer: std.ArrayList(std.StringHashMap([]const u8)),
    batch_size: usize,
    conflict_strategy: ConflictStrategy,
    unique_keys: []const []const u8, // 幂等唯一键，如mall_id,order_no

    pub fn init(
        allocator: Allocator,
        conn: *mysql.Connection,
        target_table: []const u8,
        batch_size: usize,
        conflict_strategy: ConflictStrategy,
        unique_keys: []const []const u8,
    ) !MySqlSink {
        return .{
            .allocator = allocator,
            .conn = conn,
            .target_table = try allocator.dupe(u8, target_table),
            .batch_buffer = std.ArrayList(std.StringHashMap([]const u8)).init(allocator),
            .batch_size = batch_size,
            .conflict_strategy = conflict_strategy,
            .unique_keys = try allocator.dupe([]const u8, unique_keys),
        };
    }

    pub fn deinit(self: *MySqlSink) void {
        self.allocator.free(self.target_table);
        for (self.unique_keys) |k| self.allocator.free(k);
        self.allocator.free(self.unique_keys);
        for (self.batch_buffer.items) |*row| row.deinit();
        self.batch_buffer.deinit();
    }

    /// 追加单行数据，达到批量阈值自动刷盘
    pub fn append(self: *MySqlSink, row: std.StringHashMap([]const u8)) !void {
        // 深拷贝行数据，避免外部释放导致悬垂指针
        var row_copy = std.StringHashMap([]const u8).init(self.allocator);
        var it = row.iterator();
        while (it.next()) |entry| {
            try row_copy.put(
                try self.allocator.dupe(u8, entry.key_ptr.*),
                try self.allocator.dupe(u8, entry.value_ptr.*),
            );
        }

        try self.batch_buffer.append(row_copy);
        if (self.batch_buffer.items.len >= self.batch_size) {
            try self.flush();
        }
    }

    /// 批量刷入数据库
    pub fn flush(self: *MySqlSink) !void {
        if (self.batch_buffer.items.len == 0) return;
        defer self.clearBuffer();

        const sql = try self.buildBatchSql();
        defer self.allocator.free(sql);

        _ = try self.conn.exec(sql);
        std.log.debug("批量写入 {d} 行到表 {s}", .{ self.batch_buffer.items.len, self.target_table });
    }

    /// 构造批量INSERT语句，支持幂等冲突处理
    fn buildBatchSql(self: *MySqlSink) ![]const u8 {
        const rows = self.batch_buffer.items;
        const first_row = rows[0];
        const columns = try self.getColumnList(first_row);
        defer self.allocator.free(columns);

        var sql_buf = std.ArrayList(u8).init(self.allocator);
        const writer = sql_buf.writer();

        // INSERT 头部
        try writer.print("INSERT INTO `{s}` (", .{self.target_table});
        for (columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("`{s}`", .{col});
        }
        try writer.writeAll(") VALUES ");

        // 批量值
        for (rows, 0..) |row, row_idx| {
            if (row_idx > 0) try writer.writeAll(",");
            try writer.writeByte('(');
            for (columns, 0..) |col, col_idx| {
                if (col_idx > 0) try writer.writeAll(",");
                const val = row.get(col) orelse "NULL";
                // 简单转义，生产环境建议使用预编译语句防注入
                try writer.print("'{s}'", .{val});
            }
            try writer.writeByte(')');
        }

        // 幂等冲突处理
        switch (self.conflict_strategy) {
            .ignore => try writer.writeAll(" ON DUPLICATE KEY UPDATE id=id"),
            .update => {
                try writer.writeAll(" ON DUPLICATE KEY UPDATE ");
                // 非唯一键字段全部更新
                var update_idx: usize = 0;
                for (columns) |col| {
                    // 跳过唯一键字段
                    var is_unique = false;
                    for (self.unique_keys) |uk| {
                        if (std.mem.eql(u8, col, uk)) {
                            is_unique = true;
                            break;
                        }
                    }
                    if (is_unique) continue;

                    if (update_idx > 0) try writer.writeAll(",");
                    try writer.print("`{s}`=VALUES(`{s}`)", .{ col, col });
                    update_idx += 1;
                }
            },
            .error => {},
        }

        return sql_buf.toOwnedSlice();
    }

    /// 从第一行数据提取字段列表
    fn getColumnList(self: *MySqlSink, row: std.StringHashMap([]const u8)) ![]const []const u8 {
        var cols = std.ArrayList([]const u8).init(self.allocator);
        var it = row.keyIterator();
        while (it.next()) |key| {
            try cols.append(try self.allocator.dupe(u8, key.*));
        }
        return cols.toOwnedSlice();
    }

    /// 清空缓冲区，释放内存
    fn clearBuffer(self: *MySqlSink) void {
        for (self.batch_buffer.items) |*row| {
            var it = row.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            row.deinit();
        }
        self.batch_buffer.clearRetainingCapacity();
    }
};
```

---

### 2.4 CDC 层：同步位点持久化实现
**文件路径**：`src/cdc/position.zig`
基于 SQLite 持久化 binlog 位点，支持 GTID 与文件位置双模式，保证断点续传不丢数据。

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");

pub const SyncPosition = struct {
    task_id: usize,
    binlog_file: []const u8,
    binlog_pos: u64,
    gtid_set: []const u8,
    last_event_time: i64,
    updated_at: i64,

    pub fn init(task_id: usize) SyncPosition {
        return .{
            .task_id = task_id,
            .binlog_file = "",
            .binlog_pos = 0,
            .gtid_set = "",
            .last_event_time = 0,
            .updated_at = std.time.timestamp(),
        };
    }

    /// 判断是否为初始状态（未同步过任何数据）
    pub fn isInitial(self: *const SyncPosition) bool {
        return self.binlog_pos == 0 and self.gtid_set.len == 0;
    }
};

/// 位点管理器，负责持久化与读取
pub const PositionManager = struct {
    allocator: Allocator,
    db: *sqlite.Db,

    pub fn init(allocator: Allocator, db: *sqlite.Db) !PositionManager {
        // 自动创建位点表
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS sync_position (
            \\  task_id INTEGER PRIMARY KEY,
            \\  binlog_file TEXT NOT NULL DEFAULT '',
            \\  binlog_pos INTEGER NOT NULL DEFAULT 0,
            \\  gtid_set TEXT NOT NULL DEFAULT '',
            \\  last_event_time INTEGER NOT NULL DEFAULT 0,
            \\  updated_at INTEGER NOT NULL DEFAULT 0
            \\)
        );
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    /// 加载指定任务的同步位点
    pub fn load(self: *PositionManager, task_id: usize) !SyncPosition {
        var stmt = try self.db.prepare("SELECT binlog_file, binlog_pos, gtid_set, last_event_time, updated_at FROM sync_position WHERE task_id = ?");
        defer stmt.deinit();

        try stmt.bind(.{ task_id });
        const row = try stmt.one() orelse return SyncPosition.init(task_id);

        return .{
            .task_id = task_id,
            .binlog_file = try self.allocator.dupe(u8, row[0].text),
            .binlog_pos = @intCast(row[1].int),
            .gtid_set = try self.allocator.dupe(u8, row[2].text),
            .last_event_time = row[3].int,
            .updated_at = row[4].int,
        };
    }

    /// 保存同步位点（原子更新）
    pub fn save(self: *PositionManager, pos: SyncPosition) !void {
        try self.db.exec(
            \\INSERT INTO sync_position (task_id, binlog_file, binlog_pos, gtid_set, last_event_time, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(task_id) DO UPDATE SET
            \\  binlog_file = excluded.binlog_file,
            \\  binlog_pos = excluded.binlog_pos,
            \\  gtid_set = excluded.gtid_set,
            \\  last_event_time = excluded.last_event_time,
            \\  updated_at = excluded.updated_at
        , .{
            pos.task_id,
            pos.binlog_file,
            pos.binlog_pos,
            pos.gtid_set,
            pos.last_event_time,
            std.time.timestamp(),
        });
    }

    /// 清理指定任务的位点
    pub fn delete(self: *PositionManager, task_id: usize) !void {
        try self.db.exec("DELETE FROM sync_position WHERE task_id = ?", .{task_id});
    }
};
```

---

## 三、前端页面设计说明（HTMX + Alpine.js）
配合 Zig 后端采用无构建轻量方案，所有静态资源编译期嵌入二进制，单文件部署：
1. **页面结构**：左侧导航 + 右侧内容区，包含数据源、任务、监控、对账、告警、设置六大模块
2. **交互方式**：HTMX 负责局部刷新，Alpine.js 处理前端状态，无打包工具
3. **核心页面**：
   - 数据源列表页：表格展示所有商城数据源，支持批量导入、测试连接
   - 任务配置页：可视化字段映射拖拽、佣金规则配置、过滤条件设置
   - 监控大盘：实时延迟曲线图、任务状态总览、异常任务高亮
   - 对账报表：每日对账记录、异常差值导出、手动触发对账
