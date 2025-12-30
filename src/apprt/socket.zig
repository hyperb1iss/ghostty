//! Unix socket IPC for cross-platform remote control.
//!
//! This module provides socket-based IPC as an alternative to D-Bus for platforms
//! that don't support it (macOS, Windows). The protocol uses JSON over Unix domain
//! sockets (or named pipes on Windows).
//!
//! Socket path resolution:
//! - Linux: $XDG_RUNTIME_DIR/ghostty/<instance>.sock or /tmp/ghostty-$UID/<instance>.sock
//! - macOS: $TMPDIR/ghostty-$UID/<instance>.sock or /tmp/ghostty-$UID/<instance>.sock
//! - Windows: \\.\pipe\ghostty-<instance> (named pipe)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const ipc = @import("ipc.zig");

const log = std.log.scoped(.ipc_socket);

fn writeAll(socket: posix.socket_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.send(socket, buf[off..], 0);
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

fn readExact(socket: posix.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.recv(socket, buf[off..], 0);
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

/// Default socket filename for the primary instance.
pub const default_socket_name = "ghostty.sock";

/// JSON request sent to the socket server.
pub const Request = struct {
    /// Protocol version for future compatibility.
    version: u32 = 1,

    /// The action to perform.
    action: ActionPayload,

    /// Target instance (class name or null for default).
    target: ?[]const u8 = null,

    pub const ActionPayload = union(ipc.Action.Key) {
        new_window: NewWindowPayload,
        new_tab: NewTabPayload,
        list_surfaces: void,
        send_text: SendTextPayload,

        pub const NewWindowPayload = struct {
            /// Command arguments to run in the new window.
            arguments: ?[]const []const u8 = null,
        };

        pub const NewTabPayload = struct {
            /// Command arguments to run in the new tab.
            arguments: ?[]const []const u8 = null,
        };

        pub const SendTextPayload = struct {
            /// The surface ID to send text to.
            surface_id: []const u8,
            /// The text to send.
            text: []const u8,
        };
    };
};

/// JSON response from the socket server.
pub const Response = struct {
    /// Whether the action succeeded.
    ok: bool,

    /// Error message if ok is false.
    @"error": ?[]const u8 = null,

    /// Optional result data.
    data: ?Data = null,

    pub const Data = struct {
        /// ID of created resource (window, tab, etc.)
        id: ?[]const u8 = null,

        /// List of windows (for list_surfaces action).
        windows: ?[]const Window = null,
    };

    /// Window in list_surfaces response.
    pub const Window = struct {
        id: []const u8,
        focused: bool = false,
        tabs: []const Tab = &.{},
    };

    /// Tab in list_surfaces response.
    pub const Tab = struct {
        id: []const u8,
        title: []const u8 = "",
        active: bool = false,
        surfaces: []const Surface = &.{},
    };

    /// Surface in list_surfaces response.
    pub const Surface = struct {
        id: []const u8,
        title: []const u8 = "",
        focused: bool = false,
        pwd: []const u8 = "",
        rows: u32 = 0,
        cols: u32 = 0,
    };
};

/// Get the socket directory path for the current platform.
/// Caller owns the returned memory.
pub fn getSocketDir(alloc: Allocator) ![]u8 {
    const uid = switch (builtin.os.tag) {
        .windows => 0, // Windows doesn't use UID in path
        else => posix.getuid(),
    };

    // Try XDG_RUNTIME_DIR first (Linux)
    if (builtin.os.tag == .linux) {
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
            return try std.fs.path.join(alloc, &.{ runtime_dir, "ghostty" });
        }
    }

    // Try TMPDIR (macOS sets this per-user)
    if (std.posix.getenv("TMPDIR")) |tmpdir| {
        const subdir = try std.fmt.allocPrint(alloc, "ghostty-{d}", .{uid});
        defer alloc.free(subdir);
        return try std.fs.path.join(alloc, &.{ tmpdir, subdir });
    }

    // Fallback to /tmp/ghostty-$UID
    return try std.fmt.allocPrint(alloc, "/tmp/ghostty-{d}", .{uid});
}

/// Get the full socket path for the given instance name.
/// Caller owns the returned memory.
pub fn getSocketPath(alloc: Allocator, instance: ?[]const u8) ![]u8 {
    const dir = try getSocketDir(alloc);
    defer alloc.free(dir);

    const filename = instance orelse default_socket_name;
    const sock_filename = if (std.mem.endsWith(u8, filename, ".sock"))
        try alloc.dupe(u8, filename)
    else
        try std.fmt.allocPrint(alloc, "{s}.sock", .{filename});
    defer alloc.free(sock_filename);

    return try std.fs.path.join(alloc, &.{ dir, sock_filename });
}

/// Serialize an IPC action to a JSON request.
pub fn serializeRequest(
    alloc: Allocator,
    target: ipc.Target,
    comptime action_key: ipc.Action.Key,
    value: ipc.Action.Value(action_key),
) ![]u8 {
    const request = Request{
        .version = 1,
        .target = switch (target) {
            .class => |c| c,
            .detect => null,
        },
        .action = switch (action_key) {
            .new_window => .{
                .new_window = .{
                    .arguments = if (value.arguments) |args| blk: {
                        // Convert [][:0]const u8 to []const []const u8
                        var list = try alloc.alloc([]const u8, args.len);
                        for (args, 0..) |arg, i| {
                            list[i] = std.mem.sliceTo(arg, 0);
                        }
                        break :blk list;
                    } else null,
                },
            },
            .new_tab => .{
                .new_tab = .{
                    .arguments = if (value.arguments) |args| blk: {
                        // Convert [][:0]const u8 to []const []const u8
                        var list = try alloc.alloc([]const u8, args.len);
                        for (args, 0..) |arg, i| {
                            list[i] = std.mem.sliceTo(arg, 0);
                        }
                        break :blk list;
                    } else null,
                },
            },
            .list_surfaces => .{ .list_surfaces = {} },
            .send_text => .{
                .send_text = .{
                    .surface_id = std.mem.sliceTo(value.surface_id, 0),
                    .text = std.mem.sliceTo(value.text, 0),
                },
            },
        },
    };

    return std.json.Stringify.valueAlloc(alloc, request, .{});
}

/// Parse a JSON response from the server.
pub fn parseResponse(alloc: Allocator, data: []const u8) !Response {
    return try std.json.parseFromSliceLeaky(Response, alloc, data, .{
        .ignore_unknown_fields = true,
        // Ensure returned strings do not borrow from `data`.
        .allocate = .alloc_always,
    });
}

/// Socket client for sending IPC requests.
pub const Client = struct {
    alloc: Allocator,
    socket: posix.socket_t,
    path: []u8,

    pub fn init(alloc: Allocator, target: ipc.Target) !Client {
        // On macOS, the app bundle is generally single-instance, so we always
        // use the default socket path to avoid `--class` making IPC unusable.
        const instance_name: ?[]const u8 = switch (target) {
            .class => |c| if (builtin.os.tag.isDarwin()) null else c,
            .detect => null,
        };

        const path = try getSocketPath(alloc, instance_name);
        errdefer alloc.free(path);

        // Create Unix domain socket
        const socket = try posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM,
            0,
        );
        errdefer posix.close(socket);

        // Avoid SIGPIPE on Darwin when the peer disconnects.
        if (builtin.os.tag.isDarwin()) {
            const one: c_int = 1;
            posix.setsockopt(
                socket,
                posix.SOL.SOCKET,
                posix.SO.NOSIGPIPE,
                std.mem.asBytes(&one),
            ) catch {};
        }

        // Connect to the server
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (path.len >= addr.path.len) {
            return error.PathTooLong;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);

        posix.connect(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
            log.err("failed to connect to socket {s}: {}", .{ path, err });
            return error.IPCFailed;
        };

        return .{
            .alloc = alloc,
            .socket = socket,
            .path = path,
        };
    }

    pub fn deinit(self: *Client) void {
        posix.close(self.socket);
        self.alloc.free(self.path);
    }

    /// Send a request and receive a response.
    pub fn sendRequest(self: *Client, request_json: []const u8) !Response {
        if (request_json.len > std.math.maxInt(u32)) return error.RequestTooLarge;

        // Send length-prefixed message (u32, little-endian)
        const len: u32 = @intCast(request_json.len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, len, .little);

        try writeAll(self.socket, len_bytes[0..]);
        try writeAll(self.socket, request_json);

        // Receive response
        var resp_len_bytes: [4]u8 = undefined;
        try readExact(self.socket, resp_len_bytes[0..]);
        const resp_len = std.mem.readInt(u32, &resp_len_bytes, .little);
        if (resp_len > 1024 * 1024) { // 1MB max response
            return error.ResponseTooLarge;
        }

        const resp_buf = try self.alloc.alloc(u8, resp_len);
        defer self.alloc.free(resp_buf);

        try readExact(self.socket, resp_buf);

        return try parseResponse(self.alloc, resp_buf);
    }
};

/// Perform IPC via Unix socket.
///
/// Returns true if the action succeeded. Returns `error.IPCFailed` if no
/// compatible Ghostty instance is reachable or the request fails.
pub fn performIpc(
    alloc: Allocator,
    target: ipc.Target,
    comptime action_key: ipc.Action.Key,
    value: ipc.Action.Value(action_key),
) !bool {
    // Serialize the request
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const request_json = serializeRequest(arena_alloc, target, action_key, value) catch {
        log.err("failed to serialize IPC request", .{});
        return error.IPCFailed;
    };

    // Connect and send
    var client = Client.init(arena_alloc, target) catch |err| switch (err) {
        error.IPCFailed => {
            // Socket doesn't exist or can't connect - no server running
            log.err("no Ghostty instance found. Is Ghostty running?", .{});
            return error.IPCFailed;
        },
        else => {
            log.err("failed to connect to Ghostty", .{});
            return error.IPCFailed;
        },
    };
    defer client.deinit();

    const response = client.sendRequest(request_json) catch {
        log.err("failed to send IPC request", .{});
        return error.IPCFailed;
    };

    if (!response.ok) {
        if (response.@"error") |err_msg| {
            log.err("Ghostty returned error: {s}", .{err_msg});
        } else {
            log.err("Ghostty returned unknown error", .{});
        }
        return error.IPCFailed;
    }

    return true;
}

/// Query IPC via Unix socket, returning the full response.
///
/// Unlike `performIpc`, this returns the full Response including any data
/// returned by the server. Use this for actions that return data (like list_surfaces).
pub fn queryIpc(
    alloc: Allocator,
    target: ipc.Target,
    comptime action_key: ipc.Action.Key,
    value: ipc.Action.Value(action_key),
) !Response {
    // Serialize the request
    const request_json = serializeRequest(alloc, target, action_key, value) catch {
        log.err("failed to serialize IPC request", .{});
        return error.IPCFailed;
    };
    defer alloc.free(request_json);

    // Connect and send
    var client = Client.init(alloc, target) catch |err| switch (err) {
        error.IPCFailed => {
            log.err("no Ghostty instance found. Is Ghostty running?", .{});
            return error.IPCFailed;
        },
        else => {
            log.err("failed to connect to Ghostty", .{});
            return error.IPCFailed;
        },
    };
    defer client.deinit();

    const response = client.sendRequest(request_json) catch {
        log.err("failed to send IPC request", .{});
        return error.IPCFailed;
    };

    return response;
}

test "socket path generation" {
    const alloc = std.testing.allocator;

    // Test default path
    const path = try getSocketPath(alloc, null);
    defer alloc.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "ghostty.sock"));

    // Test custom instance
    const custom_path = try getSocketPath(alloc, "my-instance");
    defer alloc.free(custom_path);
    try std.testing.expect(std.mem.endsWith(u8, custom_path, "my-instance.sock"));
}

test "request serialization new_window" {
    const alloc = std.testing.allocator;

    const json = try serializeRequest(
        alloc,
        .detect,
        .new_window,
        .{ .arguments = null },
    );
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "new_window") != null);
}

test "request serialization new_tab" {
    const alloc = std.testing.allocator;

    const json = try serializeRequest(
        alloc,
        .detect,
        .new_tab,
        .{ .arguments = null },
    );
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "new_tab") != null);
}
