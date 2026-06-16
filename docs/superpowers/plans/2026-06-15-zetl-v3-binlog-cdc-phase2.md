# zetl V3 binlog CDC Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the V3 binlog CDC parser to handle UPDATE/DELETE row events, strip binlog CRC32 checksums, and make the MySQL 8 master-status query compatible.

**Architecture:** Keep changes localized to `src/cdc/binlog/parser.zig` for row-event parsing and `src/engine/runtime.zig` for the MySQL 8 status fallback. Reuse the existing `RowEvent` structure and column-decoding logic; no new files are needed.

**Tech Stack:** Zig (0.17 nightly), zfinal MySQL C API wrapper, built-in `zig test`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/cdc/binlog/parser.zig` | Binlog event parsing | Add `readRowInto`, `parseUpdateRows`, `parseDeleteRows`, and checksum stripping in `processEvent` |
| `src/engine/runtime.zig` | SyncTask runtime | Update `queryMasterStatus` to try `SHOW BINARY LOG STATUS` first, then fall back to `SHOW MASTER STATUS`; adjust `processBatch` to honor `ev.op` |

---

## Task 1: Strip binlog CRC32 checksum in parser

**Files:**
- Modify: `src/cdc/binlog/parser.zig:147-166`
- Test: `src/cdc/binlog/parser.zig`

**Context:** MySQL appends a 4-byte CRC32 to most binlog events. The existing code uses `buffer[19..]` as the body, which includes the CRC and corrupts row parsing.

- [ ] **Step 1: Add a failing test for checksum stripping**

Append this test to `src/cdc/binlog/parser.zig` (after the existing WRITE_ROWS_V2 tests):

```zig
test "processEvent strips 4-byte binlog checksum from WRITE_ROWS_V2" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 1 col TINYINT, db="db", tbl="t", body = 17 bytes, event_size = 36.
    var tm_buf: [64]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 36, .little);
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    std.mem.writeInt(u48, tm_buf[19..25], 0x42, .little);
    tm_buf[25] = 2;
    @memcpy(tm_buf[26..][0..2], "db");
    tm_buf[28] = 0;
    tm_buf[29] = 1;
    @memcpy(tm_buf[30..][0..1], "t");
    tm_buf[31] = 0;
    tm_buf[32] = 1;
    tm_buf[33] = 0x01; // TINYINT
    tm_buf[34] = 0;
    tm_buf[35] = 0;
    _ = try p.processEvent(&tm_buf);

    // WRITE_ROWS_V2: 1 row, 1 col = 42. body = 15 bytes, event_size = 34.
    // Append 4 fake CRC bytes -> total buffer length = 38, event_size = 34.
    var wr_buf: [64]u8 = undefined;
    @memset(&wr_buf, 0);
    std.mem.writeInt(u32, wr_buf[0..4], 0, .little);
    wr_buf[4] = 0x1e;
    std.mem.writeInt(u32, wr_buf[5..9], 1, .little);
    std.mem.writeInt(u32, wr_buf[9..13], 34, .little);
    std.mem.writeInt(u32, wr_buf[13..17], 0, .little);
    std.mem.writeInt(u16, wr_buf[17..19], 0, .little);
    std.mem.writeInt(u48, wr_buf[19..25], 0x42, .little);
    wr_buf[29] = 1; // col_count
    wr_buf[30] = 0x01; // used_bitmap
    wr_buf[31] = 1; // num_rows
    wr_buf[32] = 0x00; // null_bitmap
    wr_buf[33] = 42; // value
    // bytes 34..37 are fake CRC (already zeroed)

    var ev = try p.processEvent(&wr_buf);
    defer freeRowEvents(a, ev.row);
    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    try std.testing.expectEqualStrings("42", ev.row[0].getField("c0").?);
}
```

- [ ] **Step 2: Run the new test and confirm it fails**

Run:

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig test src/cdc/binlog/parser.zig --mod zfinal::/Users/n0x/w4_proj/zig_ws/zfinal/zig-out/lib/libzfinal.a -lc -lpthread -lm -lssl -lcrypto -lz
```

> Note: Use the actual build command from the project (`zig build test` if available). The command above is illustrative.

Expected: FAIL with `error.BufferTooShort` or similar, because the parser tries to read into the CRC bytes.

- [ ] **Step 3: Implement checksum stripping**

In `src/cdc/binlog/parser.zig`, modify `processEvent` to compute the body end without the trailing 4 bytes:

```zig
pub fn processEvent(self: *Parser, buffer: []const u8) ParseError!ParsedEvent {
    const header = try parseHeader(buffer);
    const event_type: EventType = @enumFromInt(header.type_code);

    // MySQL appends a 4-byte CRC32 checksum to non-header-only events.
    const body_end = if (header.event_size >= 19 + 4) header.event_size - 4 else header.event_size;
    if (buffer.len < body_end) return error.BufferTooShort;
    const body = buffer[19..body_end];

    return switch (event_type) {
        .rotate => try parseRotate(self.allocator, header, body),
        .heartbeat => ParsedEvent.heartbeat,
        .table_map => try self.processTableMap(body),
        .write_rows_v2 => try self.parseWriteRows(header, body),
        .update_rows_v2 => try self.parseUpdateRows(header, body),
        .delete_rows_v2 => try self.parseDeleteRows(header, body),
        else => ParsedEvent{ .unknown = header },
    };
}
```

- [ ] **Step 4: Run tests to verify the checksum test passes**

Run:

```bash
zig test src/cdc/binlog/parser.zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/cdc/binlog/parser.zig
git commit -m "feat(cdc/binlog): strip 4-byte CRC32 checksum from events"
```

---

## Task 2: Extract reusable row-decoding helper

**Files:**
- Modify: `src/cdc/binlog/parser.zig:182-271`
- Test: `src/cdc/binlog/parser.zig` (existing tests still pass)

**Context:** `parseWriteRows` contains the logic for reading null bitmaps, used columns, and field values. This logic will be reused by UPDATE and DELETE parsers.

- [ ] **Step 1: Extract `readRowInto`**

Add this helper inside the `Parser` struct (after `parseWriteRows`):

```zig
fn readRowInto(
    self: *Parser,
    row: *event_mod.RowEvent,
    tm: TableMap,
    used_columns: []const usize,
    body: []const u8,
    pos: *usize,
) (ParseError || std.mem.Allocator.Error)!void {
    const null_bitmap_len = (used_columns.len + 7) / 8;
    if (body.len < pos.* + null_bitmap_len) return error.BufferTooShort;
    const null_bitmap = body[pos.*..][0..null_bitmap_len];
    pos.* += null_bitmap_len;

    for (used_columns, 0..) |col_idx, used_idx| {
        if (isBitSet(null_bitmap, used_idx)) continue;

        const col_type = tm.column_types[col_idx];
        const value = try readColumnValue(self.allocator, col_type, body, pos);
        const col_name = try std.fmt.allocPrint(self.allocator, "c{d}", .{col_idx});
        errdefer self.allocator.free(col_name);
        try row.fields.put(col_name, value);
    }
}
```

- [ ] **Step 2: Refactor `parseWriteRows` to use `readRowInto`**

Replace the inline row-reading block in `parseWriteRows` with a call to `readRowInto`. The new `parseWriteRows` should look like:

```zig
fn parseWriteRows(self: *Parser, header: EventHeader, body: []const u8) ParseError!ParsedEvent {
    var pos: usize = 0;

    if (body.len < pos + 6) return error.BufferTooShort;
    const table_id = readInt48(body[pos..][0..6]);
    pos += 6;

    if (body.len < pos + 2) return error.BufferTooShort;
    pos += 2; // flags

    if (body.len < pos + 2) return error.BufferTooShort;
    const extra_data_len = std.mem.readInt(u16, body[pos..][0..2], .little);
    pos += 2;

    if (body.len < pos + extra_data_len) return error.BufferTooShort;
    pos += extra_data_len;

    const tm = self.table_maps.get(table_id) orelse return error.UnknownTableId;

    const col_count_p = try readPackedInt(body[pos..]);
    pos += col_count_p.len;
    const col_count: usize = @intCast(col_count_p.value);

    const used_bitmap_len = (col_count + 7) / 8;
    if (body.len < pos + used_bitmap_len) return error.BufferTooShort;
    const used_bitmap = body[pos..][0..used_bitmap_len];
    pos += used_bitmap_len;

    var used_columns = std.ArrayList(usize).empty;
    defer used_columns.deinit(self.allocator);
    for (0..col_count) |i| {
        if (isBitSet(used_bitmap, i)) {
            try used_columns.append(self.allocator, i);
        }
    }

    var rows = std.ArrayList(event_mod.RowEvent).empty;
    errdefer {
        for (rows.items) |*r| r.deinit(self.allocator);
        rows.deinit(self.allocator);
    }

    const num_rows_p = try readPackedInt(body[pos..]);
    pos += num_rows_p.len;
    const num_rows: usize = @intCast(num_rows_p.value);

    for (0..num_rows) |_| {
        var row = event_mod.RowEvent{
            .op = .insert,
            .table = try self.allocator.dupe(u8, tm.table),
            .database = try self.allocator.dupe(u8, tm.database),
            .fields = std.StringHashMap([]const u8).init(self.allocator),
            .timestamp = @as(i64, header.timestamp),
        };
        errdefer row.deinit(self.allocator);
        try self.readRowInto(&row, tm, used_columns.items, body, &pos);
        try rows.append(self.allocator, row);
    }

    return ParsedEvent{ .row = try rows.toOwnedSlice(self.allocator) };
}
```

- [ ] **Step 3: Run existing parser tests**

Run:

```bash
zig test src/cdc/binlog/parser.zig
```

Expected: all existing tests still PASS.

- [ ] **Step 4: Commit**

```bash
git add src/cdc/binlog/parser.zig
git commit -m "refactor(cdc/binlog): extract readRowInto helper for row decoding"
```

---

## Task 3: Implement DELETE_ROWS_EVENT_V2 parsing

**Files:**
- Modify: `src/cdc/binlog/parser.zig`
- Test: `src/cdc/binlog/parser.zig`

- [ ] **Step 1: Add a failing test for DELETE rows**

Append this test:

```zig
test "Parser parses DELETE_ROWS_V2 with before_fields" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 2 cols [TINYINT, VARCHAR], db="db", tbl="t"
    var tm_buf: [80]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 52, .little); // event_size placeholder
    std.mem.writeInt(u32, tm_buf[13..17], 0, .little);
    std.mem.writeInt(u16, tm_buf[17..19], 0, .little);
    var tpos: usize = 19;
    std.mem.writeInt(u48, tm_buf[tpos..][0..6], 0x42, .little);
    tpos += 6;
    tm_buf[tpos] = 2; tpos += 1; // db_len
    @memcpy(tm_buf[tpos..][0..2], "db"); tpos += 2;
    tm_buf[tpos] = 0; tpos += 1;
    tm_buf[tpos] = 1; tpos += 1; // tbl_len
    @memcpy(tm_buf[tpos..][0..1], "t"); tpos += 1;
    tm_buf[tpos] = 0; tpos += 1;
    tm_buf[tpos] = 2; tpos += 1; // col_count
    tm_buf[tpos] = 0x01; tpos += 1; // TINYINT
    tm_buf[tpos] = 0x0f; tpos += 1; // VARCHAR
    tm_buf[tpos] = 0; tpos += 1; // meta_len
    tm_buf[tpos] = 0; tpos += 1; // null_bitmap
    std.mem.writeInt(u32, tm_buf[9..13], @intCast(tpos), .little);
    _ = try p.processEvent(&tm_buf);

    // DELETE_ROWS_V2: 1 row [id=7, name="x"]
    var del_buf: [80]u8 = undefined;
    @memset(&del_buf, 0);
    std.mem.writeInt(u32, del_buf[0..4], 0, .little);
    del_buf[4] = 0x20; // DELETE_ROWS_V2
    std.mem.writeInt(u32, del_buf[5..9], 1, .little);
    std.mem.writeInt(u32, del_buf[9..13], 36, .little);
    std.mem.writeInt(u32, del_buf[13..17], 0, .little);
    std.mem.writeInt(u16, del_buf[17..19], 0, .little);
    std.mem.writeInt(u48, del_buf[19..25], 0x42, .little);
    del_buf[29] = 2; // col_count
    del_buf[30] = 0x03; // used_bitmap: cols 0,1 used
    del_buf[31] = 1; // num_rows
    del_buf[32] = 0x00; // null_bitmap
    del_buf[33] = 7; // id
    del_buf[34] = 1; // varchar len
    @memcpy(del_buf[35..][0..1], "x");

    var ev = try p.processEvent(&del_buf);
    defer freeRowEvents(a, ev.row);

    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    const row = &ev.row[0];
    try std.testing.expectEqual(event_mod.RowOp.delete, row.op);
    try std.testing.expectEqualStrings("7", row.getBeforeField("c0").?);
    try std.testing.expectEqualStrings("x", row.getBeforeField("c1").?);
    try std.testing.expect(row.fields.count() == 0);
}
```

- [ ] **Step 2: Implement `parseDeleteRows`**

Add this method inside `Parser`:

```zig
fn parseDeleteRows(self: *Parser, header: EventHeader, body: []const u8) ParseError!ParsedEvent {
    var pos: usize = 0;

    if (body.len < pos + 6) return error.BufferTooShort;
    const table_id = readInt48(body[pos..][0..6]);
    pos += 6;

    if (body.len < pos + 2) return error.BufferTooShort;
    pos += 2; // flags

    if (body.len < pos + 2) return error.BufferTooShort;
    const extra_data_len = std.mem.readInt(u16, body[pos..][0..2], .little);
    pos += 2;

    if (body.len < pos + extra_data_len) return error.BufferTooShort;
    pos += extra_data_len;

    const tm = self.table_maps.get(table_id) orelse return error.UnknownTableId;

    const col_count_p = try readPackedInt(body[pos..]);
    pos += col_count_p.len;
    const col_count: usize = @intCast(col_count_p.value);

    const used_bitmap_len = (col_count + 7) / 8;
    if (body.len < pos + used_bitmap_len) return error.BufferTooShort;
    const used_bitmap = body[pos..][0..used_bitmap_len];
    pos += used_bitmap_len;

    var used_columns = std.ArrayList(usize).empty;
    defer used_columns.deinit(self.allocator);
    for (0..col_count) |i| {
        if (isBitSet(used_bitmap, i)) {
            try used_columns.append(self.allocator, i);
        }
    }

    var rows = std.ArrayList(event_mod.RowEvent).empty;
    errdefer {
        for (rows.items) |*r| r.deinit(self.allocator);
        rows.deinit(self.allocator);
    }

    const num_rows_p = try readPackedInt(body[pos..]);
    pos += num_rows_p.len;
    const num_rows: usize = @intCast(num_rows_p.value);

    for (0..num_rows) |_| {
        var row = event_mod.RowEvent{
            .op = .delete,
            .table = try self.allocator.dupe(u8, tm.table),
            .database = try self.allocator.dupe(u8, tm.database),
            .fields = std.StringHashMap([]const u8).init(self.allocator),
            .timestamp = @as(i64, header.timestamp),
        };
        errdefer row.deinit(self.allocator);
        row.before_fields = std.StringHashMap([]const u8).init(self.allocator);
        try self.readRowInto(&row.before_fields.?, tm, used_columns.items, body, &pos);
        try rows.append(self.allocator, row);
    }

    return ParsedEvent{ .row = try rows.toOwnedSlice(self.allocator) };
}
```

- [ ] **Step 3: Update `processEvent` to call `parseDeleteRows`**

Already done in Task 1 (switch includes `.delete_rows_v2 => try self.parseDeleteRows(header, body)`).

- [ ] **Step 4: Run tests**

Run:

```bash
zig test src/cdc/binlog/parser.zig
```

Expected: PASS, including the new DELETE test.

- [ ] **Step 5: Commit**

```bash
git add src/cdc/binlog/parser.zig
git commit -m "feat(cdc/binlog): parse DELETE_ROWS_EVENT_V2"
```

---

## Task 4: Implement UPDATE_ROWS_EVENT_V2 parsing

**Files:**
- Modify: `src/cdc/binlog/parser.zig`
- Test: `src/cdc/binlog/parser.zig`

- [ ] **Step 1: Add a failing test for UPDATE rows**

Append this test:

```zig
test "Parser parses UPDATE_ROWS_V2 with before and after images" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();

    // TABLE_MAP: 2 cols [TINYINT, VARCHAR], db="db", tbl="t"
    var tm_buf: [80]u8 = undefined;
    @memset(&tm_buf, 0);
    std.mem.writeInt(u32, tm_buf[0..4], 0, .little);
    tm_buf[4] = 0x13;
    std.mem.writeInt(u32, tm_buf[5..9], 1, .little);
    std.mem.writeInt(u32, tm_buf[9..13], 52, .little);
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
    tm_buf[tpos] = 2; tpos += 1;
    tm_buf[tpos] = 0x01; tpos += 1;
    tm_buf[tpos] = 0x0f; tpos += 1;
    tm_buf[tpos] = 0; tpos += 1;
    tm_buf[tpos] = 0; tpos += 1;
    std.mem.writeInt(u32, tm_buf[9..13], @intCast(tpos), .little);
    _ = try p.processEvent(&tm_buf);

    // UPDATE_ROWS_V2 layout:
    // post-header(10) + col_count(1) + used_bitmap(1) + update_bitmap(1) +
    // num_rows(1) + before_null_bitmap(1) + before_values(TINYINT=1, VARCHAR=1+1) +
    // after_null_bitmap(1) + after_values(TINYINT=1, VARCHAR=1+1) = 22
    // event_size = 19 + 22 = 41
    var upd_buf: [80]u8 = undefined;
    @memset(&upd_buf, 0);
    std.mem.writeInt(u32, upd_buf[0..4], 0, .little);
    upd_buf[4] = 0x1f; // UPDATE_ROWS_V2
    std.mem.writeInt(u32, upd_buf[5..9], 1, .little);
    std.mem.writeInt(u32, upd_buf[9..13], 41, .little);
    std.mem.writeInt(u32, upd_buf[13..17], 0, .little);
    std.mem.writeInt(u16, upd_buf[17..19], 0, .little);
    std.mem.writeInt(u48, upd_buf[19..25], 0x42, .little);
    upd_buf[29] = 2; // col_count
    upd_buf[30] = 0x03; // used_bitmap: cols 0,1 used
    upd_buf[31] = 0x03; // update_bitmap: cols 0,1 used for update
    upd_buf[32] = 1; // num_rows
    // before image: id=5, name="a"
    upd_buf[33] = 0x00; // before null_bitmap
    upd_buf[34] = 5; // id
    upd_buf[35] = 1; // varchar len
    @memcpy(upd_buf[36..][0..1], "a");
    // after image: id=5, name="b"
    upd_buf[37] = 0x00; // after null_bitmap
    upd_buf[38] = 5; // id
    upd_buf[39] = 1; // varchar len
    @memcpy(upd_buf[40..][0..1], "b");

    var ev = try p.processEvent(&upd_buf);
    defer freeRowEvents(a, ev.row);

    try std.testing.expect(ev == .row);
    try std.testing.expectEqual(@as(usize, 1), ev.row.len);
    const row = &ev.row[0];
    try std.testing.expectEqual(event_mod.RowOp.update, row.op);
    try std.testing.expectEqualStrings("5", row.getBeforeField("c0").?);
    try std.testing.expectEqualStrings("a", row.getBeforeField("c1").?);
    try std.testing.expectEqualStrings("5", row.getField("c0").?);
    try std.testing.expectEqualStrings("b", row.getField("c1").?);
}
```

- [ ] **Step 2: Implement `parseUpdateRows`**

Add this method inside `Parser`:

```zig
fn parseUpdateRows(self: *Parser, header: EventHeader, body: []const u8) ParseError!ParsedEvent {
    var pos: usize = 0;

    if (body.len < pos + 6) return error.BufferTooShort;
    const table_id = readInt48(body[pos..][0..6]);
    pos += 6;

    if (body.len < pos + 2) return error.BufferTooShort;
    pos += 2; // flags

    if (body.len < pos + 2) return error.BufferTooShort;
    const extra_data_len = std.mem.readInt(u16, body[pos..][0..2], .little);
    pos += 2;

    if (body.len < pos + extra_data_len) return error.BufferTooShort;
    pos += extra_data_len;

    const tm = self.table_maps.get(table_id) orelse return error.UnknownTableId;

    const col_count_p = try readPackedInt(body[pos..]);
    pos += col_count_p.len;
    const col_count: usize = @intCast(col_count_p.value);

    const used_bitmap_len = (col_count + 7) / 8;
    if (body.len < pos + used_bitmap_len) return error.BufferTooShort;
    const used_bitmap = body[pos..][0..used_bitmap_len];
    pos += used_bitmap_len;

    if (body.len < pos + used_bitmap_len) return error.BufferTooShort;
    const update_bitmap = body[pos..][0..used_bitmap_len];
    pos += used_bitmap_len;

    // For FULL row image, update_bitmap should match used_bitmap. Defensive check.
    if (!std.mem.eql(u8, used_bitmap, update_bitmap)) {
        // Different image modes are not supported in this phase.
        return error.InvalidEvent;
    }

    var used_columns = std.ArrayList(usize).empty;
    defer used_columns.deinit(self.allocator);
    for (0..col_count) |i| {
        if (isBitSet(used_bitmap, i)) {
            try used_columns.append(self.allocator, i);
        }
    }

    var rows = std.ArrayList(event_mod.RowEvent).empty;
    errdefer {
        for (rows.items) |*r| r.deinit(self.allocator);
        rows.deinit(self.allocator);
    }

    const num_rows_p = try readPackedInt(body[pos..]);
    pos += num_rows_p.len;
    const num_rows: usize = @intCast(num_rows_p.value);

    for (0..num_rows) |_| {
        var row = event_mod.RowEvent{
            .op = .update,
            .table = try self.allocator.dupe(u8, tm.table),
            .database = try self.allocator.dupe(u8, tm.database),
            .fields = std.StringHashMap([]const u8).init(self.allocator),
            .timestamp = @as(i64, header.timestamp),
        };
        errdefer row.deinit(self.allocator);

        row.before_fields = std.StringHashMap([]const u8).init(self.allocator);
        try self.readRowInto(&row.before_fields.?, tm, used_columns.items, body, &pos);
        try self.readRowInto(&row, tm, used_columns.items, body, &pos);

        try rows.append(self.allocator, row);
    }

    return ParsedEvent{ .row = try rows.toOwnedSlice(self.allocator) };
}
```

- [ ] **Step 3: Run tests**

Run:

```bash
zig test src/cdc/binlog/parser.zig
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/cdc/binlog/parser.zig
git commit -m "feat(cdc/binlog): parse UPDATE_ROWS_EVENT_V2 with before/after images"
```

---

## Task 5: MySQL 8 compatibility for master status query

**Files:**
- Modify: `src/engine/runtime.zig:284-300`
- Test: `src/engine/runtime.zig` (manual or integration; no unit test for SQL fallback without a mock DB)

- [ ] **Step 1: Update `queryMasterStatus` to try `SHOW BINARY LOG STATUS` first**

Replace the existing `queryMasterStatus` method with:

```zig
fn queryMasterStatus(self: *SyncTask) !BinlogStartPos {
    const conn = try self.src_pool.acquire();
    defer self.src_pool.release(conn) catch {};

    var result = conn.query("SHOW BINARY LOG STATUS") catch |err| {
        common.logger.warn(
            "[task {d}] SHOW BINARY LOG STATUS failed ({s}), falling back to SHOW MASTER STATUS",
            .{ self.cfg.task_id, @errorName(err) },
        );
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

- [ ] **Step 2: Build the project to verify compilation**

Run:

```bash
zig build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "fix(engine): prefer SHOW BINARY LOG STATUS for MySQL 8 compatibility"
```

---

## Task 6: Honor `RowEvent.op` in `processBatch`

**Files:**
- Modify: `src/engine/runtime.zig:313-328`

**Context:** Currently `processBatch` takes a `default_op` and applies it to every row. For binlog rows, the parser now sets the correct `op` per row. We need `processBatch` to respect it when it differs from the default insert.

- [ ] **Step 1: Modify `processBatch` to use `ev.op` when set by binlog**

Replace the `processBatch` method with:

```zig
fn processBatch(self: *SyncTask, rows: []cdc.event.RowEvent, default_op: cdc.event.RowOp) !void {
    for (rows) |*ev| {
        // Poll-based CDC only sees the current snapshot; treat rows as upserts.
        // Binlog rows already carry the correct op (insert/update/delete).
        var op = ev.op;
        if (op == .insert and default_op != .insert) {
            op = default_op;
        }
        if (ev.fields.get("is_delete")) |v| {
            if (std.mem.eql(u8, v, "1")) op = .delete;
        }
        ev.op = op;
        const t = self.transformer.process(ev.*) catch |err| switch(err) { transform.engine.TransformError.FilterSkip=>continue, else=>{common.logger.warn("[task {d}] xf: {s}",.{self.cfg.task_id,@errorName(err)}); continue;} };
        try self.sink.append(t);
    }
    try self.sink.flush();
    meta.metrics.Service.incrementSuccess(self.store, self.cfg.task_id, @intCast(rows.len)) catch {};
}
```

- [ ] **Step 2: Build the project**

Run:

```bash
zig build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "fix(engine): honor RowEvent.op from binlog parser in processBatch"
```

---

## Task 7: Full parser test suite and final verification

**Files:**
- All modified files above

- [ ] **Step 1: Run the full parser test suite**

Run:

```bash
zig test src/cdc/binlog/parser.zig
```

Expected: all tests PASS.

- [ ] **Step 2: Run the full project test suite**

Run:

```bash
zig build test
```

Expected: all tests PASS (or at least no regressions in existing suites).

- [ ] **Step 3: Review git log**

Run:

```bash
git log --oneline -7
```

Expected: see clean, focused commits for checksum, helper extraction, DELETE, UPDATE, MySQL 8 fallback, and processBatch fix.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - UPDATE rows with before/after images → Task 4
  - DELETE rows with before_fields → Task 3
  - binlog CRC32 checksum stripping → Task 1
  - MySQL 8 `SHOW BINARY LOG STATUS` → Task 5
  - `RowEvent.op` honored in runtime → Task 6
- [ ] **No placeholders:** every step shows code, commands, and expected outputs.
- [ ] **Type consistency:** `readRowInto` uses the same `RowEvent`/`TableMap` types defined in earlier tasks.
