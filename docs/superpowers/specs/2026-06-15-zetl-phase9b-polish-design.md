# zetl Phase 9b: 完善 (Memory Leaks + README 指针) 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V9 (Phase 9 ai-recipes 刚合并)
- **状态**：待实现

---

## 0. 目标

修缮 Phase 9 落地后的两个可见瑕疵:
1. **Phase 6c 测试内存泄漏** — 2 个 `parseNamingRule` object-form 测试不释放 allocator 分配的 prefix slice, 导致 `zig build test` 报 "2 tests leaked memory".
2. **README.md 没有 ai-recipes 入口** — 新用户看 README 不知道有"AI 速搭文档".

---

## 1. 不在本轮范围

- 落地 transform.filter / mask_phone (Phase 10)
- Phase 7b (auto-detect VARCHAR/DECIMAL precision)
- ai-recipes 英文翻译
- Web UI 增强

---

## 2. 设计方案

### 2.1 修复 `src/transform/engine.zig` 测试内存泄漏

**根因**: 测试 `parseNamingRule handles object form add_prefix` (line 554-567) 和 `parseNamingRule handles object form strip_prefix` (line 595-608) 调用 `parseNamingRule` 后拿到 `?NamingRule`, 但 `add_prefix` / `strip_prefix` 变体持有 allocator-owned slice, 测试从未调用 free.

**修复**: 在测试末尾用 `transform.mapper.freeRule(allocator, rule)` 释放 (Phase 6b Task 3 已实现该 helper).

### 2.2 README.md 增加 ai-recipes 指针

在 `## 快速开始` 之前插入新 section:

```markdown
## 面向 AI 业务场景搭建

新同步场景? 让 AI 在 5 分钟内帮你写出 zetl 任务配置 JSON:

→ **[docs/ai-recipes/](docs/ai-recipes/)** 决策树

包含:
- 4 个场景 Recipe (订单/用户/商品/多源汇总)
- 4 个速查手册 (字段映射/列名转换/Sink/Task API)
- 完整 TaskConfig 字段参考
```

### 2.3 dev.md 更新 Phase 9 section

补一句 "Phase 9b 修复了 V6c 留下的 2 个测试内存泄漏, README 增加了 ai-recipes 入口" 到 Phase 9 末尾.

---

## 3. 文件改动

| File | Change |
|------|--------|
| `src/transform/engine.zig` | 2 个测试加 `defer transform.mapper.freeRule(a, rule)` (or inline free) |
| `README.md` | 新增 "面向 AI 业务场景搭建" section |
| `dev.md` | Phase 9 section 末尾追加 Phase 9b 说明 |

无 API 变更, 无 schema 变更. 仅 polish.

---

## 4. 测试策略

- `zig build test` 应从 "213 tests pass / 2 leaked" → "213 tests pass / 0 leaked"
- `zig fmt --check` 保持 OK
- 阅读 README 应能看到 ai-recipes 链接

---

## 5. 风险与回退

| 风险 | 应对 |
|------|------|
| 修复引入新的泄漏 (defer free 顺序错) | 跑 `zig build test` 看是否还有 leaked message |
| README section 顺序破坏现有内容 | 只插入新 section, 不动现有 section |

---

## 6. 后续扩展 (Phase 10+)

- Phase 10: 落地 `transform.filter` + `transform.mask_phone`, 让 ai-recipes/order-sync.md 和 user-sync.md 的"待实现"注释变可运行
- Phase 11: Phase 7b (auto-detect VARCHAR/DECIMAL precision)
- Phase 12: ai-recipes 英文版