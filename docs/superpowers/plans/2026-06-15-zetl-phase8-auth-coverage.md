# zetl Phase 8: /api/tasks 鉴权覆盖 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the existing `authInterceptor` + `permissionInterceptor` to the 6 currently-unprotected `/api/tasks/*` endpoints so any client must authenticate and have the right RBAC permission to manage sync tasks.

**Architecture:** Replace direct `app.get / app.post / app.put / app.delete` registrations in `src/web/routes.zig` with `app.getWithInterceptors / postWithInterceptors / putWithInterceptors / deleteWithInterceptors` chains of `[authInterceptor(), permissionInterceptor("task:...")]`, mirroring the existing V1 `/api/v1/task/*` pattern.

**Tech Stack:** Zig (0.17 nightly), existing zfinal HTTP framework + RBAC table.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/web/routes.zig` | Replace 6 unprotected endpoint registrations with `*WithInterceptors` versions | Modify |
| `src/auth/rbac.zig` | Verify `task:read / task:write / task:delete / task:start` permissions exist; add any missing | Modify (small) |
| `src/web/api/tasks.zig` | Confirm handler signatures match what `routes.zig` already expects | No change (verify only) |
| `dev.md` | Document the auth breaking change | Modify |

---

## Task 1: Audit RBAC permission table

**Files:**
- Modify: `src/auth/rbac.zig` (only if a permission is missing)
- Test: existing RBAC tests

- [ ] **Step 1: Search for existing `task:*` permissions**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -n "task:" src/auth/rbac.zig | head -20
```

Expected output: at least `task:read`, `task:write`, `task:delete`, `task:start`, `task:stop` are present (these are used by `/api/v1/task/*`).

- [ ] **Step 2: If any of `task:read / task:write / task:delete / task:start` is missing**

Add them to the permission list following the existing convention. As an example, the RBAC table likely has entries like:

```zig
// P1 任务 1.1 (replace with the existing entry, if missing add one)
.{ .perm = "task:read", .description = "Read sync task configs" },
.{ .perm = "task:write", .description = "Create or update sync task configs" },
.{ .perm = "task:delete", .description = "Delete sync tasks" },
.{ .perm = "task:start", .description = "Start / reload sync tasks" },
```

- [ ] **Step 3: Run tests to confirm nothing breaks**

```bash
zig build test 2>&1 | tail -5
```

Expected: 189 tests still pass.

- [ ] **Step 4: Commit only if Step 2 added a permission**

```bash
git add src/auth/rbac.zig
git commit -m "feat(auth): ensure task:read/write/delete/start permissions exist"
```

Skip this commit if Step 2 added nothing.

Report DONE when finished (or skipped).

---

## Task 2: Add auth coverage to `/api/tasks/*` in `routes.zig`

**Files:**
- Modify: `src/web/routes.zig`
- Test: existing route registration tests (if any); manual integration test deferred

- [ ] **Step 1: Locate the 6 unprotected endpoint registrations**

Find the block:

```zig
    // V5 Phase 5 Task 5: 动态任务管理 /api/tasks (DB + Scheduler 联动, 暂不鉴权)
    try app.get("/api/tasks", tasks_api.list);
    try app.post("/api/tasks", tasks_api.create);
    try app.get("/api/tasks/:id", tasks_api.detail);
    try app.put("/api/tasks/:id", tasks_api.update);
    try app.delete("/api/tasks/:id", tasks_api.delete);
    try app.post("/api/tasks/:id/reload", tasks_api.reload);
```

- [ ] **Step 2: Replace with `*WithInterceptors` versions**

Read the existing V1 task interceptor declarations to copy the style exactly (likely earlier in the same `registerAll` function):

```bash
grep -n "task_read_intc\|task_write_intc\|task_delete_intc\|task_start_intc" src/web/routes.zig
```

Replace the 6 lines with:

```zig
    // V5 Phase 5 Task 5 + Phase 8: 动态任务管理 /api/tasks (DB + Scheduler 联动, 已加鉴权)
    const v5_task_read_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:read") };
    const v5_task_write_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:write") };
    const v5_task_delete_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:delete") };
    const v5_task_start_intc = [_]zfinal.Interceptor{ auth_mw.authInterceptor(), auth_mw.permissionInterceptor("task:start") };
    try app.getWithInterceptors("/api/tasks", tasks_api.list, &v5_task_read_intc);
    try app.postWithInterceptors("/api/tasks", tasks_api.create, &v5_task_write_intc);
    try app.getWithInterceptors("/api/tasks/:id", tasks_api.detail, &v5_task_read_intc);
    try app.putWithInterceptors("/api/tasks/:id", tasks_api.update, &v5_task_write_intc);
    try app.deleteWithInterceptors("/api/tasks/:id", tasks_api.delete, &v5_task_delete_intc);
    try app.postWithInterceptors("/api/tasks/:id/reload", tasks_api.reload, &v5_task_start_intc);
```

> Adapt the variable names and the `*WithInterceptors` API if the existing project uses a different signature. Read the V1 `/api/v1/task/*` registrations (just above) to copy the convention exactly.

- [ ] **Step 3: Build and run tests**

```bash
zig build 2>&1 | head -20
zig build test 2>&1 | tail -5
```

Expected: builds clean, 189 tests still pass (no new tests required for this routing change).

- [ ] **Step 4: Commit**

```bash
git add src/web/routes.zig
git commit -m "feat(web): add auth + RBAC coverage to /api/tasks endpoints"
```

Report DONE when finished.

---

## Task 3: Add unit test for `isPublicPath`

**Files:**
- Modify: `src/web/auth_middleware.zig` (add a test)
- Test: `src/web/auth_middleware.zig`

- [ ] **Step 1: Add a failing test**

In `src/web/auth_middleware.zig`, locate the existing `isPublicPath` function and add this test below it:

```zig
test "isPublicPath returns false for /api/tasks endpoints" {
    try std.testing.expect(!isPublicPath("/api/tasks"));
    try std.testing.expect(!isPublicPath("/api/tasks/1"));
    try std.testing.expect(!isPublicPath("/api/tasks/1/reload"));
    try std.testing.expect(!isPublicPath("/api/v1/task"));
    try std.testing.expect(!isPublicPath("/api/v1/task/1/start"));
}

test "isPublicPath returns true for known public paths" {
    try std.testing.expect(isPublicPath("/health"));
    try std.testing.expect(isPublicPath("/api/v1/auth/login"));
    try std.testing.expect(isPublicPath("/api/v1/auth/logout"));
    try std.testing.expect(isPublicPath("/admin/login"));
}
```

- [ ] **Step 2: Run tests to confirm they pass**

```bash
zig test src/web/auth_middleware.zig
```

Expected: 2 new tests pass. If `isPublicPath` has unexpected behavior, this will reveal it.

- [ ] **Step 3: Commit**

```bash
git add src/web/auth_middleware.zig
git commit -m "test(web): cover isPublicPath for /api/tasks"
```

Report DONE when finished.

---

## Task 4: Update dev.md + final verification

**Files:**
- Modify: `dev.md`

- [ ] **Step 1: Add Phase 8 section**

In `dev.md`, after the Phase 7 section, add:

```
## Phase 8: 鉴权覆盖 (Auth coverage)

Phase 5 引入的 `/api/tasks/*` 端点此前**绕过鉴权中间件** (注释 "暂不鉴权"). Phase 8 修复这个安全漏洞: 给 6 个端点加 `authInterceptor` + `permissionInterceptor("task:read|write|delete|start")`, 与 V1 `/api/v1/task/*` 对齐.

- `/api/tasks` (GET)         需要 `task:read`
- `/api/tasks` (POST)        需要 `task:write`
- `/api/tasks/:id` (GET)     需要 `task:read`
- `/api/tasks/:id` (PUT)     需要 `task:write`
- `/api/tasks/:id` (DELETE)  需要 `task:delete`
- `/api/tasks/:id/reload` (POST) 需要 `task:start`

无 token → 401; 携带 viewer token 但缺少权限 → 403; admin token → 200/201.
```

- [ ] **Step 2: Final verification**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig fmt --check src/web/routes.zig src/web/auth_middleware.zig
zig build test 2>&1 | tail -5
```

Expected: formatting OK, all tests pass.

- [ ] **Step 3: Commit the design/plan docs (if not yet committed) and dev.md**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add dev.md docs/superpowers/specs/2026-06-15-zetl-phase8-auth-coverage-design.md docs/superpowers/plans/2026-06-15-zetl-phase8-auth-coverage.md
git commit -m "docs: add Phase 8 section + commit design/plan docs"
```

If the design/plan docs were already committed (e.g., during brainstorming), drop them.

Report DONE when finished.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - RBAC audit → Task 1
  - Add `*WithInterceptors` to `/api/tasks/*` → Task 2
  - `isPublicPath` unit test → Task 3
  - dev.md update → Task 4
- [ ] **No placeholders:** every step shows concrete code or commands; route registration API is illustrative and adapted during implementation by reading the V1 example.
- [ ] **Type consistency:** interceptor variable names, permission strings consistent across tasks.