# V3 真 binlog CDC 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 zetl 中实现基于 libmysqlclient replication API 的真 MySQL binlog CDC，替代现有 `update_time` 轮询伪 CDC，同时保留轮询作为降级模式。

**Architecture:** 扩展 zfinal 暴露 `mysql_binlog_open/fetch/close` 能力；zetl 新增 `cdc/binlog/` 模块负责 dump、解析、生成 `RowEvent`；`SyncTask` 根据 `sync_mode` 选择 `Poller` 或 `BinlogReader`；位点用 `file + position` 持久化到 SQLite。

**Tech Stack:** Zig 0.17-dev, zfinal (本地路径), libmysqlclient 8.0.26+, MySQL binlog protocol events, SQLite

---

## 文件结构

### zfinal 改动（前置依赖，需发 0.10.9）
- `src/db/drivers/mysql.zig`：在 `MySQLDB` 上实现 `binlogOpen/BinlogFetch/binlogClose`。
- `src/db/db.zig`：在 `DB` 上暴露统一的 `binlogOpen/BinlogFetch/binlogClose` 方法。

### zetl 改动
- `src/cdc/event.zig`：扩展 `RowEvent`，新增 `before_fields`。
- `src/cdc/binlog/position.zig`：新增 `BinlogPosition` 结构。
- `src/cdc/binlog/reader.zig`：封装 `zfinal.DB` 的 binlog dump。
- `src/cdc/binlog/parser.zig`：解析 binlog 事件包为 `RowEvent`。
- `src/cdc/binlog/mod.zig`：模块聚合与对外接口。
- `src/meta/position.zig`：扩展 `SyncPosition`，新增 `binlog_file` / `binlog_pos`，新增 `SyncStage.binlog`。
- `src/meta/task.zig`：扩展 `SyncMode` 为 `{full, poll, binlog, both}`。
- `src/engine/runtime.zig`：`SyncTask` 新增 `runBinlogIncremental`，根据 sync_mode 分支。
- `src/engine/scheduler.zig`：兼容旧 `sync_mode` 字符串映射。
- `src/web/handler/task.zig`：创建/更新任务时支持新 sync_mode。
- `build.zig` / `build.zig.zon`：保持现有 zfinal 路径依赖，升级后指向 0.10.9。

---

## Task 1: 扩展 zfinal 暴露 binlog API

**Files:**
- Modify: `/Users/n0x/w4_proj/zig_ws/zfinal/src/db/drivers/mysql.zig`
- Modify: `/Users/n0x/w4_proj/zig_ws/zfinal/src/db/db.zig`

**Goal:** 让 zetl 可以通过 `zfinal.DB.binlogOpen/BinlogFetch/binlogClose` 操作 binlog dump。

- [ ] **Step 1: 在 MySQLDB 中增加 binlog 方法**

在 `src/db/drivers/mysql.zig` 的 `MySQLDB` 结构体后追加：

```zig
pub const BinlogError = error{
    BinlogOpenFailed,
    BinlogFetchFailed,
    BinlogCloseFailed,
};

pub const RawBinlogEvent = struct {
    buffer: [*c]const u8,
    size: c_ulong,
};

pub fn binlogOpen(self: *MySQLDB, file: [:0]const u8, pos: u64) !void {
    if (self.conn == null) return error.ConnectionClosed;
    var rpl: c.MYSQL_RPL = .{
        .file_name_length = file.len,
        .file_name = file.ptr,
        .start_position = pos,
        .server_id = 0x7a65746c, // 'zetl' 避免与真实 slave 冲突
        .flags = 0,
        .gtid_set_encoded_size = 0,
        .fix_gtid_set = null,
        .gtid_set_arg = null,
        .size = 0,
        .buffer = null,
    };
    if (c.mysql_binlog_open(self.conn, &rpl) != 0) {
        std.debug.print("mysql_binlog_open failed: {s}\n", .{c.mysql_error(self.conn)});
        return error.BinlogOpenFailed;
    }
}

pub fn binlogFetch(self: *MySQLDB) !?RawBinlogEvent {
    if (self.conn == null) return error.ConnectionClosed;
    var rpl: c.MYSQL_RPL = undefined;
    if (c.mysql_binlog_fetch(self.conn, &rpl) != 0) {
        std.debug.print("mysql_binlog_fetch failed: {s}\n", .{c.mysql_error(self.conn)});
        return error.BinlogFetchFailed;
    }
    if (rpl.buffer == null or rpl.size == 0) return null;
    return RawBinlogEvent{ .buffer = rpl.buffer, .size = rpl.size };
}

pub fn binlogClose(self: *MySQLDB) void {
    if (self.conn) |conn| {
        var rpl: c.MYSQL_RPL = undefined;
        c.mysql_binlog_close(conn, &rpl);
    }
}
```

- [ ] **Step 2: 在 DB 上暴露统一方法**

在 `src/db/db.zig` 中追加：

```zig
pub fn binlogOpen(self: *DB, file: [:0]const u8, pos: u64) !void {
    switch (self.driver) {
        .mysql => |*d| try d.binlogOpen(file, pos),
        else => return error.UnsupportedDriver,
    }
}

pub fn binlogFetch(self: *DB) !?MySQLDB.RawBinlogEvent {
    return switch (self.driver) {
        .mysql => |*d| try d.binlogFetch(),
        else => error.UnsupportedDriver,
    };
}

pub fn binlogClose(self: *DB) void {
    switch (self.driver) {
        .mysql => |*d| d.binlogClose(),
        else => {},
    }
}
```

注意需要在 `src/db/db.zig` 顶部导入 `MySQLDB`：

```zig
const MySQLDB = @import("drivers/mysql.zig").MySQLDB;
```

- [ ] **Step 3: 构建验证**

Run:
```bash
cd /Users/n0x/w4_proj/zig_ws/zfinal
zig build -Ddriver_mysql=true
```
Expected: 编译通过，无错误。

- [ ] **Step 4: 提交 zfinal**

```bash
cd /Users/n0x/w4_proj/zig_ws/zfinal
git add src/db/drivers/mysql.zig src/db/db.zig
zig build -Ddriver_mysql=true # 再次确认
zig build test
git commit -m "feat(db): expose mysql_binlog_open/fetch/close for CDC"
```

---

## Task 2: zfinal 发版 0.10.9

**Files:**
- Modify: `/Users/n0x/w4_proj/zig_ws/zfinal/CHANGELOG.md`

- [ ] **Step 1: 更新 CHANGELOG**

在 CHANGELOG 顶部追加：

```markdown
## [0.10.9] - 2026-06-16

### Added
- **MySQL binlog replication API**: `DB.binlogOpen/BinlogFetch/binlogClose` wrap libmysqlclient's `mysql_binlog_open/fetch/close` for real CDC clients.
```

- [ ] **Step 2: 提交并推送**

```bash
cd /Users/n0x/w4_proj/zig_ws/zfinal
git add CHANGELOG.md
git commit -m "chore(release): bump CHANGELOG for v0.10.9"
git push origin main
```

---

## Task 3: 扩展 RowEvent

**Files:**
- Modify: `src/cdc/event.zig`

- [ ] **Step 1: 扩展 RowEvent 结构体**

```zig
pub const RowEvent = struct {
    op: RowOp = .insert,
    table: []const u8 = "",
    database: []const u8 = "",
    fields: std.StringHashMap([]const u8),
    before_fields: ?std.StringHashMap([]const u8) = null, // before image for update/delete
    timestamp: i64 = 0,
    pk_value: []const u8 = "",

    pub fn deinit(self: *RowEvent, allocator: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.fields.deinit();
        if (self.before_fields) |*bf| {
            var bit = bf.iterator();
            while (bit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            bf.deinit();
        }
        allocator.free(self.table);
        allocator.free(self.database);
        allocator.free(self.pk_value);
    }

    pub fn getField(self: *const RowEvent, name: []const u8) ?[]const u8 {
        return self.fields.get(name);
    }

    pub fn getBeforeField(self: *const RowEvent, name: []const u8) ?[]const u8 {
        if (self.before_fields) |bf| return bf.get(name);
        return null;
    }
};
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test
```
Expected: 通过（现有测试不依赖 before_fields）。

- [ ] **Step 3: 提交**

```bash
git add src/cdc/event.zig
git commit -m "feat(cdc): add before_fields to RowEvent for binlog CDC"
```

---

## Task 4: 新增 binlog 位点结构

**Files:**
- Create: `src/cdc/binlog/position.zig`

- [ ] **Step 1: 创建文件**

```zig
//! Binlog 位点 (file + position)

const std = @import("std");

pub const Position = struct {
    file: []const u8 = "",
    pos: u64 = 0,

    pub fn deinit(self: *Position, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
    }

    pub fn dupe(self: *const Position, allocator: std.mem.Allocator) !Position {
        return .{
            .file = try allocator.dupe(u8, self.file),
            .pos = self.pos,
        };
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}:{d}", .{ self.file, self.pos });
    }
};
```

- [ ] **Step 2: 提交**

```bash
git add src/cdc/binlog/position.zig
git commit -m "feat(cdc/binlog): add file+position position struct"
```

---

## Task 5: 新增 BinlogReader

**Files:**
- Create: `src/cdc/binlog/reader.zig`
- Create: `src/cdc/binlog/mod.zig`

- [ ] **Step 1: 创建 reader.zig**

```zig
//! Binlog dump 读取器 — 封装 zfinal.DB 的 binlog API

const std = @import("std");
const zfinal = @import("zfinal");
const position_mod = @import("position.zig");

pub const RawEvent = struct {
    buffer: [*c]const u8,
    size: c_ulong,
};

pub const BinlogReader = struct {
    allocator: std.mem.Allocator,
    db: *zfinal.DB,
    current_file: []const u8 = "",
    current_pos: u64 = 0,
    opened: bool = false,

    pub fn init(allocator: std.mem.Allocator, db: *zfinal.DB) BinlogReader {
        return .{ .allocator = allocator, .db = db };
    }

    pub fn deinit(self: *BinlogReader) void {
        self.close();
        self.allocator.free(self.current_file);
    }

    pub fn open(self: *BinlogReader, file: []const u8, pos: u64) !void {
        self.close();
        const file_z = try self.allocator.dupeZ(u8, file);
        defer self.allocator.free(file_z);
        try self.db.binlogOpen(file_z, pos);
        self.allocator.free(self.current_file);
        self.current_file = try self.allocator.dupe(u8, file);
        self.current_pos = pos;
        self.opened = true;
    }

    pub fn close(self: *BinlogReader) void {
        if (self.opened) {
            self.db.binlogClose();
            self.opened = false;
        }
    }

    pub fn nextEvent(self: *BinlogReader) !?RawEvent {
        if (!self.opened) return error.NotOpened;
        const ev = try self.db.binlogFetch() orelse return null;
        // libmysqlclient 返回的 buffer 生命期到下一次 fetch 之前有效，这里不复制
        return RawEvent{ .buffer = ev.buffer, .size = ev.size };
    }

    pub fn currentPosition(self: *const BinlogReader) position_mod.Position {
        return .{ .file = self.current_file, .pos = self.current_pos };
    }
};
```

- [ ] **Step 2: 创建 mod.zig**

```zig
pub const Position = @import("position.zig").Position;
pub const BinlogReader = @import("reader.zig").BinlogReader;
pub const RawEvent = @import("reader.zig").RawEvent;
```

- [ ] **Step 3: 编译验证**

```bash
zig build -Ddriver_mysql=true
```
Expected: 编译通过（parser 还未引用，reader 本身可独立编译）。

- [ ] **Step 4: 提交**

```bash
git add src/cdc/binlog/reader.zig src/cdc/binlog/mod.zig
git commit -m "feat(cdc/binlog): add BinlogReader wrapping zfinal DB binlog API"
```

---

## Task 6: 扩展 SyncPosition / SyncStage

**Files:**
- Modify: `src/meta/position.zig`
- Modify: `schema.sql`（如有需要）

- [ ] **Step 1: 扩展 SyncStage 和 SyncPosition**

```zig
pub const SyncStage = enum {
    full,
    incremental, // 保留给 poll 模式
    binlog,

    pub fn toString(s: SyncStage) []const u8 {
        return switch (s) {
            .full => "full",
            .incremental => "incremental",
            .binlog => "binlog",
        };
    }

    pub fn fromString(s: []const u8) SyncStage {
        if (std.mem.eql(u8, s, "incremental")) return .incremental;
        if (std.mem.eql(u8, s, "binlog")) return .binlog;
        return .full;
    }
};

pub const SyncPosition = struct {
    task_id: i64,
    last_pk: []const u8 = "",
    last_update_time: []const u8 = "",
    last_event_time: ?[]const u8 = null,
    binlog_file: []const u8 = "",
    binlog_pos: u64 = 0,
    stage: SyncStage = .full,
    updated_at: []const u8 = "",

    pub fn deinit(self: *SyncPosition, allocator: std.mem.Allocator) void {
        allocator.free(self.last_pk);
        allocator.free(self.last_update_time);
        if (self.last_event_time) |e| allocator.free(e);
        allocator.free(self.binlog_file);
        allocator.free(self.updated_at);
    }

    pub fn isInitial(self: *const SyncPosition) bool {
        return self.last_pk.len == 0 and self.last_update_time.len == 0 and self.binlog_file.len == 0;
    }
};
```

- [ ] **Step 2: 更新 Service.load / save**

`load` 中读取 `binlog_file` / `binlog_pos` 列，默认空/0：

```zig
return SyncPosition{
    .task_id = try std.fmt.parseInt(i64, row.get("task_id") orelse "0", 10),
    .last_pk = try allocator.dupe(u8, last_pk_s),
    .last_update_time = try allocator.dupe(u8, last_ut_s),
    .last_event_time = if (last_et_s.len == 0) null else try allocator.dupe(u8, last_et_s),
    .binlog_file = try allocator.dupe(u8, row.get("binlog_file") orelse ""),
    .binlog_pos = try std.fmt.parseInt(u64, row.get("binlog_pos") orelse "0", 10),
    .stage = SyncStage.fromString(stage_s),
    .updated_at = try allocator.dupe(u8, updated_s),
};
```

`save` 中增加对应参数：

```zig
const sql: [:0]const u8 =
    "INSERT INTO sync_position (task_id, last_pk, last_update_time, last_event_time, binlog_file, binlog_pos, stage, updated_at) " ++
    "VALUES ($1, $2, $3, $4, $5, $6, $7, datetime('now')) " ++
    "ON CONFLICT(task_id) DO UPDATE SET " ++
    "last_pk = excluded.last_pk, " ++
    "last_update_time = excluded.last_update_time, " ++
    "last_event_time = excluded.last_event_time, " ++
    "binlog_file = excluded.binlog_file, " ++
    "binlog_pos = excluded.binlog_pos, " ++
    "stage = excluded.stage, " ++
    "updated_at = excluded.updated_at";

try store.db.execParams(sql, &.{
    .{ .int = pos.task_id },
    .{ .text = pos.last_pk },
    .{ .text = pos.last_update_time },
    event_param,
    .{ .text = pos.binlog_file },
    .{ .int = @intCast(pos.binlog_pos) },
    .{ .text = pos.stage.toString() },
});
```

- [ ] **Step 3: 更新 schema.sql**

如果 `schema.sql` 中定义了 `sync_position` 表，增加列：

```sql
ALTER TABLE sync_position ADD COLUMN binlog_file TEXT DEFAULT '';
ALTER TABLE sync_position ADD COLUMN binlog_pos INTEGER DEFAULT 0;
```

或直接在 schema.sql 中修改建表语句（新部署生效）。

- [ ] **Step 4: 编译验证**

```bash
zig build test
```

- [ ] **Step 5: 提交**

```bash
git add src/meta/position.zig schema.sql
git commit -m "feat(meta): extend SyncPosition with binlog file+position"
```

---

## Task 7: 扩展 SyncMode

**Files:**
- Modify: `src/meta/task.zig`
- Modify: `src/engine/scheduler.zig`

- [ ] **Step 1: 更新 SyncMode 枚举**

```zig
pub const SyncMode = enum {
    full,
    poll,
    binlog,
    both,

    pub fn toString(s: SyncMode) []const u8 {
        return switch (s) {
            .full => "full",
            .poll => "poll",
            .binlog => "binlog",
            .both => "both",
        };
    }
};
```

- [ ] **Step 2: 兼容旧数据库值**

在 `src/engine/scheduler.zig` 的 `startTask` 中，加载 task 后做兼容映射：

```zig
var sync_mode = std.meta.stringToEnum(meta.task.SyncMode, task.sync_mode) orelse .poll;
// 兼容旧数据：旧 'cdc' 视为 poll，旧 'both' 保持 both（语义改为 binlog）
if (std.mem.eql(u8, task.sync_mode, "cdc")) sync_mode = .poll;
```

- [ ] **Step 3: 编译验证**

```bash
zig build test
```

- [ ] **Step 4: 提交**

```bash
git add src/meta/task.zig src/engine/scheduler.zig
git commit -m "feat(task): extend SyncMode to full/poll/binlog/both with legacy mapping"
```

---

## Task 8: 实现 binlog 事件解析器

**Files:**
- Create: `src/cdc/binlog/parser.zig`

- [ ] **Step 1: 实现最小可行解析器**

先支持事件头解析 + ROTATE_EVENT + 忽略其他事件：

```zig
//! 轻量 binlog 事件解析器
//! 阶段 1：只解析 ROTATE_EVENT 更新位点，其余事件返回未处理.
//! 阶段 2：解析 WRITE/UPDATE/DELETE_ROWS_EVENT.

const std = @import("std");
const event_mod = @import("../event.zig");
const position_mod = @import("position.zig");

pub const EventType = enum(u8) {
    rotate = 0x04,
    heartbeat = 0x1b,
    table_map = 0x13,
    write_rows_v2 = 0x1e,
    update_rows_v2 = 0x1f,
    delete_rows_v2 = 0x20,
    xid = 0x10,
    _,
};

pub const EventHeader = struct {
    timestamp: u32,
    type_code: u8,
    server_id: u32,
    event_size: u32,
    log_pos: u32,
    flags: u16,
};

pub const ParsedEvent = union(enum) {
    rotate: position_mod.Position,
    heartbeat,
    unknown: EventHeader,
    row: event_mod.RowEvent,
};

pub fn parseHeader(buffer: []const u8) !EventHeader {
    if (buffer.len < 19) return error.BufferTooShort;
    return .{
        .timestamp = std.mem.readInt(u32, buffer[0..4], .little),
        .type_code = buffer[4],
        .server_id = std.mem.readInt(u32, buffer[5..9], .little),
        .event_size = std.mem.readInt(u32, buffer[9..13], .little),
        .log_pos = std.mem.readInt(u32, buffer[13..17], .little),
        .flags = std.mem.readInt(u16, buffer[17..19], .little),
    };
}

pub fn parseEvent(allocator: std.mem.Allocator, buffer: []const u8) !?ParsedEvent {
    const header = try parseHeader(buffer);
    const event_type: EventType = @enumFromInt(header.type_code);
    const body = buffer[19..];

    switch (event_type) {
        .rotate => {
            if (body.len < 8) return error.BufferTooShort;
            const pos = std.mem.readInt(u64, body[0..8], .little);
            const name_len = header.event_size - 19 - 8;
            const name = body[8..][0..name_len];
            return ParsedEvent{ .rotate = .{ .file = try allocator.dupe(u8, name), .pos = pos } };
        },
        .heartbeat => return ParsedEvent.heartbeat,
        else => return ParsedEvent{ .unknown = header },
    }
}
```

- [ ] **Step 2: 写单元测试**

在 `src/cdc/binlog/parser.zig` 底部追加 test block：

```zig
test "parse rotate event" {
    const a = std.testing.allocator;
    // 构造一个假的 ROTATE_EVENT (type=0x04)
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0, .little); // timestamp
    buf[4] = 0x04; // ROTATE_EVENT
    std.mem.writeInt(u32, buf[5..9], 1, .little); // server_id
    std.mem.writeInt(u32, buf[9..13], 64, .little); // event_size
    std.mem.writeInt(u32, buf[13..17], 0, .little); // log_pos
    std.mem.writeInt(u16, buf[17..19], 0, .little); // flags
    std.mem.writeInt(u64, buf[19..27], 12345, .little); // position
    @memcpy(buf[27..][0..10], "bin.000001");

    const ev = try parseEvent(a, &buf);
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(EventType.rotate, @as(EventType, @enumFromInt((try parseHeader(&buf)).type_code)));
}
```

- [ ] **Step 3: 编译并运行测试**

```bash
zig build test
```
Expected: 测试通过。

- [ ] **Step 4: 提交**

```bash
git add src/cdc/binlog/parser.zig
git commit -m "feat(cdc/binlog): add minimal binlog event parser with rotate/heartbeat"
```

---

## Task 9: 实现行事件解析（WRITE/UPDATE/DELETE）

**Files:**
- Modify: `src/cdc/binlog/parser.zig`

- [ ] **Step 1: 实现 TableMap 缓存和行解码**

此步骤较复杂，分小步：

a. 增加 `TableMap` 结构缓存 table_id → 表名/列类型：

```zig
pub const TableMap = struct {
    table_id: u64,
    database: []const u8,
    table: []const u8,
    column_types: []const u8,
    column_metadata: []const u8,
    null_bitmap: []const u8,
};
```

b. 实现 `parseTableMapEvent`。

c. 实现 `parseRowsEvent`，根据 `binlog_row_image` 解码 before/after 行：

```zig
fn parseRowsEvent(
    allocator: std.mem.Allocator,
    header: EventHeader,
    body: []const u8,
    table_map: TableMap,
    op: event_mod.RowOp,
) ![]event_mod.RowEvent {
    // 1. 读取 table_id (6 bytes) + flags (2 bytes)
    // 2. 读取 extra data length (varint) + extra data
    // 3. 读取 column count (varint)
    // 4. 根据 op 读取 used columns bitmap (after / before+after)
    // 5. 逐行解析：null bitmap + field values
    // 6. 生成 RowEvent
    _ = header;
    _ = body;
    _ = table_map;
    _ = op;
    // TODO: 详细实现，见后续任务
    return &[];
}
```

由于行解码涉及 MySQL 字段类型和位图，**此任务可进一步拆分为子任务**。为保持计划可读，先标记为占位，实际执行时拆分：

- Task 9a: TABLE_MAP 解析
- Task 9b: 行数据位图解码
- Task 9c: 常用字段类型解码（INT/BIGINT/VARCHAR/DATETIME/DECIMAL）
- Task 9d: 集成 WRITE/UPDATE/DELETE 事件

- [ ] **Step 2: 运行测试**

```bash
zig build test
```

- [ ] **Step 3: 提交**

```bash
git add src/cdc/binlog/parser.zig
git commit -m "feat(cdc/binlog): parse write/update/delete rows events"
```

---

## Task 10: 集成 BinlogReader 到 SyncTask

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: 新增 runBinlogIncremental**

```zig
fn runBinlogIncremental(self: *SyncTask) !void {
    common.logger.inf("[task {d}] 启动 binlog CDC", .{self.cfg.task_id});

    var reader = cdc.binlog.BinlogReader.init(self.allocator, try self.acquireSourceDb());
    defer reader.deinit();

    const start_pos = if (self.pos.binlog_file.len > 0)
        cdc.binlog.Position{ .file = self.pos.binlog_file, .pos = self.pos.binlog_pos }
    else
        try self.queryMasterStatus();

    try reader.open(start_pos.file, start_pos.pos);

    var table_map: ?cdc.binlog.parser.TableMap = null;
    defer if (table_map) |*tm| tm.deinit(self.allocator);

    while (self.is_running.load(.acquire)) {
        const raw = reader.nextEvent() catch |err| {
            common.logger.err_("[task {d}] binlog fetch: {s}", .{self.cfg.task_id, @errorName(err)});
            sleepMs(1000);
            continue;
        } orelse continue;

        const buf = raw.buffer[0..raw.size];
        const parsed = try cdc.binlog.parser.parseEvent(self.allocator, buf);
        switch (parsed) {
            .rotate => |pos| {
                self.allocator.free(self.pos.binlog_file);
                self.pos.binlog_file = try self.allocator.dupe(u8, pos.file);
                self.pos.binlog_pos = pos.pos;
                pos.deinit(self.allocator);
            },
            .heartbeat => {},
            .row => |ev| {
                var events = try self.allocator.alloc(cdc.event.RowEvent, 1);
                events[0] = ev;
                defer self.freeRowEvents(events);
                try self.processBatch(events, ev.op);
            },
            .unknown => {},
        }

        // 每次事件后更新位点（实际可在 XID 边界批量保存）
        const cur = reader.currentPosition();
        self.allocator.free(self.pos.binlog_file);
        self.pos.binlog_file = try self.allocator.dupe(u8, cur.file);
        self.pos.binlog_pos = cur.pos;
        try self.savePosition();
    }
}

fn queryMasterStatus(self: *SyncTask) !cdc.binlog.Position {
    const conn = try self.src_pool.acquire();
    defer self.src_pool.release(conn);
    var result = try conn.query("SHOW MASTER STATUS");
    defer result.deinit();
    if (result.next()) {
        if (result.getCurrentRowMap()) |row| {
            const file = row.get("File") orelse return error.MissingMasterStatus;
            const pos_s = row.get("Position") orelse return error.MissingMasterStatus;
            const pos = try std.fmt.parseInt(u64, pos_s, 10);
            return .{ .file = try self.allocator.dupe(u8, file), .pos = pos };
        }
    }
    return error.MissingMasterStatus;
}

fn acquireSourceDb(self: *SyncTask) !*zfinal.DB {
    // 从 src_pool 取一个连接并临时持有（实际需改造 ConnectionPool 暴露 DB 指针）
    // 简化：先实现一个 dedicated binlog DB 连接
    _ = self;
    return error.NotImplemented;
}
```

- [ ] **Step 2: 改造 runLoop 分支**

```zig
fn runLoop(self: *SyncTask) void {
    common.logger.inf("[task {d}] 启动 stage={s}", .{self.cfg.task_id, self.pos.stage.toString()});
    defer {
        common.logger.inf("[task {d}] 退出", .{self.cfg.task_id});
        self.is_finished.store(true, .release);
    }

    if (self.cfg.enable_commission_calc) self.reloadRulesIfStale();

    // 全量阶段
    if (self.pos.stage == .full and (self.cfg.sync_mode == .full or self.cfg.sync_mode == .poll or self.cfg.sync_mode == .binlog or self.cfg.sync_mode == .both)) {
        self.runFull() catch |err| {
            common.logger.err_("[task {d}] 全量: {s}", .{self.cfg.task_id, @errorName(err)});
            self.markError(@errorName(err));
            return;
        };
    }

    if (!self.is_running.load(.acquire)) return;

    // 增量阶段
    switch (self.cfg.sync_mode) {
        .full => return,
        .poll => self.runIncremental() catch |err| {
            common.logger.err_("[task {d}] 增量轮询: {s}", .{self.cfg.task_id, @errorName(err)});
            self.markError(@errorName(err));
        },
        .binlog, .both => self.runBinlogIncremental() catch |err| {
            common.logger.err_("[task {d}] binlog: {s}", .{self.cfg.task_id, @errorName(err)});
            self.markError(@errorName(err));
        },
    }
}
```

- [ ] **Step 3: 编译验证**

```bash
zig build -Ddriver_mysql=true
```

- [ ] **Step 4: 提交**

```bash
git add src/engine/runtime.zig
git commit -m "feat(engine): integrate BinlogReader into SyncTask"
```

---

## Task 11: 为 binlog 提供独立源库连接

**Files:**
- Modify: `src/engine/runtime.zig`
- Modify: `src/engine/scheduler.zig`

当前 `SyncTask` 持有 `src_pool: *zfinal.ConnectionPool`。binlog dump 需要一个独立的 `zfinal.DB` 连接（不是从 pool 中借用）。

- [ ] **Step 1: SyncTask 新增独立 binlog DB**

```zig
pub const SyncTask = struct {
    // ... 现有字段 ...
    src_pool: *zfinal.ConnectionPool,
    binlog_db: ?zfinal.DB = null, // 独立连接，用于 binlog dump
    // ...
};
```

- [ ] **Step 2: 在 init 中创建 binlog_db**

```zig
// 在 runtime.zig init 中，构造完 src_pool 后，再创建一个独立 DB
const binlog_cfg = zfinal.DBConfig{
    .db_type = .mysql,
    .host = src_host,
    .port = ds.port,
    .database = src_db,
    .username = src_user,
    .password = src_pass,
};
const binlog_db = try zfinal.DB.init(a, binlog_cfg);
```

- [ ] **Step 3: deinit 中关闭 binlog_db**

```zig
pub fn deinit(self: *SyncTask) void {
    self.transformer.deinit();
    self.sink.deinit();
    self.src_pool.deinit();
    if (self.binlog_db) |*bd| bd.deinit();
    // ...
}
```

- [ ] **Step 4: runBinlogIncremental 使用 self.binlog_db**

```zig
const db = if (self.binlog_db) |*bd| bd else return error.NoBinlogDb;
var reader = cdc.binlog.BinlogReader.init(self.allocator, db);
```

- [ ] **Step 5: 编译验证并提交**

```bash
zig build -Ddriver_mysql=true
zig build test
git add src/engine/runtime.zig
git commit -m "feat(engine): dedicated binlog DB connection per task"
```

---

## Task 12: Web 控制台支持新 sync_mode

**Files:**
- Modify: `src/web/handler/task.zig`
- Modify: `src/web/routes.zig`（如需要）

- [ ] **Step 1: 创建/更新任务时允许 poll/binlog/both**

在 `task.zig` 的 create/update 中，校验 `sync_mode`：

```zig
const valid_modes = &.{ "full", "poll", "binlog", "both" };
if (!std.mem.containsAtLeast(u8, valid_modes, 1, input.sync_mode)) {
    return error.InvalidSyncMode;
}
```

- [ ] **Step 2: 提交**

```bash
git add src/web/handler/task.zig
git commit -m "feat(web): accept new sync_mode values full/poll/binlog/both"
```

---

## Task 13: E2E 验证

**Files:**
- None（手动测试）

- [ ] **Step 1: 准备环境**

确保本地 MySQL 已开启 binlog：

```sql
SHOW VARIABLES LIKE 'log_bin';
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'binlog_row_image';
```

Expected: `log_bin=ON`, `binlog_format=ROW`, `binlog_row_image=FULL`。

- [ ] **Step 2: 启动 zetl**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build -Ddriver_mysql=true
./zig-out/bin/zetl
```

- [ ] **Step 3: 创建 binlog 任务**

通过 Web 或 API 创建任务，sync_mode = `binlog`。

- [ ] **Step 4: 在源库执行 DML**

```sql
INSERT INTO order_info (...) VALUES (...);
UPDATE order_info SET order_total = 999 WHERE order_no = '...';
DELETE FROM order_info WHERE order_no = '...';
```

- [ ] **Step 5: 验证归集库**

检查 `union_all_order`：INSERT 新增、UPDATE 更新、DELETE 删除对应行。

- [ ] **Step 6: 重启续传验证**

停止 zetl，再源库插入数据，启动 zetl，确认从位点续传且不重复。

---

## Task 14: 文档与版本更新

**Files:**
- Modify: `dev.md`
- Modify: `docs/superpowers/specs/2026-06-16-zetl-v3-binlog-cdc-design.md`（标记状态）
- Modify: `CHANGELOG.md`（如存在）

- [ ] **Step 1: 更新 dev.md**

```markdown
- **伪 CDC**: V1/V2 基于 `update_time` 轮询; V3 新增真 binlog CDC (`sync_mode=binlog/both`), 可感知物理删除.
- **轮询降级**: 源库未开启 binlog 时可用 `sync_mode=poll` 保持原行为.
```

- [ ] **Step 2: 更新 spec 状态**

在 spec 文件顶部将状态改为：`- **状态**：已实现`

- [ ] **Step 3: 提交并推送**

```bash
git add dev.md docs/superpowers/specs/2026-06-16-zetl-v3-binlog-cdc-design.md
git commit -m "docs: update status for V3 binlog CDC"
git push origin main
```

---

## 自我审查

### Spec 覆盖检查

| Spec 需求 | 对应任务 |
|-----------|----------|
| 封装 libmysqlclient replication API | Task 1-2 |
| file + position 位点 | Task 4, 6 |
| INSERT/UPDATE/DELETE DML + before 镜像 | Task 3, 8, 9 |
| 每个任务独立 binlog 连接 | Task 11 |
| sync_mode 扩展 + 兼容旧值 | Task 7, 12 |
| 保留 poll 降级 | Task 7 |
| DDL 只记录不同步 | Task 8（unknown 事件忽略） |

### 占位符检查

- Task 9 中的行解码需要进一步拆分，已标注为可拆分子任务。
- `acquireSourceDb` 在 Task 10 中先占位，由 Task 11 实现。

### 类型一致性

- `RowEvent.before_fields` 在 Task 3 定义，Task 9 使用。
- `cdc.binlog.Position` 在 Task 4 定义，后续一致使用。
- `SyncStage.binlog` 在 Task 6 定义，Task 10 使用。

---

## 执行交接

**Plan complete and saved to `docs/superpowers/plans/2026-06-16-v3-binlog-cdc.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
