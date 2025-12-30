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

    /// The surface ID to read from.
    surface: ?[:0]const u8 = null,

    /// Which screen portion to read: "viewport", "active", or "screen".
    screen: [:0]const u8 = "viewport",

    /// Output format: "text" (default) or "json".
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

/// The `get-screen` command reads the terminal screen content from a specific
/// surface in a running Ghostty instance.
///
/// Use `+list-surfaces` to discover surface IDs, then use those IDs to
/// read terminal content.
///
/// Flags:
///
///   * `--class=<class>`: Target a custom instance of Ghostty.
///
///   * `--surface=<id>`: The surface ID to read from (required).
///       Get surface IDs from `+list-surfaces`.
///
///   * `--screen=<type>`: Which portion of the screen to read:
///     - `viewport` (default): Currently visible content
///     - `active`: Active screen area (no scrollback)
///     - `screen`: Full screen including scrollback
///
///   * `--format=<format>`: Output format:
///     - `text` (default): Raw screen content
///     - `json`: JSON with content and cursor position
///
/// Examples:
///
///   Read the visible screen content:
///     ghostty +get-screen --surface=0x153872000
///
///   Read full scrollback as JSON:
///     ghostty +get-screen --surface=0x153872000 --screen=screen --format=json
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

    const response = apprt.socket.queryIpc(alloc, target, .get_screen, .{
        .surface_id = surface_id,
        .screen = opts.screen,
    }) catch |err| {
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
    var stdout_buffer: [65536]u8 = undefined; // Larger buffer for screen content
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, opts.format, "json")) {
        // JSON output with content and cursor
        try std.json.Stringify.value(response.data, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        // Text output - raw screen content
        if (response.data) |data| {
            if (data.content) |content| {
                try stdout.writeAll(content);
                // Add trailing newline if not present
                if (content.len > 0 and content[content.len - 1] != '\n') {
                    try stdout.writeAll("\n");
                }
            } else {
                try stderr.print("No screen content returned.\n", .{});
                return 1;
            }
        } else {
            try stderr.print("No data returned.\n", .{});
            return 1;
        }
    }

    stdout.flush() catch {};
    return 0;
}
