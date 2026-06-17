# zetl V3 binlog CDC Phase 2b 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3
- **前置版本**：Phase 2（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

把 binlog 行事件中的常用列类型从占位符 `"TODO"` 解码为可读字符串，方便下游 transform / sink 直接消费：

| MySQL 类型 | 类型常量 | 输出格式 |
|---|---|---|
| DATETIME | `MYSQL_TYPE_DATETIME = 0x0c` | `"YYYY-MM-DD HH:MM:SS"` |
| DATETIME(fsp) | `MYSQL_TYPE_DATETIME2 = 0x12` | `"YYYY-MM-DD HH:MM:SS.ffffff"` |
| DECIMAL | `MYSQL_TYPE_NEWDECIMAL = 0xf6` | 十进制字符串，保留精度和符号 |
| BLOB | `MYSQL_TYPE_BLOB = 0xfc` | UTF-8 文本（binary collation 时返回 hex） |
| TEXT | `MYSQL_TYPE_BLOB = 0xfc`（field 元数据含 pack_length） | UTF-8 文本 |
| JSON | `MYSQL_TYPE_JSON = 0x5f` | 原 JSON 字符串 |
| VARCHAR > 255 | `MYSQL_TYPE_VARCHAR = 0x0f` | UTF-8 文本（2 字节长度编码） |

本轮 **不** 处理 `DATE`、`TIME`、`TIMESTAMP`、`FLOAT`、`DOUBLE`、`BIT`、`ENUM`、`SET`、`GEOMETRY`、`YEAR`、`NULL bitmap 之外的类型`。

---

## 1. 不在本轮范围

- 修改 transform.engine 或 MySqlSink 行为（输出统一是字符串，已兼容）。
- 字符集（charset）解码：仅假设 UTF-8；如果源库使用 latin1，仍以原始字节呈现，下游按需转换。
- DECIMAL 与 BLOB 的二进制兼容性：仅按常用路径实现；罕见精度（>30 位数字）走 `"TODO"`。
- JSON 语法校验：仅透传 bytes 为字符串。
- VARCHAR > 65535（max_length 上限 65535）。

---

## 2. 架构与修改点

### 2.1 新建 `src/cdc/binlog/decoder.zig`

职责：根据 MySQL 类型常量和列元数据，从 binlog 行 buffer 中解码单个字段值。

核心 API：

```zig
pub fn decodeColumn(
    allocator: std.mem.Allocator,
    col_type: u8,
    metadata: []const u8,
    body: []const u8,
    pos: *usize,
) DecodeError![]const u8;
```

实现细节：

- **整数类型**（`0x01` TINY、`0x02` SHORT、`0x03` LONG、`0x08` LONGLONG、`0x09` INT24）：从 `metadata = []` 切出对应字节数并格式化为十进制字符串。
- **VARCHAR ≤ 255**（`0x0f`）：1 字节长度 + N 字节内容。
- **VARCHAR > 255**（`0x0f` 且 metadata[0] | (metadata[1] << 8) > 255）：2 字节小端长度 + N 字节内容。
- **DATETIME**（`0x0c`）：读 8 字节小端整数，解析为 `YYYY-MM-DD HH:MM:SS`。
- **DATETIME2**（`0x12`）：读 5 字节整数部分（高 5 字节）+ fsp 字节（metadata[0] 给位数）。
- **NEWDECIMAL**（`0xf6`）：按 metadata[0] = precision、metadata[1] = scale 解析 packed decimal bytes，输出带符号的十进制字符串。
- **BLOB / TEXT**（`0xfc` / `0xfd`）：根据 metadata[0] = pack_length 决定长度字段字节数（1/2/3/4），读取 length + content。
- **JSON**（`0x5f`）：复用 BLOB 的长度编码路径，内容按 UTF-8 字符串透传。

未实现类型：保留 `"TODO"` 字符串，但不推进 `pos`，等待后续扩展。

### 2.2 修改 `src/cdc/binlog/parser.zig`

#### 2.2.1 `TableMap` 增加元数据切分方法

```zig
const TableMap = struct {
    table_id: u64,
    database: []const u8,
    table: []const u8,
    column_types: []const u8,
    column_metadata: []const u8,
    null_bitmap: []const u8,

    pub fn metadataLengthForType(col_type: u8) usize { ... }

    pub fn metadataForColumn(self: TableMap, col_idx: usize) []const u8 { ... }
};
```

`metadataForColumn` 通过对前 `col_idx` 列调用 `metadataLengthForType` 累加偏移切出该列的元数据。

#### 2.2.2 `readColumnValue` 变薄封装

```zig
fn readColumnValue(
    self: *Parser,
    tm: TableMap,
    col_idx: usize,
    body: []const u8,
    pos: *usize,
) ParseError![]const u8 {
    const col_type = tm.column_types[col_idx];
    const meta = tm.metadataForColumn(col_idx);
    return decoder.decodeColumn(self.allocator, col_type, meta, body, pos);
}
```

#### 2.2.3 `readRowInto` 调用点

`readRowInto` 接收 `tm` 已经存在，循环里改为：

```zig
const value = try self.readColumnValue(tm, col_idx, body, pos);
```

### 2.3 不需要修改

- `src/cdc/event.zig`：`RowEvent.fields` 已是 `StringHashMap([]const u8)`。
- `src/engine/runtime.zig`：上游传入字符串，对下游透明。

---

## 3. 数据流示例

`order_info` 表结构（binlog 行）：

```sql
CREATE TABLE order_info (
    id INT PRIMARY KEY,
    paid_at DATETIME(6),
    amount DECIMAL(18,4),
    note TEXT,
    extra JSON
);
```

TABLE_MAP_EVENT:

- `column_types`: `[0x03, 0x12, 0xf6, 0xfc, 0x5f]`
- `column_metadata`: `[<0 字节给 LONG>, 0x06, 0x12 0x04, 0x04, 0x04]`

行数据：

```zig
[id=42, paid_at="2026-06-15 12:34:56.123456", amount="99.5000", note="hello", extra='{"k":1}']
```

解析后 `RowEvent.fields`：

```
c0 -> "42"
c1 -> "2026-06-15 12:34:56.123456"
c2 -> "99.5000"
c3 -> "hello"
c4 -> "{\"k\":1}"
```

---

## 4. 测试策略

### 4.1 decoder.zig 单元测试

| 测试名 | 覆盖 |
|---|---|
| `decodeTINY` | `0x01` 正/负 |
| `decodeSHORT` | `0x02` |
| `decodeLONG` | `0x03` |
| `decodeLONGLONG` | `0x08` |
| `decodeINT24` | `0x09` |
| `decodeVarcharShort` | `0x0f` metadata ≤ 255 |
| `decodeVarcharLong` | `0x0f` metadata > 255 |
| `decodeDatetime` | `0x0c` |
| `decodeDatetime2` | `0x12` fsp=6 |
| `decodeDecimal` | `0xf6` 正负 + 精度 |
| `decodeBlob` | `0xfc` 多种 pack_length |
| `decodeJson` | `0x5f` |
| `decodeUnsupportedReturnsTODO` | 占位符 |

### 4.2 parser.zig 集成测试

- `test "Parser parses WRITE_ROWS_V2 with DATETIME/DECIMAL/BLOB/JSON"`：
  - 构造对应 TABLE_MAP + WRITE_ROWS，验证 `RowEvent.fields` 中各字段值为可读字符串。

### 4.3 错误路径

- `decodeColumn` 在 buffer 不足时返回 `error.BufferTooShort`。
- 未实现类型仍返回 `"TODO"`，但 `pos` 不动，避免破坏后续字节对齐。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| `metadataLengthForType` 切分错位 | 每种类型有明确常量表；测试覆盖每种类型；切分失败返回 `error.InvalidEvent` |
| DECIMAL packed 格式复杂 | 严格按 MySQL 源码实现 9 字节 digit group + 字节内高低位；不支持 >30 位精度，溢出返回 `"TODO"` |
| DATETIME2 的 fsp 字节解析错 | 严格按 MySQL 5.6+ 规范；fsp ∈ [0,6] |
| JSON 内容含二进制 | 直接透传 bytes 为字符串，不做 JSON 语法校验 |
| VARCHAR max_length 边界（=255） | 长度编码仅当 `>255` 时用 2 字节，与 MySQL 行为一致 |

---

## 6. 后续扩展

- Phase 2c：补充 DATE / TIME / TIMESTAMP / FLOAT / DOUBLE / BIT / ENUM / SET。
- Phase 2d：字符集（charset）解码（GBK / GB18030 / latin1 → UTF-8）。
- Phase 3：JSON 解析与 transform.engine 对 JSON 的内置支持。