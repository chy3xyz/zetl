# zetl — Agent Instructions

## 项目概述

zetl 是一个基于 Zig 0.17 + zfinal v0.10.4 的多源 MySQL 数据归集 ETL 引擎。

- **框架**: zfinal 0.10.4 (Web + DB + Token 管理)
- **编译器**: Zig 0.17-dev.813
- **架构**: 6 大模块 — common/meta/cdc/transform/sink/engine/web
- **V2 新增**: reconcile / alarm / metrics / audit / auth (共 13 模块)

## 构建

```bash
# SQLite 模式 (单元测试, 单测)
zig build

# MySQL 模式 (完整构建, 需要 libmysqlclient)
zig build -Ddriver_mysql=true

# 运行所有测试
zig build test
zig build -Ddriver_mysql=true test

# 运行
zig build run -Ddriver_mysql=true
# 或
./zig-out/bin/zetl
```

## 编码约定

### 核心 API (zfinal)
```zig
// 路由注册
app.get(path, handler)           // 无鉴权
app.getWithInterceptors(path, handler, &interceptors)  // 带拦截器

// 上下文操作
ctx.renderJson(data)             // 序列化任意类型到 JSON
ctx.parseJsonBody(T)             // 解析请求体
ctx.getPathParam("id")           // 路径参数
ctx.getHeader("Authorization")   // 请求头

// 数据库
zfinal.DB.init(allocator, config)           // 单连接
zfinal.ConnectionPool.init(allocator, config, N)  // 连接池 (v0.10.4 返回 *ConnectionPool)
pool.acquire() / pool.release(conn)         // 获取/归还连接
```

### RowData 所有权
`transform.engine.freeRowData(allocator, &row)` — 释放 HashMap 内所有 key/value 并 deinit。必须对所有 process() 返回的 RowData 调用。

### PollerConfig
使用 `PollerConfig.fromSlices(host, port, user, pass, db, table, pk, ut, batch)` 创建，内部是 fixed-size buffers (`@splat(0)`)。

### 线程安全
- zfinal `ConnectionPool` 在主线程创建后、通过 `*ConnectionPool` 指针传入子线程 — v0.10.4 API。
- **池的 DBConfig 字符串必须堆分配**（不能引用栈），由 `SyncTask._sh/_sd/_su/_sp` 持有寿命。

### 字符串寿命
```zig
// ❌ 错误: 栈 buffer, startTask 返回后失效
var buf: [64]u8 = undefined;
const cfg = .{ .host = buf[0..len:0] }; // 指向栈

// ✅ 正确: 堆分配, SyncTask 持有
const host = try allocator.dupe(u8, ds.host);
const cfg = .{ .host = host }; // 指向堆
```

## 数据流

```
源 MySQL ─→ Poller(主键分页/update_time) ─→ RowEvent
  ─→ TransformEngine(字段映射+常量+过滤+佣金) ─→ RowData
  ─→ MySqlSink(批量 INSERT...ON DUPLICATE KEY) ─→ 归集 MySQL
```

## 已知问题

1. **任务线程 MySQL 连接** (`Lost connection at 'reading initial communication packet'`):
   - `DB.init` 在子线程首行可用，但从 `ConnectionPool.acquire` 路径失败
   - 主线程 API (testConnection) 100% 可靠
   - 原因: Zig 0.17-dev 在 aarch64-macos 上的线程局部存储与 mysql C 库交互问题
   - 进度: zfinal v0.10.4 修复了 mutex 拷贝 (#1), 但 acquire 路径仍有问题

2. **TokenManager validate() 死锁**: V2 绕过，logout 靠客户端丢 token + 服务端 TTL

## 测试

```
31 个单元测试覆盖:
  crypto (2) / mapper (5) / commission (6) / engine (2)
  sink (10) / meta (1) / poller (1) / web (1) / config (1)
  main (2)

SQLite + MySQL 双构建通过
```
