//! Inter-process Communication to a running Ghostty instance from a separate
//! process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("../lib/main.zig");

pub const Errors = error{
    /// The IPC failed. If a function returns this error, it's expected that
    /// an a more specific error message will have been written to stderr (or
    /// otherwise shown to the user in an appropriate way).
    IPCFailed,
};

pub const Target = union(Key) {
    /// Open up a new window in a custom instance of Ghostty.
    class: [:0]const u8,

    /// Detect which instance to open a new window in.
    detect,

    // Sync with: ghostty_ipc_target_tag_e
    pub const Key = enum(c_int) {
        class,
        detect,

        test "ghostty.h Target.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_TARGET_");
        }
    };

    // Sync with: ghostty_ipc_target_u
    pub const CValue = extern union {
        class: [*:0]const u8,
        detect: void,
    };

    // Sync with: ghostty_ipc_target_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    /// Convert to ghostty_ipc_target_s.
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .class => |class| .{ .class = class.ptr },
                .detect => .{ .detect = {} },
            },
        };
    }
};

pub const Action = union(enum) {
    // A GUIDE TO ADDING NEW ACTIONS:
    //
    // 1. Add the action to the `Key` enum. The order of the enum matters
    //    because it maps directly to the libghostty C enum. For ABI
    //    compatibility, new actions should be added to the end of the enum.
    //
    // 2. Add the action and optional value to the Action union.
    //
    // 3. If the value type is not void, ensure the value is C ABI
    //    compatible (extern). If it is not, add a `C` decl to the value
    //    and a `cval` function to convert to the C ABI compatible value.
    //
    // 4. Update `include/ghostty.h`: add the new key, value, and union
    //    entry. If the value type is void then only the key needs to be
    //    added. Ensure the order matches exactly with the Zig code.

    /// The arguments to pass to Ghostty as the command for a new window.
    new_window: NewWindow,

    /// The arguments to pass to Ghostty as the command for a new tab.
    new_tab: NewTab,

    /// List all open surfaces (windows, tabs, splits).
    list_surfaces: void,

    /// Send text to a specific surface.
    send_text: SendText,

    /// Get the screen content from a specific surface.
    get_screen: GetScreen,

    /// Focus a specific surface (bring window to front).
    focus_surface: FocusSurface,

    /// Close a specific surface.
    close_surface: CloseSurface,

    /// Resize a surface's window.
    resize_surface: ResizeSurface,

    /// Take a screenshot of a surface.
    screenshot_surface: ScreenshotSurface,

    /// Send a mouse event to a surface.
    send_mouse: SendMouse,

    /// Send a scroll event to a surface.
    send_scroll: SendScroll,

    /// Send a key event to a surface.
    send_key: SendKey,

    pub const SendKey = struct {
        /// The surface ID to send the key event to (from list_surfaces).
        surface_id: [:0]const u8,

        /// Key name in W3C format (e.g., "Escape", "ArrowUp", "KeyA", "Enter").
        key: [:0]const u8,

        /// Key action: "press", "release", or "repeat". Default is "press".
        action: ?[:0]const u8 = null,

        /// Modifier keys: comma-separated list of "shift", "ctrl", "alt", "super".
        mods: ?[:0]const u8 = null,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
            key: [*:0]const u8,
            action: ?[*:0]const u8,
            mods: ?[*:0]const u8,
        };

        pub fn cval(self: SendKey) SendKey.C {
            return .{
                .surface_id = self.surface_id.ptr,
                .key = self.key.ptr,
                .action = if (self.action) |a| a.ptr else null,
                .mods = if (self.mods) |m| m.ptr else null,
            };
        }
    };

    pub const SendScroll = struct {
        /// The surface ID to send the scroll event to (from list_surfaces).
        surface_id: [:0]const u8,

        /// Horizontal scroll delta (positive = right, negative = left).
        x: f64 = 0,

        /// Vertical scroll delta (positive = down, negative = up).
        y: f64 = 0,

        /// Modifier keys: comma-separated list of "shift", "ctrl", "alt", "super".
        mods: ?[:0]const u8 = null,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
            x: f64,
            y: f64,
            mods: ?[*:0]const u8,
        };

        pub fn cval(self: SendScroll) SendScroll.C {
            return .{
                .surface_id = self.surface_id.ptr,
                .x = self.x,
                .y = self.y,
                .mods = if (self.mods) |m| m.ptr else null,
            };
        }
    };

    pub const SendMouse = struct {
        /// The surface ID to send the mouse event to (from list_surfaces).
        surface_id: [:0]const u8,

        /// X position in pixels (relative to surface origin).
        x: f64,

        /// Y position in pixels (relative to surface origin).
        y: f64,

        /// Mouse button: "left", "right", "middle", "four", "five", etc.
        /// Optional for motion-only events.
        button: ?[:0]const u8 = null,

        /// Button action: "press" or "release". Required if button is set.
        button_action: ?[:0]const u8 = null,

        /// Modifier keys: comma-separated list of "shift", "ctrl", "alt", "super".
        mods: ?[:0]const u8 = null,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
            x: f64,
            y: f64,
            button: ?[*:0]const u8,
            button_action: ?[*:0]const u8,
            mods: ?[*:0]const u8,
        };

        pub fn cval(self: SendMouse) SendMouse.C {
            return .{
                .surface_id = self.surface_id.ptr,
                .x = self.x,
                .y = self.y,
                .button = if (self.button) |b| b.ptr else null,
                .button_action = if (self.button_action) |a| a.ptr else null,
                .mods = if (self.mods) |m| m.ptr else null,
            };
        }
    };

    pub const ScreenshotSurface = struct {
        /// The surface ID to screenshot (from list_surfaces).
        surface_id: [:0]const u8,

        /// Output file path (PNG format).
        output_path: [:0]const u8,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
            output_path: [*:0]const u8,
        };

        pub fn cval(self: ScreenshotSurface) ScreenshotSurface.C {
            return .{
                .surface_id = self.surface_id.ptr,
                .output_path = self.output_path.ptr,
            };
        }
    };

    pub const ResizeSurface = struct {
        /// The surface ID to resize (from list_surfaces).
        surface_id: [:0]const u8,

        /// Number of rows (if resizing by cells). 0 means don't change.
        rows: u32 = 0,

        /// Number of columns (if resizing by cells). 0 means don't change.
        cols: u32 = 0,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
            rows: u32,
            cols: u32,
        };

        pub fn cval(self: ResizeSurface) ResizeSurface.C {
            return .{
                .surface_id = self.surface_id.ptr,
                .rows = self.rows,
                .cols = self.cols,
            };
        }
    };

    pub const CloseSurface = struct {
        /// The surface ID to close (from list_surfaces).
        surface_id: [:0]const u8,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
        };

        pub fn cval(self: CloseSurface) CloseSurface.C {
            return .{
                .surface_id = self.surface_id.ptr,
            };
        }
    };

    pub const FocusSurface = struct {
        /// The surface ID to focus (from list_surfaces).
        surface_id: [:0]const u8,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
        };

        pub fn cval(self: FocusSurface) FocusSurface.C {
            return .{
                .surface_id = self.surface_id.ptr,
            };
        }
    };

    pub const GetScreen = struct {
        /// The surface ID to read from (from list_surfaces).
        surface_id: [:0]const u8,

        /// Which portion of the screen to read.
        /// - "viewport": Currently visible content
        /// - "active": Active screen area (no scrollback)
        /// - "screen": Full screen including scrollback
        screen: [:0]const u8,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
            screen: [*:0]const u8,
        };

        pub fn cval(self: GetScreen) GetScreen.C {
            return .{
                .surface_id = self.surface_id.ptr,
                .screen = self.screen.ptr,
            };
        }
    };

    pub const SendText = struct {
        /// The surface ID to send text to (from list_surfaces).
        surface_id: [:0]const u8,

        /// The text to send to the surface.
        text: [:0]const u8,

        pub const C = extern struct {
            surface_id: [*:0]const u8,
            text: [*:0]const u8,
        };

        pub fn cval(self: SendText) SendText.C {
            return .{
                .surface_id = self.surface_id.ptr,
                .text = self.text.ptr,
            };
        }
    };

    pub const NewWindow = struct {
        /// A list of command arguments to launch in the new window. If this is
        /// `null` the command configured in the config or the user's default
        /// shell should be launched.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *NewWindow.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *NewWindow, alloc: Allocator) Allocator.Error!NewWindow.C {
            var result: NewWindow.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const NewTab = struct {
        /// A list of command arguments to launch in the new tab. If this is
        /// `null` the command configured in the config or the user's default
        /// shell should be launched.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *NewTab.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *NewTab, alloc: Allocator) Allocator.Error!NewTab.C {
            var result: NewTab.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    /// Sync with: ghostty_ipc_action_tag_e
    pub const Key = enum(c_int) {
        new_window,
        new_tab,
        list_surfaces,
        send_text,
        get_screen,
        focus_surface,
        close_surface,
        resize_surface,
        screenshot_surface,
        send_mouse,
        send_scroll,
        send_key,

        test "ghostty.h Action.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_ACTION_");
        }
    };

    /// Sync with: ghostty_ipc_action_u
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var union_fields: [key_fields.len]std.builtin.Type.UnionField = undefined;
        for (key_fields, 0..) |field, i| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                // Types can provide custom types for their CValue.
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };

            union_fields[i] = .{
                .name = field.name,
                .type = Type,
                .alignment = @alignOf(Type),
            };
        }

        break :cvalue @Type(.{ .@"union" = .{
            .layout = .@"extern",
            .tag_type = null,
            .fields = &union_fields,
            .decls = &.{},
        } });
    };

    /// Sync with: ghostty_ipc_action_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    comptime {
        // For ABI compatibility, we expect that this is our union size.
        // At the time of writing, we don't promise ABI compatibility
        // so we can change this but I want to be aware of it.
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 32, // SendMouse.C: 4 ptr + 2*8 f64 + 3*4 ptr = 32
            8 => 48, // SendMouse.C: 1*8 ptr + 2*8 f64 + 3*8 ptr = 48
            else => unreachable,
        });
    }

    /// Returns the value type for the given key.
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }

        unreachable;
    }

    /// Convert to ghostty_ipc_action_s.
    pub fn cval(self: Action, alloc: Allocator) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval(alloc) else v,
            ),
        };

        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};
