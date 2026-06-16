# zetl V3 binlog CDC Phase 2 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3
- **前置版本**：Phase 1 已实现并合并到 main
- **状态**：待实现

---

## 0. 本轮目标

在 Phase 1 基础上，补齐 binlog CDC 的核心事件解析与运行兼容性：

1. 支持 `UPDATE_ROWS_EVENT_V2` 解析，生成 `op=.update` 的 `RowEvent`，同时携带 `before_fields` 与 `fields`。
2. 支持 `DELETE_ROWS_EVENT_V2` 解析，生成 `op=.delete` 的 `RowEvent`，仅携带 `before_fields`。
3. 处理 MySQL binlog 末尾 4 字节 CRC32 checksum，避免解析器读到校验数据。
4. 修复 MySQL 8 兼容性：`SHOW MASTER STATUS` 已废弃，优先使用 `SHOW BINARY LOG STATUS`，失败时回退旧语句。

---

## 1. 不在本轮范围

- 新增列类型解码（DATETIME / DECIMAL / BLOB / TEXT / JSON 等）继续返回 `"TODO"`。
- DDL 事件同步（QUERY_EVENT）。
- GTID 位点、多任务共享 binlog 连接。
- Task 退出状态清理与 ConnectionPool deinit segfault（作为独立修复跟进）。

---

## 2. 架构与修改点

### 2.1 `src/cdc/binlog/parser.zig`

#### 2.1.1 公共行解码辅助函数

新增 `readRowInto()`：

- 输入：`body`、当前偏移 `pos`、已计算出的 `used_columns`、`null_bitmap_len`、`TableMap`。
- 输出：解析后的 `RowEvent`（按调用方指定的 `RowOp` 填充）。
- 复用现有的 `readColumnValue()` 解码列值。

#### 2.1.2 事件解析改造

- `parseWriteRows()`：调用 `readRowInto()` 生成 `op=.insert` 的行，字段写入 `fields`。
- 新增 `parseUpdateRows()`：
  - 解析 post-header（table_id、flags、extra_data_len）。
  - 读取 col_count 与 `used_columns`（after image）。
  - 读取并跳过 `columns_used_for_update_bitmap`（binlog_row_image=FULL 时与 used bitmap 等长）。
  - 对每一行：先读 **before image** 填入 `before_fields`，再读 **after image** 填入 `fields`，生成单个 `RowEvent { op=.update }`。
- 新增 `parseDeleteRows()`：
  - 结构与 `parseWriteRows()` 类似，但生成 `op=.delete`。
  - 行数据写入 `before_fields`，`fields` 保持为空。

#### 2.1.3 checksum 处理

在 `processEvent()` 中，切分 body 前先根据 `header.event_size` 截断末尾 4 字节 CRC32：

```zig
const event_body_end = if (header.event_size >= 19 + 4) header.event_size - 4 else header.event_size;
const body = buffer[19..event_body_end];
```

- header 事件（如 HEARTBEAT、仅含 header 的未知事件）`event_size == 19`，不做截断。
- 所有非 header 事件默认含 checksum。

### 2.2 `src/cdc/binlog/reader.zig`

保持最小封装，不处理 checksum。`nextEvent()` 继续返回原始 `RawEvent`，由 parser 负责裁剪。

### 2.3 `src/engine/runtime.zig`

#### 2.3.1 `queryMasterStatus()` 兼容性

```zig
fn queryMasterStatus(self: *SyncTask) !BinlogStartPos {
    const conn = try self.src_pool.acquire();
    defer self.src_pool.release(conn) catch {};

    var result = conn.query("SHOW BINARY LOG STATUS") catch |err| {
        common.logger.warn("[task {d}] SHOW BINARY LOG STATUS failed, fallback to SHOW MASTER STATUS: {s}", .{ self.cfg.task_id, @errorName(err) });
        result = try conn.query("SHOW MASTER STATUS");
    };
    defer result.deinit();

    if (result.next()) {
        if (result.getCurrentRowMap()) |row| {
            const file = row.get("File") orelse return error.MissingMasterStatus;
            const pos_s = row.get("Position") orelse return error.MissingMasterStatus;
            const pos = try std.fmt.parseInt(i64, pos_s, 10);
            return .{ .file = try self.allocator.dupe(u8, file), .pos = pos };
        }
    }
    return error.MissingMasterStatus;
}
```

- MySQL 8 的 `SHOW BINARY LOG STATUS` 返回列名仍为 `File` 与 `Position`。
- 回退逻辑确保 MySQL 5.7 及以下仍可工作。

#### 2.3.2 `processBatch()` 行为调整

当前签名：`processBatch(self, rows, default_op)`。

binlog 模式下，每行已经带有正确的 `ev.op`（insert/update/delete），无需再用 `default_op` 覆盖。但为保持 poll 模式兼容，保留 `default_op` 参数：

- 若 `ev.op` 为默认值 `.insert` 且 `default_op` 非 `.insert`，使用 `default_op`（兼容旧轮询路径）。
- 否则尊重 `ev.op`。

实际修改后，`runBinlogIncremental()` 中调用 `processBatch(rows, ev.op)` 或 `.insert` 均可，因为 UPDATE/DELETE 行已自带正确 `op`。

### 2.4 `src/cdc/event.zig`

无需修改。`RowEvent` 已预留 `before_fields: ?StringHashMap([]const u8)`，且 `deinit()` 已释放。

---

## 3. 数据流示例

源库执行：

```sql
UPDATE order_info SET order_total = 200 WHERE id = 1;
DELETE FROM order_info WHERE id = 2;
```

binlog 事件序列：

```
TABLE_MAP_EVENT (order_info)
UPDATE_ROWS_EVENT_V2: [before {id=1, order_total=100}, after {id=1, order_total=200}]
DELETE_ROWS_EVENT_V2: [before {id=2, order_total=300}]
```

解析结果：

```zig
RowEvent{
    .op = .update,
    .table = "order_info",
    .before_fields = {"c0":"1", "c1":"100"},
    .fields = {"c0":"1", "c1":"200"},
}
RowEvent{
    .op = .delete,
    .table = "order_info",
    .before_fields = {"c0":"2", "c1":"300"},
    .fields = {},
}
```

---

## 4. 测试策略

### 4.1 单元测试（mock 字节）

- `test "parseUpdateRowsV2 with before/after images"`
  - 构造 TABLE_MAP + UPDATE_ROWS_V2，验证 `op=.update`、before/after 字段正确。
- `test "parseDeleteRowsV2 carries before_fields"`
  - 构造 TABLE_MAP + DELETE_ROWS_V2，验证 `op=.delete`、`before_fields` 非空、`fields` 为空。
- `test "processEvent strips 4-byte binlog checksum"`
  - 在现有 WRITE_ROWS_V2 测试 buffer 末尾追加 4 字节伪 CRC，验证解析仍成功。

### 4.2 集成测试

- 启动 `sync_mode=binlog` 任务。
- 源库执行 INSERT/UPDATE/DELETE，验证归集库：
  - INSERT：新增行。
  - UPDATE：目标行被更新（ commissions 重算）。
  - DELETE：目标行被删除（或按业务配置软删）。

---

## 5. 错误处理与风险

| 风险 | 应对 |
|------|------|
| `columns_used_for_update_bitmap` 长度与预期不一致 | 读取后断言长度等于 `used_bitmap_len`，不一致记录 error 并跳过该事件 |
| checksum 截断误伤 header-only 事件 | 仅当 `header.event_size >= 19 + 4` 时截断 |
| MySQL 5.7 不支持 `SHOW BINARY LOG STATUS` | 捕获错误后回退 `SHOW MASTER STATUS` |
| UPDATE/DELETE 遇到未实现列类型 | 与 Phase 1 行为一致，字段值输出 `"TODO"`，不影响事件框架 |

---

## 6. 后续扩展

- Phase 2b：扩展 `readColumnValue()` 支持 DATETIME / DECIMAL / BLOB / TEXT / JSON 等常用类型。
- Phase 2c：修复 Task 退出状态清理与 ConnectionPool deinit 稳定性问题。
