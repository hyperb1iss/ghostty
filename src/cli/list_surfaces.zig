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

    /// Output format: "json" or "text" (default).
    format: []const u8 = "text",

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

/// The `list-surfaces` command queries a running Ghostty instance for all open
/// windows, tabs, and surfaces.
///
/// This is useful for scripting and automation - you can discover surface IDs
/// to target with other commands like `get-screen` or `send-text`.
///
/// Flags:
///
///   * `--class=<class>`: Query a custom instance of Ghostty.
///
///   * `--format=<format>`: Output format. Options are:
///     - `text` (default): Human-readable tree output
///     - `json`: JSON output for scripting
///
/// Available since: 1.4.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
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

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Use socket IPC directly to get the response data
    const target: apprt.ipc.Target = if (opts.class) |class| .{ .class = class } else .detect;

    const response = apprt.socket.queryIpc(alloc, target, .list_surfaces, {}) catch |err| {
        if (err != error.IPCFailed) {
            try stderr.print("IPC query failed: {}\n", .{err});
        }
        return 1;
    };

    if (!response.ok) {
        if (response.@"error") |err_msg| {
            try stderr.print("Error: {s}\n", .{err_msg});
        } else {
            try stderr.print("Unknown error from Ghostty\n", .{});
        }
        return 1;
    }

    // Output the results
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, opts.format, "json")) {
        // JSON output
        try std.json.Stringify.value(response.data, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        // Text output - tree format
        if (response.data) |data| {
            if (data.windows) |windows| {
                for (windows, 0..) |window, wi| {
                    const focus_marker: []const u8 = if (window.focused) " *" else "";
                    try stdout.print("Window {d}{s} [{s}]\n", .{ wi, focus_marker, window.id });

                    for (window.tabs, 0..) |tab, ti| {
                        const active_marker: []const u8 = if (tab.active) " *" else "";
                        try stdout.print("  Tab {d}{s}: {s} [{s}]\n", .{ ti, active_marker, tab.title, tab.id });

                        for (tab.surfaces) |surface| {
                            const sfocus: []const u8 = if (surface.focused) " *" else "";
                            try stdout.print("    Surface{s}: {s} [{s}]\n", .{ sfocus, surface.title, surface.id });
                            try stdout.print("      size: {d}x{d}, pwd: {s}\n", .{ surface.cols, surface.rows, surface.pwd });
                        }
                    }
                }
            } else {
                try stdout.print("No windows found.\n", .{});
            }
        } else {
            try stdout.print("No data returned.\n", .{});
        }
    }

    stdout.flush() catch {};
    return 0;
}
