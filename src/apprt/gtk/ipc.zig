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

const apprt = @import("../structs.zig");
const input = @import("../../input.zig");
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

    var windows: std.ArrayListUnmanaged(Response.Window) = .empty;

    // Iterate over all top-level windows
    const window_list = gtk.Window.listToplevels();
    defer window_list.free();

    var node: ?*glib.List = @ptrCast(window_list);
    while (node) |n| : (node = n.f_next) {
        const data = n.f_data orelse continue;
        const widget: *gtk.Widget = @ptrCast(@alignCast(data));

        // Only process our Window type
        if (!gobject.ext.isA(widget, Window)) continue;
        const window: *Window = @ptrCast(widget);

        const window_id = formatObjectId(alloc, window) catch continue;
        const is_focused = window.as(gtk.Window).isActive() != 0;

        var tabs: std.ArrayListUnmanaged(Response.Tab) = .empty;
        collectTabs(window, &tabs, alloc) catch continue;

        windows.append(alloc, .{
            .id = window_id,
            .focused = is_focused,
            .tabs = tabs.toOwnedSlice(alloc) catch &.{},
        }) catch continue;
    }

    return ipc.successData(.{
        .windows = windows.toOwnedSlice(alloc) catch &.{},
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

/// Send a mouse event to a surface.
pub fn sendMouse(
    app: *Application,
    surface_id: []const u8,
    x: f64,
    y: f64,
    button_str: ?[]const u8,
    action_str: ?[]const u8,
    mods_str: ?[]const u8,
) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Parse modifiers
    const mods = parseMods(mods_str);

    // Create cursor position
    const pos: apprt.CursorPos = .{
        .x = @floatCast(x),
        .y = @floatCast(y),
    };

    // If no button specified, this is a motion event
    if (button_str == null) {
        core.cursorPosCallback(pos, mods) catch {
            return ipc.err("Failed to process mouse motion");
        };
        return ipc.success();
    }

    // Parse button
    const button = parseMouseButton(button_str.?) orelse {
        return ipc.err("Invalid mouse button");
    };

    // Parse action (default to press if not specified)
    const action: input.MouseButtonState = if (action_str) |a| blk: {
        if (std.mem.eql(u8, a, "press")) break :blk .press;
        if (std.mem.eql(u8, a, "release")) break :blk .release;
        return ipc.err("Invalid button action (use 'press' or 'release')");
    } else .press;

    // Update cursor position first (mouse events need position context)
    core.cursorPosCallback(pos, mods) catch {
        return ipc.err("Failed to update cursor position");
    };

    // Send button event
    _ = core.mouseButtonCallback(action, button, mods) catch {
        return ipc.err("Failed to process mouse button");
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
/// Captures the last rendered GL frame and saves it as a PNG file.
pub fn screenshotSurface(app: *Application, alloc: Allocator, surface_id: []const u8, output_path: []const u8) Response {
    _ = app;

    // Validate path — reject traversal attempts
    if (std.mem.indexOf(u8, output_path, "..") != null) {
        return ipc.err("Invalid output path");
    }

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    // Create a null-terminated copy of the output path
    const path_z = alloc.dupeZ(u8, output_path) catch {
        return ipc.err("Failed to allocate path");
    };

    if (!surface.screenshotToFile(path_z)) {
        return ipc.err("Failed to capture screenshot");
    }

    return ipc.success();
}

/// Create a new window.
pub fn newWindow(app: *Application, arguments: ?[]const []const u8) Response {
    _ = arguments; // TODO: implement command arguments

    // Queue a new window action via the application
    _ = app.performAction(.app, .new_window, {}) catch {
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
    var node: ?*glib.List = @ptrCast(window_list);
    while (node) |n| : (node = n.f_next) {
        const data = n.f_data orelse continue;
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

    var node: ?*glib.List = @ptrCast(window_list);
    while (node) |n| : (node = n.f_next) {
        const data = n.f_data orelse continue;
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
fn collectTabs(window: *Window, tabs: *std.ArrayListUnmanaged(Response.Tab), alloc: Allocator) !void {
    // Get the active surface info as a single-surface/single-tab representation
    // Full tab iteration would require accessing private tab_view
    const active = window.getActiveSurface() orelse return;

    const surface_id = try formatObjectId(alloc, active);
    const title: []const u8 = if (active.getTitle()) |t| t else "";
    const pwd: []const u8 = if (active.getPwd()) |p| p else "";

    const core = active.core();
    var grid_rows: u32 = 0;
    var grid_cols: u32 = 0;
    if (core) |c| {
        const grid = c.size.grid();
        grid_rows = grid.rows;
        grid_cols = grid.columns;
    }

    var surfaces: std.ArrayListUnmanaged(Response.Surface) = .empty;
    try surfaces.append(alloc, .{
        .id = surface_id,
        .title = try alloc.dupe(u8, title),
        .focused = active.getFocused(),
        .pwd = try alloc.dupe(u8, pwd),
        .rows = grid_rows,
        .cols = grid_cols,
    });

    const window_id = try formatObjectId(alloc, window);
    try tabs.append(alloc, .{
        .id = try std.fmt.allocPrint(alloc, "{s}:0", .{window_id}),
        .title = try alloc.dupe(u8, title),
        .active = true,
        .surfaces = try surfaces.toOwnedSlice(alloc),
    });
}

/// Parse a mouse button string to MouseButton enum.
fn parseMouseButton(button_str: []const u8) ?input.MouseButton {
    if (std.mem.eql(u8, button_str, "left")) return .left;
    if (std.mem.eql(u8, button_str, "right")) return .right;
    if (std.mem.eql(u8, button_str, "middle")) return .middle;
    if (std.mem.eql(u8, button_str, "four")) return .four;
    if (std.mem.eql(u8, button_str, "five")) return .five;
    if (std.mem.eql(u8, button_str, "six")) return .six;
    if (std.mem.eql(u8, button_str, "seven")) return .seven;
    if (std.mem.eql(u8, button_str, "eight")) return .eight;
    if (std.mem.eql(u8, button_str, "nine")) return .nine;
    if (std.mem.eql(u8, button_str, "ten")) return .ten;
    if (std.mem.eql(u8, button_str, "eleven")) return .eleven;
    return null;
}

/// Send a scroll event to a surface.
pub fn sendScroll(
    app: *Application,
    surface_id: []const u8,
    x: f64,
    y: f64,
    mods_str: ?[]const u8,
) Response {
    _ = app;
    _ = mods_str; // TODO: modifiers not currently used for scroll

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Send discrete scroll event (non-precision)
    const scroll_mods: input.ScrollMods = .{
        .precision = false,
        .momentum = .none,
    };

    core.scrollCallback(x, y, scroll_mods) catch {
        return ipc.err("Failed to process scroll event");
    };

    return ipc.success();
}

/// Send a key event to a surface.
pub fn sendKey(
    app: *Application,
    surface_id: []const u8,
    key_str: []const u8,
    action_str: ?[]const u8,
    mods_str: ?[]const u8,
) Response {
    _ = app;

    const surface = findSurfaceById(surface_id) orelse {
        return ipc.err("Surface not found");
    };

    const core = surface.core() orelse {
        return ipc.err("Surface not initialized");
    };

    // Parse key using W3C key code format
    const key = input.Key.fromW3C(key_str) orelse {
        return ipc.err("Invalid key name");
    };

    // Parse action (default to press)
    const action: input.Action = if (action_str) |a| blk: {
        if (std.mem.eql(u8, a, "press")) break :blk .press;
        if (std.mem.eql(u8, a, "release")) break :blk .release;
        if (std.mem.eql(u8, a, "repeat")) break :blk .repeat;
        return ipc.err("Invalid action (use 'press', 'release', or 'repeat')");
    } else .press;

    // Parse modifiers
    const mods = parseMods(mods_str);

    // Create key event
    const event: input.KeyEvent = .{
        .action = action,
        .key = key,
        .mods = mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = "",
        .unshifted_codepoint = 0,
    };

    // Send key event
    _ = core.keyCallback(event) catch {
        return ipc.err("Failed to process key event");
    };

    return ipc.success();
}

/// Parse modifier string to Mods struct.
fn parseMods(mods_str: ?[]const u8) input.Mods {
    var mods: input.Mods = .{};
    const str = mods_str orelse return mods;

    var iter = std.mem.tokenizeAny(u8, str, ", ");
    while (iter.next()) |mod| {
        const trimmed = std.mem.trim(u8, mod, " ");
        if (std.mem.eql(u8, trimmed, "shift")) mods.shift = true;
        if (std.mem.eql(u8, trimmed, "ctrl")) mods.ctrl = true;
        if (std.mem.eql(u8, trimmed, "alt")) mods.alt = true;
        if (std.mem.eql(u8, trimmed, "super")) mods.super = true;
    }
    return mods;
}
