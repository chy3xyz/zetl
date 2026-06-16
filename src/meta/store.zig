//! 元数据存储 (SQLite) - 建表与连接管理
//! 严格按 docs/ard.md §1.2

const std = @import("std");
const zfinal = @import("zfinal");

pub const MetaStore = struct {
    allocator: std.mem.Allocator,
    db: zfinal.DB,

    pub fn init(allocator: std.mem.Allocator, sqlite_path: []const u8) !MetaStore {
        const cfg = zfinal.DBConfig.sqlite(sqlite_path);
        const db = try zfinal.DB.init(allocator, cfg);
        var store = MetaStore{ .allocator = allocator, .db = db };
        try store.createAllTables();
        return store;
    }

    pub fn deinit(self: *MetaStore) void {
        self.db.deinit();
    }

    fn migrateSyncPosition(self: *MetaStore) !void {
        var info = try self.db.query("PRAGMA table_info(sync_position)");
        defer info.deinit();
        var has_file = false;
        var has_pos = false;
        while (info.next()) {
            if (info.getCurrentRowMap()) |row| {
                const name = row.get("name") orelse continue;
                if (std.mem.eql(u8, name, "binlog_file")) has_file = true;
                if (std.mem.eql(u8, name, "binlog_pos")) has_pos = true;
            }
        }
        if (!has_file) try self.db.exec("ALTER TABLE sync_position ADD COLUMN binlog_file TEXT NOT NULL DEFAULT ''");
        if (!has_pos) try self.db.exec("ALTER TABLE sync_position ADD COLUMN binlog_pos INTEGER NOT NULL DEFAULT 0");
    }

    pub fn createAllTables(self: *MetaStore) !void {
        // 数据源
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS datasource (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  mall_id TEXT NOT NULL UNIQUE,
            \\  ds_type TEXT NOT NULL DEFAULT 'mysql',
            \\  host TEXT NOT NULL,
            \\  port INTEGER NOT NULL DEFAULT 3306,
            \\  db_name TEXT NOT NULL,
            \\  username TEXT NOT NULL,
            \\  password TEXT NOT NULL,
            \\  remark TEXT,
            \\  status INTEGER NOT NULL DEFAULT 1,
            \\  created_at TEXT DEFAULT (datetime('now')),
            \\  updated_at TEXT DEFAULT (datetime('now'))
            \\)
        );

        // 同步任务
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS sync_task (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  task_name TEXT NOT NULL,
            \\  datasource_id INTEGER NOT NULL,
            \\  source_table TEXT NOT NULL,
            \\  target_table TEXT NOT NULL,
            \\  sync_mode TEXT NOT NULL DEFAULT 'cdc',
            \\  field_mappings TEXT,
            \\  filter_condition TEXT,
            \\  batch_size INTEGER NOT NULL DEFAULT 1000,
            \\  enable_commission_calc INTEGER NOT NULL DEFAULT 0,
            \\  status INTEGER NOT NULL DEFAULT 0,
            \\  last_run_time TEXT,
            \\  last_error TEXT,
            \\  created_at TEXT DEFAULT (datetime('now')),
            \\  FOREIGN KEY (datasource_id) REFERENCES datasource(id)
            \\)
        );

        // 位点 (伪 CDC: last_pk 全量游标 + last_update_time 增量游标; binlog CDC: binlog_file + binlog_pos)
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS sync_position (
            \\  task_id INTEGER PRIMARY KEY,
            \\  last_pk TEXT NOT NULL DEFAULT '',
            \\  last_update_time TEXT NOT NULL DEFAULT '',
            \\  last_event_time TEXT,
            \\  stage TEXT NOT NULL DEFAULT 'full',
            \\  updated_at TEXT DEFAULT (datetime('now')),
            \\  binlog_file TEXT NOT NULL DEFAULT '',
            \\  binlog_pos INTEGER NOT NULL DEFAULT 0,
            \\  FOREIGN KEY (task_id) REFERENCES sync_task(id)
            \\)
        );
        try self.migrateSyncPosition();

        // 运行时指标
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS runtime_metrics (
            \\  task_id INTEGER PRIMARY KEY,
            \\  today_rows INTEGER NOT NULL DEFAULT 0,
            \\  success_count INTEGER NOT NULL DEFAULT 0,
            \\  fail_count INTEGER NOT NULL DEFAULT 0,
            \\  last_error TEXT,
            \\  updated_at TEXT DEFAULT (datetime('now')),
            \\  FOREIGN KEY (task_id) REFERENCES sync_task(id)
            \\)
        );

        // V1 仅建表不写业务 (V2 启用)
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS alarm_config (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  alarm_type TEXT NOT NULL,
            \\  threshold TEXT,
            \\  webhook_url TEXT NOT NULL,
            \\  is_enabled INTEGER NOT NULL DEFAULT 1
            \\)
        );
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS operation_log (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  operator TEXT NOT NULL,
            \\  op_type TEXT NOT NULL,
            \\  op_target TEXT NOT NULL,
            \\  op_detail TEXT,
            \\  ip TEXT,
            \\  created_at TEXT DEFAULT (datetime('now'))
            \\)
        );
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS reconcile_record (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  mall_id TEXT NOT NULL,
            \\  table_name TEXT NOT NULL,
            \\  source_count INTEGER NOT NULL,
            \\  target_count INTEGER NOT NULL,
            \\  diff_count INTEGER NOT NULL,
            \\  source_amount REAL,
            \\  target_amount REAL,
            \\  diff_amount REAL,
            \\  reconcile_time TEXT DEFAULT (datetime('now')),
            \\  is_abnormal INTEGER NOT NULL DEFAULT 0
            \\)
        );

        // V2.2 鉴权表
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS role (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  role_name TEXT NOT NULL UNIQUE,
            \\  description TEXT,
            \\  created_at TEXT DEFAULT (datetime('now'))
            \\)
        );
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS user (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  username TEXT NOT NULL UNIQUE,
            \\  password_hash TEXT NOT NULL,
            \\  display_name TEXT,
            \\  email TEXT,
            \\  is_active INTEGER NOT NULL DEFAULT 1,
            \\  must_change_password INTEGER NOT NULL DEFAULT 0,
            \\  created_at TEXT DEFAULT (datetime('now')),
            \\  last_login_at TEXT
            \\)
        );
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS user_role (
            \\  user_id INTEGER NOT NULL,
            \\  role_id INTEGER NOT NULL,
            \\  PRIMARY KEY (user_id, role_id),
            \\  FOREIGN KEY (user_id) REFERENCES user(id),
            \\  FOREIGN KEY (role_id) REFERENCES role(id)
            \\)
        );
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS role_permission (
            \\  role_id INTEGER NOT NULL,
            \\  permission TEXT NOT NULL,
            \\  PRIMARY KEY (role_id, permission),
            \\  FOREIGN KEY (role_id) REFERENCES role(id)
            \\)
        );
    }
};
