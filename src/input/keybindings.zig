const std = @import("std");
const commands = @import("commands.zig");
const Command = commands.Command;

const c = @cImport({
    @cInclude("gdk/gdk.h");
});

// Symbolic key name enum
pub const KeyName = enum {
    NONE,
    // Letters
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,
    // Numbers
    NUM_0,
    NUM_1,
    NUM_2,
    NUM_3,
    NUM_4,
    NUM_5,
    NUM_6,
    NUM_7,
    NUM_8,
    NUM_9,
    // Arrow keys
    ARROW_UP,
    ARROW_DOWN,
    ARROW_LEFT,
    ARROW_RIGHT,
    // Special keys
    SPACE,
    ENTER,
    ESCAPE,
    TAB,
    BACKSPACE,
    // Symbols
    PLUS,
    MINUS,
    EQUAL,
    SLASH,
    QUESTION,
    LESS_THAN,
    GREATER_THAN,
    COLON,
    SEMICOLON,
    // Function keys
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
};

// Modifier flags
pub const ModifierFlags = struct {
    const NONE = 0;
    const SHIFT = 1 << 0;
    const CTRL = 1 << 1;
    const ALT = 1 << 2;
    const SUPER = 1 << 3;
};

pub const Modifiers = u32;

pub const KeyBinding = struct {
    key: KeyName,
    modifiers: Modifiers,
};

// TODO: Implement me (tries?)
pub const KeyCombination = struct {};

pub fn gdkKeyvalToKeyName(keyval: u32) KeyName {
    return switch (keyval) {
        // Letters
        c.GDK_KEY_a => .a,
        c.GDK_KEY_b => .b,
        c.GDK_KEY_c => .c,
        c.GDK_KEY_d => .d,
        c.GDK_KEY_e => .e,
        c.GDK_KEY_f => .f,
        c.GDK_KEY_g => .g,
        c.GDK_KEY_h => .h,
        c.GDK_KEY_i => .i,
        c.GDK_KEY_j => .j,
        c.GDK_KEY_k => .k,
        c.GDK_KEY_l => .l,
        c.GDK_KEY_m => .m,
        c.GDK_KEY_n => .n,
        c.GDK_KEY_o => .o,
        c.GDK_KEY_p => .p,
        c.GDK_KEY_q => .q,
        c.GDK_KEY_r => .r,
        c.GDK_KEY_s => .s,
        c.GDK_KEY_t => .t,
        c.GDK_KEY_u => .u,
        c.GDK_KEY_v => .v,
        c.GDK_KEY_w => .w,
        c.GDK_KEY_x => .x,
        c.GDK_KEY_y => .y,
        c.GDK_KEY_z => .z,
        c.GDK_KEY_A => .A,
        c.GDK_KEY_B => .B,
        c.GDK_KEY_C => .C,
        c.GDK_KEY_D => .D,
        c.GDK_KEY_E => .E,
        c.GDK_KEY_F => .F,
        c.GDK_KEY_G => .G,
        c.GDK_KEY_H => .H,
        c.GDK_KEY_I => .I,
        c.GDK_KEY_J => .J,
        c.GDK_KEY_K => .K,
        c.GDK_KEY_L => .L,
        c.GDK_KEY_M => .M,
        c.GDK_KEY_N => .N,
        c.GDK_KEY_O => .O,
        c.GDK_KEY_P => .P,
        c.GDK_KEY_Q => .Q,
        c.GDK_KEY_R => .R,
        c.GDK_KEY_S => .S,
        c.GDK_KEY_T => .T,
        c.GDK_KEY_U => .U,
        c.GDK_KEY_V => .V,
        c.GDK_KEY_W => .W,
        c.GDK_KEY_X => .X,
        c.GDK_KEY_Y => .Y,
        c.GDK_KEY_Z => .Z,
        // Numbers
        c.GDK_KEY_0 => .NUM_0,
        c.GDK_KEY_1 => .NUM_1,
        c.GDK_KEY_2 => .NUM_2,
        c.GDK_KEY_3 => .NUM_3,
        c.GDK_KEY_4 => .NUM_4,
        c.GDK_KEY_5 => .NUM_5,
        c.GDK_KEY_6 => .NUM_6,
        c.GDK_KEY_7 => .NUM_7,
        c.GDK_KEY_8 => .NUM_8,
        c.GDK_KEY_9 => .NUM_9,
        // Arrow keys
        c.GDK_KEY_Up => .ARROW_UP,
        c.GDK_KEY_Down => .ARROW_DOWN,
        c.GDK_KEY_Left => .ARROW_LEFT,
        c.GDK_KEY_Right => .ARROW_RIGHT,
        // Special keys
        c.GDK_KEY_space => .SPACE,
        c.GDK_KEY_Return => .ENTER,
        c.GDK_KEY_Escape => .ESCAPE,
        c.GDK_KEY_Tab => .TAB,
        c.GDK_KEY_BackSpace => .BACKSPACE,
        // Symbols
        c.GDK_KEY_plus => .PLUS,
        c.GDK_KEY_minus => .MINUS,
        c.GDK_KEY_equal => .EQUAL,
        c.GDK_KEY_slash => .SLASH,
        c.GDK_KEY_question => .QUESTION,
        c.GDK_KEY_less => .LESS_THAN,
        c.GDK_KEY_greater => .GREATER_THAN,
        c.GDK_KEY_colon => .COLON,
        c.GDK_KEY_semicolon => .SEMICOLON,
        // Function keys
        c.GDK_KEY_F1 => .F1,
        c.GDK_KEY_F2 => .F2,
        c.GDK_KEY_F3 => .F3,
        c.GDK_KEY_F4 => .F4,
        c.GDK_KEY_F5 => .F5,
        c.GDK_KEY_F6 => .F6,
        c.GDK_KEY_F7 => .F7,
        c.GDK_KEY_F8 => .F8,
        c.GDK_KEY_F9 => .F9,
        c.GDK_KEY_F10 => .F10,
        c.GDK_KEY_F11 => .F11,
        c.GDK_KEY_F12 => .F12,
        else => .NONE,
    };
}

pub fn gdkModifiersToFlags(gdk_modifiers: u32) Modifiers {
    var flags: Modifiers = ModifierFlags.NONE;
    if (gdk_modifiers & c.GDK_SHIFT_MASK != 0) flags |= ModifierFlags.SHIFT;
    if (gdk_modifiers & c.GDK_CONTROL_MASK != 0) flags |= ModifierFlags.CTRL;
    if (gdk_modifiers & c.GDK_MOD1_MASK != 0) flags |= ModifierFlags.ALT;
    if (gdk_modifiers & c.GDK_SUPER_MASK != 0) flags |= ModifierFlags.SUPER;
    return flags;
}

pub const KeyBindings = struct {
    const Self = @This();

    bindings: std.AutoArrayHashMap(KeyBinding, Command),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        var bindings = std.AutoArrayHashMap(KeyBinding, Command).init(allocator);
        _ = initDefaultBindings(&bindings) catch {};

        return .{
            .bindings = bindings,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.bindings.deinit();
    }

    fn initDefaultBindings(bindings: *std.AutoArrayHashMap(KeyBinding, Command)) !void {
        // Navigation (vim-style)
        try bindings.put(.{ .key = .j, .modifiers = ModifierFlags.NONE }, .next_page);
        try bindings.put(.{ .key = .k, .modifiers = ModifierFlags.NONE }, .prev_page);
        try bindings.put(.{ .key = .h, .modifiers = ModifierFlags.NONE }, .scroll_left);
        try bindings.put(.{ .key = .l, .modifiers = ModifierFlags.NONE }, .scroll_right);

        // Page navigation
        try bindings.put(.{ .key = .g, .modifiers = ModifierFlags.NONE }, .first_page);
        try bindings.put(.{ .key = .G, .modifiers = ModifierFlags.NONE }, .last_page);
        try bindings.put(.{ .key = .SPACE, .modifiers = ModifierFlags.NONE }, .next_page);
        try bindings.put(.{ .key = .BACKSPACE, .modifiers = ModifierFlags.NONE }, .prev_page);

        // Arrow keys
        try bindings.put(.{ .key = .ARROW_UP, .modifiers = ModifierFlags.NONE }, .scroll_up);
        try bindings.put(.{ .key = .ARROW_DOWN, .modifiers = ModifierFlags.NONE }, .scroll_down);
        try bindings.put(.{ .key = .ARROW_LEFT, .modifiers = ModifierFlags.NONE }, .scroll_left);
        try bindings.put(.{ .key = .ARROW_RIGHT, .modifiers = ModifierFlags.NONE }, .scroll_right);

        // Zoom
        try bindings.put(.{ .key = .PLUS, .modifiers = ModifierFlags.NONE }, .zoom_in);
        try bindings.put(.{ .key = .EQUAL, .modifiers = ModifierFlags.NONE }, .zoom_in);
        try bindings.put(.{ .key = .MINUS, .modifiers = ModifierFlags.NONE }, .zoom_out);
        try bindings.put(.{ .key = .NUM_0, .modifiers = ModifierFlags.NONE }, .zoom_original);

        // Fit modes
        try bindings.put(.{ .key = .a, .modifiers = ModifierFlags.NONE }, .zoom_fit_page);
        try bindings.put(.{ .key = .s, .modifiers = ModifierFlags.NONE }, .zoom_fit_width);

        // Application
        try bindings.put(.{ .key = .q, .modifiers = ModifierFlags.NONE }, .quit);
        try bindings.put(.{ .key = .r, .modifiers = ModifierFlags.NONE }, .refresh);
        try bindings.put(.{ .key = .f, .modifiers = ModifierFlags.NONE }, .toggle_fullscreen);
        try bindings.put(.{ .key = .ESCAPE, .modifiers = ModifierFlags.NONE }, .quit);

        // TOC navigation
        try bindings.put(.{ .key = .TAB, .modifiers = ModifierFlags.NONE }, .toggle_toc);
        try bindings.put(.{ .key = .ENTER, .modifiers = ModifierFlags.NONE }, .toc_select);

        // Highlighting
        try bindings.put(.{ .key = .h, .modifiers = ModifierFlags.NONE }, .save_highlight);
        try bindings.put(.{ .key = .c, .modifiers = ModifierFlags.NONE }, .clear_selection);

        // Layout controls
        try bindings.put(.{ .key = .GREATER_THAN, .modifiers = ModifierFlags.NONE }, .increase_pages_per_row);
        try bindings.put(.{ .key = .LESS_THAN, .modifiers = ModifierFlags.NONE }, .decrease_pages_per_row);
        try bindings.put(.{ .key = .NUM_1, .modifiers = ModifierFlags.NONE }, .single_page_mode);
        try bindings.put(.{ .key = .NUM_2, .modifiers = ModifierFlags.NONE }, .double_page_mode);

        // Search
        try bindings.put(.{ .key = .SLASH, .modifiers = ModifierFlags.NONE }, .search_forward);
        try bindings.put(.{ .key = .QUESTION, .modifiers = ModifierFlags.NONE }, .search_backward);
        try bindings.put(.{ .key = .N, .modifiers = ModifierFlags.NONE }, .search_next);
        try bindings.put(.{ .key = .n, .modifiers = ModifierFlags.NONE }, .search_prev);
    }

    pub fn getCommand(self: *const Self, keyName: KeyName, modifiers: Modifiers) ?Command {
        const key: KeyBinding = .{ .key = keyName, .modifiers = modifiers };
        return self.bindings.get(key);
    }
};
