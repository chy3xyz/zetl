# zetl — Multi-Source MySQL Aggregation ETL Engine

A lightweight data aggregation engine that consolidates tables from multiple MySQL sources into a single sink database, built on [Zig 0.17](https://ziglang.org) and the [zfinal](https://github.com/chy3xyz/zfinal) framework.

[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange)](https://ziglang.org)
[![zfinal](https://img.shields.io/badge/zfinal-v0.28.11-blue)](https://github.com/chy3xyz/zfinal)
[![Tests](https://img.shields.io/badge/tests-262%20passing-brightgreen)](#testing)

```
source MySQL ──> Poller (PK pagination / update_time) or Binlog reader ──> RowEvent
    ──> TransformEngine (mapping + defaults + filters + naming + commission + masking) ──> RowData
    ──> MySqlSink (batched INSERT ... ON DUPLICATE KEY UPDATE) ──> sink MySQL
```

## Features

- **Single-binary deployment** — ~4.8 MB (ReleaseSafe), bundles the web UI, REST API and ETL engine
- **Multi-source aggregation** — many business databases → one sink database
- **Three sync modes** — `poll` (PK pagination for full + `update_time` for incremental), `binlog` (real CDC, tombstone-aware), or `both` (full backfill then incremental)
- **Automatic schema handling** — source columns discovered via `SHOW COLUMNS`, target table auto-created with exact `VARCHAR(N)` / `DECIMAL(P,S)` types and an idempotent `(mall_id, pk)` unique key
- **Transform pipeline** — field mapping with defaults and type overrides, column naming rules (`camel_to_snake`, prefix, regex replace, chained), row filters, tiered commission calculation, PII masking (phone / email / id-card)
- **Idempotent writes** — batched upserts, safe to re-run
- **Scheduled reconciliation** — cron-driven row/amount diff between source and sink, CSV export
- **Alerting** — generic webhook + WeCom Markdown, 5-minute cooldown
- **Prometheus metrics** — `/metrics`, liveness and readiness probes
- **Audit log** — every write operation recorded
- **RBAC** — admin / operator / viewer roles, per-endpoint permissions
- **Embedded UI** — HTMX + Alpine.js admin console, single embedded HTML

## AI-Assisted Setup

Want to wire up a new sync scenario? The [docs/ai-recipes/](docs/ai-recipes/) decision tree helps an AI coding agent produce a runnable task config JSON in about 5 minutes:

- 4 scenario recipes (orders / users / products / multi-source)
- 4 quick references (naming rules / field overrides / sink DDL / Task API)
- Full `TaskConfig` field reference

## Quick Start

Prerequisites: Zig 0.17.0, a MySQL 8.x sink (libmysqlclient), SQLite 3.

```bash
# Build (SQLite only, no MySQL needed — used for unit tests)
zig build

# Full build with the MySQL sink driver
zig build -Ddriver_mysql=true

# Run
./zig-out/bin/zetl

# Unit tests
zig build test
zig build -Ddriver_mysql=true test
```

## Configuration

Edit `config.toml`:

```toml
[server]
host = "0.0.0.0"
port = 18080

# Bootstrap admin account (created on first run)
[meta]
sqlite_path = "zetl_meta.db"
admin_username = "admin"
admin_password = "admin123"

[sink]
host = "127.0.0.1"
port = 3306
database = "zetl_sink"
username = "root"
password = ""
pool_size = 8
batch_size = 100
flush_interval_ms = 500

[engine]
full_sync_sleep_ms = 100
incremental_poll_ms = 2000
max_retries = 3

[log]
level = "info"

[reconcile]
enabled = true
# @hourly / @daily / @weekly / @monthly / @yearly, or a 5-field cron
cron_expr = "0 2 * * *"
poll_interval_s = 60
```

## API (32 endpoints)

```
Public:
  GET  /health                    Health check
  GET  /health/live               Liveness probe
  GET  /health/ready              Readiness probe
  GET  /metrics                   Prometheus metrics
  POST /api/v1/auth/login         Login (returns Bearer token)
  POST /api/v1/auth/logout        Logout

Protected (Bearer token):
  GET  /api/v1/auth/me                     Current user
  GET  /api/v1/user                        List users
  POST /api/v1/user                        Create user
  GET  /api/v1/role                        List roles
  POST /api/v1/datasource                  Register source
  POST /api/v1/datasource/test             Test connection
  GET  /api/v1/datasource/list             List sources
  DELETE /api/v1/datasource/:id            Delete source
  GET  /api/tasks                          List tasks
  POST /api/tasks                          Create task (config JSON)
  GET  /api/tasks/:id                      Task detail
  PUT  /api/tasks/:id                      Update task (auto-reload)
  DELETE /api/tasks/:id                    Delete task (stops if active)
  POST /api/tasks/:id/reload               Reload (rebuild + start)
  POST /api/tasks/:id/stop                 Stop instance, keep config
  GET  /api/v1/monitor/overview            Fleet overview
  GET  /api/v1/monitor/task/:id            Per-task metrics
  POST /api/v1/reconcile/run               Trigger reconciliation
  GET  /api/v1/reconcile/list              Reconciliation records
  GET  /api/v1/reconcile/:id               Record detail
  GET  /api/v1/reconcile/:id/export        Export diff as CSV
  GET  /api/v1/alarm/config                List alarm rules
  POST /api/v1/alarm/config                Create alarm rule
  DELETE /api/v1/alarm/config/:id          Delete alarm rule
  POST /api/v1/alarm/test                  Send test alert
  GET  /api/v1/audit/list                  Audit log
```

The admin UI is served at `/` and `/admin/*`.

## E2E Walkthrough

```bash
# 1. Create databases (source holds your business tables, sink is created by zetl)
mysql -u root -e "CREATE DATABASE IF NOT EXISTS zetl_source; CREATE DATABASE IF NOT EXISTS zetl_sink;"

# 2. Start zetl with the E2E config
./zig-out/bin/zetl

# 3. Log in and grab a token
TOKEN=$(curl -sS -X POST -d '{"username":"admin","password":"admin123"}' \
  http://127.0.0.1:18080/api/v1/auth/login | jq -r '.data.token')

# 4. Register a source, create a task, start it
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -d '{"mall_id":"mall_001","host":"127.0.0.1","port":3306,"db_name":"zetl_source","username":"root","password":""}' \
  http://127.0.0.1:18080/api/v1/datasource

curl -X POST -H "Authorization: Bearer $TOKEN" \
  -d '{"task_name":"orders","source_table":"t_order","target_table":"t_order","sync_mode":"both"}' \
  http://127.0.0.1:18080/api/v1/task

curl -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18080/api/v1/task/1/start

# 5. Verify
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18080/api/v1/monitor/overview
```

## Testing

262 unit tests across transform (69), CDC (47), auth (25), engine (22), reconcile (19), alarm (15), web (15), sink (14), meta (8) and others — green on both SQLite and MySQL builds. A live MySQL pool regression test (child-thread acquire path) runs when `ZETL_LIVE_MYSQL=1` is set and skips otherwise.

## Project Structure

```
src/
├── main.zig                Entry point
├── config.zig              TOML config parsing
├── common/                 Logging, crypto
├── meta/                   Metadata store (SQLite): datasources, tasks, positions, metrics
│   └── task/               V1 sync_task model + V5 tasks_config (config/service)
├── cdc/                    Ingestion: poller (pseudo-CDC), binlog reader + parser + decoder
├── transform/              Mapper, naming rules, commission, pipeline engine
├── sink/                   Idempotent batched MySQL writer, auto DDL
├── engine/                 Task runtime, multi-task scheduler
├── web/                    HTTP layer
│   ├── routes.zig          All route registrations
│   ├── deps.zig            Global dependencies
│   ├── auth_middleware.zig Auth + permission interceptors
│   ├── response.zig        Unified response envelope
│   └── handler/            ALL HTTP handlers (auth, datasource, task, tasks, monitor, alarm, audit, reconcile)
├── reconcile/              Reconciliation services: summary, cron scheduler
├── alarm/                  Alert rules, triggers, webhooks
├── metrics/                Prometheus exporter
├── audit/                  Audit trail service
├── auth/                   Users, roles, RBAC, bcrypt
└── assets/
    └── index.html          Admin UI (embedded)
```

## Dependencies

- [zfinal](https://github.com/chy3xyz/zfinal) v0.28.11 — web framework, DB drivers, token management (pinned via git+https in `build.zig.zon`; pulls in zent v0.78.0 transitively)
- Zig 0.17.0 — compiler and standard library (required by zfinal v0.28.1+)
- MySQL 8.x — sink database (libmysqlclient)
- SQLite 3 — metadata store (system library)

## License

MIT
