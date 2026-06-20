# zetl Phase 9b: 完善 (Memory Leaks + README 指针) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 2 pre-existing test memory leaks from Phase 6c + add a discoverable README pointer to `docs/ai-recipes/`.

**Architecture:** Pure polish. No API or schema changes. Two test edits use the existing `freeRule` helper from Phase 6b/9 to clean up heap-owned prefix slices. One README section insertion. One dev.md annotation.

**Tech Stack:** Zig 0.17, `std.testing.allocator` leak detection. Markdown.

---

## File Structure

| File | Change |
|------|--------|
| `src/transform/engine.zig` | Modify 2 tests to free heap-owned slices |
| `README.md` | Insert new section above "快速开始" |
| `dev.md` | Append Phase 9b note to Phase 9 section |

---

## Task 1: Fix Phase 6c memory leaks in engine.zig

**Files:**
- Modify: `src/transform/engine.zig` (lines 554-567 and 595-608)

- [ ] **Step 1: Confirm leaks exist (baseline)**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test 2>&1 | grep -E "leaked memory|All [0-9]+ tests"
```

Expected: `2 tests leaked memory.` (the 2 `parseNamingRule handles object form add_prefix/strip_prefix` tests).

- [ ] **Step 2: Fix `parseNamingRule handles object form add_prefix` (lines 554-567)**

Add `defer freeRule(a, rule);` right after the `expect(rule != null);` line:

```zig
test "parseNamingRule handles object form add_prefix" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"type":"add_prefix","value":"dt_"}
    , .{});
    defer parsed.deinit();

    const rule = try parseNamingRule(parsed.value, a);
    try std.testing.expect(rule != null);
    defer freeRule(a, rule);  // <-- NEW: release prefix slice
    switch (rule.?) {
        .add_prefix => |p| try std.testing.expectEqualStrings("dt_", p),
        else => return error.UnexpectedRule,
    }
}
```

> If `freeRule` is private to the test module (it's declared with `fn` not `pub fn`), it should be accessible because the test is in the same file. Verify by reading lines 100-150 of `engine.zig`. If `freeRule` is named differently (e.g., `freeNamingRule`), adapt to the actual name.

- [ ] **Step 3: Fix `parseNamingRule handles object form strip_prefix` (lines 595-608)**

Same edit pattern:

```zig
test "parseNamingRule handles object form strip_prefix" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"type":"strip_prefix","value":"dt_"}
    , .{});
    defer parsed.deinit();

    const rule = try parseNamingRule(parsed.value, a);
    try std.testing.expect(rule != null);
    defer freeRule(a, rule);  // <-- NEW: release prefix slice
    switch (rule.?) {
        .strip_prefix => |p| try std.testing.expectEqualStrings("dt_", p),
        else => return error.UnexpectedRule,
    }
}
```

- [ ] **Step 4: Verify no leaks**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test 2>&1 | grep -E "leaked memory|All [0-9]+ tests"
zig fmt --check src/transform/engine.zig
```

Expected:
- `All 213 tests passed.` (no `leaked memory` line)
- `zig fmt` clean

- [ ] **Step 5: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add src/transform/engine.zig
git commit -m "fix(transform): free heap-owned prefix slices in 2 parseNamingRule tests"
```

---

## Task 2: Add ai-recipes pointer to README.md

**Files:**
- Modify: `README.md` (insert between line 21 and line 23, between "## 特性" and "## 快速开始")

- [ ] **Step 1: Insert section**

Insert at the end of `## 特性 (V2)` (after the last `- HTMX + Alpine.js UI` bullet, line 20), then a blank line, then the new section:

```markdown
## 面向 AI 业务场景搭建

新同步场景? 让 AI 在 5 分钟内帮你写出 zetl 任务配置 JSON:

→ **[docs/ai-recipes/](docs/ai-recipes/)** 决策树

包含:
- 4 个场景 Recipe (订单 / 用户 / 商品 / 多源汇总)
- 4 个速查手册 (字段映射 / 列名转换 / Sink / Task API)
- 完整 TaskConfig 字段参考
```

Final structure (target around line 21-30):

```
- **HTMX + Alpine.js UI** — 单 HTML @embedFile

## 面向 AI 业务场景搭建

新同步场景? 让 AI 在 5 分钟内帮你写出 zetl 任务配置 JSON:

→ **[docs/ai-recipes/](docs/ai-recipes/)** 决策树

包含:
- 4 个场景 Recipe (订单 / 用户 / 商品 / 多源汇总)
- 4 个速查手册 (字段映射 / 列名转换 / Sink / Task API)
- 完整 TaskConfig 字段参考

## 快速开始
```

- [ ] **Step 2: Verify**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -n "ai-recipes" README.md
grep -n "面向 AI" README.md
ls docs/ai-recipes/README.md  # verify link target exists
```

Expected:
- 2 lines containing `ai-recipes` (section header + link)
- 1 line containing `面向 AI`
- `docs/ai-recipes/README.md` exists (target valid)

- [ ] **Step 3: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add README.md
git commit -m "docs: README pointer to ai-recipes"
```

---

## Task 3: Append Phase 9b note to dev.md

**Files:**
- Modify: `dev.md` (append to Phase 9 section)

- [ ] **Step 1: Find end of Phase 9 section**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -n "Phase 9\|Phase 8" dev.md | head -5
```

Expected: Phase 9 at line ~127, Phase 8 at line ~143.

- [ ] **Step 2: Append Phase 9b annotation**

Find the line `无代码变更. 仅 markdown.` (the last line of Phase 9 section, around line 142), then immediately after it (before the blank line that precedes `## Phase 8`), append:

```
\n## Phase 9b: 完善\n\n- 修复 Phase 6c 留下的 2 个测试内存泄漏 (`parseNamingRule handles object form add_prefix/strip_prefix`): 加 `defer freeRule(a, rule)`, `zig build test` 从 "2 leaked" → "0 leaked".\n- README.md 新增"面向 AI 业务场景搭建"section, 链接到 `docs/ai-recipes/` 决策树, 让新用户能发现 AI 速搭文档.\n
```

Target output around lines 142-150:

```
无代码变更. 仅 markdown.

## Phase 9b: 完善

- 修复 Phase 6c 留下的 2 个测试内存泄漏 (`parseNamingRule handles object form add_prefix/strip_prefix`): 加 `defer freeRule(a, rule)`, `zig build test` 从 "2 leaked" → "0 leaked".
- README.md 新增"面向 AI 业务场景搭建"section, 链接到 `docs/ai-recipes/` 决策树, 让新用户能发现 AI 速搭文档.

## Phase 8: 鉴权覆盖 (Auth coverage)
```

- [ ] **Step 3: Verify**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -A 4 "## Phase 9b" dev.md
```

Expected: 4 lines including the heading + 2 bullet points.

- [ ] **Step 4: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add dev.md
git commit -m "docs: Phase 9b section in dev.md"
```

---

## Task 4: Final verification + push + PR + merge

**Files:**
- All changes from Tasks 1-3.

- [ ] **Step 1: Run all tests + format check**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
zig build test 2>&1 | tail -3
zig fmt --check src/transform/engine.zig
```

Expected: `All 213 tests passed.` with no `leaked memory`. `zig fmt` clean.

- [ ] **Step 2: Diff stat**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git diff main --stat
```

Expected:
- 1 file changed in src/ (engine.zig)
- 1-2 files changed in docs (README.md, dev.md)
- 2 design/plan docs (already untracked, will be added)

- [ ] **Step 3: Commit design/plan docs (if not yet committed)**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/superpowers/specs/2026-06-15-zetl-phase9b-polish-design.md docs/superpowers/plans/2026-06-15-zetl-phase9b-polish.md
git commit -m "docs: Phase 9b design + plan"
```

- [ ] **Step 4: Push + create PR**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git checkout -b feat/v9b-polish
git push -u origin feat/v9b-polish
gh pr create --title "V9b 完善: fix memory leaks + README ai-recipes pointer" --body "$(cat <<'EOF'
## Summary
- 修复 Phase 6c 留下的 2 个 `parseNamingRule` 测试内存泄漏
- README.md 新增"面向 AI 业务场景搭建"section, 链接到 `docs/ai-recipes/`
- dev.md 追加 Phase 9b section

## Test Plan
- [x] `zig build test` — `All 213 tests passed.` (0 leaked)
- [x] `zig fmt --check src/transform/engine.zig` — clean
- [x] `grep "ai-recipes" README.md` — 2 matches
EOF
)"
```

- [ ] **Step 5: Squash-merge + cleanup**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
gh pr merge --squash --delete-branch
git checkout main
git pull --ff-only
git log --oneline -3
```

Expected: PR merged, branch deleted, main has the squash commit.

Report DONE.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - Phase 6c memory leak fix (add_prefix test) → Task 1 Step 2
  - Phase 6c memory leak fix (strip_prefix test) → Task 1 Step 3
  - README ai-recipes pointer → Task 2
  - dev.md Phase 9b section → Task 3
  - Verification + push + PR + merge → Task 4
- [ ] **No placeholders:** every step has concrete code; `freeRule` may need renaming based on actual function name in engine.zig.
- [ ] **Type consistency:** same test pattern (parseNamingRule + freeRule defer) applied to both object-form tests.