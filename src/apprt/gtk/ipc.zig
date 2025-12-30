//! IPC handler implementations for GTK.
//!
//! This module provides the handler methods required by the IPC server.
//! These handlers are called from the socket server to perform actions
//! like listing surfaces, sending text, taking screenshots, etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gtk = @import("gtk");
const gdk = @import("gdk");
const gobject = @import("gobject");
const adw = @import("adw");

const ipc = @import("../ipc/mod.zig");
const socket = @import("../socket.zig");
const Response = socket.Response;
const CoreSurface = @import("../../Surface.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_ipc);

/// List all surfaces in the application.
pub fn listSurfaces(app: *Application, alloc: Allocator) Response {
    _ = app;

    var windows = std.ArrayList(Response.Window).init(alloc);

    // Iterate over all top-level windows
    const window_list = gtk.Window.listToplevels();
    defer window_list.free();

    var iter = window_list.iterator();
    while (iter.next()) |data| {
        const widget: *gtk.Widget = @ptrCast(@alignCast(data));

        // Only process our Window type
        if (!gobject.ext.isA(widget, Window)) continue;
        const window: *Window = @ptrCast(widget);

        const window_id = formatObjectId(alloc, window) catch continue;
        const is_focused = window.as(gtk.Window).isActive() != 0;

        var tabs = std.ArrayList(Response.Tab).init(alloc);
        collectTabs(window, &tabs, alloc) catch continue;

        windows.append(.{
            .id = window_id,
            .focused = is_focused,
            .tabs = tabs.toOwnedSlice() catch &.{},
        }) catch continue;
    }

    return ipc.successData(.{
        .windows = windows.toOwnedSlice() catch &.{},
    });
}

/// Send text to a surface.
pub fn sendText(app: *Application, surface_id: []const u8, text: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // Get the core surface and write to it
    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Use writeRaw to bypass bracketed paste mode
    core.writeRaw(text) catch {
        return ipc.err("Failed to write to surface");
    };

    return ipc.success();
}

/// Get screen content from a surface.
pub fn getScreen(app: *Application, alloc: Allocator, surface_id: []const u8, screen_type: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Get screen content using core API
    const content = core.getScreenContent(alloc, screen_type) catch {
        return ipc.err("Failed to get screen content");
    };

    // Get cursor position
    const cursor_pos = core.getCursorPosition();

    return ipc.successData(.{
        .content = content,
        .cursor_x = cursor_pos.x,
        .cursor_y = cursor_pos.y,
    });
}

/// Focus a surface (bring its window to front).
pub fn focusSurface(app: *Application, surface_id: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // Get the window containing this surface
    const root = surface.as(gtk.Widget).getRoot() orelse {
        return ipc.err("Surface has no window");
    };

    // Present the window (brings to front)
    if (gobject.ext.cast(gtk.Window, root)) |gtk_window| {
        gtk_window.present();
    }

    // Focus the specific surface within the window
    _ = surface.as(gtk.Widget).grabFocus();

    return ipc.success();
}

/// Close a surface.
pub fn closeSurface(app: *Application, surface_id: []const u8) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // Request close through the surface's close method
    surface.close();

    return ipc.success();
}

/// Resize a surface's window.
pub fn resizeSurface(app: *Application, surface_id: []const u8, rows: u32, cols: u32) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Get current grid size if needed
    const current_grid = core.size.grid();
    const new_rows = if (rows > 0) rows else current_grid.rows;
    const new_cols = if (cols > 0) cols else current_grid.columns;

    // Get cell size for pixel calculation
    const cell_width: c_int = @intCast(core.size.cell.width);
    const cell_height: c_int = @intCast(core.size.cell.height);

    if (cell_width == 0 or cell_height == 0) {
        return ipc.err("Invalid cell size");
    }

    // Calculate new window size in pixels
    const new_width = @as(c_int, @intCast(new_cols)) * cell_width;
    const new_height = @as(c_int, @intCast(new_rows)) * cell_height;

    // Get the window and resize it
    const root = surface.as(gtk.Widget).getRoot() orelse {
        return ipc.err("Surface has no window");
    };

    if (gobject.ext.cast(gtk.Window, root)) |gtk_window| {
        gtk_window.setDefaultSize(new_width, new_height);
    }

    return ipc.success();
}

/// Take a screenshot of a surface.
/// Note: This is a simplified implementation. Full screenshot support
/// requires more complex GTK snapshot/render pipeline.
pub fn screenshotSurface(app: *Application, surface_id: []const u8, output_path: []const u8) Response {
    _ = app;

    // Validate path - reject traversal attempts
    if (std.mem.indexOf(u8, output_path, "..") != null) {
        return ipc.err("Invalid output path");
    }

    _ = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // TODO: Implement GTK screenshot using GdkPaintable/snapshot
    // This requires more complex GTK4 rendering pipeline
    return ipc.err("Screenshot not yet implemented for GTK");
}

/// Create a new window.
pub fn newWindow(app: *Application, arguments: ?[]const []const u8) Response {
    _ = arguments; // TODO: implement command arguments

    // Queue a new window action via the application
    app.performAction(.app, .new_window, .{}) catch {
        return ipc.err("Failed to create new window");
    };

    return ipc.success();
}

/// Create a new tab.
pub fn newTab(app: *Application, arguments: ?[]const []const u8) Response {
    // TODO: implement command arguments
    _ = arguments;

    // Get the focused window for the new tab
    const window_list = gtk.Window.listToplevels();
    defer window_list.free();

    var target_window: ?*Window = null;
    var iter = window_list.iterator();
    while (iter.next()) |data| {
        const widget: *gtk.Widget = @ptrCast(@alignCast(data));
        if (!gobject.ext.isA(widget, Window)) continue;
        const window: *Window = @ptrCast(widget);
        if (window.as(gtk.Window).isActive() != 0) {
            target_window = window;
            break;
        }
    }

    if (target_window) |window| {
        // Create new tab in this window using the action
        _ = window.as(gtk.Widget).activateAction("win.new-tab", null);
        return ipc.success();
    } else {
        // No active window, create a new window instead
        return newWindow(app, null);
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Format an object pointer as a hex ID string.
fn formatObjectId(alloc: Allocator, obj: anytype) ![]const u8 {
    const ptr_int = @intFromPtr(obj);
    return try std.fmt.allocPrint(alloc, "0x{x}", .{ptr_int});
}

/// Parse a hex ID string back to a pointer value.
fn parseObjectId(id: []const u8) ?usize {
    if (id.len < 3 or !std.mem.startsWith(u8, id, "0x")) {
        return null;
    }
    return std.fmt.parseInt(usize, id[2..], 16) catch null;
}

/// Find a surface by its hex ID.
fn findSurfaceById(surface_id: []const u8) ?*Surface {
    const target_ptr = parseObjectId(surface_id) orelse return null;

    // Iterate all windows to find the surface
    const window_list = gtk.Window.listToplevels();
    defer window_list.free();

    var iter = window_list.iterator();
    while (iter.next()) |data| {
        const widget: *gtk.Widget = @ptrCast(@alignCast(data));
        if (!gobject.ext.isA(widget, Window)) continue;
        const window: *Window = @ptrCast(widget);

        // Check surfaces in this window's tabs
        if (findSurfaceInWindow(window, target_ptr)) |surface| {
            return surface;
        }
    }

    return null;
}

/// Find a surface in a window by pointer value.
fn findSurfaceInWindow(window: *Window, target_ptr: usize) ?*Surface {
    // Get the active surface first as a quick check
    if (window.getActiveSurface()) |active| {
        if (@intFromPtr(active) == target_ptr) {
            return active;
        }
    }

    // If not the active surface, we'd need to iterate through tabs
    // For now, return null and rely on the active surface check
    // Full implementation would require accessing the tab_view which is private
    return null;
}

/// Collect tabs from a window.
fn collectTabs(window: *Window, tabs: *std.ArrayList(Response.Tab), alloc: Allocator) !void {
    // Get the active surface info as a single-surface/single-tab representation
    // Full tab iteration would require accessing private tab_view
    const active = window.getActiveSurface() orelse return;

    const surface_id = try formatObjectId(alloc, active);
    const title_raw = active.getTitle();
    const title = if (title_raw) |t| std.mem.span(t) else "";
    const pwd_raw = active.getPwd();
    const pwd = if (pwd_raw) |p| std.mem.span(p) else "";

    const core = active.core();
    var grid_rows: u32 = 0;
    var grid_cols: u32 = 0;
    if (core) |c| {
        const grid = c.size.grid();
        grid_rows = grid.rows;
        grid_cols = grid.columns;
    }

    var surfaces = std.ArrayList(Response.Surface).init(alloc);
    try surfaces.append(.{
        .id = surface_id,
        .title = try alloc.dupe(u8, title),
        .focused = active.getFocused(),
        .pwd = try alloc.dupe(u8, pwd),
        .rows = grid_rows,
        .cols = grid_cols,
    });

    const window_id = try formatObjectId(alloc, window);
    try tabs.append(.{
        .id = try std.fmt.allocPrint(alloc, "{s}:0", .{window_id}),
        .title = try alloc.dupe(u8, title),
        .active = true,
        .surfaces = try surfaces.toOwnedSlice(),
    });
}
