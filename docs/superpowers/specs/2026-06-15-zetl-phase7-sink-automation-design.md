# zetl Phase 7: sink 自动化 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3 + V5 + V6
- **前置版本**：Phase 6 transform automation（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

把 `MySqlSink` 从"假设目标表已存在"升级为 **自动创建目标表（基于 source schema）**：

1. SyncTask 启动 `runFull` / `runBinlogIncremental` 前，先确保目标表存在。
2. 通过 source schema（来自 Phase 6 的 `fetchSourceColumns`）生成 `CREATE TABLE IF NOT EXISTS target_db.target_table (...)` 语句。
3. 重复启动 idempotent：表已存在时不报错。
4. 用户无需在归集库手工建表，添加新表同步时全自动搞定。

本轮 **不** 处理：
- ALTER TABLE 增列（Phase 7b）
- 字符集 / 索引迁移
- DROP / TRUNCATE 之类的 DDL

---

## 1. 不在本轮范围

- ALTER TABLE schema evolution（加列/减列/改类型）
- 列名重命名（Phase 6b 已说明，仍是后续）
- 索引迁移（target 表索引）
- partition / 字符集 / engine 选项自动推断
- target DB 的存在性检查（假设 target_db 已存在）

---

## 2. 架构与修改点

### 2.1 `src/sink/schema_ddl.zig`（新建）

职责：把 `[]mapper.ColumnMeta` 转成 `CREATE TABLE` 语句。

```zig
pub const DdlOptions = struct {
    /// 数据库名（CREATE TABLE db.target 中使用；空则不带 schema）
    database: []const u8 = "",
    /// ENGINE 子句 (默认 "InnoDB")
    engine: []const u8 = "InnoDB",
    /// DEFAULT CHARSET (默认 "utf8mb4")
    charset: []const u8 = "utf8mb4",
};

/// 生成 CREATE TABLE IF NOT EXISTS <db>.<table> (...) ENGINE=... DEFAULT CHARSET=...;
/// 返回的字符串由 allocator 拥有。
pub fn buildCreateTable(
    allocator: std.mem.Allocator,
    target_table: []const u8,
    columns: []const mapper.ColumnMeta,
    options: DdlOptions,
) ![]u8;
```

列类型映射：
- `ColumnMeta.type` (MySQL 类型字节) → MySQL DDL 类型字符串。
- 类型映射表（与 Phase 2/3 decoder 互补）：
  - `0x01` (TINYINT) → `TINYINT`
  - `0x02` (SMALLINT) → `SMALLINT`
  - `0x03` (INT) → `INT`
  - `0x09` (MEDIUMINT) → `MEDIUMINT`
  - `0x08` (BIGINT) → `BIGINT`
  - `0x04` (FLOAT) → `FLOAT`
  - `0x05` (DOUBLE) → `DOUBLE`
  - `0x00` / `0xf6` (DECIMAL) → `DECIMAL(precision, scale)`（需要从 `column_metadata` 读精度）
  - `0x07` / `0x0a` / `0x0b` / `0x0c` (DATE / TIME / DATETIME / TIMESTAMP) → 对应类型
  - `0x0d` (YEAR) → `YEAR`
  - `0x0f` (VARCHAR) → `VARCHAR(255)` (简化为默认长度; 实际长度从 metadata)
  - `0xfc` (BLOB) → `BLOB`
  - `0xfd` (TEXT) → `TEXT`
  - `0xf5` (JSON) → `JSON`
  - 未知 → `TEXT` (fallback)

精确长度信息（VARCHAR(N) / DECIMAL(p,s)）需要从 source 表的 `column_metadata` 解析；Phase 7 简化处理：VARCHAR 用 255，DECIMAL 用 (precision, scale)（如果可以读），其他用默认。

### 2.2 `src/sink/mysql_sink.zig`

新增 `ensureTable(allocator, conn, target_table, columns, options)` 函数：

```zig
pub fn ensureTable(
    pool: *zfinal.ConnectionPool,
    target_table: []const u8,
    columns: []const mapper.ColumnMeta,
    options: DdlOptions,
) !void {
    const ddl = try schema_ddl.buildCreateTable(pool.allocator, target_table, columns, options);
    defer pool.allocator.free(ddl);

    const conn = try pool.acquire();
    defer pool.release(conn) catch {};

    try conn.exec(ddl);
}
```

`MySqlSink.init` 不变（仍接受 `target_table`）。新增 `MySqlSink.ensureTargetTable(...)` 由 `SyncTask` 调用。

### 2.3 `src/engine/runtime.zig`

`SyncTask` 在调用 `TransformEngine.init` 之后、`runFull` / `runBinlogIncremental` 主体循环之前，调用 `MySqlSink.ensureTargetTable`：

```zig
// Phase 7: 自动确保 target_table 存在
MySqlSink.ensureTargetTable(
    self.sink.pool,
    self.sink.target_table,
    cols,
    .{ .database = self.target_db_name orelse "" },
) catch |err| {
    common.logger.warn("[task {d}] ensureTargetTable 失败: {s}, 继续执行 (假设已存在)", .{ self.cfg.task_id, @errorName(err) });
};
```

字段 `target_db_name` 从 `TaskConfig.target_db` 读取；Phase 7 暂用空字符串（target_table 单一名字，不带 schema），后续 Phase 7b 增强。

### 2.4 `src/transform/mapper.zig`

`ColumnMeta.type` 已经在 Phase 6 中预留但未填充。Phase 7 把 `fetchSourceColumns` 扩展为：

```zig
const row = result.getCurrentRowMap() orelse break;
const field_name = row.get("Field") orelse return error.MissingColumnName;
const type_str = row.get("Type") orelse "";       // 新增
const type_byte = try parseMySqlTypeString(type_str, row.get("Null"), row.get("Key"), ...);
cols[i] = .{ .name = ..., .type = type_byte };
```

`parseMySqlTypeString` 把 "int(11) unsigned" → `0x03`，"varchar(255)" → `0x0f` 等。

---

## 3. 数据流示例

源库表 `order_info`：

```sql
CREATE TABLE order_info (
  order_id  INT PRIMARY KEY,
  paid_at   DATETIME,
  amount    DECIMAL(18,4),
  note      VARCHAR(255)
);
```

新增任务配置：

```
source_db = "primary"
source_table = "order_info"
target_table = "order_info"
sync_mode = 2
```

SyncTask 启动流程：

```
SyncTask.init()
  → fetchSourceColumns()  // SHOW COLUMNS FROM order_info
       → [
           {name="order_id", type=0x03},
           {name="paid_at",  type=0x0c},
           {name="amount",   type=0xf6},
           {name="note",     type=0x0f},
         ]

  → TransformEngine.initWithSchema(cols)

  → MySqlSink.ensureTargetTable(
      target_table="order_info",
      columns=[
        {name="order_id", type=0x03},
        ...
      ],
    )

  → CREATE TABLE IF NOT EXISTS order_info (
        order_id INT,
        paid_at DATETIME,
        amount DECIMAL(18,4),
        note VARCHAR(255)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

第二次启动（表已存在）：`CREATE TABLE IF NOT EXISTS` 不会报错，幂等通过。

---

## 4. 测试策略

### 4.1 `schema_ddl.zig` 单元测试

- `buildCreateTable` 输出格式正确（不含 schema / 含 schema / 含 ENGINE / 含 CHARSET）。
- 列类型映射：TINYINT/INT/BIGINT/DECIMAL/VARCHAR/TEXT/DATE/TIMESTAMP/DATETIME/JSON 全部覆盖。
- 未知类型 fallback 到 TEXT。
- `\` ` 列名转义（如 `note` 包含空格）。

### 4.2 `mysql_sink.zig` 集成测试

- `ensureTargetTable` 在表不存在时执行 DDL。
- `ensureTargetTable` 在表已存在时仍然幂等。
- 失败时不抛错（warn 后继续）。

### 4.3 `runtime.zig` 集成测试

- `SyncTask` 启动时自动调用 `ensureTargetTable`，不需要手工建表。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| DDL 类型映射不全（罕见 type） | fallback 到 TEXT，warn log |
| target DB 不存在 | `ensureTargetTable` 报错；运行时降级（warn 后继续） |
| target 表已存在但 schema 不同 | 不做 DROP / ALTER；`CREATE TABLE IF NOT EXISTS` 是 no-op，运行可能因列错位失败 |
| charset 不匹配 | 默认 utf8mb4；后续 Phase 7b 增强 |
| 重复 `SHOW COLUMNS` 性能 | 启动期一次，可以接受；后续可缓存 |

---

## 6. 后续扩展

- **Phase 7b**：ALTER TABLE ADD COLUMN（schema evolution）
- **Phase 7c**：target 表索引迁移（UNIQUE/PRIMARY KEY）
- **Phase 7d**：target DB 自动创建（`CREATE DATABASE IF NOT EXISTS`）
- **Phase 7e**：charset 推断 / 字符集自动转换