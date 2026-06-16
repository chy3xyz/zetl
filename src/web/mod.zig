pub const deps_mod = @import("deps.zig");
pub const routes = @import("routes.zig");
pub const response = @import("response.zig");
pub const auth_middleware = @import("auth_middleware.zig");
pub const handler = struct {
    pub const auth = @import("handler/auth.zig");
    pub const datasource = @import("handler/datasource.zig");
    pub const task = @import("handler/task.zig");
    pub const monitor = @import("handler/monitor.zig");
};
