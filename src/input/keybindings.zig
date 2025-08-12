const std = @import("std");
const commands = @import("commands.zig");
const Command = commands.Command;

// GTK modifier constants
const SHIFT_MASK: u32 = 1;

pub const KeyBinding = struct {
    key: u32,
    modifiers: u32,
    command: Command,
};

pub const KeyBindings = struct {
    const Self = @This();

    bindings: std.ArrayList(KeyBinding),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .bindings = std.ArrayList(KeyBinding).init(allocator),
            .allocator = allocator,
        };

        // Initialize default vim-like bindings
        self.initDefaultBindings() catch {};

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.bindings.deinit();
    }

    fn initDefaultBindings(self: *Self) !void {
        // Navigation (vim-style)
        try self.bindings.append(.{ .key = 'j', .modifiers = 0, .command = .next_page });
        try self.bindings.append(.{ .key = 'k', .modifiers = 0, .command = .prev_page });
        try self.bindings.append(.{ .key = 'h', .modifiers = 0, .command = .scroll_left });
        try self.bindings.append(.{ .key = 'l', .modifiers = 0, .command = .scroll_right });

        // Page navigation
        try self.bindings.append(.{ .key = 'g', .modifiers = 0, .command = .first_page });
        try self.bindings.append(.{ .key = 'G', .modifiers = SHIFT_MASK, .command = .last_page });
        try self.bindings.append(.{ .key = 32, .modifiers = 0, .command = .next_page }); // Space
        try self.bindings.append(.{ .key = 65288, .modifiers = 0, .command = .prev_page }); // Backspace

        // Arrow keys
        try self.bindings.append(.{ .key = 65362, .modifiers = 0, .command = .scroll_up }); // Up
        try self.bindings.append(.{ .key = 65364, .modifiers = 0, .command = .scroll_down }); // Down
        try self.bindings.append(.{ .key = 65361, .modifiers = 0, .command = .scroll_left }); // Left
        try self.bindings.append(.{ .key = 65363, .modifiers = 0, .command = .scroll_right }); // Right

        // Zoom
        try self.bindings.append(.{ .key = '+', .modifiers = SHIFT_MASK, .command = .zoom_in });
        try self.bindings.append(.{ .key = '=', .modifiers = 0, .command = .zoom_in });
        try self.bindings.append(.{ .key = '-', .modifiers = 0, .command = .zoom_out });
        try self.bindings.append(.{ .key = '0', .modifiers = 0, .command = .zoom_original });

        // Fit modes
        try self.bindings.append(.{ .key = 'a', .modifiers = 0, .command = .zoom_fit_page });
        try self.bindings.append(.{ .key = 's', .modifiers = 0, .command = .zoom_fit_width });

        // Application
        try self.bindings.append(.{ .key = 'q', .modifiers = 0, .command = .quit });
        try self.bindings.append(.{ .key = 'r', .modifiers = 0, .command = .refresh });
        try self.bindings.append(.{ .key = 'F', .modifiers = SHIFT_MASK, .command = .toggle_fullscreen });
        try self.bindings.append(.{ .key = 65307, .modifiers = 0, .command = .quit }); // Escape

        // TOC navigation
        try self.bindings.append(.{ .key = 65289, .modifiers = 0, .command = .toggle_toc }); // Tab
        try self.bindings.append(.{ .key = 65293, .modifiers = 0, .command = .toc_select }); // Enter (when in TOC mode)

        // Highlighting
        try self.bindings.append(.{ .key = 'H', .modifiers = SHIFT_MASK, .command = .save_highlight }); // Shift+H
        try self.bindings.append(.{ .key = 'c', .modifiers = 0, .command = .clear_selection }); // 'c' to clear selection

        // Layout controls - shift-modified characters need shift modifier
        try self.bindings.append(.{ .key = '>', .modifiers = SHIFT_MASK, .command = .increase_pages_per_row });
        try self.bindings.append(.{ .key = '<', .modifiers = 0, .command = .decrease_pages_per_row });
        try self.bindings.append(.{ .key = '1', .modifiers = 0, .command = .single_page_mode });
        try self.bindings.append(.{ .key = '2', .modifiers = 0, .command = .double_page_mode });

        // Search
        try self.bindings.append(.{ .key = '/', .modifiers = 0, .command = .search_forward });
        try self.bindings.append(.{ .key = '?', .modifiers = SHIFT_MASK, .command = .search_backward });
        try self.bindings.append(.{ .key = 'n', .modifiers = 0, .command = .search_next });
        try self.bindings.append(.{ .key = 'N', .modifiers = SHIFT_MASK, .command = .search_prev });
    }

    pub fn getCommand(self: *const Self, key: u32, modifiers: u32) ?Command {
        for (self.bindings.items) |binding| {
            if (binding.key == key and binding.modifiers == modifiers) {
                return binding.command;
            }
        }
        return null;
    }

    pub fn addBinding(self: *Self, key: u32, modifiers: u32, command: Command) !void {
        try self.bindings.append(.{
            .key = key,
            .modifiers = modifiers,
            .command = command,
        });
    }
};
