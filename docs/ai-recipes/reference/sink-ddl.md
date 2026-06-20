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

## 已知限制解除 (Phase 7b, 待实现)

- 从 `SHOW COLUMNS FROM source.table` 解析长度 / precision / scale.
- 兜底: 如果自动 DDL 报错, 用 `TEXT` 兜底重试.

## 幂等性

- `CREATE TABLE IF NOT EXISTS` 是幂等的, 已存在的表**不会**被改 schema.
- 想强制重置: `DROP TABLE union_all_order;` 后重启 zetl.

详见 `dev.md` Phase 7 section.
