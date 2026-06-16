-- ============================================================
-- zetl V1 数据库建表脚本
-- 1) 元数据: SQLite 单文件 zetl_meta.db
-- 2) 业务归集: MySQL/PolarDB MySQL, 库名 zetl_sink
--    (与 docs/ard.md §1.1 完全一致)
-- ============================================================

-- ---------- 1. 业务归集库 (MySQL) ----------
-- 在 MySQL 客户端执行 (建库 + 4 张业务表)

-- CREATE DATABASE IF NOT EXISTS zetl_sink
--   DEFAULT CHARACTER SET utf8mb4
--   DEFAULT COLLATE utf8mb4_unicode_ci;

-- USE zetl_sink;

-- 全渠道订单归集表
CREATE TABLE IF NOT EXISTS `union_all_order` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `mall_id` varchar(32) NOT NULL,
  `order_no` varchar(64) NOT NULL,
  `agent_id` varchar(32) DEFAULT NULL,
  `order_total` decimal(12,2) NOT NULL DEFAULT '0.00',
  `agent_commission` decimal(12,2) NOT NULL DEFAULT '0.00',
  `commission_rate` decimal(6,4) NOT NULL DEFAULT '0.0000',
  `order_status` tinyint NOT NULL DEFAULT '0',
  `pay_time` datetime DEFAULT NULL,
  `source_create_time` datetime NOT NULL,
  `source_update_time` datetime NOT NULL,
  `sync_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `sync_type` tinyint NOT NULL DEFAULT '1',
  `is_delete` tinyint NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_mall_order` (`mall_id`,`order_no`),
  KEY `idx_agent_id` (`agent_id`),
  KEY `idx_pay_time` (`pay_time`),
  KEY `idx_sync_time` (`sync_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 全渠道用户归集表
CREATE TABLE IF NOT EXISTS `union_all_user` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `mall_id` varchar(32) NOT NULL,
  `user_id` varchar(64) NOT NULL,
  `agent_id` varchar(32) DEFAULT NULL,
  `phone` varchar(32) DEFAULT NULL,
  `nickname` varchar(64) DEFAULT NULL,
  `register_time` datetime DEFAULT NULL,
  `sync_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `is_delete` tinyint NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_mall_user` (`mall_id`,`user_id`),
  KEY `idx_agent_id` (`agent_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 异常脏数据表
CREATE TABLE IF NOT EXISTS `error_order` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `mall_id` varchar(32) NOT NULL,
  `order_no` varchar(64) NOT NULL,
  `raw_data` json DEFAULT NULL,
  `error_type` varchar(32) NOT NULL,
  `error_msg` varchar(512) DEFAULT NULL,
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `retry_count` tinyint NOT NULL DEFAULT '0',
  `is_resolved` tinyint NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  KEY `idx_mall_id` (`mall_id`),
  KEY `idx_create_time` (`create_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 代理商佣金规则
CREATE TABLE IF NOT EXISTS `agent_commission_rule` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `agent_id` varchar(32) NOT NULL,
  `mall_id` varchar(32) NOT NULL DEFAULT '*',
  `commission_rate` decimal(6,4) NOT NULL,
  `min_amount` decimal(12,2) NOT NULL DEFAULT '0.00',
  `max_amount` decimal(12,2) NOT NULL DEFAULT '999999.00',
  `status` tinyint NOT NULL DEFAULT '1',
  `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_agent_mall` (`agent_id`,`mall_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------- 2. 元数据 (SQLite, 由 src/meta/store.zig 自动建表) ----------
-- 元数据表结构与 docs/ard.md §1.2 一致
-- 表: datasource / sync_task / sync_position / alarm_config / operation_log / reconcile_record / runtime_metrics

-- 同步位点 (V3 binlog CDC 扩展 binlog_file + binlog_pos)
CREATE TABLE IF NOT EXISTS sync_position (
  task_id INTEGER PRIMARY KEY,
  last_pk TEXT NOT NULL DEFAULT '',
  last_update_time TEXT NOT NULL DEFAULT '',
  last_event_time TEXT,
  stage TEXT NOT NULL DEFAULT 'full',
  updated_at TEXT DEFAULT (datetime('now')),
  binlog_file TEXT NOT NULL DEFAULT '',
  binlog_pos INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (task_id) REFERENCES sync_task(id)
);

-- 已部署数据库的列迁移由 src/meta/store.zig 自动处理 (V3 binlog CDC)
-- ALTER TABLE sync_position ADD COLUMN binlog_file TEXT NOT NULL DEFAULT '';
-- ALTER TABLE sync_position ADD COLUMN binlog_pos INTEGER NOT NULL DEFAULT 0;
