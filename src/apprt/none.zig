const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// For `none` runtime builds, we only support IPC on platforms that have
    /// a separate native app runtime (currently: macOS via the Swift app).
    pub fn performIpc(
        alloc: Allocator,
        target: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) !bool {
        if (builtin.os.tag.isDarwin()) {
            return try apprt.socket.performIpc(alloc, target, action, value);
        }

        return false;
    }
};
pub const Surface = struct {};
