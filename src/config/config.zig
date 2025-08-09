const std = @import("std");
const commands = @import("../input/commands.zig");

pub const Config = struct {
    const Self = @This();
    
    // Appearance
    background_color: [3]f32 = .{ 0.9, 0.9, 0.9 },
    
    // Zoom settings
    default_scale: f64 = 1.0,
    zoom_step: f64 = 1.2,
    max_scale: f64 = 5.0,
    min_scale: f64 = 0.1,
    
    // Window settings
    window_width: i32 = 800,
    window_height: i32 = 600,
    window_title: []const u8 = "Sarek PDF Viewer",
    
    // Navigation
    scroll_step: i32 = 50,
    
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        _ = allocator;
        _ = path;
        // For now, return default config
        // TODO: Implement actual config file parsing
        return Self{};
    }
    
    pub fn getDefault() Self {
        return Self{};
    }
};