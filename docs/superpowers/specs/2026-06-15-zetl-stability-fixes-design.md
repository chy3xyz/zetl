# zetl 稳定性修复 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V3 + V5
- **前置版本**：V5 config-dynamic-tasks（已合并到 main）
- **状态**：待实现

---

## 0. 本轮目标

修复两处稳定性缺陷：

1. **SyncTask 退出状态不一致**：
   - 现状：`is_running: bool` + `is_finished: bool` + `status: i32 = 1` 三个字段分散，赋值时机不统一。
   - `stop()` 调用 `thread.join()` 后没有设置 `is_finished`；`markError()` 写 `status=2` 但没设 `is_finished`。
   - `deinit()` 不 join thread，如果外部没先 stop，会 UAF / 段错误。

2. **`ConnectionPool.deinit()` 段错误风险**：
   - `src_pool` 在 `SyncTask.deinit()` 中调用 `self.src_pool.deinit()`，但 zfinal 的 `ConnectionPool` 是自管理（内部 self-destroy），双重 deinit 会 crash。

---

## 1. 不在本轮范围

- 添加超时退出机制（`stop()` 仍阻塞 join）
- thread pool 改造
- binlog / poll 子模块的并发修复
- scheduler 中的 task 列表并发（Phase 5 已修复）

---

## 2. 架构与修改点

### 2.1 引入 `TaskStatus` enum（替换三字段）

在 `src/engine/runtime.zig` 顶部：

```zig
pub const TaskStatus = enum(u8) {
    pending = 0,
    running = 1,
    success = 2,
    error = 3,
};

pub const SyncTask = struct {
    // ... 既有字段 ...
    state: std.atomic.Value(TaskStatus) = std.atomic.Value(TaskStatus).init(.pending),
    /// 上次错误信息（state=error 时可读）
    last_error: ?[]const u8 = null,
    thread: ?std.Thread = null,

    // 移除:
    // is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // is_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // status: i32 = 1,
};
```

### 2.2 状态转换

- `init()` 完成后 `state` 为 `.pending`。
- `start()` 检查 `state == .pending || state == .error || state == .success`，CAS 到 `.running`，spawn thread。失败回滚。
- `runLoop` 入口检查 `state == .running`；defer 块根据本地 flag（success / error）置为 `.success` 或 `.error`。
- `stop()` 翻转 `should_stop` 标志（保留为 atomic bool 独立字段），调用 `thread.join()`，不修改 `state`。

### 2.3 `deinit()` 幂等

```zig
pub fn deinit(self: *SyncTask) void {
    const current = self.state.load(.acquire);
    switch (current) {
        .running => {
            // 触发停止并 join
            self.should_stop.store(true, .release);
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            self.state.store(.success, .release);
        },
        .pending, .success, .error => {},
    }

    // 释放资源 (只释放一次)
    self.transformer.deinit();
    self.sink.deinit();
    // src_pool 由 ConnectionPool.init 在内部 self-destroy, 外部只需 deinit 一次.
    // 但多次 deinit 必须幂等: 通过引用计数或 state CAS 保证只调用一次.
    if (self._pool_deinit_done.swap(true, .acq_rel)) {
        // 已 deinit, 跳过
    } else {
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

`_pool_deinit_done: std.atomic.Value(bool)` 保证 `src_pool.deinit()` 只调用一次。

### 2.4 `markSuccess` / `markError`

新增：

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

`runLoop` 的 defer 中：

```zig
defer {
    self.is_finished.store(true, .release);
    if (self.state.load(.acquire) == .running) {
        // runLoop 正常返回（未被 stop 调用） -> success
        markSuccess(self);
    }
    // 若 state 已被 stop() 改为 .success 或被 markError 改过, 这里覆盖; 不, defer 只在
    // 没异常路径上设置 success. 显式错误路径在 catch 块已经 markError.
}
```

实际更简洁的实现：runLoop 在主路径成功结束时调用 `self.markSuccess()`；错误路径 catch 块已调用 `self.markError(...)`；defer 块不修改 state，只设 `is_finished`。

### 2.5 替换内部 `is_running.load(.acquire)` 引用

所有 `is_running.load(.acquire)` 替换为 `self.state.load(.acquire) == .running`。

所有 `is_running.store(false, .release)` 替换为 `self.should_stop.store(true, .release)`（在 stop 函数中）。

### 2.6 `ConnectionPool.deinit()` 段错误风险

当前 `SyncTask.deinit()` 直接调用 `self.src_pool.deinit()`。如果：

- Scheduler 停止 task 后再释放（双重 deinit）。
- 或 task 自身异常路径已经 deinit src_pool，又走 deinit() 路径。

修复：

- 在 `SyncTask` 中加 `_pool_deinit_done: std.atomic.Value(bool)` 标志。
- `deinit()` 中先 CAS swap 到 true，成功者调用 `src_pool.deinit()`，失败者跳过。
- 这是临时方案；理想修复在 zfinal 内部实现引用计数（本轮不修改 zfinal）。

---

## 3. 数据流

### 3.1 正常启动 + 退出

```
SyncTask.init()      → state = .pending
SyncTask.start()     → state = .running (CAS), thread spawned
runLoop() { ... }    → state = .running (持续)
runLoop defer        → is_finished = true
runLoop 成功结束     → markSuccess → state = .success
syncTask.deinit()    → state != .running (already .success), 释放资源
```

### 3.2 异常退出

```
SyncTask.init()      → state = .pending
SyncTask.start()     → state = .running
runLoop() catch err  → markError(@errorName(err)) → state = .error
syncTask.deinit()    → state != .running, 释放资源
```

### 3.3 stop + deinit 顺序

```
stop()  → should_stop = true, thread.join(), 不修改 state
deinit() → state == .running 检查, 走 running 分支, join + 释放
```

stop 后 state 仍然是 `.running`（thread 已退出但未改 state）。deinit 时检测到 `.running` 走特殊路径。

### 3.4 双重 deinit

```
deinit() 第一次 → state 已经被 stop() + runLoop defer 改为 .success, 走 success 分支
              → _pool_deinit_done CAS → true → 释放 src_pool
deinit() 第二次 → state != .running, 但 _pool_deinit_done == true → 跳过 src_pool.deinit()
              → 其他资源可能也已被释放, 所以这里也直接 return
```

第二次 deinit 必须整体短路：

```zig
if (self._deinit_done.swap(true, .acq_rel)) return;
```

---

## 4. 测试策略

### 4.1 单元测试

- `SyncTask` 状态转换：init → pending，start → running，runLoop 完成 → success，runLoop 出错 → error。
- `markError` 写入 last_error 后可读取。
- `deinit()` 幂等：调用两次不 crash，src_pool 只 deinit 一次（通过 mock pool 计数验证）。

### 4.2 集成测试

- 启动任务 → 跑几个 batch → 正常退出 → state = .success。
- 启动任务 → 模拟错误 → state = .error，last_error 非空。
- `stop()` 后 `deinit()` 正常完成。
- `deinit()` 不 join（模拟未启动的 task）直接返回。

### 4.3 错误路径

- `start()` 调用两次：第二次返回 `error.AlreadyRunning`。
- `deinit()` 在 running 状态被调用：内部 join 线程后释放资源。
- 双重 `deinit()` 不 crash。

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| 引入 `TaskStatus` enum 改动面广 | 一次性替换所有 `is_running / is_finished / status` 引用；编译期会指出遗漏 |
| `_pool_deinit_done` 标志语义不清 | 单元测试明确覆盖；注释说明是临时方案 |
| runLoop defer 与 markError 状态冲突 | defer 不修改 state，只设 `is_finished`；显式成功/错误路径各自负责 |
| stop 后 state 仍为 running 导致 deinit 误判 | 明确 stop 不改 state；deinit 在 running 分支特殊处理 |

---

## 6. 后续扩展

- zfinal ConnectionPool 内部引用计数（彻底消除外部双重 deinit）
- task 超时停止（`stop_with_timeout(sec)`）
- 统一资源 RAII 包装