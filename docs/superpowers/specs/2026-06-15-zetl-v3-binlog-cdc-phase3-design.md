# zetl V3 binlog CDC Phase 3 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3
- **前置版本**：Phase 2b（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

扩展 `src/cdc/binlog/decoder.zig` 的 `decodeColumn` 分发，让剩余的常用标量类型输出可读字符串：

| MySQL 类型 | 类型常量 | 输出格式 |
|---|---|---|
| DATE | `MYSQL_TYPE_DATE = 0x0a` | `"YYYY-MM-DD"` |
| YEAR | `MYSQL_TYPE_YEAR = 0x0d` | `"2026"`（4 位） |
| TIMESTAMP | `MYSQL_TYPE_TIMESTAMP = 0x07` | `"YYYY-MM-DD HH:MM:SS"` |
| TIMESTAMP2 | `MYSQL_TYPE_TIMESTAMP2 = 0x11` | `"YYYY-MM-DD HH:MM:SS[.ffffff]"` |
| TIME | `MYSQL_TYPE_TIME = 0x0b` | `"HH:MM:SS"` |
| TIME2 | `MYSQL_TYPE_TIME2 = 0x13` | `"HH:MM:SS[.ffffff]"` |
| FLOAT | `MYSQL_TYPE_FLOAT = 0x04` | `"{d}"`（保精度） |
| DOUBLE | `MYSQL_TYPE_DOUBLE = 0x05` | `"{d}"`（保精度） |

---

## 1. 不在本轮范围

- `BIT / ENUM / SET / GEOMETRY / CHAR` 留给 Phase 4。
- charset 解码（latin1 → UTF-8）留给 Phase 4。
- DDL（QUERY_EVENT）解析。
- GTID 位点、多任务共享 binlog 连接。
- 字符集协商。

---

## 2. 架构与修改点

### 2.1 时间日期类型解码

#### 2.1.1 DATE (0x0a)

读 3 字节大端整数：
- `year = val >> 9`（15 位，0..9999）
- `month = (val >> 5) & 0x0f`（4 位，1..12）
- `day = val & 0x1f`（5 位，1..31）

输出 `"YYYY-MM-DD"`。允许 `0000-00-00`（MySQL 零日期）。

#### 2.1.2 YEAR (0x0d)

读 1 字节：
- `0x00` → `"0000"`
- `0x01`..`0x99` → `"2001"`..`"2099"`
- `0x9a`..`0xff` → `"1990"`..`"1999"`

或者直接 `1900 + val`。输出 4 位字符串。

#### 2.1.3 TIMESTAMP (0x07)

读 4 字节大端 `i64` Unix 时间戳，转为 UTC 时间字符串。

#### 2.1.4 TIMESTAMP2 (0x11)

参考 DATETIME2 的 5 字节 packed 布局（`year*13+month` 公式 + hms 17 位）。EPOCH 是 1970-01-01 00:00:01 UTC（MySQL TIMESTAMP 范围 1970-01-01 00:00:01 .. 2038-01-19 03:14:07 UTC）。fsp 字节处理与 DATETIME2 一致。

#### 2.1.5 TIME (0x0b)

读 3 字节大端 `i24`：
- 符号：`(val >> 23) & 1`；负数时整个 24 位取反 + 1
- `hour = (val >> 12) & 0x3ff`（10 位）
- `minute = (val >> 6) & 0x3f`（6 位）
- `second = val & 0x3f`（6 位）

输出 `"[-]HH:MM:SS"`。

#### 2.1.6 TIME2 (0x13)

读 3 字节大端 hms（同 TIME）+ fsp 字节，组合为 `"[-]HH:MM:SS[.ffffff]"`。

### 2.2 浮点类型解码

#### 2.2.1 FLOAT (0x04)

读 4 字节 big-endian，转 `f32`：

```zig
const v = std.mem.readInt(u32, body[pos..][0..4], .big);
const f: f32 = @bitCast(v);
return std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory;
```

#### 2.2.2 DOUBLE (0x05)

读 8 字节 big-endian，转 `f64`：

```zig
const v = std.mem.readInt(u64, body[pos..][0..8], .big);
const f: f64 = @bitCast(v);
return std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory;
```

Zig `std.fmt` 默认支持 `{d}` 输出 `nan` / `inf`，无需特殊处理。

### 2.3 `metadataLengthForType`

已正确覆盖（0x07/0x0a/0x0b/0x0d/0x04/0x05 → 0；0x11/0x13 → 1），无需修改。

### 2.4 `decodeColumn` 分发扩展

```zig
0x0a, 0x0d => decodeDateOrYear(col_type, body, pos),
0x07 => decodeTimestamp(body, pos),
0x11 => decodeTimestamp2(metadata, body, pos),
0x0b => decodeTime(body, pos),
0x13 => decodeTime2(metadata, body, pos),
0x04 => decodeFloat(body, pos),
0x05 => decodeDouble(body, pos),
```

> DATE 和 YEAR 共享一个 `decodeDateOrYear` 分发函数（参数化输出格式）；其它每个类型单独函数。

---

## 3. 数据流示例

`events` 表结构（binlog 行）：

```sql
CREATE TABLE events (
    d DATE,
    y YEAR,
    t TIME,
    ts TIMESTAMP,
    f FLOAT,
    g DOUBLE
);
```

TABLE_MAP_EVENT:
- `column_types`: `[0x0a, 0x0d, 0x0b, 0x07, 0x04, 0x05]`
- `column_metadata`: `[]`（全 0 字节）

行数据示例：

| col | 输入字节 | 输出字符串 |
|---|---|---|
| DATE | `0x4a d1 a0` | `"2026-06-15"` |
| YEAR | `0x7a` | `"2026"` |
| TIME | `0x12 bf f0` | `"12:34:56"` |
| TIMESTAMP | `0x68 5e c1 c0` | `"2026-06-15 12:34:56"` |
| FLOAT | `0x3f c0 00 00` | `"1.5e0"` |
| DOUBLE | `0x3f f0 00 00 00 00 00 00` | `"1.0e0"` |

---

## 4. 测试策略

### 4.1 decoder.zig 单元测试

每个类型至少一个 happy-path 测试：

| 测试名 | 覆盖 |
|---|---|
| `decodeColumn for DATE` | `0x0a` |
| `decodeColumn for YEAR` | `0x0d` |
| `decodeColumn for TIMESTAMP` | `0x07` |
| `decodeColumn for TIMESTAMP2(6)` | `0x11` 含 fsp |
| `decodeColumn for TIME` | `0x0b` |
| `decodeColumn for TIME2(6)` | `0x13` 含 fsp |
| `decodeColumn for FLOAT` | `0x04` |
| `decodeColumn for DOUBLE` | `0x05` |

### 4.2 parser.zig 集成测试

构造 TABLE_MAP + WRITE_ROWS_V2 含 6 种类型，验证 `RowEvent.fields` 各字段值正确。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| TIMESTAMP 4 字节溢出（2038） | `i64` 计算时间戳 |
| TIME 负值 | 检测符号位后加 `-` 前缀 |
| FLOAT/DOUBLE NaN/Inf | Zig `std.fmt` 默认输出 `"nan"` / `"inf"` |
| DATE/YEAR 零值 | 直接输出 `"0000-00-00"` / `"0000"` |
| TIMESTAMP2 epoch 与 DATETIME2 混淆 | 拆分为独立 `decodeTimestamp2` 函数 |

---

## 6. 后续扩展

- Phase 4：BIT / ENUM / SET / GEOMETRY / CHAR
- Phase 4：charset 解码
- Phase 5：DDL（QUERY_EVENT）
- Phase 6：GTID 位点