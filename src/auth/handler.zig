//! 鉴权 REST API - V2.2
const std = @import("std");
const zfinal = @import("zfinal");
const au = @import("user.zig");
const ar = @import("role.zig");
const web_deps = @import("../web/deps.zig");
const response = @import("../web/response.zig");

/// POST /api/v1/auth/login (V2 改造)
pub fn loginV2(ctx: *zfinal.Context) !void {
    const p = ctx.parseJsonBody(struct { username: []const u8, password: []const u8 }) catch { try response.fail(ctx, .param_error, "请求体不合法"); return; };
    defer p.deinit();
    const v = p.value;
    if (au.verifyUserPassword(web_deps.store_ptr, v.username, v.password)) {
        au.updateLoginTime(web_deps.store_ptr, v.username) catch {};
        const t = try web_deps.tokenMgr.generate();
        try response.ok(ctx, .{.token=t,.expires_in=3600,.username=v.username});
        return;
    }
    // fallback V1 admin
    if (std.mem.eql(u8, v.username, web_deps.config_ptr.meta.admin_username) and std.mem.eql(u8, v.password, web_deps.config_ptr.meta.admin_password)) {
        const t = try web_deps.tokenMgr.generate();
        try response.ok(ctx, .{.token=t,.expires_in=3600,.username=v.username});
        return;
    }
    try response.fail(ctx, .permission_denied, "账号或密码错误");
}

pub fn listUsers(ctx: *zfinal.Context) !void {
    const a = ctx.allocator;
    const us = au.findAll(web_deps.store_ptr, a) catch |err| { try response.fail(ctx, .system_error, @errorName(err)); return; };
    defer { for (us) |*u| u.deinit(a); a.free(us); }
    const It = struct { id: i64, username: []const u8, display_name: []const u8, email: []const u8, is_active: i32, created_at: []const u8, last_login_at: []const u8 };
    var items = try a.alloc(It, us.len); defer a.free(items);
    for (us, 0..) |u, i| items[i] = .{.id=u.id,.username=u.username,.display_name=u.display_name,.email=u.email,.is_active=u.is_active,.created_at=u.created_at,.last_login_at=u.last_login_at};
    try response.ok(ctx, .{.total=@as(i64,@intCast(us.len)),.list=items});
}

pub fn createUser(ctx: *zfinal.Context) !void {
    const a = ctx.allocator;
    const p = ctx.parseJsonBody(struct { username: []const u8, password: []const u8, display_name: []const u8="", email: []const u8="" }) catch { try response.fail(ctx, .param_error, "请求体不合法"); return; };
    defer p.deinit(); const v = p.value;
    const id = au.createUser(web_deps.store_ptr, a, v.username, v.password, v.display_name, v.email) catch |err| { try response.fail(ctx, .system_error, @errorName(err)); return; };
    try response.ok(ctx, .{.id=id,.username=v.username});
}

pub fn listRoles(ctx: *zfinal.Context) !void {
    const a = ctx.allocator;
    var r = web_deps.store_ptr.db.query("SELECT id, role_name, COALESCE(description,'') d FROM role") catch |err| { try response.fail(ctx, .system_error, @errorName(err)); return; };
    defer r.deinit();
    const It = struct { id: i64, role_name: []const u8, description: []const u8 };
    var items = std.ArrayList(It).empty; defer items.deinit(a);
    while (r.next()) { if (r.getCurrentRowMap()) |rm| try items.append(a, .{.id=try std.fmt.parseInt(i64,rm.get("id") orelse "0",10),.role_name=try a.dupe(u8,rm.get("role_name") orelse ""),.description=try a.dupe(u8,rm.get("d") orelse "")}); }
    try response.ok(ctx, .{.total=@as(i64,@intCast(items.items.len)),.list=items.items});
}
