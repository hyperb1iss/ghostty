//! GTK IPC server integration.
//!
//! Client I/O happens on worker threads so the GTK main loop only handles the
//! actual widget interactions via `glib.idleAdd`.

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

/// Maximum number of concurrent client threads.
const max_concurrent_clients: u32 = 8;

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
    app: *Application,
    accept_thread: ?std.Thread = null,
    client_mutex: std.Thread.Mutex = .{},
    client_cond: std.Thread.Condition = .{},
    active_clients: u32 = 0,
    shutting_down: bool = false,

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
        try socket_client.removeSocketFile(socket_path);

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

        // Create the server struct
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .socket_fd = socket_fd,
            .socket_path = socket_path,
            .app = app,
        };

        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        log.info("IPC server listening on {s}", .{socket_path});
        return self;
    }

    /// Stop the server and clean up.
    pub fn deinit(self: *Server) void {
        self.client_mutex.lock();
        self.shutting_down = true;
        self.client_mutex.unlock();

        // Close socket
        posix.close(self.socket_fd);

        if (self.accept_thread) |thread| {
            thread.join();
        }

        self.client_mutex.lock();
        while (self.active_clients > 0) {
            self.client_cond.wait(&self.client_mutex);
        }
        self.client_mutex.unlock();

        // Remove socket file
        socket_client.removeSocketFile(self.socket_path) catch {};

        // Free memory
        self.alloc.free(self.socket_path);
        self.alloc.destroy(self);

        log.info("IPC server stopped", .{});
    }

    fn acceptLoop(self: *Server) void {
        while (true) {
            var client_addr: posix.sockaddr.un = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

            const client_fd = posix.accept(
                self.socket_fd,
                @ptrCast(&client_addr),
                &addr_len,
                0,
            ) catch |e| {
                self.client_mutex.lock();
                const shutting_down = self.shutting_down;
                self.client_mutex.unlock();
                if (shutting_down) return;

                log.err("accept failed: {}", .{e});
                return;
            };

            self.client_mutex.lock();
            if (self.shutting_down) {
                self.client_mutex.unlock();
                posix.close(client_fd);
                return;
            }
            if (self.active_clients >= max_concurrent_clients) {
                self.client_mutex.unlock();
                self.sendBusy(client_fd);
                posix.close(client_fd);
                continue;
            }
            self.active_clients += 1;
            self.client_mutex.unlock();

            const thread = std.Thread.spawn(.{}, clientThread, .{ self, client_fd }) catch |e| {
                log.err("failed to spawn client thread: {}", .{e});
                self.clientDone();
                posix.close(client_fd);
                continue;
            };
            thread.detach();
        }
    }

    /// Client thread: validates peer, reads request, dispatches to main thread,
    /// sends response. All blocking I/O happens here, not on the GTK main loop.
    fn clientThread(self: *Server, client_fd: posix.socket_t) void {
        defer self.clientDone();
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
            self.sendReadError(client_fd, e);
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
        const request = try std.json.parseFromSliceLeaky(
            socket_client.Request,
            alloc,
            buf,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        try socket_client.validateRequestVersion(request);
        return request;
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

    fn sendBusy(self: *Server, client_fd: posix.socket_t) void {
        self.sendError(client_fd, "Too many concurrent IPC requests");
    }

    fn sendReadError(self: *Server, client_fd: posix.socket_t, err: anyerror) void {
        switch (err) {
            error.UnsupportedProtocolVersion => self.sendError(client_fd, "Unsupported protocol version"),
            else => self.sendError(client_fd, "Failed to read request"),
        }
    }

    fn clientDone(self: *Server) void {
        self.client_mutex.lock();
        defer self.client_mutex.unlock();
        self.active_clients -= 1;
        if (self.shutting_down and self.active_clients == 0) {
            self.client_cond.signal();
        }
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
