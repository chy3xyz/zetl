下面给出 zetl `/api/tasks` 请求体的全部字段.

每行格式: `字段名: 类型 / 必填 / 默认值 / 示例 / 错误信息`.

---

## 顶层字段 (实际实现, `web/handler/tasks.zig::parseConfigFromJson`)

```
name:         string / 必填 (name 唯一) / 无 / "order-sync-from-mall-001" / "name/source_db/source_table/target_table 必填"
source_db:    string / 必填 / 无 / "mall-001" (对应已注册 datasource 的 mall_id) / 同上
source_table: string / 必填 / 无 / "orders" / 同上
target_table: string / 必填 / 无 / "union_all_order" / 同上
sync_mode:    int / 选填 / 1 / 3 (0=full 1=poll 2=binlog 3=both; 其他值回退 poll)
config_json:  string / 选填 / "{}" / "{\"batch_size\":500}" (嵌套 JSON 字符串, 见下)
status:       int / 选填 / 1 / 1 (0=disabled 1=active; 其他值 → "status 必须是 0 或 1")
```

- 未知字段被忽略 (`ignore_unknown_fields`), 不会报错.
- 源端连接 (host/port/user/password) **不在请求体里** — 先 `POST /api/v1/datasource` 注册,
  `source_db` 填该数据源的 `mall_id`.
- 目标端连接走全局 `config.toml [sink]` 段, 归集库统一.

## `config_json` 内已实现的透传键 (`engine/scheduler.zig::parseV5Overrides`)

任何键解析失败 / 类型非法 → warn + 该键回退默认 (任务照常启动, 不会 400):

```
batch_size:             int / 选填 / 1000 / 500 (有效范围 1..100000)
field_mappings:         string|object|array / 选填 / 无
                        string: 原样作为 overrides JSON 交给 mapper
                        object/array: 自动序列化为 JSON 文本
filter:                 object / 选填 / 无 / {"field":"amount","op":"gte","value":"0"}
                        op ∈ gte|gt|lte|lt|eq|ne, 行级数值过滤 (engine 生效路径)
enable_commission_calc: bool / 选填 / false (佣金计算, 见 order-sync recipe)
transform.naming_rule:  string|object / 选填 / 无 (单规则, 见 reference/transform-naming.md)
transform.naming_rules: array / 选填 / 无 (链式 pipeline, 优先于 naming_rule 单规则)
transform.mask_phone / mask_email / mask_id_card / mask_all: bool / 选填 / false
transform.case_insensitive_fields: bool / 选填 / true
```

`mall_id` 注入: TransformEngine 自动把 datasource 的 `mall_id` 追加到每行, 无需配置.
目标表无需预建: Phase 7 `ensureTargetTable` 按 source schema 自动 `CREATE TABLE IF NOT EXISTS`
(精确 VARCHAR(N)/DECIMAL(P,S), 详见 reference/sink-ddl.md).

---

## `source` 子对象 (⚠️ 规划未实现 — 下方 source/target/sink/schedule 段均为设计稿)

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

## 完整最小例子 (⚠️ 规划结构, 非当前 API — 实际例子见各 recipes/)

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
