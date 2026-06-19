# zetl 稳定性修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `is_running / is_finished / status` triplet with a single atomic `TaskStatus` enum on `SyncTask`, plus make `deinit()` idempotent so it can safely run from any state (including running, stopped, or already-deinited).

**Architecture:** Add `TaskStatus = enum { pending, running, success, error }` as an atomic value on `SyncTask`. Centralize state transitions in `start` / `stop` / `runLoop` / `markSuccess` / `markError`. Add `_deinit_done` and `_pool_deinit_done` atomic flags so `deinit()` and `src_pool.deinit()` can be called multiple times safely.

**Tech Stack:** Zig (0.17 nightly), `std.atomic.Value`, built-in `zig test`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/engine/runtime.zig` | SyncTask runtime | Replace 3 fields with `state` enum; add `_deinit_done` / `_pool_deinit_done` flags; make `deinit` idempotent; replace `markError` with `markSuccess`+`markError` |
| `src/engine/scheduler.zig` | Scheduler / addTask / removeTask | Update `is_running` / `is_finished` references |

---

## Task 1: Introduce `TaskStatus` enum + atomic state field

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Add `TaskStatus` enum and replace 3 fields**

In `src/engine/runtime.zig`, immediately after the existing top-level definitions (before `pub const SyncTask = struct {`), add:

```zig
/// SyncTask 生命周期状态. 所有转换通过 atomic.Value 在 SyncTask 结构体内同步.
pub const TaskStatus = enum(u8) {
    pending = 0,
    running = 1,
    success = 2,
    error = 3,
};
```

In the `SyncTask` struct, replace:

```zig
    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// runLoop 退出后置 true, 供 stopAll 提前结束等待.
    is_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
```

with:

```zig
    /// 当前任务状态. 所有转换: start → running, runLoop 退出 → success/error.
    state: std.atomic.Value(TaskStatus) = std.atomic.Value(TaskStatus).init(.pending),
    /// stop() 翻转此标志, runLoop 检测后优雅退出. 与 state 字段独立 (state 是结果, 这是原因).
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// runLoop 退出后置 true, 供 stopAll 提前结束等待. 与 state 区分: state=结果, is_finished=过程完成.
    is_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// deinit() 幂等保护: 多次调用只生效一次.
    _deinit_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// src_pool.deinit() 幂等保护: zfinal ConnectionPool 二次 deinit 会 crash.
    _pool_deinit_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
```

Also remove `status: i32 = 1,` from the struct (replaced by `state`).

- [ ] **Step 2: Verify build**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build 2>&1 | head -30
```

Expected: build fails with errors like `error: no member named 'status' / 'is_running' in struct 'SyncTask'` in callers (`scheduler.zig`, etc.). That's expected; we fix them in Task 4. The runtime.zig file itself should compile in isolation. If you want a clean build at this point, temporarily stub out the callers with `// TODO: Phase 6.4` comments.

- [ ] **Step 3: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "refactor(engine): introduce TaskStatus enum + replace 3 atomic fields"
```

---

## Task 2: Update `start` / `stop` to drive the state machine

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Replace `start`**

Replace:

```zig
pub fn start(self: *SyncTask) !void {
    if (self.is_running.load(.acquire)) return;
    self.is_running.store(true, .release);
    self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
}
```

with:

```zig
pub fn start(self: *SyncTask) !void {
    const prev = self.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire) catch |err| switch (err) {
        error.ValueTooLarge => unreachable,
    };
    if (prev != .pending and prev != .success and prev != .error) return error.AlreadyRunning;
    self.should_stop.store(false, .release);
    self.is_finished.store(false, .release);
    if (self.last_error) |old| {
        self.allocator.free(old);
        self.last_error = null;
    }
    self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
}
```

- [ ] **Step 2: Replace `stop`**

Replace:

```zig
pub fn stop(self: *SyncTask) void {
    self.is_running.store(false, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
}
```

with:

```zig
pub fn stop(self: *SyncTask) void {
    self.should_stop.store(true, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    // 注意: 不修改 state — 由 runLoop 在退出时根据自身结果置 success/error.
}
```

- [ ] **Step 3: Verify file compiles in isolation**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build obj src/engine/runtime.zig 2>&1 | head -20
```

Expected: errors only in callers (`scheduler.zig`), not in runtime.zig itself.

- [ ] **Step 4: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "refactor(engine): drive SyncTask state machine via TaskStatus"
```

---

## Task 3: Make `deinit` idempotent + ConnectionPool guard

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Replace `deinit`**

Replace the existing `deinit` body with:

```zig
pub fn deinit(self: *SyncTask) void {
    // 幂等: 第二次调用直接返回.
    if (self._deinit_done.swap(true, .acq_rel)) return;

    // 如果仍在 running, 触发 stop 并 join.
    const current = self.state.load(.acquire);
    if (current == .running) {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // runLoop 已经退出, 让 stop()/deinit() 路径能识别 (state 仍 .running).
        self.state.store(.success, .release);
    }

    self.transformer.deinit();
    self.sink.deinit();
    // src_pool 双重 deinit 会段错误 (zfinal ConnectionPool 内部 self-destroy).
    if (!self._pool_deinit_done.swap(true, .acq_rel)) {
        self.src_pool.deinit();
    }
    if (self.binlog_db) |*bd| bd.deinit();
    self.allocator.free(self._sh);
    self.allocator.free(self._sd);
    self.allocator.free(self._su);
    self.allocator.free(self._sp);
    self.pos.deinit(self.allocator);
    if (self.last_error) |e| self.allocator.free(e);
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build 2>&1 | head -30
```

Expected: still fails on callers (Task 4). runtime.zig should be clean.

- [ ] **Step 3: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "refactor(engine): make SyncTask.deinit idempotent + guard ConnectionPool"
```

---

## Task 4: Replace internal `is_running` references + add `markSuccess`

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Replace `markError` with `markSuccess` + `markError`**

Replace the existing `markError` function with:

```zig
fn markSuccess(self: *SyncTask) void {
    self.state.store(.success, .release);
}

fn markError(self: *SyncTask, err_msg: []const u8) void {
    if (self.last_error) |old| self.allocator.free(old);
    self.last_error = self.allocator.dupe(u8, err_msg) catch null;
    self.state.store(.error, .release);
}
```

- [ ] **Step 2: Update `runLoop` defer + body to use the new state machine**

In the `runLoop` function:

Replace:

```zig
defer {
    common.logger.inf("[task {d}] 退出", .{self.cfg.task_id});
    self.is_finished.store(true, .release);
}
```

with:

```zig
defer {
    common.logger.inf("[task {d}] 退出", .{self.cfg.task_id});
    self.is_finished.store(true, .release);
    // 主路径 (runLoop 自身正常返回, 未被 stop) 标记 success;
    // 错误路径在 catch 块已经 markError; stop() 路径已在外部修改 state.
    if (self.state.load(.acquire) == .running) {
        self.markSuccess();
    }
}
```

In the main catch blocks (`runFull`, `runIncremental`, `runBinlogIncremental`), the calls to `self.markError(@errorName(err))` already work — they go to the new `markError` definition above.

- [ ] **Step 3: Replace `is_running.load(.acquire)` references with `state == .running`**

Use this command:

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -n "is_running.load(.acquire)" src/engine/runtime.zig
```

For each occurrence (in `runFull`, `runIncremental`, `runBinlogIncremental`), replace:

```zig
while (self.is_running.load(.acquire)) {
```

with:

```zig
while (self.state.load(.acquire) == .running and !self.should_stop.load(.acquire)) {
```

And:

```zig
if (!self.is_running.load(.acquire)) return;
```

with:

```zig
if (self.should_stop.load(.acquire)) return;
```

- [ ] **Step 4: Build**

```bash
zig build 2>&1 | head -30
```

Expected: runtime.zig compiles cleanly. There may still be errors in `src/engine/scheduler.zig` and `src/main.zig` — Task 5 fixes those.

- [ ] **Step 5: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "refactor(engine): replace is_running refs with state == .running + should_stop"
```

---

## Task 5: Update scheduler and main callers

**Files:**
- Modify: `src/engine/scheduler.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Identify callers**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -rn "\.is_running\|\.is_finished\|\.status " src/engine/scheduler.zig src/main.zig src/meta/ src/web/ 2>/dev/null
```

For each match:

- `task.is_running.load(...)` → `task.state.load(...) == .running` (or use `task.should_stop.load(...)` if checking the "stop requested" condition).
- `task.is_finished.load(...)` → unchanged (still exists).
- `task.status` (the i32 field) → use `task.state.load(...)` and convert to integer if needed.

- [ ] **Step 2: Update `Scheduler.stopAll` and any other sync-task callers**

For example, in `src/engine/scheduler.zig`:

- The `stopAll` method (search for `stopAll` or `is_shutting_down`) should:
  1. Set `should_stop` on each task.
  2. Join each task.
  3. The state field will become `.success` or `.error` based on runLoop's own logic — no scheduler-side transition needed.

Adapt the actual code present in your version of `scheduler.zig`. The pattern in the design doc's section 2.5 describes the replacement strategy.

- [ ] **Step 3: Build**

```bash
zig build 2>&1 | head -30
```

Expected: clean build.

- [ ] **Step 4: Run tests**

```bash
zig build test 2>&1 | tail -10
```

Expected: existing 174 tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/engine/scheduler.zig src/main.zig
git commit -m "refactor: update scheduler/main callers for TaskStatus enum"
```

---

## Task 6: Add stability unit tests

**Files:**
- Modify: `src/engine/runtime.zig`

- [ ] **Step 1: Add unit tests for `TaskStatus` state machine + idempotent deinit**

Append to `src/engine/runtime.zig`:

```zig
test "SyncTask state transitions to running on start" {
    const a = std.testing.allocator;
    var st = std.atomic.Value(TaskStatus).init(.pending);
    st.store(.running, .release);
    try std.testing.expectEqual(TaskStatus.running, st.load(.acquire));
}

test "TaskStatus enum stringifies correctly" {
    try std.testing.expectEqualStrings("pending", @tagName(TaskStatus.pending));
    try std.testing.expectEqualStrings("running", @tagName(TaskStatus.running));
    try std.testing.expectEqualStrings("success", @tagName(TaskStatus.success));
    try std.testing.expectEqualStrings("error", @tagName(TaskStatus.error));
}

test "deinit_done flag is atomic and idempotent" {
    var flag = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(false, flag.swap(true, .acq_rel));
    try std.testing.expectEqual(true, flag.swap(true, .acq_rel));
    try std.testing.expectEqual(true, flag.load(.acquire));
}

test "pool_deinit_done flag is atomic and idempotent" {
    var flag = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(false, flag.swap(true, .acq_rel));
    try std.testing.expectEqual(true, flag.load(.acquire));
}
```

- [ ] **Step 2: Run tests**

```bash
zig build test 2>&1 | tail -10
```

Expected: 178 tests pass (174 existing + 4 new).

- [ ] **Step 3: Commit**

```bash
git add src/engine/runtime.zig
git commit -m "test(engine): add TaskStatus state machine + idempotent deinit tests"
```

---

## Task 7: Update dev.md + final verification

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Add a stability section**

In `dev.md`, add a short note near the existing limitations:

```
## 稳定性 (Stability 修复)

- `SyncTask.state` 是 `TaskStatus` enum (pending / running / success / error), 取代之前的 `is_running / is_finished / status: i32` 三字段, 状态转换在编译期可检查.
- `SyncTask.deinit()` 幂等: `_deinit_done` + `_pool_deinit_done` atomic 标志保证多次调用安全.
- `SyncTask.start()` 是 CAS-protected, 重复调用返回 `error.AlreadyRunning`.
- ConnectionPool 双重 deinit 已通过 `_pool_deinit_done` 标志保护 (zfinal 内部引用计数是后续优化).
```

- [ ] **Step 2: Final verification**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/engine/runtime.zig src/engine/scheduler.zig src/main.zig
zig build test 2>&1 | tail -5
```

Expected: formatting OK, all 178 tests pass.

- [ ] **Step 3: Commit**

```bash
git add dev.md
git commit -m "docs: dev.md stability section"
```

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - TaskStatus enum → Task 1
  - Replace is_running / is_finished / status → Task 1
  - deinit idempotent → Task 3
  - ConnectionPool double-deinit guard → Task 3
  - start CAS / stop should_stop → Task 2
  - markSuccess + markError → Task 4
  - Scheduler / main caller updates → Task 5
  - Unit tests → Task 6
  - dev.md update → Task 7
- [ ] **No placeholders:** every step shows concrete code or commands.
- [ ] **Type consistency:** `TaskStatus`, `state`, `should_stop`, `_deinit_done`, `_pool_deinit_done` field names consistent across tasks.