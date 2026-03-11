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

    /// The surface ID to send the mouse event to.
    surface: ?[:0]const u8 = null,

    /// X position in pixels (relative to surface origin).
    x: ?f64 = null,

    /// Y position in pixels (relative to surface origin).
    y: ?f64 = null,

    /// Mouse button: "left", "right", "middle", "four", "five".
    button: ?[:0]const u8 = null,

    /// Button action: "press" or "release".
    @"button-action": ?[:0]const u8 = null,

    /// Modifier keys: comma-separated list of "shift", "ctrl", "alt", "super".
    mods: ?[:0]const u8 = null,

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

/// The `send-mouse` command sends a mouse event to a specific surface in a
/// running Ghostty instance.
///
/// Use `+list-surfaces` to discover surface IDs, then use those IDs to
/// target specific terminals for mouse input.
///
/// Flags:
///
///   * `--class=<class>`: Target a custom instance of Ghostty.
///
///   * `--surface=<id>`: The surface ID to send the event to (required).
///       Get surface IDs from `+list-surfaces`.
///
///   * `--x=<pixels>`: X position in pixels (required).
///
///   * `--y=<pixels>`: Y position in pixels (required).
///
///   * `--button=<button>`: Mouse button (optional for motion events).
///       Options: "left", "right", "middle", "four", "five".
///
///   * `--button-action=<action>`: Button action (required if button set).
///       Options: "press", "release".
///
///   * `--mods=<mods>`: Modifier keys, comma-separated.
///       Options: "shift", "ctrl", "alt", "super".
///
/// Examples:
///
///   Click at position (100, 200):
///     ghostty +send-mouse --surface=0x123 --x=100 --y=200 --button=left --button-action=press
///     ghostty +send-mouse --surface=0x123 --x=100 --y=200 --button=left --button-action=release
///
///   Right-click:
///     ghostty +send-mouse --surface=0x123 --x=50 --y=80 --button=right --button-action=press
///     ghostty +send-mouse --surface=0x123 --x=50 --y=80 --button=right --button-action=release
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

    const x = opts.x orelse {
        try stderr.print("Error: --x is required\n", .{});
        return 1;
    };

    const y = opts.y orelse {
        try stderr.print("Error: --y is required\n", .{});
        return 1;
    };

    // Convert button_action from CLI name to IPC name
    const button_action = opts.@"button-action";

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target: apprt.ipc.Target = if (opts.class) |class| .{ .class = class } else .detect;

    const success = apprt.socket.performIpc(alloc, target, .send_mouse, .{
        .surface_id = surface_id,
        .x = x,
        .y = y,
        .button = opts.button,
        .button_action = button_action,
        .mods = opts.mods,
    }) catch |err| {
        if (err != error.IPCFailed) {
            try stderr.print("IPC failed: {}\n", .{err});
        }
        return 1;
    };

    if (!success) {
        try stderr.print("Failed to send mouse event\n", .{});
        return 1;
    }

    return 0;
}
