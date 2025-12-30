const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");

/// Process escape sequences in a string (e.g., \n, \r, \t, \\, \xNN).
fn processEscapes(alloc: Allocator, input: []const u8) ![:0]u8 {
    var result = try alloc.alloc(u8, input.len + 1);
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];

            // Handle \xNN hex escapes
            if (next == 'x' and i + 3 < input.len) {
                if (std.fmt.parseInt(u8, input[i + 2 .. i + 4], 16)) |byte| {
                    result[out_idx] = byte;
                    out_idx += 1;
                    i += 4;
                    continue;
                } else |_| {}
            }

            const replacement: ?u8 = switch (next) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'a' => 0x07, // bell
                'b' => 0x08, // backspace
                'f' => 0x0c, // form feed
                'v' => 0x0b, // vertical tab
                '\\' => '\\',
                '0' => 0,
                'e' => 0x1b, // escape
                else => null,
            };

            if (replacement) |r| {
                result[out_idx] = r;
                out_idx += 1;
                i += 2;
                continue;
            }
        }
        result[out_idx] = input[i];
        out_idx += 1;
        i += 1;
    }

    result[out_idx] = 0;
    return result[0..out_idx :0];
}

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, query a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    /// The surface ID to send text to.
    surface: ?[:0]const u8 = null,

    /// Text to send (can also be provided as positional argument).
    text: ?[:0]const u8 = null,

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

/// The `send-text` command sends text to a specific surface in a running
/// Ghostty instance.
///
/// Use `+list-surfaces` to discover surface IDs, then use those IDs to
/// target specific terminals for text input.
///
/// Flags:
///
///   * `--class=<class>`: Target a custom instance of Ghostty.
///
///   * `--surface=<id>`: The surface ID to send text to (required).
///       Get surface IDs from `+list-surfaces`.
///
///   * `--text=<text>`: The text to send. Can also be provided as a
///       positional argument.
///
/// Examples:
///
///   Send "hello" to a surface:
///     ghostty +send-text --surface=0x153872000 "hello"
///
///   Send a command with newline:
///     ghostty +send-text --surface=0x153872000 "ls -la\n"
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

    const text = opts.text orelse {
        try stderr.print("Error: --text is required\n", .{});
        return 1;
    };

    const surface_id = opts.surface orelse {
        try stderr.print("Error: --surface is required\n", .{});
        return 1;
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Process escape sequences like \n, \r, \t
    const processed_text = processEscapes(alloc, text) catch {
        try stderr.print("Error processing escape sequences\n", .{});
        return 1;
    };

    const target: apprt.ipc.Target = if (opts.class) |class| .{ .class = class } else .detect;

    const success = apprt.socket.performIpc(alloc, target, .send_text, .{
        .surface_id = surface_id,
        .text = processed_text,
    }) catch |err| {
        if (err != error.IPCFailed) {
            try stderr.print("IPC failed: {}\n", .{err});
        }
        return 1;
    };

    if (!success) {
        try stderr.print("Failed to send text\n", .{});
        return 1;
    }

    return 0;
}
