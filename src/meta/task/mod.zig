//! 同步任务模块 — V5 收敛后唯一任务系统 (tasks_config 表)
//! legacy V1 sync_task model/service 已移除 (2026-11-21)
//!   - `SyncMode`  → 同步模式枚举 (full/poll/binlog/both), scheduler/runtime 使用
//!   - `config`    → `TaskConfig` / `TaskActiveStatus`
//!   - `service`   → V5 Service 命名空间 (create/getById/list/update/delete/setStatus)

const std = @import("std");
const zfinal = @import("zfinal");
const store_mod = @import("../store.zig");

// V5: 暴露给 Scheduler / Web handler 使用.
pub const config = @import("config.zig");
pub const service = @import("service.zig");

pub const SyncMode = enum {
    full,
    poll,
    binlog,
    both,

    pub fn toString(s: SyncMode) []const u8 {
        return switch (s) {
            .full => "full",
            .poll => "poll",
            .binlog => "binlog",
            .both => "both",
        };
    }
};
