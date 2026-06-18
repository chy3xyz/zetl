//! tasks_config Service 命名空间 (V5 Phase 5)
//!
//! Phase 5 Task 1: 仅放 `Service` 空结构作为占位, 让 plan 指定的 file path 存在.
//!   - schema 实际由 `meta.store.MetaStore.createAllTables()` 集中创建 (与本仓库
//!     其他表保持一致: DDL 在 store.zig, 业务表对应 Service 在 meta/ 各文件).
//!   - 真正的 CRUD 方法 (insert/findAll/updateStatus/deleteById) 在
//!     Phase 5 Task 2 中追加.

const std = @import("std");

pub const config_mod = @import("config.zig");
pub const TaskConfig = config_mod.TaskConfig;
pub const TaskActiveStatus = config_mod.TaskActiveStatus;

/// tasks_config 表的 Service 命名空间.
/// 真正的 CRUD 方法在 Phase 5 Task 2 中追加; 当前仅保证 plan 指定的 file path 存在.
pub const Service = struct {
    // Task 2 将追加:
    //   pub fn insert(...) !i64 { ... }
    //   pub fn findAll(...) ![]TaskConfig { ... }
    //   pub fn updateStatus(...) !void { ... }
    //   pub fn deleteById(...) !void { ... }
};
