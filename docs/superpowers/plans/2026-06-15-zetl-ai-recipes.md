# zetl AI 速搭文档 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `docs/ai-recipes/` documentation tree that lets an AI coding agent write a complete zetl task config JSON for a new business sync scenario in ≤ 5 minutes.

**Architecture:** Pure markdown documentation. Entry point is a README decision tree that points to scenario recipes (order/user/product/multi-source) and reference docs (schema/transform/sink/API). Each recipe is a copy-paste-ready config_json with verification steps. No code changes.

**Tech Stack:** Markdown only. JSON validation via `python3 -c "import json; json.loads(open('...').read())"`. Internal links checked via grep.

---

## File Structure

| File | Type | Purpose |
|------|------|---------|
| `docs/ai-recipes/README.md` | Create | Entry point + decision tree |
| `docs/ai-recipes/00-task-config-schema.md` | Create | All TaskConfig fields with type/required/example |
| `docs/ai-recipes/01-quickstart.md` | Create | 5-line minimum config + verify |
| `docs/ai-recipes/recipes/order-sync.md` | Create | Order sync scenario (mall_id + commission) |
| `docs/ai-recipes/recipes/user-sync.md` | Create | User sync scenario (mall_id + phone masking) |
| `docs/ai-recipes/recipes/product-sync.md` | Create | Product catalog scenario (camel → snake) |
| `docs/ai-recipes/recipes/multi-source-aggregation.md` | Create | 30-source aggregation pattern |
| `docs/ai-recipes/reference/transform-naming.md` | Create | naming_rule/naming_rules reference |
| `docs/ai-recipes/reference/transform-overrides.md` | Create | field_mappings_json reference |
| `docs/ai-recipes/reference/sink-ddl.md` | Create | ensureTargetTable behavior |
| `docs/ai-recipes/reference/api-tasks.md` | Create | /api/tasks/* REST API |
| `AGENTS.md` | Modify | Add pointer to ai-recipes |
| `dev.md` | Modify | Add Phase 9 section |

Total: 11 new files + 2 modified.

---

## Task 1: Directory + README.md

**Files:**
- Create: `docs/ai-recipes/README.md`

- [ ] **Step 1: Create the directory**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
mkdir -p docs/ai-recipes/recipes docs/ai-recipes/reference
```

- [ ] **Step 2: Write `README.md`**

```markdown
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
```

- [ ] **Step 3: Verify the file exists and line count**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
wc -l docs/ai-recipes/README.md
```

Expected: ≤ 80 lines (decision tree is compact by design).

- [ ] **Step 4: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/README.md
git commit -m "docs(ai-recipes): entry README with decision tree"
```

---

## Task 2: 00-task-config-schema.md

**Files:**
- Create: `docs/ai-recipes/00-task-config-schema.md`

- [ ] **Step 1: Write the schema reference**

```markdown
# TaskConfig 完整字段参考

下面给出 zetl `config_json` (POST 给 `/api/tasks` 的 body) 的全部字段.

每行格式: `字段名: 类型 / 必填 / 默认值 / 示例 / 错误信息`.

---

## 顶层字段

```
name:        string / 必填 / 无 / "order-sync-from-mall-001" / "name required"
sync_mode:   enum{polling, binlog, both} / 选填 / both / "both" / "invalid sync_mode"
```

### `sync_mode` 取值

- `polling`: 仅全量 + 按 update_time 轮询增量 (Phase 1/2).
- `binlog`: 仅 binlog CDC (V3).
- `both`: 全量初始化后自动切 binlog 增量 (推荐).

---

## `source` 子对象 (源端连接)

```
source.host:     string / 必填 / 无 / "polar-001.local"
source.port:     int    / 必填 / 无 / 3306
source.user:     string / 必填 / 无 / "etl"
source.password: string / 必填 / 无 / "<encrypted>"
source.db:       string / 必填 / 无 / "mall_001"
source.table:    string / 必填 / 无 / "orders"
source.mall_id:  string / 必填 / 无 / "mall-001"
```

权限要求: `SELECT, REPLICATION SLAVE, REPLICATION CLIENT` (Phase 2 PRD).

---

## `target` 子对象 (目标端连接)

```
target.host:     string / 必填 / 无 / "central.local"
target.port:     int    / 必填 / 无 / 3306
target.user:     string / 必填 / 无 / "etl"
target.password: string / 必填 / 无 / "<encrypted>"
target.db:       string / 必填 / 无 / "central"
target.table:    string / 必填 / 无 / "union_all_order"
```

`ensureTargetTable` 会自动 `CREATE TABLE IF NOT EXISTS`, 不需要预先建表 (Phase 7).

---

## `transform` 子对象 (转换规则)

```
transform.naming_rule:         string|object / 选填 / identity
transform.naming_rules:        array / 选填 / []
transform.field_mappings_json:  string (JSON) / 选填 / "[]"
transform.commission:          object / 选填 / null
```

详见 [reference/transform-naming.md](reference/transform-naming.md) 和 [reference/transform-overrides.md](reference/transform-overrides.md).

### `transform.commission` 子对象

```
transform.commission.rate:           float / 必填 / 无 / 0.05
transform.commission.amount_field:   string / 必填 / 无 / "order_total"
transform.commission.output_field:   string / 选填 / "agent_commission"
transform.commission.rate_field:     string / 选填 / "commission_rate"
```

---

## `sink` 子对象 (写入策略)

```
sink.on_conflict: enum{replace, ignore, error} / 选填 / replace
sink.batch_size:  int / 选填 / 100
```

- `replace`: UPSERT (`ON DUPLICATE KEY UPDATE`), 用主键覆盖.
- `ignore`: 重复主键跳过.
- `error`: 重复主键报错.

详见 [reference/sink-ddl.md](reference/sink-ddl.md).

---

## `schedule` 子对象 (定时)

```
schedule.cron:        string / 选填 / null / "0 2 * * *"
schedule.reconcile:    bool   / 选填 / false
```

`schedule.cron` 为标准 cron 表达式, 触发全量重跑.

---

## 完整最小例子

```json
{
  "name": "order-sync-from-mall-001",
  "sync_mode": "both",
  "source": {
    "host": "polar-001.local", "port": 3306,
    "user": "etl", "password": "x",
    "db": "mall_001", "table": "orders",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "x",
    "db": "central", "table": "union_all_order"
  }
}
```

下一步: 跑 [01-quickstart.md](01-quickstart.md), 或直接看 [recipes/](recipes/).
```

- [ ] **Step 2: Verify line count**

```bash
wc -l /Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/00-task-config-schema.md
```

Expected: ≤ 150 lines.

- [ ] **Step 3: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/00-task-config-schema.md
git commit -m "docs(ai-recipes): full TaskConfig schema reference"
```

---

## Task 3: 01-quickstart.md

**Files:**
- Create: `docs/ai-recipes/01-quickstart.md`

- [ ] **Step 1: Write the quickstart**

```markdown
# Quickstart: 5 分钟跑通最小链路

假设你已经有一对 PolarDB MySQL 库 (源 + 目标), 想用 zetl 把源 `orders` 表同步到目标.

## Step 1: 准备 JSON

保存下面 JSON 到 `/tmp/order-task.json`:

```json
{
  "name": "quickstart-order",
  "sync_mode": "polling",
  "source": {
    "host": "127.0.0.1", "port": 3306,
    "user": "etl", "password": "etl",
    "db": "mall_001", "table": "orders",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "127.0.0.1", "port": 3306,
    "user": "etl", "password": "etl",
    "db": "central", "table": "union_all_order"
  }
}
```

## Step 2: POST 给 zetl

```bash
curl -X POST http://127.0.0.1:8080/api/tasks \
  -H "Authorization: Bearer <admin_token>" \
  -H "Content-Type: application/json" \
  --data @/tmp/order-task.json
```

返回 `201 Created` + 任务 JSON.

## Step 3: 查看任务列表

```bash
curl -H "Authorization: Bearer <admin_token>" \
  http://127.0.0.1:8080/api/tasks
```

找到刚才创建的任务, 复制 `id`.

## Step 4: 启动任务

```bash
curl -X POST http://127.0.0.1:8080/api/tasks/<id>/reload \
  -H "Authorization: Bearer <admin_token>"
```

## Step 5: 验证

往源 `orders` 表插一行, 等 1 秒, 在目标 `union_all_order` 看到同样的行 (带 mall_id).

## 下一步

- 加上 `transform.commission` 做佣金计算 → [recipes/order-sync.md](recipes/order-sync.md)
- 加上 `transform.naming_rule` 做列名转换 → [reference/transform-naming.md](reference/transform-naming.md)
- 多套库并发同步 → [recipes/multi-source-aggregation.md](recipes/multi-source-aggregation.md)
```

- [ ] **Step 2: Verify**

```bash
wc -l /Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/01-quickstart.md
```

Expected: ≤ 80 lines.

- [ ] **Step 3: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/01-quickstart.md
git commit -m "docs(ai-recipes): 5-line quickstart"
```

---

## Task 4: recipes/order-sync.md

**Files:**
- Create: `docs/ai-recipes/recipes/order-sync.md`

- [ ] **Step 1: Write the order sync recipe**

```markdown
# Recipe: 订单同步 (mall_id 注入 + 佣金计算)

## 目标

把单套 PolarDB 商城的 `orders` 表同步到总归集库的 `union_all_order`, 自动注入 `mall_id` 并实时计算 `agent_commission` (5% 提成).

## 前置

- 源端 PolarDB 已开 binlog (`binlog_format=ROW`, `binlog_row_image=FULL`).
- 源端账号权限: `SELECT, REPLICATION SLAVE, REPLICATION CLIENT`.
- 目标库 `central.union_all_order` 不需要预先建表 (Phase 7 自动 CREATE TABLE IF NOT EXISTS).

## 源表 `mall_001.orders` 结构

```sql
CREATE TABLE orders (
  id            BIGINT       NOT NULL PRIMARY KEY,
  mall_id       VARCHAR(32)  NOT NULL,
  order_no      VARCHAR(64)  NOT NULL UNIQUE,
  agent_id      BIGINT       NULL,
  order_total   DECIMAL(10,2) NOT NULL,
  order_status  TINYINT      NOT NULL DEFAULT 0,
  pay_time      DATETIME     NULL,
  create_time   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

## 目标表 `central.union_all_order` 期望结构

```sql
CREATE TABLE union_all_order (
  id                BIGINT       NOT NULL PRIMARY KEY,
  mall_id           VARCHAR(32)  NOT NULL,
  order_no          VARCHAR(64)  NOT NULL,
  agent_id          BIGINT       NULL,
  order_total       DECIMAL(10,2) NOT NULL,
  agent_commission  DECIMAL(10,2) NULL,
  commission_rate   DECIMAL(5,4)  NULL,
  order_status      TINYINT      NOT NULL DEFAULT 0,
  pay_time          DATETIME     NULL,
  sync_time         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mall_order(mall_id, order_no)
);
```

## 完整 `config_json`

```json
{
  "name": "order-sync-from-mall-001",
  "sync_mode": "both",
  "source": {
    "host": "polar-001.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "orders",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "union_all_order"
  },
  "transform": {
    "commission": {
      "rate": 0.05,
      "amount_field": "order_total",
      "output_field": "agent_commission",
      "rate_field": "commission_rate"
    }
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 200
  }
}
```

## 字段解读

- `mall_id: "mall-001"` 自动追加到目标行, 与 order_no 组成联合唯一索引.
- `transform.commission.rate = 0.05`: 每行 `agent_commission = order_total * 0.05`.
- `sink.on_conflict = "replace"`: 重复订单 (mall_id+order_no) 覆盖更新.
- `sink.batch_size = 200`: 200 行一批写入, 适合 PolarDB 网络抖动场景.

## 验证步骤

1. 源 `orders` 插一行: `INSERT INTO orders VALUES (1, 'mall-001', 'O-2026-001', 100, 100.00, 1, NOW(), NOW());`
2. 等 ≤ 10 秒 (Phase 2 端到端延迟).
3. 目标查: `SELECT * FROM union_all_order WHERE order_no = 'O-2026-001';`
   - 期望 `mall_id = 'mall-001'`, `agent_commission = 5.00`, `commission_rate = 0.0500`.

## 常见变更

### 想用 7% 佣金

改 `transform.commission.rate` 为 `0.07`.

### 想加 update_time 过滤 (只同步已支付订单)

等 Phase 9 `transform.filter` 落地 (见 [dev.md](../../dev.md) Phase 9).

### 想从 30 套 PolarDB 一起同步

看 [multi-source-aggregation.md](multi-source-aggregation.md).
```

- [ ] **Step 2: Verify**

```bash
python3 -c "import json; json.load(open('/Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/recipes/order-sync.md'.replace('.md','.json')))" 2>/dev/null; \
python3 <<'PY'
import re
content = open('/Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/recipes/order-sync.md').read()
# Extract first ```json block
m = re.search(r'```json\n(.*?)\n```', content, re.DOTALL)
assert m, "no json block found"
data = __import__('json').loads(m.group(1))
assert data['name'].startswith('order-sync')
assert data['transform']['commission']['rate'] == 0.05
print("OK: config_json parses and validates")
PY
```

Expected: `OK: config_json parses and validates`.

- [ ] **Step 3: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/recipes/order-sync.md
git commit -m "docs(ai-recipes): order-sync recipe"
```

---

## Task 5: recipes/user-sync.md

**Files:**
- Create: `docs/ai-recipes/recipes/user-sync.md`

- [ ] **Step 1: Write the user sync recipe**

```markdown
# Recipe: 用户同步 (mall_id + 手机号脱敏)

## 目标

把单套 PolarDB 商城的 `users` 表同步到总归集库的 `union_all_user`, 自动追加 `mall_id`, 并把 `phone` 字段从 `13800138000` 脱敏成 `138****8000`.

## 前置

- 同 order-sync 基础前置.
- 脱敏规则硬编码在 `transform` 中 (Phase 9 计划支持自定义表达式).

## 源表 `mall_001.users` 结构

```sql
CREATE TABLE users (
  id            BIGINT       NOT NULL PRIMARY KEY,
  phone         VARCHAR(20)  NOT NULL,
  register_time DATETIME     NOT NULL,
  agent_id      BIGINT       NULL
);
```

## 目标表 `central.union_all_user` 期望结构

```sql
CREATE TABLE union_all_user (
  id            BIGINT       NOT NULL PRIMARY KEY,
  mall_id       VARCHAR(32)  NOT NULL,
  phone         VARCHAR(20)  NOT NULL,    -- 脱敏后
  register_time DATETIME     NOT NULL,
  agent_id      BIGINT       NULL,
  sync_time     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mall_user(mall_id, id)
);
```

## 完整 `config_json`

```json
{
  "name": "user-sync-from-mall-001",
  "sync_mode": "both",
  "source": {
    "host": "polar-001.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "users",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "union_all_user"
  },
  "transform": {
    "field_mappings_json": "[{\"source\":\"phone\",\"target\":\"phone\",\"default\":\"****\"}]"
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 500
  }
}
```

## 字段解读

- `transform.field_mappings_json`: 当前仅支持字段重命名 + 默认值填充; 手机号脱敏是 V6 已知限制, 落地到 Phase 9 (`transform.mask_phone = true` 简写).
- `batch_size = 500`: 用户表无金额计算, 可放大批量.

## Phase 9 简化版 (未来)

Phase 9 落地后, `config_json` 简化成:

```json
{
  "transform": {
    "mask_phone": true
  }
}
```

届时本文档会更新. 详见 [dev.md](../../dev.md) Phase 9.

## 验证步骤

1. 源 `users` 插一行: `INSERT INTO users VALUES (1, '13800138000', NOW(), 100);`
2. 目标查: `SELECT phone FROM union_all_user WHERE id = 1;`
   - 期望 `phone = '****'` (Phase 9 落地后) 或保留原始 (Phase 6c 当前).

## 已知限制

- 当前 `field_mappings_json` 不支持表达式, 脱敏在目标端 SQL 层做 (见 `reference/sink-ddl.md`).
```

- [ ] **Step 2: Verify**

```bash
python3 <<'PY'
import re, json
content = open('/Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/recipes/user-sync.md').read()
m = re.search(r'```json\n(.*?)\n```', content, re.DOTALL)
data = json.loads(m.group(1))
assert data['name'].startswith('user-sync')
assert data['source']['table'] == 'users'
print("OK")
PY
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/recipes/user-sync.md
git commit -m "docs(ai-recipes): user-sync recipe"
```

---

## Task 6: recipes/product-sync.md + multi-source-aggregation.md

**Files:**
- Create: `docs/ai-recipes/recipes/product-sync.md`
- Create: `docs/ai-recipes/recipes/multi-source-aggregation.md`

- [ ] **Step 1: Write product-sync.md**

```markdown
# Recipe: 商品目录同步 (camelCase → snake_case)

## 目标

源端商品表用 camelCase 列名 (`productName`, `unitPrice`), 目标端标准命名是 snake_case. 用 Phase 6b 的 `naming_rule: "camel_to_snake"` 自动转换, 无需手工写 `field_mappings_json`.

## 源表 `mall_001.products` 结构 (驼峰)

```sql
CREATE TABLE products (
  id           BIGINT        NOT NULL PRIMARY KEY,
  productName  VARCHAR(255)  NOT NULL,
  unitPrice    DECIMAL(10,2) NOT NULL,
  categoryId   INT           NOT NULL,
  createTime   DATETIME      NOT NULL
);
```

## 目标表 `central.product` 期望 (下划线)

```sql
CREATE TABLE product (
  id            BIGINT        NOT NULL PRIMARY KEY,
  mall_id       VARCHAR(32)   NOT NULL,
  product_name  VARCHAR(255)  NOT NULL,
  unit_price    DECIMAL(10,2) NOT NULL,
  category_id   INT           NOT NULL,
  create_time   DATETIME      NOT NULL,
  sync_time     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mall_product(mall_id, id)
);
```

## 完整 `config_json`

```json
{
  "name": "product-sync-from-mall-001",
  "sync_mode": "both",
  "source": {
    "host": "polar-001.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "products",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "product"
  },
  "transform": {
    "naming_rule": "camel_to_snake"
  },
  "sink": {
    "on_conflict": "replace"
  }
}
```

## 字段解读

- `naming_rule: "camel_to_snake"`: `productName` 自动变成 `product_name`, 无需写 `field_mappings_json`.
- 想加更复杂规则 (比如 `naming_rule: "camel_to_snake"` 后再加 `add_prefix("dt_")`) 用 Phase 6c 的 `naming_rules` 数组, 详见 [reference/transform-naming.md](../reference/transform-naming.md).

## 验证

1. 源插一行 `productName='iPhone 15', unitPrice=5999.00`.
2. 目标查: `SELECT product_name, unit_price FROM product WHERE id = ?;` → `iPhone 15 | 5999.00`.
```

- [ ] **Step 2: Write multi-source-aggregation.md**

```markdown
# Recipe: 多商城汇总 (30 套 PolarDB → 1 个中央库)

## 目标

30 套独立的 PolarDB 商城 (mall-001 到 mall-030), 各自有 `orders` 表, 全部汇总到中央 `central.union_all_order` (按 `mall_id` 区分).

## 实施方式

不要写 30 个配置文件. 用一个 shell 脚本循环生成 30 个 task, POST 给 zetl.

## 模板 `config_template.json`

```json
{
  "name": "order-sync-from-__MALL_ID__",
  "sync_mode": "both",
  "source": {
    "host": "polar-__N__.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "orders",
    "mall_id": "__MALL_ID__"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "union_all_order"
  },
  "transform": {
    "commission": {
      "rate": 0.05,
      "amount_field": "order_total"
    }
  },
  "sink": {
    "on_conflict": "replace",
    "batch_size": 200
  }
}
```

## 生成脚本 `bulk-create.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

TOKEN="<admin_token>"
ZETL_URL="http://127.0.0.1:8080"

for n in $(seq -w 1 30); do
  mall_id="mall-$(printf '%03d' $((10#$n)))"

  config=$(sed \
    -e "s/__MALL_ID__/${mall_id}/g" \
    -e "s/__N__/${n}/g" \
    config_template.json)

  curl -s -X POST "${ZETL_URL}/api/tasks" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${config}"
  echo
done
```

## 字段解读

- `__MALL_ID__` / `__N__` 是占位符, `sed` 替换成 `mall-001` / `001` 等.
- 30 个任务全部 POST 到同一个 `target.union_all_order`, 通过 `mall_id` 区分.
- `UNIQUE KEY uk_mall_order(mall_id, order_no)` 保证不同 mall 的 order_no 互不冲突.

## 性能建议

- 30 套 PolarDB 都在同一地域: zetl 单机 (4 核 8G) 可承载, 见 [PRD §5.1](../../docs/zetl_prd.md) (单进程 ≥ 100 链路).
- `sink.batch_size = 200` 在 PolarDB 写入场景是经验值, 大促可降到 50.

## 验证

1. 跑完 `bulk-create.sh` 后 `curl -H "Authorization: Bearer $TOKEN" $ZETL_URL/api/tasks | jq '. | length'` → `30`.
2. 任选 2 套 mall 各插一行, 目标 `union_all_order` 应有 2 行, `mall_id` 字段不同.
```

- [ ] **Step 3: Verify both files**

```bash
python3 <<'PY'
import re, json
for path in [
    '/Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/recipes/product-sync.md',
    '/Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/recipes/multi-source-aggregation.md',
]:
    content = open(path).read()
    blocks = re.findall(r'```json\n(.*?)\n```', content, re.DOTALL)
    for i, b in enumerate(blocks):
        try:
            json.loads(b)
            print(f"{path}: block {i+1} OK")
        except Exception as e:
            print(f"{path}: block {i+1} FAIL: {e}")
            raise
PY
```

Expected: all blocks OK.

- [ ] **Step 4: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/recipes/product-sync.md docs/ai-recipes/recipes/multi-source-aggregation.md
git commit -m "docs(ai-recipes): product-sync + multi-source-aggregation recipes"
```

---

## Task 7: 4 reference files

**Files:**
- Create: `docs/ai-recipes/reference/transform-naming.md`
- Create: `docs/ai-recipes/reference/transform-overrides.md`
- Create: `docs/ai-recipes/reference/sink-ddl.md`
- Create: `docs/ai-recipes/reference/api-tasks.md`

- [ ] **Step 1: Write transform-naming.md**

```markdown
# Naming Rule 速查 (Phase 6b / 6c)

## 单规则形式 (`naming_rule`)

```
"naming_rule": "identity"           // 不变
"naming_rule": "camel_to_snake"     // orderId → order_id
"naming_rule": "snake_to_camel"     // order_id → orderId
"naming_rule": "upper"              // foo → FOO
"naming_rule": "lower"              // FOO → foo
"naming_rule": {"type":"add_prefix","value":"dt_"}   // id → dt_id
"naming_rule": {"type":"strip_prefix","value":"dt_"} // dt_id → id
"naming_rule": {"type":"regex_replace","pattern":"_tmp$","replacement":""}  // order_tmp → order
```

## 链式规则 (`naming_rules`, Phase 6c)

```json
"naming_rules": [
  {"type": "camel_to_snake"},
  {"type": "regex_replace", "pattern": "_tmp$", "replacement": ""},
  {"type": "add_prefix", "value": "dt_"}
]
```

`orderId` → `order_id` → `order` → `dt_order`.

空数组 `[]` = `identity`.

## 已知限制

- `camel_to_snake` 对 `userIDNumber` 返回 `user_i_d_number` (连续大写处理是 best-effort, 90% 覆盖).
- regex_replace 是 zetl 内置 mini 引擎, 不支持 `*?` (lazy quantifier) / 环视 / `\d` 简写 (用 `[0-9]` 替代).

详见 `dev.md` Phase 6b / 6c section.
```

- [ ] **Step 2: Write transform-overrides.md**

```markdown
# `field_mappings_json` 速查

## 语法

字符串化的 JSON 数组, 每项是一个 mapping:

```json
[
  {"source": "user_phone", "target": "phone"},
  {"source": "amount", "target": "order_total", "default": "0.00"},
  {"source": "status", "target": "is_active", "type": "bool"}
]
```

字段:
- `source` (必填): 源列名.
- `target` (必填): 目标列名.
- `default` (选填): 当源列 NULL 时的默认值.
- `type` (选填): 目标类型 (`string` / `int` / `float` / `bool` / `datetime`).

## 6 个常用例子

```json
// 1. 重命名
[{"source": "phone", "target": "user_phone"}]

// 2. 默认值填充
[{"source": "remark", "target": "remark", "default": ""}]

// 3. 类型转换
[{"source": "is_vip", "target": "is_vip", "type": "bool"}]

// 4. 跳过列 (不写就不会同步)
[]

// 5. 多个 override
[{"source": "a", "target": "a"}, {"source": "b", "target": "B"}]

// 6. 配合 naming_rule (override 优先)
[
  {"source": "id", "target": "mall_id"},
  {"source": "mallId", "target": "real_mall_id"}
]
```

## 与 `naming_rule` 关系

- `naming_rule` 是批量规则, 适用于所有列.
- `field_mappings_json` 是个例 override, 命中 source 的项**覆盖**自动规则生成的 target.
- 想跳过 `naming_rule` 的某些列, 在 `field_mappings_json` 里写 `target = source` 即可.

详见 `dev.md` Phase 6 section.
```

- [ ] **Step 3: Write sink-ddl.md**

```markdown
# Sink 自动建表 (`ensureTargetTable`)

## 行为

Phase 7 起, `SyncTask.init` 在写数据前会自动调用 `MySqlSink.ensureTargetTable`, 用 `CREATE TABLE IF NOT EXISTS db.target_table (...)` 创建目标表.

## 类型映射 (源 → MySQL DDL)

| zetl 列类型 | MySQL DDL 类型 |
|------------|----------------|
| INT / TINY / SHORT | `INT` / `TINYINT` / `SMALLINT` |
| LONGLONG | `BIGINT` |
| FLOAT / DOUBLE | `FLOAT` / `DOUBLE` |
| DECIMAL | `DECIMAL(10,2)` (默认, 见限制) |
| DATETIME / TIMESTAMP | `DATETIME` |
| DATE | `DATE` |
| TIME | `TIME` |
| YEAR | `YEAR` |
| VARCHAR | `VARCHAR(255)` (默认) |
| CHAR | `CHAR(1)` (默认) |
| TEXT / BLOB | `TEXT` / `BLOB` |
| JSON | `JSON` |
| 其他 | `TEXT` (兜底) |

## 默认值

```sql
ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
```

## 已知限制 (Phase 7)

- VARCHAR / CHAR 长度用默认值 (255 / 1), 不能从源 metadata 推断.
- DECIMAL precision/scale 用默认值 (10, 2).
- 不支持 BIT / ENUM / SET / GEOMETRY (Phase 3 未实现).

## 已知限制解除 (Phase 7b, 待实现)

- 从 `SHOW COLUMNS FROM source.table` 解析长度 / precision / scale.
- 兜底: 如果自动 DDL 报错, 用 `TEXT` 兜底重试.

## 幂等性

- `CREATE TABLE IF NOT EXISTS` 是幂等的, 已存在的表**不会**被改 schema.
- 想强制重置: `DROP TABLE union_all_order;` 后重启 zetl.

详见 `dev.md` Phase 7 section.
```

- [ ] **Step 4: Write api-tasks.md**

```markdown
# `/api/tasks/*` REST API

## 端点 (Phase 5 + Phase 8)

| Method | Path | 权限 | 说明 |
|--------|------|------|------|
| GET | `/api/tasks` | `task:read` | 列出所有任务 |
| GET | `/api/tasks/{id}` | `task:read` | 查看单个任务 |
| POST | `/api/tasks` | `task:write` | 创建任务 |
| PUT | `/api/tasks/{id}` | `task:write` | 更新任务 (active 时自动 reload) |
| DELETE | `/api/tasks/{id}` | `task:delete` | 删除任务 (active 时先 stop) |
| POST | `/api/tasks/{id}/reload` | `task:start` | 强制重载 |

## Auth

所有端点都需要 Bearer token:

```bash
curl -H "Authorization: Bearer <token>" http://127.0.0.1:8080/api/tasks
```

- 无 token → `401 Unauthorized`
- viewer token 但缺少权限 → `403 Forbidden`
- admin/operator token → `200/201`

## 例子

### 列出所有任务

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8080/api/tasks | jq '.'
```

### 创建任务

```bash
curl -X POST http://127.0.0.1:8080/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/order-task.json
```

返回 `201 Created` + `{"id": 42, ...}`.

### 启动任务

```bash
curl -X POST http://127.0.0.1:8080/api/tasks/42/reload \
  -H "Authorization: Bearer $TOKEN"
```

### 删除任务

```bash
curl -X DELETE http://127.0.0.1:8080/api/tasks/42 \
  -H "Authorization: Bearer $TOKEN"
```

详见 `dev.md` Phase 5 + Phase 8 section.
```

- [ ] **Step 5: Verify all 4 reference files**

```bash
for f in /Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes/reference/*.md; do
  echo "=== $f ==="
  wc -l "$f"
done
```

Expected: each file ≤ 100 lines.

- [ ] **Step 6: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add docs/ai-recipes/reference/
git commit -m "docs(ai-recipes): 4 reference files (naming/overrides/sink/api)"
```

---

## Task 8: AGENTS.md + dev.md updates

**Files:**
- Modify: `AGENTS.md` (top)
- Modify: `dev.md` (add Phase 9 section)

- [ ] **Step 1: Update AGENTS.md**

Read `AGENTS.md`, then add at the top (after the `# zetl — Agent Instructions` header, before `## 项目概述`):

```markdown
## 业务场景搭建

如果你的任务是 **为一个新的同步场景写 zetl 配置 JSON** (不是改 zetl 自身代码), 先读 `docs/ai-recipes/README.md` 的决策树. 通常读 1 个 recipe + 1-2 个 reference 就够.

如果你的任务是 **改 zetl 自身代码** (加新模块 / 修 bug / 加测试), 按下面的"构建"和"编码约定"继续.
```

- [ ] **Step 2: Update dev.md**

Read `dev.md`, then append a Phase 9 section after the existing Phase 8 section:

```markdown
## Phase 9: AI 速搭文档

新增 `docs/ai-recipes/` 文档树, 面向 AI 编程代理, 让 AI 在 5 分钟内为一个新业务场景写出可运行的 `config_json`.

- `README.md` — 决策树 (订单/用户/商品/多源/自定义)
- `00-task-config-schema.md` — 完整 TaskConfig 字段参考
- `01-quickstart.md` — 5 行 JSON 最小链路
- `recipes/` — 4 个场景模板 (order/user/product/multi-source)
- `reference/` — 4 个速查手册 (naming/overrides/sink/api)

`AGENTS.md` 顶部新增指针: 业务场景搭建先看 `docs/ai-recipes/`, 改 zetl 自身代码按原有约定.

无代码变更. 仅 markdown.
```

- [ ] **Step 3: Verify**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
head -20 AGENTS.md
tail -25 dev.md
```

Expected: AGENTS.md shows the new section near top; dev.md shows Phase 9 at the bottom.

- [ ] **Step 4: Commit**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git add AGENTS.md dev.md
git commit -m "docs: AGENTS.md + dev.md point to ai-recipes"
```

---

## Task 9: Final verification

**Files:**
- All `docs/ai-recipes/` files.

- [ ] **Step 1: List all created files**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
find docs/ai-recipes -type f | sort
```

Expected:
```
docs/ai-recipes/00-task-config-schema.md
docs/ai-recipes/01-quickstart.md
docs/ai-recipes/README.md
docs/ai-recipes/recipes/multi-source-aggregation.md
docs/ai-recipes/recipes/order-sync.md
docs/ai-recipes/recipes/product-sync.md
docs/ai-recipes/recipes/user-sync.md
docs/ai-recipes/reference/api-tasks.md
docs/ai-recipes/reference/sink-ddl.md
docs/ai-recipes/reference/transform-naming.md
docs/ai-recipes/reference/transform-overrides.md
```

11 files.

- [ ] **Step 2: Verify all recipe JSON blocks parse**

```bash
python3 <<'PY'
import re, json, pathlib
ok = True
for f in pathlib.Path('/Users/n0x/w4_proj/zfinal_ws/zetl/docs/ai-recipes').rglob('*.md'):
    content = f.read_text()
    blocks = re.findall(r'```json\n(.*?)\n```', content, re.DOTALL)
    for i, b in enumerate(blocks):
        try:
            json.loads(b)
        except Exception as e:
            print(f"FAIL {f}:{i+1}: {e}")
            ok = False
print("ALL JSON OK" if ok else "SOME FAILED")
PY
```

Expected: `ALL JSON OK`.

- [ ] **Step 3: Verify internal links resolve**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
grep -rEn '\]\([^)]+\.md' docs/ai-recipes/ | while IFS=: read -r file line rest; do
  target=$(echo "$rest" | grep -oE '\]\([^)]+\.md[^)]*\)' | head -1 | sed -E 's/^\]\(//; s/\)$//')
  if [ -n "$target" ]; then
    link_path=$(dirname "$file")/"$target"
    link_path_norm=$(echo "$link_path" | sed -E 's|//|/|g; s|/./|/|g')
    if [ ! -f "$link_path_norm" ]; then
      echo "BROKEN LINK in $file:$line -> $target"
    fi
  fi
done
```

Expected: no `BROKEN LINK` lines.

- [ ] **Step 4: Verify no code changes leaked**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git diff main --stat -- ':!docs/ai-recipes' ':!AGENTS.md' ':!dev.md' ':!docs/superpowers'
```

Expected: empty output (no code changes outside docs).

- [ ] **Step 5: Final commit (if any doc tweaks)**

```bash
cd /Users/n0x/w4_proj/zfinal_ws/zetl
git status
# If uncommitted:
git add docs/ai-recipes/
git commit -m "docs(ai-recipes): post-verification tweaks"
```

Report DONE when finished.

---

## Self-Review Checklist

- [ ] **Spec coverage:**
  - `docs/ai-recipes/README.md` (decision tree) → Task 1
  - `00-task-config-schema.md` (full field reference) → Task 2
  - `01-quickstart.md` (5-line minimum) → Task 3
  - recipes/order-sync.md (mall_id + commission) → Task 4
  - recipes/user-sync.md (mall_id + mask phone) → Task 5
  - recipes/product-sync.md (camel → snake) → Task 6
  - recipes/multi-source-aggregation.md (30 marts) → Task 6
  - reference/transform-naming.md (Phase 6b/6c) → Task 7
  - reference/transform-overrides.md (field_mappings_json) → Task 7
  - reference/sink-ddl.md (Phase 7 auto DDL) → Task 7
  - reference/api-tasks.md (Phase 5 + Phase 8) → Task 7
  - AGENTS.md pointer → Task 8
  - dev.md Phase 9 section → Task 8
  - JSON validation per recipe → Tasks 4-6 + 9
  - Internal link verification → Task 9
- [ ] **No placeholders:** every file has the actual content shown in the plan.
- [ ] **Type / field consistency:** all JSON examples use the same `name`, `sync_mode`, `source.{host,port,user,password,db,table,mall_id}`, `target.{...}`, `transform.{naming_rule, naming_rules, field_mappings_json, commission}`, `sink.{on_conflict, batch_size}` shape across files.