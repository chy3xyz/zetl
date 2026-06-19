# zetl Phase 7: sink 自动化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-create the target table from source schema via `CREATE TABLE IF NOT EXISTS`, so users don't have to hand-maintain the destination schema.

**Architecture:** Add `src/sink/schema_ddl.zig` that builds CREATE TABLE statements from `[]mapper.ColumnMeta`. Extend `MySqlSink.ensureTargetTable` to execute the DDL. Hook `SyncTask.init` to call ensureTargetTable after the TransformEngine is initialized, using columns fetched in Phase 6. Fall back to original behavior on DDL failure.

**Tech Stack:** Zig (0.17 nightly), zfinal MySQL C API wrapper, `std.fmt.allocPrint` for SQL composition.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/sink/schema_ddl.zig` | Build CREATE TABLE DDL from source columns | New |
| `src/sink/mysql_sink.zig` | `ensureTargetTable` runs the DDL | Extend |
| `src/engine/runtime.zig` | SyncTask calls `ensureTargetTable` after TransformEngine init | Extend |
| `src/transform/mapper.zig` | `ColumnMeta.type` parsed from `SHOW COLUMNS` | Extend |

---

## Task 1: `schema_ddl.zig` skeleton + `buildCreateTable`

**Files:**
- Create: `src/sink/schema_ddl.zig`
- Test: `src/sink/schema_ddl.zig`

- [ ] **Step 1: Create the file with the skeleton**

Create `src/sink/schema_ddl.zig`:

```zig
const std = @import("std");
const mapper = @import("../transform/mapper.zig");

pub const DdlOptions = struct {
    database: []const u8 = "",
    engine: []const u8 = "InnoDB",
    charset: []const u8 = "utf8mb4",
};

/// 把 MySQL 类型字节转 DDL 类型字符串. 未知类型 fallback 到 TEXT.
fn mySqlTypeName(col_type: u8) []const u8 {
    return switch (col_type) {
        0x01 => "TINYINT",
        0x02 => "SMALLINT",
        0x03 => "INT",
        0x09 => "MEDIUMINT",
        0x08 => "BIGINT",
        0x04 => "FLOAT",
        0x05 => "DOUBLE",
        0x00 => "DECIMAL",          // 旧 DECIMAL; 用默认 (10, 0)
        0xf6 => "DECIMAL(18,4)",     // NEWDECIMAL 默认值
        0x0a => "DATE",
        0x0b => "TIME",
        0x0c => "DATETIME",
        0x12 => "DATETIME(6)",
        0x07 => "TIMESTAMP",
        0x11 => "TIMESTAMP(6)",
        0x0d => "YEAR",
        0x0f => "VARCHAR(255)",
        0xfc => "BLOB",
        0xfd => "TEXT",
        0xf5 => "JSON",
        else => "TEXT", // 兜底
    };
}

/// 反引号转义列名 (MySQL DDL 用反引号包列名).
fn quoteIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "`{s}`", .{name});
}

/// 生成 CREATE TABLE IF NOT EXISTS <db.>table (col1 TYPE, col2 TYPE, ...) ENGINE=... DEFAULT CHARSET=...;
/// 返回的字符串由 allocator 拥有.
pub fn buildCreateTable(
    allocator: std.mem.Allocator,
    target_table: []const u8,
    columns: []const mapper.ColumnMeta,
    options: DdlOptions,
) ![]u8 {
    // 列定义 buffer
    var col_parts = std.ArrayList([]const u8).empty;
    defer {
        for (col_parts.items) |c| allocator.free(c);
        col_parts.deinit(allocator);
    }
    for (columns) |col| {
        const quoted = try quoteIdentifier(allocator, col.name);
        const type_name = mySqlTypeName(col.type);
        const part = try std.fmt.allocPrint(allocator, "    {s} {s}", .{ quoted, type_name });
        allocator.free(quoted);
        try col_parts.append(allocator, part);
    }

    // 拼接列定义
    var cols_buf = std.ArrayList(u8).empty;
    defer cols_buf.deinit(allocator);
    for (col_parts.items, 0..) |part, i| {
        if (i > 0) try cols_buf.append(allocator, ',');
        try cols_buf.appendSlice(allocator, part);
    }

    const target = if (options.database.len > 0)
        try std.fmt.allocPrint(allocator, "`{s}`.`{s}`", .{ options.database, target_table })
    else
        try std.fmt.allocPrint(allocator, "`{s}`", .{target_table});
    defer allocator.free(target);

    return std.fmt.allocPrint(
        allocator,
        "CREATE TABLE IF NOT EXISTS {s} (\n{s}\n) ENGINE={s} DEFAULT CHARSET={s};",
        .{ target, cols_buf.items, options.engine, options.charset },
    );
}

test "buildCreateTable formats basic identity table" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{
        .{ .name = "id", .type = 0x03 },
        .{ .name = "name", .type = 0x0f },
    };
    const ddl = try buildCreateTable(a, "orders", &cols, .{});
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "CREATE TABLE IF NOT EXISTS `orders`") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`id` INT") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`name` VARCHAR(255)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "ENGINE=InnoDB") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "DEFAULT CHARSET=utf8mb4") != null);
}

test "buildCreateTable includes database prefix when provided" {
    const a = std.testing.allocator;
    const cols = [_]mapper.ColumnMeta{.{ .name = "id", .type = 0x03 }};
    const ddl = try buildCreateTable(a, "orders", &cols, .{ .database = "analytics" });
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "`analytics`.`orders`") != null);
}
```

- [ ] **Step 2: Run tests to confirm they pass**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig test src/sink/schema_ddl.zig --mod zfinal::/Users/n0x/w4_proj/zig_ws/zfinal/zig-out/lib/libzfinal.a -lc -lpthread -lm -lssl -lcrypto -lz
```

If the `--mod` syntax differs in this project, try:

```bash
zig test src/sink/schema_ddl.zig
```

Expected: 2 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/sink/schema_ddl.zig
git commit -m "feat(sink): add schema_ddl.buildCreateTable for CREATE TABLE generation"
```

---

## Task 2: Extend `fetchSourceColumns` to populate `ColumnMeta.type`

**Files:**
- Modify: `src/engine/runtime.zig`
- Test: existing test coverage (the helper is invoked indirectly)

- [ ] **Step 1: Find `fetchSourceColumns`**

Search for `fn fetchSourceColumns` in `src/engine/runtime.zig`. The current implementation reads only the `Field` column.

- [ ] **Step 2: Add Type parsing**

Replace the row-extraction loop with:

```zig
    var i: usize = 0;
    while (try result.next()) {
        const row = result.getCurrentRowMap() orelse break;
        const field_name = row.get("Field") orelse return error.MissingColumnName;
        const type_str = row.get("Type") orelse "";
        const type_byte = parseMySqlTypeString(type_str);
        cols[i] = .{
            .name = try self.allocator.dupe(u8, field_name),
            .type = type_byte,
        };
        i += 1;
    }
```

Add a helper method on `SyncTask` (or a free function in the same file):

```zig
/// 解析 SHOW COLUMNS 返回的 Type 字符串 (如 "int(11) unsigned", "varchar(255)", "datetime")
/// 转 MySQL 类型字节. 未知类型返回 0xff (建表时 fallback TEXT).
fn parseMySqlTypeString(type_str: []const u8) u8 {
    // 取括号前的关键字部分
    var end: usize = 0;
    while (end < type_str.len and type_str[end] != '(' and type_str[end] != ' ') : (end += 1) {}
    const keyword = type_str[0..end];

    if (std.mem.eql(u8, keyword, "tinyint")) return 0x01;
    if (std.mem.eql(u8, keyword, "smallint")) return 0x02;
    if (std.mem.eql(u8, keyword, "int")) return 0x03;
    if (std.mem.eql(u8, keyword, "mediumint")) return 0x09;
    if (std.mem.eql(u8, keyword, "bigint")) return 0x08;
    if (std.mem.eql(u8, keyword, "float")) return 0x04;
    if (std.mem.eql(u8, keyword, "double")) return 0x05;
    if (std.mem.eql(u8, keyword, "decimal")) return 0xf6;
    if (std.mem.eql(u8, keyword, "date")) return 0x0a;
    if (std.mem.eql(u8, keyword, "time")) return 0x0b;
    if (std.mem.eql(u8, keyword, "datetime")) return 0x12;
    if (std.mem.eql(u8, keyword, "timestamp")) return 0x11;
    if (std.mem.eql(u8, keyword, "year")) return 0x0d;
    if (std.mem.eql(u8, keyword, "varchar")) return 0x0f;
    if (std.mem.eql(u8, keyword, "char")) return 0xfe;
    if (std.mem.eql(u8, keyword, "text")) return 0xfd;
    if (std.mem.eql(u8, keyword, "tinytext")) return 0xfd;
    if (std.mem.eql(u8, keyword, "mediumtext")) return 0xfd;
    if (std.mem.eql(u8, keyword, "longtext")) return 0xfd;
    if (std.mem.eql(u8, keyword, "blob")) return 0xfc;
    if (std.mem.eql(u8, keyword, "tinyblob")) return 0xfc;
    if (std.mem.eql(u8, keyword, "mediumblob")) return 0xfc;
    if (std.mem.eql(u8, keyword, "longblob")) return 0xfc;
    if (std.mem.eql(u8, keyword, "json")) return 0xf5;
    return 0xff; // unknown
}
```

- [ ] **Step 3: Build**

```bash
zig build 2>&1 | head -20
```

Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "feat(engine): parseMySqlTypeString for ColumnMeta.type"
```

---

## Task 3: `MySqlSink.ensureTargetTable`

**Files:**
- Modify: `src/sink/mysql_sink.zig`
- Test: `src/sink/mysql_sink.zig` (manual integration; unit test deferred)

- [ ] **Step 1: Add the method**

In `src/sink/mysql_sink.zig`, add:

```zig
const schema_ddl = @import("schema_ddl.zig");

/// 通过 CREATE TABLE IF NOT EXISTS 自动确保 target_table 存在.
/// 失败时返回 error 让调用方决定 warn or fail.
pub fn ensureTargetTable(
    pool: *zfinal.ConnectionPool,
    target_table: []const u8,
    columns: []const mapper.ColumnMeta,
    options: schema_ddl.DdlOptions,
) !void {
    const a = pool.allocator;
    const ddl = try schema_ddl.buildCreateTable(a, target_table, columns, options);
    defer a.free(ddl);

    const conn = try pool.acquire();
    defer pool.release(conn) catch {};

    try conn.exec(ddl);
}
```

> Adapt the pool acquire/release signature to whatever zfinal's API uses for this project. Read existing methods on `MySqlSink` to copy the pattern.

- [ ] **Step 2: Build**

```bash
zig build 2>&1 | head -20
```

Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add src/sink/mysql_sink.zig
git commit -m "feat(sink): add MySqlSink.ensureTargetTable via CREATE TABLE IF NOT EXISTS"
```

---

## Task 4: SyncTask integration

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Find where Phase 6 wired `fetchSourceColumns`**

Locate the `tr_init:` block in `SyncTask.init` (added in Phase 6 Task 5). After the transformer is initialized via `initWithSchema` and the `defer for (cols) ...` block, add the table-ensure call.

- [ ] **Step 2: Add ensureTargetTable call**

Right after the existing `defer for (cols) |c| self.allocator.free(c.name); defer self.allocator.free(cols);` lines (which free the cols slice), add:

```zig
    // Phase 7: 自动确保 target_table 存在
    mysql_sink.MySqlSink.ensureTargetTable(
        self.sink.pool,
        self.sink.target_table,
        cols,
        .{},
    ) catch |err| {
        common.logger.warn("[task {d}] ensureTargetTable 失败: {s}, 继续 (假设已存在)", .{ self.cfg.task_id, @errorName(err) });
    };
```

The error path uses `|` block capture and `catch` (rather than `catch |err|` arrow notation) — adapt to whichever style the project uses by reading similar code in the file.

- [ ] **Step 3: Build and run tests**

```bash
zig build 2>&1 | head -20
zig build test 2>&1 | tail -5
```

Expected: builds clean, all 187 tests still pass.

- [ ] **Step 4: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "feat(engine): call ensureTargetTable after initWithSchema"
```

---

## Task 5: dev.md + final verification

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Add Phase 7 section to dev.md**

In `dev.md`, after the Phase 6 section, add:

```
## Phase 7: sink 自动化

`MySqlSink.ensureTargetTable` 自动通过 `CREATE TABLE IF NOT EXISTS` 创建 target_table, 用户添加新表同步时无需手工建表.

- `src/sink/schema_ddl.zig::buildCreateTable` 从 `[]ColumnMeta` 生成 DDL, 类型字节 → MySQL 类型字符串映射.
- `MySqlSink.ensureTargetTable` 执行 DDL, 表已存在时幂等.
- `SyncTask.init` 在 `initWithSchema` 之后调用 `ensureTargetTable`; 失败时 warn + 继续.
- 默认 charset utf8mb4 + engine InnoDB; target_db 可选.
- binlog / poll 路径自动复用 Phase 6 的 source schema.
```

- [ ] **Step 2: Final verification**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/sink/schema_ddl.zig src/sink/mysql_sink.zig src/engine/runtime.zig
zig build test 2>&1 | tail -5
```

Expected: formatting OK, all 189 tests pass (187 + 2 new schema_ddl tests).

- [ ] **Step 3: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add dev.md docs/superpowers/specs/2026-06-15-zetl-phase7-sink-automation-design.md docs/superpowers/plans/2026-06-15-zetl-phase7-sink-automation.md
git commit -m "docs: add Phase 7 section + commit design/plan docs"
```

If design/plan docs were already committed in a previous commit, drop them.

Report DONE when finished.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - schema_ddl.buildCreateTable → Task 1
  - parseMySqlTypeString → Task 2
  - ColumnMeta.type populated → Task 2
  - MySqlSink.ensureTargetTable → Task 3
  - SyncTask integration → Task 4
  - dev.md update → Task 5
- [ ] **No placeholders:** every step shows concrete code; pool acquire/release signatures are illustrative and adapted during implementation.
- [ ] **Type consistency:** ColumnMeta.type, schema_ddl.DdlOptions, MySqlSink.ensureTargetTable signatures consistent across tasks.