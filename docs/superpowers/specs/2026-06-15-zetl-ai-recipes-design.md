# zetl AI 速搭文档 设计文档

- **项目代号**：zETL
- **设计日期**：2026-06-15
- **适用版本**：V6c
- **状态**：待实现

---

## 0. 目标

让 AI（编程代理 / 助手）能在 **5 分钟内**为一个新的业务同步场景写出可运行的 zETL 任务配置 JSON。

**核心场景**: 数据管理员说「我要把 PolarDB 商城的 `orders` 表同步到总归集库, 加 mall_id, 计算佣金」→ AI 直接吐出正确的 `config_json`, 用户粘到 Web UI 提交即可.

---

## 1. 不在本轮范围

- 视频教程 / 交互式 demo
- 自动从 MySQL schema 反推完整 config 的工具
- Web UI 增强（drag-and-drop 配置）
- 多语言 (本期仅中文, 后期同步翻译英文)

---

## 2. 设计方案

新增 `docs/ai-recipes/` 目录, 结构如下:

```
docs/ai-recipes/
├── README.md                 # 主入口: 3 句话概述 + 目录 + 决策树
├── 00-task-config-schema.md  # 完整 TaskConfig JSON 字段参考
├── 01-quickstart.md          # 最小可运行例子 (5 行 JSON)
├── recipes/
│   ├── order-sync.md         # 订单同步 (mall_id 注入 + 佣金)
│   ├── user-sync.md          # 用户同步 (mall_id + 手机号脱敏)
│   ├── product-sync.md       # 商品目录同步 (camelCase → snake_case)
│   └── multi-source-aggregation.md  # 多商城汇总
└── reference/
    ├── transform-naming.md   # naming_rule 速查
    ├── transform-overrides.md# field_mappings_json 速查
    ├── sink-ddl.md           # ensureTargetTable 自动建表规则
    └── api-tasks.md          # /api/tasks/* REST API
```

**4 个核心文件**:
1. `README.md` (入口, 决策树)
2. `00-task-config-schema.md` (字段参考)
3. `01-quickstart.md` (5 行最小例子)
4. `recipes/order-sync.md` 等 (场景模板)

---

## 3. 关键决策

### 3.1 决策树 (README.md 主体)

```
你的业务场景是什么?
├─ 一句话说不清的复杂场景
│  └─ 读 00-task-config-schema.md 了解所有字段
├─ 跟现有场景相似 (订单/用户/商品)
│  └─ 复制 recipes/<similar>.md 改 mall_id / 表名 / 字段即可
└─ 第一次接触 zetl
   └─ 读 01-quickstart.md, 然后回到本决策树
```

### 3.2 场景 Recipe 模板

每个 recipe 文件结构 (5 段, ≤ 150 行):

1. **目标** (一句话)
2. **前置** (需要的源端 / 目标端 / 权限)
3. **源表结构** (SHOW COLUMNS 输出)
4. **目标表结构** (期望的 target columns)
5. **完整 config_json** (可直接 POST 到 /api/tasks)

### 3.3 Schema 文档风格

**面向 AI, 不面向人类**: 每个字段描述用以下结构:
```
字段名: source_table
类型: string
必填: 是
示例: "orders"
错误: missing → 任务启动失败 with "source_table required"
```

示例 (不写自然语言, 全是结构化 bullet).

### 3.4 与 AGENTS.md 的边界

| 主题 | 在哪 |
|------|------|
| zetl 编码约定 (Zig API 用法) | `AGENTS.md` |
| 如何配置一个同步任务 | `docs/ai-recipes/` |
| 设计文档 (内部) | `docs/superpowers/specs/` |
| 阶段日志 | `dev.md` |

AGENTS.md 不动; 新增 `docs/ai-recipes/` 目录专门面向场景搭建.

---

## 4. 内容规划

### 4.1 `00-task-config-schema.md` 字段清单

```yaml
name: string, 必填, 任务名 (用于 Web UI 显示)
sync_mode: enum{polling, binlog, both}, 默认 both
source:
  host: string
  port: int
  user: string
  password: string
  db: string
  table: string
  mall_id: string, 必填, 写入目标端的标识
target:
  host, port, user, password, db, table
transform:
  naming_rule: 命名规则 (string 或 object, Phase 6b)
  naming_rules: 链式规则数组 (Phase 6c)
  field_mappings_json: 字段映射覆盖 JSON 字符串
  commission: 佣金计算配置
  filter: 过滤条件 (Phase 9 待实现, 本期空)
sink:
  on_conflict: enum{replace, ignore, error}, 默认 replace
  batch_size: int, 默认 100
schedule:
  cron: 定时全量 cron (可选)
  reconcile: 对账配置 (可选)
```

### 4.2 `01-quickstart.md` 5 行最小例子

```json
{
  "name": "order-sync-from-mall-001",
  "sync_mode": "polling",
  "source": {"host": "polar-001.local", "port": 3306, "user": "etl", "password": "x", "db": "mall_001", "table": "orders", "mall_id": "mall-001"},
  "target": {"host": "central.local", "port": 3306, "user": "etl", "password": "x", "db": "central", "table": "union_all_order"}
}
```

然后一段话: 「POST 到 /api/tasks, 启动, 就能跑了」.

### 4.3 recipes/order-sync.md 完整例子

包含:
- 源 `orders` 表 schema (id, mall_id, order_no, agent_id, order_total, pay_time, status)
- 目标 `union_all_order` 表 schema (id, mall_id, order_no, agent_id, order_total, agent_commission, commission_rate, sync_time)
- 佣金计算: 5% 提成, 用 `transform.commission.rate = 0.05`
- 完整 config_json (≈30 行)

### 4.4 reference/transform-naming.md

Phase 6b/6c 已有规则速查表 (≤ 50 行), 配 JSON 示例.

### 4.5 reference/transform-overrides.md

`field_mappings_json` 语法 + 6 个例子 (重命名, 默认值, 类型转换, 跳过列, 表达式, 关联维度).

### 4.6 reference/sink-ddl.md

`ensureTargetTable` 行为 (CREATE TABLE IF NOT EXISTS), 已知限制 (VARCHAR 默认长度, DECIMAL 默认 precision).

### 4.7 reference/api-tasks.md

`/api/tasks` CRUD REST API + Auth (Phase 5 + Phase 8) 用法.

---

## 5. 测试 / 验证

文档类项目:
- ✅ 每个 recipe 的 config_json 通过 `std.json.parseFromSlice` 验证合法.
- ✅ 每个 recipe 至少一个端到端可跑通的例子 (标注: 「已在本机 MySQL 8.4 测试通过」).
- ✅ 内部交叉链接: README 决策树 → recipes → reference 全部可达.
- ✅ `docs/ai-recipes/README.md` ≤ 200 行.

---

## 6. 风险与回退

| 风险 | 应对 |
|------|------|
| AI 误解 schema (字段名拼错) | `00-task-config-schema.md` 每个字段给类型 + 示例, 错误信息写明 |
| Recipe 跟不上代码演进 | 在 `dev.md` 顶部加一行: 每次新 phase 合并后, 检查 recipes 是否需更新 |
| 中文 / 英文混排 | 本期仅中文; 后续 Phase 10 再做 i18n |
| 配置 JSON 不可读 (太长) | 每个 recipe ≤ 30 行 JSON, 大配置拆成 2 个文件 (base + overrides) |

---

## 7. 实施任务

1. 创建 `docs/ai-recipes/` 目录 + `README.md`
2. 写 `00-task-config-schema.md` (字段参考)
3. 写 `01-quickstart.md` (最小例子)
4. 写 4 个 recipes (order/user/product/multi-source)
5. 写 4 个 reference 文件 (naming/overrides/sink/api)
6. 用 `zig build test` 跑 1 个简单测试验证 json schema 可解析
7. 在 `AGENTS.md` 顶部加一行: 业务场景搭建先看 `docs/ai-recipes/`
8. 在 `dev.md` 加 Phase 9 section