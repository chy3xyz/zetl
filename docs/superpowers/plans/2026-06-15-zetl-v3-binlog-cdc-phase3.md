# zetl V3 binlog CDC Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `decoder.zig` with the remaining common MySQL column types — DATE, YEAR, TIMESTAMP, TIMESTAMP2, TIME, TIME2, FLOAT, DOUBLE — each emitting a human-readable string instead of `error.UnsupportedType`.

**Architecture:** Add per-type decoder functions in `src/cdc/binlog/decoder.zig`, grouped by semantic category (calendar / clock / float). Each type gets a dedicated unit test plus a shared parser integration test that constructs a TABLE_MAP + WRITE_ROWS_V2 with all six new column types.

**Tech Stack:** Zig (0.17 nightly), built-in `zig test`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/cdc/binlog/decoder.zig` | Per-type column value decoding | Add `decodeDate`, `decodeYear`, `decodeTimestamp`, `decodeTimestamp2`, `decodeTime`, `decodeTime2`, `decodeFloat`, `decodeDouble`; extend `decodeColumn` switch |
| `src/cdc/binlog/parser.zig` | Binlog event parsing | Add integration test exercising the new types end-to-end |

---

## Task 1: DATE (0x0a) and YEAR (0x0d) decoding

**Files:**
- Modify: `src/cdc/binlog/decoder.zig`
- Test: `src/cdc/binlog/decoder.zig`

- [ ] **Step 1: Add failing tests**

Append to `src/cdc/binlog/decoder.zig`:

```zig
test "decodeColumn for DATE reads 3-byte packed date" {
    var pos: usize = 0;
    // 2026-06-15 in MySQL DATE wire format:
    // val = (year << 9) | (month << 5) | day
    const val: u32 = (2026 << 9) | (6 << 5) | 15;
    var buf: [3]u8 = undefined;
    buf[0] = @intCast((val >> 16) & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast(val & 0xff);
    const out = try decodeColumn(std.testing.allocator, 0x0a, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15", out);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "decodeColumn for YEAR reads 1-byte year" {
    var pos: usize = 0;
    const buf = [_]u8{122}; // 122 + 1900 = 2022
    const out = try decodeColumn(std.testing.allocator, 0x0d, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2022", out);
    try std.testing.expectEqual(@as(usize, 1), pos);
}
```

- [ ] **Step 2: Run the new tests and confirm they fail**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig test src/cdc/binlog/decoder.zig
```

Expected: FAIL because `decodeColumn` returns `error.UnsupportedType` for `0x0a` and `0x0d`.

- [ ] **Step 3: Implement `decodeDate` and `decodeYear`**

Add to `src/cdc/binlog/decoder.zig`:

```zig
fn decodeDate(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 3) return error.BufferTooShort;
    const v: u32 = (@as(u32, body[pos.*]) << 16) |
        (@as(u32, body[pos.* + 1]) << 8) |
        @as(u32, body[pos.* + 2]);
    pos.* += 3;
    const year: u32 = v >> 9;
    const month: u32 = (v >> 5) & 0x0f;
    const day: u32 = v & 0x1f;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch return error.OutOfMemory;
}

fn decodeYear(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 1) return error.BufferTooShort;
    const v = body[pos.*];
    pos.* += 1;
    const year: u32 = 1900 + v;
    return std.fmt.allocPrint(allocator, "{d}", .{year}) catch return error.OutOfMemory;
}
```

Add the dispatch arm to `decodeColumn`:

```zig
0x0a => decodeDate(allocator, body, pos),
0x0d => decodeYear(allocator, body, pos),
```

- [ ] **Step 4: Run tests to verify the new tests pass**

```bash
zig test src/cdc/binlog/decoder.zig
```

Expected: PASS for both new tests, all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/cdc/binlog/decoder.zig
git commit -m "feat(cdc/decoder): implement DATE and YEAR decoding"
```

---

## Task 2: TIMESTAMP (0x07) and TIMESTAMP2 (0x11) decoding

**Files:**
- Modify: `src/cdc/binlog/decoder.zig`
- Test: `src/cdc/binlog/decoder.zig`

- [ ] **Step 1: Add failing tests**

```zig
test "decodeColumn for TIMESTAMP reads 4-byte Unix epoch" {
    var pos: usize = 0;
    // 2026-06-15 12:34:56 UTC -> 1781349296
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 1781349296, .big);
    const out = try decodeColumn(std.testing.allocator, 0x07, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56", out);
    try std.testing.expectEqual(@as(usize, 4), pos);
}

test "decodeColumn for TIMESTAMP2(6) reads 5-byte packed datetime with microseconds" {
    var pos: usize = 0;
    // 2026-06-15 12:34:56.123456 in MySQL TIMESTAMP2 wire format:
    // packed = (year*13+month) << 17 | (day << 12) | ... (h<<12)|(m<<6)|s
    const ymd: u64 = (2026 * 13 + 6) * 32 + 15;
    const hms: u64 = (12 << 12) | (34 << 6) | 56;
    const packed: u64 = ymd << 17 | hms;
    var buf: [8]u8 = undefined;
    buf[0] = @intCast((packed >> 32) & 0xff);
    buf[1] = @intCast((packed >> 24) & 0xff);
    buf[2] = @intCast((packed >> 16) & 0xff);
    buf[3] = @intCast((packed >> 8) & 0xff);
    buf[4] = @intCast(packed & 0xff);
    buf[5] = 0x01; // microseconds high
    buf[6] = 0xe2;
    buf[7] = 0x40;
    const meta = [_]u8{6};
    const out = try decodeColumn(std.testing.allocator, 0x11, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56.123456", out);
    try std.testing.expectEqual(@as(usize, 8), pos);
}
```

- [ ] **Step 2: Run the new tests and confirm they fail**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig test src/cdc/binlog/decoder.zig
```

Expected: FAIL with `error.UnsupportedType`.

- [ ] **Step 3: Implement `decodeTimestamp` and `decodeTimestamp2`**

Add to `src/cdc/binlog/decoder.zig`:

```zig
const SECONDS_PER_DAY: i64 = 86400;

// Howard Hinnant's date algorithm: days_from_civil / civil_from_days.
// Computes days since 1970-01-01 from a (year, month, day) triple.
// Reference: http://howardhinnant.github.io/date_algorithms.html
fn daysFromCivil(y: i64, m: u32, d: u32) i64 {
    const y_adj = if (m <= 2) y - 1 else y;
    const era: i64 = if (y_adj >= 0) @divFloor(y_adj, 400) else -@divFloor(-y_adj - 399, 400);
    const yoe: i64 = y_adj - era * 400;
    const m_adj: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * m_adj + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// Inverse of daysFromCivil: returns (year, month, day) for a given days-since-Unix-epoch.
fn civilFromDays(z: i64) struct { y: i64, m: u32, d: u32 } {
    const z_adj = z + 719468;
    const era: i64 = if (z_adj >= 0) @divFloor(z_adj, 146097) else -@divFloor(-z_adj - 146096, 146097);
    const doe: i64 = z_adj - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe + 1524, 1461), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year: i64 = if (m <= 2) y + 1 else y;
    return .{ .y = year, .m = m, .d = d };
}

fn decodeTimestamp(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 4) return error.BufferTooShort;
    const v = std.mem.readInt(u32, body[pos.*..][0..4], .big);
    pos.* += 4;
    const secs: i64 = @intCast(v);
    return formatUnix(allocator, secs, 0);
}

fn decodeTimestamp2(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 1) return error.InvalidValue;
    const fsp: u8 = metadata[0];
    if (fsp > 6) return error.InvalidValue;
    const frac_bytes: usize = @intCast(@divFloor(fsp + 1, 2));
    if (body.len < pos.* + 5 + frac_bytes) return error.BufferTooShort;

    var packed: u64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        packed = (packed << 8) | body[pos.* + i];
    }
    pos.* += 5;

    const ymd: u64 = packed >> 17;
    const ym: u64 = ymd >> 5;
    const year: i64 = @intCast(ym / 13);
    const month: u32 = @intCast(ym % 13);
    const day: u32 = @intCast(ymd & 0x1f);
    const hms: u64 = packed & ((@as(u64, 1) << 17) - 1);
    const hour: u32 = @intCast(hms >> 12);
    const minute: u32 = @intCast((hms >> 6) & 0x3f);
    const second: u32 = @intCast(hms & 0x3f);

    var frac_int: u64 = 0;
    i = 0;
    while (i < frac_bytes) : (i += 1) {
        frac_int = (frac_int << 8) | body[pos.* + i];
    }
    pos.* += frac_bytes;
    const shift: u6 = @intCast((3 - frac_bytes) * 8);
    const microseconds: u64 = frac_int << shift;

    // Compute Unix epoch seconds from civil (y, m, d, h, m, s).
    const days = daysFromCivil(year, month, day);
    const secs: i64 = days * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second;

    if (fsp == 0) {
        return formatUnix(allocator, secs, 0);
    }
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}",
        .{ year, month, day, hour, minute, second, microseconds },
    ) catch return error.OutOfMemory;
}

fn formatUnix(allocator: std.mem.Allocator, secs: i64, microseconds: u64) DecodeError![]const u8 {
    const days: i64 = @divFloor(secs, SECONDS_PER_DAY);
    const secs_of_day: i64 = @rem(secs, SECONDS_PER_DAY);
    const civil = civilFromDays(days);
    const hh: u32 = @intCast(@divFloor(secs_of_day, 3600));
    const mm: u32 = @intCast(@divFloor(@rem(secs_of_day, 3600), 60));
    const ss: u32 = @intCast(@rem(secs_of_day, 60));
    if (microseconds == 0) {
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
            .{ civil.y, civil.m, civil.d, hh, mm, ss },
        ) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}",
        .{ civil.y, civil.m, civil.d, hh, mm, ss, microseconds },
    ) catch return error.OutOfMemory;
}
```

Add the dispatch arms:

```zig
0x07 => decodeTimestamp(allocator, body, pos),
0x11 => decodeTimestamp2(allocator, metadata, body, pos),
```

- [ ] **Step 4: Run tests**

```bash
zig test src/cdc/binlog/decoder.zig
```

Expected: 19/19 tests pass (17 existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add src/cdc/binlog/decoder.zig
git commit -m "feat(cdc/decoder): implement TIMESTAMP and TIMESTAMP2 decoding"
```

---

## Task 3: TIME (0x0b) and TIME2 (0x13) decoding

**Files:**
- Modify: `src/cdc/binlog/decoder.zig`
- Test: `src/cdc/binlog/decoder.zig`

- [ ] **Step 1: Add failing tests**

```zig
test "decodeColumn for TIME reads 3-byte packed duration" {
    var pos: usize = 0;
    // 12:34:56 -> 0x12 bf f0
    // packed = (hour << 12) | (minute << 6) | second
    const val: u32 = (12 << 12) | (34 << 6) | 56;
    var buf: [3]u8 = undefined;
    buf[0] = @intCast((val >> 16) & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast(val & 0xff);
    const out = try decodeColumn(std.testing.allocator, 0x0b, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("12:34:56", out);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "decodeColumn for TIME2(6) reads 3+3-byte packed duration with microseconds" {
    var pos: usize = 0;
    // 12:34:56.123456
    const val: u32 = (12 << 12) | (34 << 6) | 56;
    var buf: [6]u8 = undefined;
    buf[0] = @intCast((val >> 16) & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast(val & 0xff);
    buf[3] = 0x01; // microseconds high
    buf[4] = 0xe2;
    buf[5] = 0x40;
    const meta = [_]u8{6};
    const out = try decodeColumn(std.testing.allocator, 0x13, &meta, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("12:34:56.123456", out);
    try std.testing.expectEqual(@as(usize, 6), pos);
}
```

- [ ] **Step 2: Run and confirm fail**

```bash
zig test src/cdc/binlog/decoder.zig
```

Expected: FAIL with `error.UnsupportedType`.

- [ ] **Step 3: Implement `decodeTime` and `decodeTime2`**

```zig
fn decodeTime(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 3) return error.BufferTooShort;
    const raw: u32 = (@as(u32, body[pos.*]) << 16) |
        (@as(u32, body[pos.* + 1]) << 8) |
        @as(u32, body[pos.* + 2]);
    pos.* += 3;
    // bit 23 = sign bit
    const is_negative = (raw & 0x800000) != 0;
    const abs: u32 = if (is_negative) ((~raw + 1) & 0x7fffff) else raw;
    const hour: u32 = (abs >> 12) & 0x3ff;
    const minute: u32 = (abs >> 6) & 0x3f;
    const second: u32 = abs & 0x3f;
    if (is_negative) {
        return std.fmt.allocPrint(allocator, "-{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
}

fn decodeTime2(allocator: std.mem.Allocator, metadata: []const u8, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (metadata.len < 1) return error.InvalidValue;
    const fsp: u8 = metadata[0];
    if (fsp > 6) return error.InvalidValue;
    const frac_bytes: usize = @intCast(@divFloor(fsp + 1, 2));
    if (body.len < pos.* + 3 + frac_bytes) return error.BufferTooShort;

    const raw: u32 = (@as(u32, body[pos.*]) << 16) |
        (@as(u32, body[pos.* + 1]) << 8) |
        @as(u32, body[pos.* + 2]);
    pos.* += 3;

    var frac_int: u64 = 0;
    var i: usize = 0;
    while (i < frac_bytes) : (i += 1) {
        frac_int = (frac_int << 8) | body[pos.* + i];
    }
    pos.* += frac_bytes;
    const shift: u6 = @intCast((3 - frac_bytes) * 8);
    const microseconds: u64 = frac_int << shift;

    const is_negative = (raw & 0x800000) != 0;
    const abs: u32 = if (is_negative) ((~raw + 1) & 0x7fffff) else raw;
    const hour: u32 = (abs >> 12) & 0x3ff;
    const minute: u32 = (abs >> 6) & 0x3f;
    const second: u32 = abs & 0x3f;

    if (fsp == 0) {
        if (is_negative) {
            return std.fmt.allocPrint(allocator, "-{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
        }
        return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return error.OutOfMemory;
    }
    if (is_negative) {
        return std.fmt.allocPrint(allocator, "-{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hour, minute, second, microseconds }) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hour, minute, second, microseconds }) catch return error.OutOfMemory;
}
```

Add dispatch arms:

```zig
0x0b => decodeTime(allocator, body, pos),
0x13 => decodeTime2(allocator, metadata, body, pos),
```

- [ ] **Step 4: Run tests**

```bash
zig test src/cdc/binlog/decoder.zig
```

Expected: 21/21 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cdc/binlog/decoder.zig
git commit -m "feat(cdc/decoder): implement TIME and TIME2 decoding"
```

---

## Task 4: FLOAT (0x04) and DOUBLE (0x05) decoding

**Files:**
- Modify: `src/cdc/binlog/decoder.zig`
- Test: `src/cdc/binlog/decoder.zig`

- [ ] **Step 1: Add failing tests**

```zig
test "decodeColumn for FLOAT reads 4-byte IEEE 754" {
    var pos: usize = 0;
    // 1.5 in IEEE 754 single = 0x3fc00000 big-endian
    const buf = [_]u8{ 0x3f, 0xc0, 0x00, 0x00 };
    const out = try decodeColumn(std.testing.allocator, 0x04, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1.5e0", out);
    try std.testing.expectEqual(@as(usize, 4), pos);
}

test "decodeColumn for DOUBLE reads 8-byte IEEE 754" {
    var pos: usize = 0;
    // 1.0 in IEEE 754 double = 0x3ff0000000000000 big-endian
    const buf = [_]u8{ 0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const out = try decodeColumn(std.testing.allocator, 0x05, &.{}, &buf, &pos);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1.0e0", out);
    try std.testing.expectEqual(@as(usize, 8), pos);
}
```

- [ ] **Step 2: Run and confirm fail**

```bash
zig test src/cdc/binlog/decoder.zig
```

Expected: FAIL.

- [ ] **Step 3: Implement `decodeFloat` and `decodeDouble`**

```zig
fn decodeFloat(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 4) return error.BufferTooShort;
    const raw = std.mem.readInt(u32, body[pos.*..][0..4], .big);
    pos.* += 4;
    const f: f32 = @bitCast(raw);
    return std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory;
}

fn decodeDouble(allocator: std.mem.Allocator, body: []const u8, pos: *usize) DecodeError![]const u8 {
    if (body.len < pos.* + 8) return error.BufferTooShort;
    const raw = std.mem.readInt(u64, body[pos.*..][0..8], .big);
    pos.* += 8;
    const f: f64 = @bitCast(raw);
    return std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory;
}
```

Add dispatch arms:

```zig
0x04 => decodeFloat(allocator, body, pos),
0x05 => decodeDouble(allocator, body, pos),
```

- [ ] **Step 4: Run tests**

```bash
zig test src/cdc/binlog/decoder.zig
```

Expected: 23/23 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cdc/binlog/decoder.zig
git commit -m "feat(cdc/decoder): implement FLOAT and DOUBLE decoding"
```

---

## Task 5: parser integration test

**Files:**
- Modify: `src/cdc/binlog/parser.zig`
- Test: `src/cdc/binlog/parser.zig`

- [ ] **Step 1: Add the integration test**

Append to `src/cdc/binlog/parser.zig`:

```zig
test "Parser parses WRITE_ROWS_V2 with DATE/YEAR/TIME/TIMESTAMP/FLOAT/DOUBLE columns" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 6 cols [DATE(0x0a), YEAR(0x0d), TIME(0x0b), TIMESTAMP(0x07), FLOAT(0x04), DOUBLE(0x05)]
    var tm_buf: [80]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    var tpos: usize = 19;
    std.mem.writeInt(u48, tm_buf[tpos..][0..6], 0x42, .little);
    tpos += 6;
    tm_buf[tpos] = 2; tpos += 1;
    @memcpy(tm_buf[tpos..][0..2], "db"); tpos += 2;
    tm_buf[tpos] = 0; tpos += 1;
    tm_buf[tpos] = 1; tpos += 1;
    @memcpy(tm_buf[tpos..][0..1], "t"); tpos += 1;
    tm_buf[tpos] = 0; tpos += 1;
    tm_buf[tpos] = 6; tpos += 1; // col_count
    tm_buf[tpos] = 0x0a; tpos += 1; // DATE
    tm_buf[tpos] = 0x0d; tpos += 1; // YEAR
    tm_buf[tpos] = 0x0b; tpos += 1; // TIME
    tm_buf[tpos] = 0x07; tpos += 1; // TIMESTAMP
    tm_buf[tpos] = 0x04; tpos += 1; // FLOAT
    tm_buf[tpos] = 0x05; tpos += 1; // DOUBLE
    tm_buf[tpos] = 0; tpos += 1; // meta_len (0: no metadata)
    tm_buf[tpos] = 0; tpos += 1; // null_bitmap byte
    std.mem.writeInt(u32, tm_buf[9..13], @intCast(tpos + 4), .little); // +4 for CRC
    _ = try p.processEvent(&tm_buf);

    // WRITE_ROWS_V2
    // post-header(10) + col_count(1) + used_bitmap(1) + num_rows(1) + null_bitmap(1) =
    //   14 bytes prefix
    // DATE(3) + YEAR(1) + TIME(3) + TIMESTAMP(4) + FLOAT(4) + DOUBLE(8) = 23 bytes values
    // event_size = 19 + 14 + 23 + 4 (CRC) = 60
    var wr_buf: [80]u8 = undefined;
    @memset(&wr_buf, 0);
    std.mem.writeInt(u32, wr_buf[0..4], 0, .little);
    wr_buf[4] = 0x1e; // WRITE_ROWS_V2
    std.mem.writeInt(u32, wr_buf[5..9], 1, .little);
    std.mem.writeInt(u32, wr_buf[9..13], 60, .little);
    std.mem.writeInt(u32, wr_buf[13..17], 0, .little);
    std.mem.writeInt(u16, wr_buf[17..19], 0, .little);
    std.mem.writeInt(u48, wr_buf[19..25], 0x42, .little);
    wr_buf[29] = 6; // col_count
    wr_buf[30] = 0x3f; // used_bitmap: cols 0..5 used
    wr_buf[31] = 1; // num_rows
    wr_buf[32] = 0x00; // null_bitmap
    // DATE: 2026-06-15 -> bytes (2026<<9)|(6<<5)|15 = 0x4ad1a0
    const date_val: u32 = (2026 << 9) | (6 << 5) | 15;
    wr_buf[33] = @intCast((date_val >> 16) & 0xff);
    wr_buf[34] = @intCast((date_val >> 8) & 0xff);
    wr_buf[35] = @intCast(date_val & 0xff);
    // YEAR: 126 -> 2026
    wr_buf[36] = 126;
    // TIME: 12:34:56 -> (12<<12)|(34<<6)|56 = 0x12bff0
    const time_val: u32 = (12 << 12) | (34 << 6) | 56;
    wr_buf[37] = @intCast((time_val >> 16) & 0xff);
    wr_buf[38] = @intCast((time_val >> 8) & 0xff);
    wr_buf[39] = @intCast(time_val & 0xff);
    // TIMESTAMP: 2026-06-15 12:34:56 UTC -> 1781349296
    std.mem.writeInt(u32, wr_buf[40..44], 1781349296, .big);
    // FLOAT: 1.5 = 0x3fc00000 big-endian
    @memcpy(wr_buf[44..48], "\x3f\xc0\x00\x00");
    // DOUBLE: 1.0 = 0x3ff0000000000000 big-endian
    @memcpy(wr_buf[48..56], "\x3f\xf0\x00\x00\x00\x00\x00\x00");

    var ev = try p.processEvent(&wr_buf);
    defer freeRowEvents(a, ev.row);

    try std.testing.expect(ev == .row);
    const row = &ev.row[0];
    try std.testing.expectEqualStrings("2026-06-15", row.getField("c0").?);
    try std.testing.expectEqualStrings("2026", row.getField("c1").?);
    try std.testing.expectEqualStrings("12:34:56", row.getField("c2").?);
    try std.testing.expectEqualStrings("2026-06-15 12:34:56", row.getField("c3").?);
    try std.testing.expectEqualStrings("1.5e0", row.getField("c4").?);
    try std.testing.expectEqualStrings("1.0e0", row.getField("c5").?);
}
```

- [ ] **Step 2: Run the test**

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/cdc/binlog/parser.zig
git commit -m "test(cdc/binlog): add integration test for DATE/YEAR/TIME/TIMESTAMP/FLOAT/DOUBLE"
```

---

## Task 6: Update dev.md and final verification

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Update `dev.md`**

In `dev.md`, update the line about supported column types to reflect Phase 3:

> "已支持 DATETIME / DATETIME2 / NEWDECIMAL / BLOB / TEXT / JSON / VARCHAR / DATE / YEAR / TIME / TIME2 / TIMESTAMP / TIMESTAMP2 / FLOAT / DOUBLE. 不支持 BIT / ENUM / SET / GEOMETRY, 这些列返回 `error.UnsupportedType`."

(Adjust wording to match existing `dev.md` style.)

- [ ] **Step 2: Run final verification**

```bash
zig fmt --check src/cdc/binlog/decoder.zig src/cdc/binlog/parser.zig
zig build test
```

Expected: formatting OK, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add dev.md
git commit -m "docs: update dev.md binlog column-type support list (Phase 3)"
```

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - DATE → Task 1
  - YEAR → Task 1
  - TIMESTAMP → Task 2
  - TIMESTAMP2 → Task 2
  - TIME → Task 3
  - TIME2 → Task 3
  - FLOAT → Task 4
  - DOUBLE → Task 4
  - parser integration test → Task 5
  - dev.md update → Task 6
- [ ] **No placeholders:** every step shows code, commands, expected outputs.
- [ ] **Type consistency:** `decodeColumn` switch arms consistent; helper functions use `DecodeError![]const u8` matching existing decoder functions.