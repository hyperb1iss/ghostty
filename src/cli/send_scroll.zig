const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, query a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    /// The surface ID to scroll.
    surface: ?[:0]const u8 = null,

    /// Horizontal scroll delta (positive = right, negative = left).
    x: f64 = 0,

    /// Vertical scroll delta (positive = down, negative = up).
    y: f64 = 0,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `send-scroll` command sends a scroll event to a specific surface in a
/// running Ghostty instance.
///
/// Use `+list-surfaces` to discover surface IDs, then use those IDs to
/// target specific terminals for scroll input.
///
/// Flags:
///
///   * `--class=<class>`: Target a custom instance of Ghostty.
///
///   * `--surface=<id>`: The surface ID to scroll (required).
///       Get surface IDs from `+list-surfaces`.
///
///   * `--y=<delta>`: Vertical scroll delta (default: 0).
///       Positive = down, negative = up.
///
///   * `--x=<delta>`: Horizontal scroll delta (default: 0).
///       Positive = right, negative = left.
///
/// Examples:
///
///   Scroll down 3 lines:
///     ghostty +send-scroll --surface=0x153872000 --y=3
///
///   Scroll up 5 lines:
///     ghostty +send-scroll --surface=0x153872000 --y=-5
///
/// Available since: 1.4.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = try runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    const surface_id = opts.surface orelse {
        try stderr.print("Error: --surface is required\n", .{});
        return 1;
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target: apprt.ipc.Target = if (opts.class) |class| .{ .class = class } else .detect;

    const success = apprt.socket.performIpc(alloc, target, .send_scroll, .{
        .surface_id = surface_id,
        .x = opts.x,
        .y = opts.y,
    }) catch |err| {
        if (err != error.IPCFailed) {
            try stderr.print("IPC failed: {}\n", .{err});
        }
        return 1;
    };

    if (!success) {
        try stderr.print("Failed to send scroll event\n", .{});
        return 1;
    }

    return 0;
}
