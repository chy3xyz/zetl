# zetl V3 设计文档：真 binlog CDC

- **项目代号**：zETL
- **设计日期**：2026-06-16
- **适用版本**：V3
- **前置版本**：V1/V2 核心同步闭环 + 运维闭环已完成
- **来源需求**：PRD §1.4、V1/V2 design 中标记为 V3 的 "真 binlog CDC"
- **状态**：已确认架构方案，进入实现计划

---

## 0. 设计基线

### 0.1 本轮决策

| 决策点 | 选择 | 说明 |
|--------|------|------|
| 实现路线 | **封装 libmysqlclient replication API** | `mysql_binlog_open/fetch/close`，开发快、协议完整、生产可靠 |
| 位点机制 | **file + position** | 兼容 MySQL 5.7/8.0/PolarDB，简单通用 |
| 事件范围 | **INSERT/UPDATE/DELETE DML + before 镜像** | 需要 `binlog_row_image=FULL`；DDL 暂不同步结构 |
| 连接模型 | **每个 SyncTask 独立 binlog dump 连接** | 实现简单、故障隔离；共享连接留作后续优化 |
| 降级兼容 | **保留 poll 模式，按 sync_mode 选择** | 新增 `binlog` 模式，原 `cdc` 映射为 `poll`，`both` 改为 `full` 后接 `binlog` |

### 0.2 不在 V3 范围

- GTID 位点（后续可扩展字段）
- DDL 结构同步（只记录 warn/audit，不同步执行）
- 多任务共享 binlog 连接
- 非 MySQL 数据源
- Kafka/MQ 中间件对接

---

## 1. 整体架构

### 1.1 模块划分

```
src/cdc/
├── event.zig          # 扩展 RowEvent：新增 before_fields
├── poller.zig         # 保留轮询 CDC（降级模式）
└── binlog/
    ├── mod.zig        # 对外接口（BinlogReader）
    ├── reader.zig     # 封装 libmysqlclient 的 mysql_binlog_xxx API
    ├── parser.zig     # 解析 RAW BINLOG 事件为 RowEvent
    └── position.zig   # file + position 位点结构
```

### 1.2 与现有组件关系

- `engine/runtime.zig` 中的 `SyncTask` 新增 `binlog_reader: ?cdc.binlog.BinlogReader`。
- `SyncTask.runLoop()` 根据 `sync_mode` 选择分支：
  - `full`：只跑 `runFull()`。
  - `poll`：先 `runFull()`，再 `runPollIncremental()`（原 `runIncremental()`）。
  - `binlog` / `both`：先 `runFull()`，再 `runBinlogIncremental()`。
- `meta/position.zig` 的 `SyncPosition` 新增 `binlog_file` + `binlog_pos`。
- `meta/task.zig` 的 `SyncMode` 扩展为 `{full, poll, binlog, both}`。

---

## 2. 数据流

```
源 MySQL 产生 binlog
        │
        ▼
mysql_binlog_open(filename, position)
        │
        ▼
mysql_binlog_fetch() 返回 RAW 事件包
        │
        ▼
BinlogParser 解析出 TableMapEvent / WriteRowsEvent /
              UpdateRowsEvent / DeleteRowsEvent
        │
        ▼
RowEvent { op, table, database, fields(after), before_fields, pk_value }
        │
        ▼
TransformEngine.process(ev)  →  MySqlSink.append() → flush()
        │
        ▼
归集 MySQL
        │
        ▼
每处理一批 / 定时保存 binlog_file + binlog_pos 到 SQLite
```

---

## 3. 关键组件设计

### 3.1 `cdc/binlog/reader.zig`

封装 `libmysqlclient` 的 replication API：

```zig
pub const BinlogReader = struct {
    mysql: *zfinal.DB,          // 复用 zfinal.DB 封装的 MYSQL*
    allocator: std.mem.Allocator,
    cfg: BinlogConfig,

    pub fn init(... ) !BinlogReader;
    pub fn deinit(self: *BinlogReader);

    /// 从 file/pos 开始 dump；首次从 SHOW MASTER STATUS 获取起点。
    pub fn startDump(self: *BinlogReader, file: []const u8, pos: u64) !void;

    /// 阻塞读取下一个 binlog 事件包（Bytes），返回事件类型和原始数据。
    pub fn nextEvent(self: *BinlogReader) !?RawEvent;

    /// 获取当前位点（在处理完一个事务或心跳后更新）。
    pub fn currentPosition(self: *const BinlogReader) Position;
};
```

### 3.2 `cdc/binlog/parser.zig`

解析 RAW BINLOG 事件：

- 识别事件头：timestamp / type_code / server_id / event_size / log_pos / flags。
- 处理事件类型：
  - `ROTATE_EVENT`：更新当前 binlog 文件名。
  - `TABLE_MAP_EVENT`：缓存 table_id → (database, table, column_types)。
  - `WRITE_ROWS_EVENT` / `UPDATE_ROWS_EVENT` / `DELETE_ROWS_EVENT`：结合 TableMap 解码行数据。
  - `XID_EVENT`：事务边界，可在此 flush sink 并保存位点。
  - `HEARTBEAT_EVENT`：忽略或用于保活。

行数据解码：
- 使用 `libmysqlclient` 提供的 `mysql_binlog_fetch` 已经返回解析好的 `MYSQL_RPL` 结构（包含 event buffer），但仍需手动解析事件体。
- 先实现 `mysql_rpl_parse` 的轻量封装；如果太复杂，可考虑直接解析 `MYSQL_RPL.buffer` 中的字节。

### 3.3 `cdc/event.zig` 扩展

```zig
pub const RowEvent = struct {
    op: RowOp = .insert,
    table: []const u8 = "",
    database: []const u8 = "",
    fields: std.StringHashMap([]const u8),       // after image
    before_fields: ?std.StringHashMap([]const u8) = null, // before image (update/delete)
    timestamp: i64 = 0,
    pk_value: []const u8 = "",
};
```

### 3.4 `meta/position.zig` 扩展

```zig
pub const SyncPosition = struct {
    task_id: i64,
    last_pk: []const u8 = "",
    last_update_time: []const u8 = "",
    last_event_time: ?[]const u8 = null,
    binlog_file: []const u8 = "",
    binlog_pos: u64 = 0,
    stage: SyncStage = .full,
    updated_at: []const u8 = "",
};
```

新增 `SyncStage.binlog` 阶段。

### 3.5 `engine/runtime.zig` 改造

```zig
fn runBinlogIncremental(self: *SyncTask) !void {
    var reader = try cdc.binlog.BinlogReader.init(self.allocator, self.cfg, self.src_pool);
    defer reader.deinit();

    // 若位点为空，取 SHOW MASTER STATUS
    const start_pos = if (self.pos.binlog_file.len > 0)
        .{ .file = self.pos.binlog_file, .pos = self.pos.binlog_pos }
    else
        try self.queryMasterStatus();

    try reader.startDump(start_pos.file, start_pos.pos);

    while (self.is_running.load(.acquire)) {
        const ev = reader.nextEvent() catch |err| {
            common.logger.err_("[task {d}] binlog fetch error: {s}", .{self.cfg.task_id, @errorName(err)});
            // 指数退避后重连
            sleepMs(1000);
            continue;
        } orelse continue;

        if (ev.isRowEvent()) {
            var row_events = try parser.parseRowEvent(self.allocator, ev);
            defer self.freeRowEvents(row_events);
            try self.processBatch(row_events, ev.op());
        }

        // 每个事务边界保存位点
        if (ev.isTransactionBoundary()) {
            self.pos.binlog_file = try self.allocator.dupe(u8, reader.currentPosition().file);
            self.pos.binlog_pos = reader.currentPosition().pos;
            try self.savePosition();
        }
    }
}
```

---

## 4. sync_mode 演进

### 4.1 新枚举

```zig
pub const SyncMode = enum {
    full,    // 仅全量
    poll,    // 全量 + update_time 轮询（原 cdc）
    binlog,  // 全量 + binlog CDC
    both,    // 全量 + binlog CDC（与 binlog 等价，保留语义）
};
```

### 4.2 数据库迁移

现有 `sync_task.sync_mode` 字段为文本，无约束。启动时做兼容映射：

- `"full"` → `full`
- `"cdc"` → `poll`
- `"binlog"` → `binlog`
- `"both"` → `both`

Web 控制台创建任务时，下拉选项改为：full / poll / binlog / both。

---

## 5. 错误处理

| 场景 | 行为 |
|------|------|
| 源库未开启 binlog | `startDump` 返回明确错误；用户可切 `poll` 模式 |
| `binlog_row_image != FULL` | UPDATE 缺少 before 镜像时打 warn，仍用 after 处理 |
| 网络中断 / 连接断开 | 指数退避重连，从上次保存位点续传 |
| binlog 文件被 purge | 返回错误，需要手动重置位点或切全量 |
| DDL 事件 | 记录 audit log，不同步结构，继续处理 DML |

---

## 6. 测试策略

### 6.1 单元测试
- `parser.zig`：用 mock binlog 字节验证事件头解析和 RowEvent 生成。
- `position.zig`：序列化/反序列化位点。

### 6.2 E2E 测试
- 启动 zetl，任务 sync_mode = binlog。
- 源库 INSERT → 验证归集库新增。
- 源库 UPDATE → 验证归集库更新， commissions 重算。
- 源库 DELETE → 验证归集库对应行被删除（或根据业务配置软删）。
- 重启 zetl → 验证从保存位点续传，不重复、不丢失。

---

## 7. 风险与后续扩展

- **风险**：`libmysqlclient` 的 `mysql_binlog_xxx` API 在 MySQL 8.0.26+ 才稳定；需确认 PolarDB MySQL 8.0 兼容。
- **后续扩展**：
  - GTID 位点：在 `SyncPosition` 增加 `gtid_set` 字段。
  - DDL 同步：引入 schema registry，监听 `QUERY_EVENT` 中的 DDL。
  - 共享连接：同一数据源多个任务可共用一个 binlog dump，按 table 在应用层过滤。
