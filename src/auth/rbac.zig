//! RBAC 中间件
const std = @import("std");
const zfinal = @import("zfinal");
const role_mod = @import("role.zig");
const meta = @import("../meta/mod.zig");
const web_deps = @import("../web/deps.zig");
const response = @import("../web/response.zig");

pub fn hasPermission(ctx: *zfinal.Context, store: *meta.store.MetaStore, uid: i64, required: []const u8) bool {
    if (required.len == 0) return true;
    const all = role_mod.getUserPermissions(store, ctx.allocator, uid) catch return false;
    defer ctx.allocator.free(all);
    if (std.mem.eql(u8, all, "*")) return true;
    var it = std.mem.splitScalar(u8, all, ',');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " ");
        if (std.mem.eql(u8, t, required)) return true;
        if (t.len > 1 and t[t.len-1] == ':' and std.mem.startsWith(u8, required, t)) return true;
    }
    return false;
}
