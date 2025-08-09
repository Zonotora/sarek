const std = @import("std");

pub const Command = enum {
    // Navigation
    next_page,
    prev_page,
    first_page,
    last_page,
    goto_page,
    
    // Movement within page
    scroll_up,
    scroll_down,
    scroll_left,
    scroll_right,
    
    // Zoom
    zoom_in,
    zoom_out,
    zoom_fit_page,
    zoom_fit_width,
    zoom_original,
    
    // Application
    quit,
    refresh,
    toggle_fullscreen,
    
    // Search
    search_forward,
    search_backward,
    search_next,
    search_prev,
    
    pub fn fromString(str: []const u8) ?Command {
        const map = std.ComptimeStringMap(Command, .{
            .{ "next-page", .next_page },
            .{ "prev-page", .prev_page },
            .{ "first-page", .first_page },
            .{ "last-page", .last_page },
            .{ "goto-page", .goto_page },
            .{ "scroll-up", .scroll_up },
            .{ "scroll-down", .scroll_down },
            .{ "scroll-left", .scroll_left },
            .{ "scroll-right", .scroll_right },
            .{ "zoom-in", .zoom_in },
            .{ "zoom-out", .zoom_out },
            .{ "zoom-fit-page", .zoom_fit_page },
            .{ "zoom-fit-width", .zoom_fit_width },
            .{ "zoom-original", .zoom_original },
            .{ "quit", .quit },
            .{ "refresh", .refresh },
            .{ "toggle-fullscreen", .toggle_fullscreen },
            .{ "search-forward", .search_forward },
            .{ "search-backward", .search_backward },
            .{ "search-next", .search_next },
            .{ "search-prev", .search_prev },
        });
        
        return map.get(str);
    }
};