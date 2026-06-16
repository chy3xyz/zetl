//! zetl 运行配置 - 加载与解析 config.toml
//! 实现一个最小化的 TOML 解析器（不依赖外部库，覆盖本项目用到的子集）

const std = @import("std");

pub const Config = struct {
    server: ServerConfig,
    meta: MetaConfig,
    sink: SinkConfig,
    engine: EngineConfig,
    log: LogConfig,
    reconcile: ReconcileConfig,

    pub const ServerConfig = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 8080,
    };

    pub const MetaConfig = struct {
        sqlite_path: []const u8 = "zetl_meta.db",
        admin_username: []const u8 = "admin",
        admin_password: []const u8 = "admin123",
    };

    pub const SinkConfig = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 3306,
        database: []const u8 = "zetl_sink",
        username: []const u8 = "root",
        password: []const u8 = "",
        pool_size: u32 = 8,
        batch_size: usize = 1000,
        flush_interval_ms: u64 = 1000,
        max_qps: u32 = 0,
    };

    pub const EngineConfig = struct {
        full_sync_sleep_ms: u64 = 50,
        incremental_poll_ms: u64 = 1000,
        max_retries: u32 = 3,
    };

    pub const LogConfig = struct {
        level: []const u8 = "info",
    };

    /// 对账 cron 配置 (V2.1+)
    /// enabled = false 时, 后台线程不启动, 仅依赖手动 API 触发
    /// cron_expr 支持 @hourly/@daily/@weekly/@monthly/@yearly 或 5 字段标准 cron
    pub const ReconcileConfig = struct {
        enabled: bool = true,
        cron_expr: []const u8 = "@daily",
        poll_interval_s: u64 = 60,
    };

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.server.host);
        allocator.free(self.meta.sqlite_path);
        allocator.free(self.meta.admin_username);
        allocator.free(self.meta.admin_password);
        allocator.free(self.sink.host);
        allocator.free(self.sink.database);
        allocator.free(self.sink.username);
        allocator.free(self.sink.password);
        allocator.free(self.log.level);
        allocator.free(self.reconcile.cron_expr);
    }
};

/// 加载配置文件. 若文件不存在则返回默认值.
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    var cfg: Config = .{ .server = .{}, .meta = .{}, .sink = .{}, .engine = .{}, .log = .{}, .reconcile = .{} };

    const zfinal = @import("zfinal");
    const io = zfinal.io_instance.io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.warn("config.toml not found, using defaults", .{});
            return cfg;
        },
        else => return err,
    };
    defer allocator.free(content);

    var p: usize = 0;
    while (p < content.len) {
        skipWs(content, &p);
        if (p >= content.len) break;
        if (content[p] != '[') {
            while (p < content.len and content[p] != '\n') p += 1;
            continue;
        }
        p += 1;
        const section_start = p;
        while (p < content.len and content[p] != ']') p += 1;
        const section = std.mem.trim(u8, content[section_start..p], " \t\r\n");
        p += 1;
        try parseSection(section, &cfg, allocator, content, &p);
    }

    return cfg;
}

fn skipWs(content: []const u8, p: *usize) void {
    while (p.* < content.len) {
        const c = content[p.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            p.* += 1;
        } else if (c == '#') {
            while (p.* < content.len and content[p.*] != '\n') p.* += 1;
        } else break;
    }
}

fn readBareword(content: []const u8, p: *usize) []const u8 {
    const start = p.*;
    while (p.* < content.len) {
        const c = content[p.*];
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t' or c == '#' or c == ']' or c == '[') break;
        p.* += 1;
    }
    return content[start..p.*];
}

fn parseSection(section: []const u8, cfg: *Config, allocator: std.mem.Allocator, content: []const u8, p: *usize) !void {
    if (std.mem.eql(u8, section, "server")) {
        try parseKVSection(content, p, cfg, allocator, ServerApplier.apply);
    } else if (std.mem.eql(u8, section, "meta")) {
        try parseKVSection(content, p, cfg, allocator, MetaApplier.apply);
    } else if (std.mem.eql(u8, section, "sink")) {
        try parseKVSection(content, p, cfg, allocator, SinkApplier.apply);
    } else if (std.mem.eql(u8, section, "engine")) {
        try parseKVSection(content, p, cfg, allocator, EngineApplier.apply);
    } else if (std.mem.eql(u8, section, "log")) {
        try parseKVSection(content, p, cfg, allocator, LogApplier.apply);
    } else if (std.mem.eql(u8, section, "reconcile")) {
        try parseKVSection(content, p, cfg, allocator, ReconcileApplier.apply);
    } else {
        // 跳过未知段
        while (p.* < content.len) {
            skipWs(content, p);
            if (p.* >= content.len) break;
            if (content[p.*] == '[') break;
            _ = readBareword(content, p);
            while (p.* < content.len and content[p.*] != '\n') p.* += 1;
        }
    }
}

const ApplyFn = fn (allocator: std.mem.Allocator, key: []const u8, value: []const u8, cfg: *Config) anyerror!void;

const ServerApplier = struct {
    fn apply(allocator: std.mem.Allocator, k: []const u8, v: []const u8, c: *Config) !void {
        if (std.mem.eql(u8, k, "host")) c.server.host = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "port")) c.server.port = @intCast(try std.fmt.parseInt(u16, v, 10));
    }
};

const MetaApplier = struct {
    fn apply(allocator: std.mem.Allocator, k: []const u8, v: []const u8, c: *Config) !void {
        if (std.mem.eql(u8, k, "sqlite_path")) c.meta.sqlite_path = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "admin_username")) c.meta.admin_username = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "admin_password")) c.meta.admin_password = try allocator.dupe(u8, v);
    }
};

const SinkApplier = struct {
    fn apply(allocator: std.mem.Allocator, k: []const u8, v: []const u8, c: *Config) !void {
        if (std.mem.eql(u8, k, "host")) c.sink.host = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "port")) c.sink.port = @intCast(try std.fmt.parseInt(u16, v, 10));
        if (std.mem.eql(u8, k, "database")) c.sink.database = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "username")) c.sink.username = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "password")) c.sink.password = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "pool_size")) c.sink.pool_size = @intCast(try std.fmt.parseInt(u32, v, 10));
        if (std.mem.eql(u8, k, "batch_size")) c.sink.batch_size = @intCast(try std.fmt.parseInt(usize, v, 10));
        if (std.mem.eql(u8, k, "flush_interval_ms")) c.sink.flush_interval_ms = @intCast(try std.fmt.parseInt(u64, v, 10));
        if (std.mem.eql(u8, k, "max_qps")) c.sink.max_qps = @intCast(try std.fmt.parseInt(u32, v, 10));
    }
};

const EngineApplier = struct {
    fn apply(_: std.mem.Allocator, k: []const u8, v: []const u8, c: *Config) !void {
        if (std.mem.eql(u8, k, "full_sync_sleep_ms")) c.engine.full_sync_sleep_ms = @intCast(try std.fmt.parseInt(u64, v, 10));
        if (std.mem.eql(u8, k, "incremental_poll_ms")) c.engine.incremental_poll_ms = @intCast(try std.fmt.parseInt(u64, v, 10));
        if (std.mem.eql(u8, k, "max_retries")) c.engine.max_retries = @intCast(try std.fmt.parseInt(u32, v, 10));
    }
};

const LogApplier = struct {
    fn apply(allocator: std.mem.Allocator, k: []const u8, v: []const u8, c: *Config) !void {
        if (std.mem.eql(u8, k, "level")) c.log.level = try allocator.dupe(u8, v);
    }
};

const ReconcileApplier = struct {
    fn apply(allocator: std.mem.Allocator, k: []const u8, v: []const u8, c: *Config) !void {
        if (std.mem.eql(u8, k, "enabled")) {
            c.reconcile.enabled = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, k, "cron_expr")) {
            c.reconcile.cron_expr = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "poll_interval_s")) {
            c.reconcile.poll_interval_s = @intCast(try std.fmt.parseInt(u64, v, 10));
        }
    }
};

fn parseKVSection(content: []const u8, p: *usize, cfg: *Config, allocator: std.mem.Allocator, applyFn: ApplyFn) !void {
    while (true) {
        skipWs(content, p);
        if (p.* >= content.len) break;
        if (content[p.*] == '[') break;
        const key = readBareword(content, p);
        skipWs(content, p);
        if (p.* >= content.len or content[p.*] != '=') {
            while (p.* < content.len and content[p.*] != '\n') p.* += 1;
            continue;
        }
        p.* += 1;
        skipWs(content, p);
        const val_start = p.*;
        while (p.* < content.len and content[p.*] != '\n' and content[p.*] != '#') p.* += 1;
        var end = p.*;
        while (end > val_start and (content[end - 1] == ' ' or content[end - 1] == '\t' or content[end - 1] == '\r')) end -= 1;
        var val_slice = content[val_start..end];
        if (val_slice.len >= 2 and val_slice[0] == '"' and val_slice[val_slice.len - 1] == '"') {
            val_slice = val_slice[1 .. val_slice.len - 1];
        }
        try applyFn(allocator, key, val_slice, cfg);
    }
}

test "parse config default" {
    const a = std.testing.allocator;
    const cfg = try loadConfig(a, "config.toml");
    var mutable = cfg;
    defer mutable.deinit(a);
    // 端口不写死, 只断言 > 0
    try std.testing.expect(cfg.server.port > 0);
    try std.testing.expectEqualStrings("admin", cfg.meta.admin_username);
}

test "parse config reconcile section" {
    const a = std.testing.allocator;
    const cfg = try loadConfig(a, "config.toml");
    var mutable = cfg;
    defer mutable.deinit(a);
    // 配置文件无 [reconcile] 段时应使用默认值
    try std.testing.expect(cfg.reconcile.poll_interval_s > 0);
    try std.testing.expect(cfg.reconcile.cron_expr.len > 0);
}
