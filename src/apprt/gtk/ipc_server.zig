//! GTK IPC server integration.
//!
//! This module provides the socket server for GTK, integrating with GLib's
//! main loop for event-driven socket handling. Client I/O runs on spawned
//! threads to avoid blocking the GTK main loop, while request handlers
//! execute on the main thread via glib.idleAdd (required for GTK access).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const glib = @import("glib");

const socket_client = @import("../socket.zig");
const ipc_handlers = @import("ipc.zig");
const Application = @import("class/application.zig").Application;

const log = std.log.scoped(.gtk_ipc_server);

/// Maximum message size (16 MB for screenshots).
const max_message_size: usize = 16 * 1024 * 1024;

/// Poll interval in milliseconds.
const poll_interval_ms: c_uint = 100;

/// Context passed from client thread to main thread via glib.idleAdd.
const ClientDispatch = struct {
    server: *Server,
    client_fd: posix.socket_t,
    request: socket_client.Request,
    arena: std.heap.ArenaAllocator,

    // Synchronization: thread waits for main thread to produce response.
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    response: ?socket_client.Response = null,
    done: bool = false,
};

/// GTK IPC Server using GLib's event loop.
pub const Server = struct {
    alloc: Allocator,
    socket_fd: posix.socket_t,
    socket_path: []u8,
    timer_id: c_uint,
    app: *Application,

    /// Initialize and start the server.
    pub fn init(alloc: Allocator, app: *Application, instance: ?[]const u8) !*Server {
        const socket_path = try socket_client.getSocketPath(alloc, instance);
        errdefer alloc.free(socket_path);

        // Create socket directory
        const dir_path = std.fs.path.dirname(socket_path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        // Set directory permissions to 700 (iterate=true to get a real fd, not O_PATH)
        var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
        defer dir.close();
        dir.chmod(0o700) catch {};

        // Remove existing socket file
        std.fs.deleteFileAbsolute(socket_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
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
        posix.fchmod(socket_fd, 0o600) catch {};

        // Listen for connections
        try posix.listen(socket_fd, 5);

        // Set non-blocking
        const flags = try posix.fcntl(socket_fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(socket_fd, posix.F.SETFL, @as(u32, @intCast(flags)) | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

        // Create the server struct
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        // Create GLib timeout to poll the socket
        const timer_id = glib.timeoutAdd(poll_interval_ms, pollCallback, self);

        self.* = .{
            .alloc = alloc,
            .socket_fd = socket_fd,
            .socket_path = socket_path,
            .timer_id = timer_id,
            .app = app,
        };

        log.info("IPC server listening on {s}", .{socket_path});
        return self;
    }

    /// Stop the server and clean up.
    pub fn deinit(self: *Server) void {
        // Remove the GLib timer
        if (self.timer_id != 0) {
            _ = glib.Source.remove(self.timer_id);
        }

        // Close socket
        posix.close(self.socket_fd);

        // Remove socket file
        std.fs.deleteFileAbsolute(self.socket_path) catch {};

        // Free memory
        self.alloc.free(self.socket_path);
        self.alloc.destroy(self);

        log.info("IPC server stopped", .{});
    }

    /// GLib callback to poll the socket.
    fn pollCallback(user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(user_data));
        self.acceptAll();
        return 1; // Keep timer active
    }

    /// Accept all pending connections.
    fn acceptAll(self: *Server) void {
        while (self.acceptOne()) {}
    }

    /// Accept and handle a single connection.
    /// Spawns a thread for blocking I/O to avoid stalling the GTK main loop.
    fn acceptOne(self: *Server) bool {
        var client_addr: posix.sockaddr.un = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

        const client_fd = posix.accept(
            self.socket_fd,
            @ptrCast(&client_addr),
            &addr_len,
            0,
        ) catch |e| switch (e) {
            error.WouldBlock => return false,
            else => {
                log.err("accept failed: {}", .{e});
                return false;
            },
        };

        // Spawn a detached thread for this client's I/O.
        // The thread handles blocking reads/writes off the main loop.
        const thread = std.Thread.spawn(.{}, clientThread, .{ self, client_fd }) catch |e| {
            log.err("failed to spawn client thread: {}", .{e});
            posix.close(client_fd);
            return true;
        };
        thread.detach();
        return true;
    }

    /// Client thread: validates peer, reads request, dispatches to main thread,
    /// sends response. All blocking I/O happens here, not on the GTK main loop.
    fn clientThread(self: *Server, client_fd: posix.socket_t) void {
        defer posix.close(client_fd);

        // Validate peer is same user
        if (!self.validatePeer(client_fd)) {
            log.warn("rejected connection from different user", .{});
            return;
        }

        // Set socket timeouts (1s read, 5s write for large responses)
        const read_timeout = posix.timeval{ .sec = 1, .usec = 0 };
        posix.setsockopt(
            client_fd,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&read_timeout),
        ) catch {};

        const write_timeout = posix.timeval{ .sec = 5, .usec = 0 };
        posix.setsockopt(
            client_fd,
            posix.SOL.SOCKET,
            posix.SO.SNDTIMEO,
            std.mem.asBytes(&write_timeout),
        ) catch {};

        // Read and parse request (blocking, but on this thread)
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const request = self.readRequest(client_fd, alloc) catch |e| {
            log.err("failed to read request: {}", .{e});
            self.sendError(client_fd, "Failed to read request");
            return;
        };

        // Dispatch handler to GTK main thread and wait for result.
        // IPC handlers access GTK widgets and must run on the main thread.
        var dispatch = ClientDispatch{
            .server = self,
            .client_fd = client_fd,
            .request = request,
            .arena = std.heap.ArenaAllocator.init(self.alloc),
        };

        _ = glib.idleAdd(mainThreadDispatch, &dispatch);

        // Wait for main thread to produce the response
        dispatch.mutex.lock();
        defer dispatch.mutex.unlock();
        while (!dispatch.done) {
            dispatch.cond.wait(&dispatch.mutex);
        }

        defer dispatch.arena.deinit();

        // Send response (blocking write, on this thread)
        if (dispatch.response) |response| {
            self.sendResponse(client_fd, dispatch.arena.allocator(), response) catch |e| {
                log.err("failed to send response: {}", .{e});
            };
        }
    }

    /// GLib idle callback: runs on GTK main thread.
    /// Handles the request and signals the waiting client thread.
    fn mainThreadDispatch(user_data: ?*anyopaque) callconv(.c) c_int {
        const dispatch: *ClientDispatch = @ptrCast(@alignCast(user_data));
        const alloc = dispatch.arena.allocator();

        const response = dispatch.server.handleRequest(alloc, dispatch.request);

        dispatch.mutex.lock();
        defer dispatch.mutex.unlock();
        dispatch.response = response;
        dispatch.done = true;
        dispatch.cond.signal();

        return 0; // Remove idle source (one-shot)
    }

    /// Handle a request by calling the appropriate handler.
    fn handleRequest(self: *Server, alloc: Allocator, request: socket_client.Request) socket_client.Response {
        return switch (request.action) {
            .list_surfaces => ipc_handlers.listSurfaces(self.app, alloc),
            .send_text => |p| ipc_handlers.sendText(self.app, p.surface_id, p.text),
            .get_screen => |p| ipc_handlers.getScreen(self.app, alloc, p.surface_id, p.screen),
            .focus_surface => |p| ipc_handlers.focusSurface(self.app, p.surface_id),
            .close_surface => |p| ipc_handlers.closeSurface(self.app, p.surface_id),
            .resize_surface => |p| ipc_handlers.resizeSurface(self.app, p.surface_id, p.rows, p.cols),
            .screenshot_surface => |p| ipc_handlers.screenshotSurface(self.app, alloc, p.surface_id, p.output_path),
            .new_window => |p| ipc_handlers.newWindow(self.app, if (p.arguments) |a| a else null),
            .new_tab => |p| ipc_handlers.newTab(self.app, if (p.arguments) |a| a else null),
            .send_mouse => |p| ipc_handlers.sendMouse(self.app, p.surface_id, p.x, p.y, p.button, p.button_action, p.mods),
            .send_scroll => |p| ipc_handlers.sendScroll(self.app, p.surface_id, p.x, p.y, p.mods),
            .send_key => |p| ipc_handlers.sendKey(self.app, p.surface_id, p.key, p.action, p.mods),
        };
    }

    fn validatePeer(self: *Server, client_fd: posix.socket_t) bool {
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

    fn readRequest(self: *Server, client_fd: posix.socket_t, alloc: Allocator) !socket_client.Request {
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
            socket_client.Request,
            alloc,
            buf,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    fn sendResponse(self: *Server, client_fd: posix.socket_t, alloc: Allocator, response: socket_client.Response) !void {
        _ = self;

        const json = try std.json.Stringify.valueAlloc(alloc, response, .{});

        // Send length prefix
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(json.len), .little);

        try writeAll(client_fd, &len_bytes);
        try writeAll(client_fd, json);
    }

    fn sendError(self: *Server, client_fd: posix.socket_t, message: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        self.sendResponse(client_fd, arena.allocator(), .{
            .ok = false,
            .@"error" = message,
        }) catch {};
    }
};

fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.recv(fd, buf[off..], 0) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

fn writeAll(fd: posix.socket_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.send(fd, buf[off..], 0) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}
