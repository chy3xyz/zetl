# Sink 自动建表 (`ensureTargetTable`)

## 行为

Phase 7 起, `SyncTask.init` 在写数据前会自动调用 `MySqlSink.ensureTargetTable`, 用 `CREATE TABLE IF NOT EXISTS db.target_table (...)` 创建目标表.

## 类型映射 (源 → MySQL DDL)

| zetl 列类型 | MySQL DDL 类型 |
|------------|----------------|
| INT / TINY / SHORT | `INT` / `TINYINT` / `SMALLINT` |
| LONGLONG | `BIGINT` |
| FLOAT / DOUBLE | `FLOAT` / `DOUBLE` |
| DECIMAL | `DECIMAL(10,2)` (默认, 见限制) |
| DATETIME / TIMESTAMP | `DATETIME` |
| DATE | `DATE` |
| TIME | `TIME` |
| YEAR | `YEAR` |
| VARCHAR | `VARCHAR(255)` (默认) |
| CHAR | `CHAR(1)` (默认) |
| TEXT / BLOB | `TEXT` / `BLOB` |
| JSON | `JSON` |
| 其他 | `TEXT` (兜底) |

## 默认值

```sql
ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
```

## 已知限制 (Phase 7)

- VARCHAR / CHAR 长度用默认值 (255 / 1), 不能从源 metadata 推断.
- DECIMAL precision/scale 用默认值 (10, 2).
- 不支持 BIT / ENUM / SET / GEOMETRY (Phase 3 未实现).

## Phase 7b: 自动 precision (Phase 10 起已实现)

`buildCreateTable` 现在从 `ColumnMeta.length` / `.precision` / `.scale` 生成精确 DDL:

- `VARCHAR(N)` 保留源长度 (不再强制 255)
- `DECIMAL(P,S)` 保留源 precision/scale (不再强制 18,4)
- `CHAR(N)` 保留源长度
- 没有 length/precision 的类型仍走默认 (255 / 18,4)

详见 [dev.md](../../../dev.md) Phase 10 section.

## 幂等性

- `CREATE TABLE IF NOT EXISTS` 是幂等的, 已存在的表**不会**被改 schema.
- 想强制重置: `DROP TABLE union_all_order;` 后重启 zetl.

详见 `dev.md` Phase 7 section.
