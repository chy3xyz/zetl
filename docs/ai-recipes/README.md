# zetl AI 速搭文档

把 zetl 的零散配置选项组织成"面向 AI 编程代理"的速查手册, 让 AI 在 **5 分钟内**为一个新的业务同步场景写出可运行的 `config_json`.

> 如果你是 AI 编程代理: **从下方决策树开始**, 命中相似场景就复制对应 recipe 改字段即可.

---

## 决策树: 我要配什么场景?

```
你的业务场景是什么?
│
├─ 订单同步 (有 mall_id + 佣金计算)
│  └─ recipes/order-sync.md
│
├─ 用户同步 (有 mall_id + 脱敏)
│  └─ recipes/user-sync.md
│
├─ 商品目录同步 (列名需 camel → snake)
│  └─ recipes/product-sync.md
│
├─ 几十套独立库汇总到一个中央库
│  └─ recipes/multi-source-aggregation.md
│
├─ 完全自定义场景 / 字段超出上面的模板
│  └─ 先读 00-task-config-schema.md 字段参考
│     再读 reference/transform-overrides.md / sink-ddl.md
│
└─ 第一次用 zetl
   └─ 读 01-quickstart.md (5 行 JSON 跑通最小链路)
      然后回到本决策树
```

## 目录

### 入门
- [00-task-config-schema.md](00-task-config-schema.md) — 完整 `config_json` 字段参考
- [01-quickstart.md](01-quickstart.md) — 最小可运行例子

### 场景 Recipe
- [recipes/order-sync.md](recipes/order-sync.md) — 订单 + mall_id + 佣金
- [recipes/user-sync.md](recipes/user-sync.md) — 用户 + 脱敏
- [recipes/product-sync.md](recipes/product-sync.md) — 商品 + 列名转换
- [recipes/multi-source-aggregation.md](recipes/multi-source-aggregation.md) — 多源汇总

### 参考手册 (Reference)
- [reference/transform-naming.md](reference/transform-naming.md) — `naming_rule` / `naming_rules`
- [reference/transform-overrides.md](reference/transform-overrides.md) — `field_mappings_json`
- [reference/sink-ddl.md](reference/sink-ddl.md) — `ensureTargetTable` 自动建表
- [reference/api-tasks.md](reference/api-tasks.md) — `/api/tasks/*` REST API

## 适用版本

zetl V6c (commit `676bd58` 及之后).

## 不在本手册范围

- zetl 编码约定 / Zig API 用法 → 看 `AGENTS.md`
- 内部设计文档 / 架构决策 → 看 `docs/superpowers/specs/`
- 阶段日志 / 改动历史 → 看 `dev.md`
