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
