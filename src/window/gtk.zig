const std = @import("std");
const keybindings = @import("../input/keybindings.zig");

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("cairo.h");
});

pub const GdkEventType = enum(c_int) {
    GDK_NOTHING = -1,
    GDK_DELETE = 0,
    GDK_DESTROY = 1,
    GDK_EXPOSE = 2,
    GDK_MOTION_NOTIFY = 3,
    GDK_BUTTON_PRESS = 4,
    GDK_2BUTTON_PRESS = 5,
    GDK_3BUTTON_PRESS = 6,
    GDK_BUTTON_RELEASE = 7,
    GDK_KEY_PRESS = 8,
    GDK_KEY_RELEASE = 9,
    GDK_ENTER_NOTIFY = 10,
    GDK_LEAVE_NOTIFY = 11,
    GDK_FOCUS_CHANGE = 12,
    GDK_CONFIGURE = 13,
    GDK_MAP = 14,
    GDK_UNMAP = 15,
    GDK_PROPERTY_NOTIFY = 16,
    GDK_SELECTION_CLEAR = 17,
    GDK_SELECTION_REQUEST = 18,
    GDK_SELECTION_NOTIFY = 19,
    GDK_PROXIMITY_IN = 20,
    GDK_PROXIMITY_OUT = 21,
    GDK_DRAG_ENTER = 22,
    GDK_DRAG_LEAVE = 23,
    GDK_DRAG_MOTION = 24,
    GDK_DRAG_STATUS = 25,
    GDK_DROP_START = 26,
    GDK_DROP_FINISHED = 27,
    GDK_CLIENT_EVENT = 28,
    GDK_VISIBILITY_NOTIFY = 29,
    GDK_SCROLL = 31,
    GDK_WINDOW_STATE = 32,
    GDK_SETTING = 33,
    GDK_OWNER_CHANGE = 34,
    GDK_GRAB_BROKEN = 35,
    GDK_DAMAGE = 36,
    GDK_TOUCH_BEGIN = 37,
    GDK_TOUCH_UPDATE = 38,
    GDK_TOUCH_END = 39,
    GDK_TOUCH_CANCEL = 40,
    GDK_TOUCHPAD_SWIPE = 41,
    GDK_TOUCHPAD_PINCH = 42,
    GDK_PAD_BUTTON_PRESS = 43,
    GDK_PAD_BUTTON_RELEASE = 44,
    GDK_PAD_RING = 45,
    GDK_PAD_STRIP = 46,
    GDK_PAD_GROUP_MODE = 47,
    GDK_EVENT_LAST = 48,

    pub fn name(self: GdkEventType) []const u8 {
        return switch (self) {
            inline else => @tagName(self),
        };
    }
};

pub const GdkModifierMask = enum(u32) {
    SHIFT_MASK = 1,
    LOCK_MASK = 2,
    CONTROL_MASK = 4,
    MOD1_MASK = 8,
    MOD2_MASK = 16,
    MOD3_MASK = 32,
    MOD4_MASK = 64,
    MOD5_MASK = 128,
    BUTTON1_MASK = 256,
    BUTTON2_MASK = 512,
    BUTTON3_MASK = 1024,
    BUTTON4_MASK = 2048,
    BUTTON5_MASK = 4096,
    MODIFIER_RESERVED_13_MASK = 8192,
    MODIFIER_RESERVED_14_MASK = 16384,
    MODIFIER_RESERVED_15_MASK = 32768,
    MODIFIER_RESERVED_16_MASK = 65536,
    MODIFIER_RESERVED_17_MASK = 131072,
    MODIFIER_RESERVED_18_MASK = 262144,
    MODIFIER_RESERVED_19_MASK = 524288,
    MODIFIER_RESERVED_20_MASK = 1048576,
    MODIFIER_RESERVED_21_MASK = 2097152,
    MODIFIER_RESERVED_22_MASK = 4194304,
    MODIFIER_RESERVED_23_MASK = 8388608,
    MODIFIER_RESERVED_24_MASK = 16777216,
    MODIFIER_RESERVED_25_MASK = 33554432,
    SUPER_MASK = 67108864,
    HYPER_MASK = 134217728,
    META_MASK = 268435456,
    MODIFIER_RESERVED_29_MASK = 536870912,
    RELEASE_MASK = 1073741824,
    MODIFIER_MASK = 1543512063,
};

pub const GdkEventButton = extern struct {
    type: GdkEventType,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    axes: ?*anyopaque,
    state: u32,
    button: u32,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
};

pub const GdkEventKey = extern struct {
    type: GdkEventType,
    window: *anyopaque,
    send_event: i8,
    time: u32,
    state: u32,
    keyval: u32,
    length: i32,
    string: [*c]u8,
    hardware_keycode: u16,
    group: u8,
    is_modifier: bool,
};

pub const GdkEventScroll = extern struct {
    type: GdkEventType,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    state: u32,
    direction: c.GdkScrollDirection,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
    delta_x: f64,
    delta_y: f64,
    is_stop: bool,
};

pub const GdkEventConfigure = extern struct {
    type: GdkEventType,
    window: ?*anyopaque,
    send_event: i8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

// Event handler interface - allows different types to handle events
pub const EventHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        onButtonPress: *const fn (ptr: *anyopaque, event: *GdkEventButton) bool,
        onButtonRelease: *const fn (ptr: *anyopaque, event: *GdkEventButton) bool,
        onMotionNotify: *const fn (ptr: *anyopaque, event: *GdkEventButton) bool,
        onKeyPress: *const fn (ptr: *anyopaque, event: *GdkEventKey) bool,
        onScroll: *const fn (ptr: *anyopaque, event: *GdkEventScroll) bool,
        onWindowResize: *const fn (ptr: *anyopaque, event: *GdkEventConfigure) bool,
    };

    pub fn init(pointer: anytype) EventHandler {
        const T = @TypeOf(pointer);
        const gen = struct {
            pub fn onButtonPress(ptr: *anyopaque, event: *GdkEventButton) bool {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.onButtonPress(event);
            }

            pub fn onButtonRelease(ptr: *anyopaque, event: *GdkEventButton) bool {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.onButtonRelease(event);
            }

            pub fn onMotionNotify(ptr: *anyopaque, event: *GdkEventButton) bool {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.onMotionNotify(event);
            }

            pub fn onKeyPress(ptr: *anyopaque, event: *GdkEventKey) bool {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.onKeyPress(event);
            }

            pub fn onScroll(ptr: *anyopaque, event: *GdkEventScroll) bool {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.onScroll(event);
            }

            pub fn onWindowResize(ptr: *anyopaque, event: *GdkEventConfigure) bool {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.onWindowResize(event);
            }
        };

        return EventHandler{
            .ptr = pointer,
            .vtable = &.{
                .onButtonPress = gen.onButtonPress,
                .onButtonRelease = gen.onButtonRelease,
                .onMotionNotify = gen.onMotionNotify,
                .onKeyPress = gen.onKeyPress,
                .onScroll = gen.onScroll,
                .onWindowResize = gen.onWindowResize,
            },
        };
    }
};

// Global event handler storage
var event_handler: ?EventHandler = null;

pub fn setEventHandler(handler: EventHandler) void {
    event_handler = handler;
}

// C callback wrappers
pub export fn onButtonPress(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    if (event_handler) |handler| {
        const button_event: *GdkEventButton = @ptrCast(@alignCast(event.?));
        return if (handler.vtable.onButtonPress(handler.ptr, button_event)) 1 else 0;
    }
    return 0;
}

pub export fn onButtonRelease(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    if (event_handler) |handler| {
        const button_event: *GdkEventButton = @ptrCast(@alignCast(event.?));
        return if (handler.vtable.onButtonRelease(handler.ptr, button_event)) 1 else 0;
    }
    return 0;
}

pub export fn onMotionNotify(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    if (event_handler) |handler| {
        const motion_event: *GdkEventButton = @ptrCast(@alignCast(event.?));
        return if (handler.vtable.onMotionNotify(handler.ptr, motion_event)) 1 else 0;
    }
    return 0;
}

pub export fn onKeyPress(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    if (event_handler) |handler| {
        const gdk_event: *GdkEventKey = @ptrCast(@alignCast(event.?));
        return if (handler.vtable.onKeyPress(handler.ptr, gdk_event)) 1 else 0;
    }
    return 0;
}

pub export fn onScroll(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    if (event_handler) |handler| {
        const gdk_event: *GdkEventScroll = @ptrCast(@alignCast(event.?));
        return if (handler.vtable.onScroll(handler.ptr, gdk_event)) 1 else 0;
    }
    return 0;
}

pub export fn onWindowResize(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    if (event_handler) |handler| {
        const gdk_event: *GdkEventConfigure = @ptrCast(@alignCast(event.?));
        return if (handler.vtable.onWindowResize(handler.ptr, gdk_event)) 1 else 0;
    }
    return 0;
}

pub export fn onDestroy(_: *c.GtkWidget, _: ?*anyopaque) callconv(.C) void {
    c.gtk_main_quit();
}

// This function needs to be implemented in the module that uses this
// For now, we'll export a placeholder that can be overridden
export fn updateCurrentPageFromScroll(user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    return 0;
}