//! Unix socket IPC server for terminal automation.
//!
//! This module provides the server-side socket handling. The actual action
//! handlers are provided by the platform-specific app (GTK, macOS).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const socket_client = @import("../socket.zig");
const Request = socket_client.Request;
const Response = socket_client.Response;

const log = std.log.scoped(.ipc_server);

/// Maximum message size (16 MB for screenshots).
pub const max_message_size: usize = 16 * 1024 * 1024;

/// Handler interface that platform-specific apps must implement.
pub fn Handler(comptime App: type) type {
    return struct {
        app: *App,

        const Self = @This();

        pub fn handle(self: Self, alloc: Allocator, request: Request) Response {
            return switch (request.action) {
                .list_surfaces => App.ipcListSurfaces(self.app, alloc),
                .send_text => |p| App.ipcSendText(self.app, p.surface_id, p.text),
                .get_screen => |p| App.ipcGetScreen(self.app, alloc, p.surface_id, p.screen),
                .focus_surface => |p| App.ipcFocusSurface(self.app, p.surface_id),
                .close_surface => |p| App.ipcCloseSurface(self.app, p.surface_id),
                .resize_surface => |p| App.ipcResizeSurface(self.app, p.surface_id, p.rows, p.cols),
                .screenshot_surface => |p| App.ipcScreenshotSurface(self.app, p.surface_id, p.output_path),
                .new_window => |p| App.ipcNewWindow(self.app, if (p.arguments) |a| a else null),
                .new_tab => |p| App.ipcNewTab(self.app, if (p.arguments) |a| a else null),
                .send_mouse => |p| App.ipcSendMouse(self.app, p.surface_id, p.x, p.y, p.button, p.button_action, p.mods),
                .send_scroll => |p| App.ipcSendScroll(self.app, p.surface_id, p.x, p.y, p.mods),
                .send_key => |p| App.ipcSendKey(self.app, p.surface_id, p.key, p.action, p.mods),
            };
        }
    };
}

/// IPC socket server.
pub fn Server(comptime App: type) type {
    return struct {
        alloc: Allocator,
        socket_fd: posix.socket_t,
        socket_path: []u8,
        handler: Handler(App),

        const Self = @This();

        /// Initialize and start the server.
        pub fn init(alloc: Allocator, app: *App, instance: ?[]const u8) !Self {
            const socket_path = try socket_client.getSocketPath(alloc, instance);
            errdefer alloc.free(socket_path);

            // Create socket directory
            const dir_path = std.fs.path.dirname(socket_path) orelse return error.InvalidPath;
            std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };

            // Set directory permissions to 700
            var dir = try std.fs.openDirAbsolute(dir_path, .{});
            defer dir.close();
            dir.chmod(0o700) catch {};

            // Remove existing socket file
            std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };

            // Create socket
            const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            errdefer posix.close(socket_fd);

            // Bind to path
            var addr: posix.sockaddr.un = .{
                .family = posix.AF.UNIX,
                .path = undefined,
            };

            if (socket_path.len >= addr.path.len) {
                return error.PathTooLong;
            }

            @memset(&addr.path, 0);
            @memcpy(addr.path[0..socket_path.len], socket_path);

            try posix.bind(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

            // Set socket file permissions to 600
            std.fs.cwd().chmod(socket_path, 0o600) catch {};

            // Listen for connections
            try posix.listen(socket_fd, 5);

            // Set non-blocking
            const flags = try posix.fcntl(socket_fd, posix.F.GETFL, 0);
            _ = try posix.fcntl(socket_fd, posix.F.SETFL, @as(u32, @intCast(flags)) | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

            log.info("IPC server listening on {s}", .{socket_path});

            return .{
                .alloc = alloc,
                .socket_fd = socket_fd,
                .socket_path = socket_path,
                .handler = .{ .app = app },
            };
        }

        /// Stop the server and clean up.
        pub fn deinit(self: *Self) void {
            posix.close(self.socket_fd);
            std.fs.deleteFileAbsolute(self.socket_path) catch {};
            self.alloc.free(self.socket_path);
        }

        /// Accept and handle a pending connection (non-blocking).
        /// Returns true if a connection was handled, false if none pending.
        pub fn acceptOne(self: *Self) bool {
            var client_addr: posix.sockaddr.un = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

            const client_fd = posix.accept(
                self.socket_fd,
                @ptrCast(&client_addr),
                &addr_len,
                0,
            ) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => {
                    log.err("accept failed: {}", .{err});
                    return false;
                },
            };

            self.handleClient(client_fd);
            return true;
        }

        /// Handle all pending connections.
        pub fn acceptAll(self: *Self) void {
            while (self.acceptOne()) {}
        }

        fn handleClient(self: *Self, client_fd: posix.socket_t) void {
            defer posix.close(client_fd);

            // Validate peer is same user
            if (!self.validatePeer(client_fd)) {
                log.warn("rejected connection from different user", .{});
                return;
            }

            // Set read timeout
            const timeout = posix.timeval{ .sec = 5, .usec = 0 };
            posix.setsockopt(
                client_fd,
                posix.SOL.SOCKET,
                posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout),
            ) catch {};

            // Read request
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const alloc = arena.allocator();

            const request = self.readRequest(client_fd, alloc) catch |err| {
                log.err("failed to read request: {}", .{err});
                self.sendError(client_fd, "Failed to read request");
                return;
            };

            // Handle request
            const response = self.handler.handle(alloc, request);

            // Send response
            self.sendResponse(client_fd, alloc, response) catch |err| {
                log.err("failed to send response: {}", .{err});
            };
        }

        fn validatePeer(self: *Self, client_fd: posix.socket_t) bool {
            _ = self;

            if (comptime builtin.os.tag == .linux) {
                var cred: extern struct {
                    pid: i32,
                    uid: u32,
                    gid: u32,
                } = undefined;

                posix.getsockopt(
                    client_fd,
                    posix.SOL.SOCKET,
                    posix.SO.PEERCRED,
                    std.mem.asBytes(&cred),
                ) catch return false;

                return cred.uid == posix.getuid();
            } else if (comptime builtin.os.tag.isDarwin()) {
                // macOS: use getpeereid
                var uid: posix.uid_t = undefined;
                var gid: posix.gid_t = undefined;

                const rc = std.c.getpeereid(client_fd, &uid, &gid);
                if (rc != 0) return false;

                return uid == posix.getuid();
            }

            return true;
        }

        fn readRequest(self: *Self, client_fd: posix.socket_t, alloc: Allocator) !Request {
            _ = self;

            // Read length prefix
            var len_bytes: [4]u8 = undefined;
            try readExact(client_fd, &len_bytes);

            const msg_len = std.mem.readInt(u32, &len_bytes, .little);
            if (msg_len > max_message_size) {
                return error.MessageTooLarge;
            }

            // Read message
            const buf = try alloc.alloc(u8, msg_len);
            try readExact(client_fd, buf);

            // Parse JSON
            return try std.json.parseFromSliceLeaky(
                Request,
                alloc,
                buf,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            );
        }

        fn sendResponse(self: *Self, client_fd: posix.socket_t, alloc: Allocator, response: Response) !void {
            _ = self;

            const json = try std.json.Stringify.valueAlloc(alloc, response, .{});

            // Send length prefix
            var len_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_bytes, @intCast(json.len), .little);

            try writeAll(client_fd, &len_bytes);
            try writeAll(client_fd, json);
        }

        fn sendError(self: *Self, client_fd: posix.socket_t, message: []const u8) void {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();

            self.sendResponse(client_fd, arena.allocator(), .{
                .ok = false,
                .@"error" = message,
            }) catch {};
        }
    };
}

fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.recv(fd, buf[off..], 0) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

fn writeAll(fd: posix.socket_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.send(fd, buf[off..], 0) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

/// Helper to create success response.
pub fn success() Response {
    return .{ .ok = true };
}

/// Helper to create success response with data.
pub fn successData(data: Response.Data) Response {
    return .{ .ok = true, .data = data };
}

/// Helper to create error response.
pub fn errorResponse(message: []const u8) Response {
    return .{ .ok = false, .@"error" = message };
}
