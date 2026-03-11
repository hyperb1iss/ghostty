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

    /// The surface ID to send the key event to.
    surface: ?[:0]const u8 = null,

    /// Key name in W3C format (e.g., "Escape", "ArrowUp", "KeyA", "Enter").
    key: ?[:0]const u8 = null,

    /// Key action: "press", "release", or "repeat". Default is "press".
    action: ?[:0]const u8 = null,

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

/// The `send-key` command sends a keyboard event to a specific surface in a
/// running Ghostty instance.
///
/// Use `+list-surfaces` to discover surface IDs, then use those IDs to
/// target specific terminals for key input.
///
/// Flags:
///
///   * `--class=<class>`: Target a custom instance of Ghostty.
///
///   * `--surface=<id>`: The surface ID to send the key to (required).
///       Get surface IDs from `+list-surfaces`.
///
///   * `--key=<key>`: Key name in W3C format (required). Examples:
///       Enter, Tab, Escape, Backspace, Delete, Space,
///       ArrowUp, ArrowDown, ArrowLeft, ArrowRight,
///       Home, End, PageUp, PageDown,
///       KeyA-KeyZ, Digit0-Digit9, F1-F12.
///
///   * `--action=<action>`: Key action (default: "press").
///       Options: "press", "release", "repeat".
///
///   * `--mods=<mods>`: Modifier keys, comma-separated.
///       Options: "shift", "ctrl", "alt", "super".
///
/// Examples:
///
///   Press Enter:
///     ghostty +send-key --surface=0x153872000 --key=Enter
///
///   Press Ctrl+C:
///     ghostty +send-key --surface=0x153872000 --key=KeyC --mods=ctrl
///
///   Press Ctrl+Shift+A:
///     ghostty +send-key --surface=0x153872000 --key=KeyA --mods=ctrl,shift
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

    const key = opts.key orelse {
        try stderr.print("Error: --key is required\n", .{});
        return 1;
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target: apprt.ipc.Target = if (opts.class) |class| .{ .class = class } else .detect;

    const success = apprt.socket.performIpc(alloc, target, .send_key, .{
        .surface_id = surface_id,
        .key = key,
        .action = opts.action,
        .mods = opts.mods,
    }) catch |err| {
        if (err != error.IPCFailed) {
            try stderr.print("IPC failed: {}\n", .{err});
        }
        return 1;
    };

    if (!success) {
        try stderr.print("Failed to send key\n", .{});
        return 1;
    }

    return 0;
}
