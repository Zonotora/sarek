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
    
    // Layout
    increase_pages_per_row,
    decrease_pages_per_row,
    single_page_mode,
    double_page_mode,
    
    // Application
    quit,
    refresh,
    toggle_fullscreen,
    
    // TOC
    toggle_toc,
    toc_up,
    toc_down,
    toc_select,
    
    // Highlighting
    save_highlight,
    clear_selection,
    
    // Search
    search_forward,
    search_backward,
    search_next,
    search_prev,
    
    // File operations
    open_file,
    write_file,
    save_as,
    
    // Vim cursor motions
    cursor_char_find,      // f<char> - find next char
    cursor_char_find_back, // F<char> - find previous char
    cursor_char_till,      // t<char> - till next char
    cursor_char_till_back, // T<char> - till previous char
    cursor_word_next,      // w - next word
    cursor_word_back,      // b - previous word
    cursor_word_end,       // e - end of word
    cursor_line_start,     // 0 - start of line
    cursor_line_end,       // $ - end of line
    cursor_repeat_find,    // ; - repeat last find
    cursor_repeat_find_back, // , - repeat last find backwards

    // Visual mode and hjkl navigation
    enter_visual_mode,     // v - enter visual mode
    exit_visual_mode,      // escape from visual mode
    cursor_left,           // h - move left
    cursor_down,           // j - move down
    cursor_up,             // k - move up
    cursor_right,          // l - move right
    
    pub fn fromString(str: []const u8) ?Command {
        const map = std.StaticStringMap(Command).initComptime(.{
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
            .{ "increase-pages-per-row", .increase_pages_per_row },
            .{ "decrease-pages-per-row", .decrease_pages_per_row },
            .{ "single-page-mode", .single_page_mode },
            .{ "double-page-mode", .double_page_mode },
            .{ "quit", .quit },
            .{ "refresh", .refresh },
            .{ "toggle-fullscreen", .toggle_fullscreen },
            .{ "toggle-toc", .toggle_toc },
            .{ "toc-up", .toc_up },
            .{ "toc-down", .toc_down },
            .{ "toc-select", .toc_select },
            .{ "save-highlight", .save_highlight },
            .{ "clear-selection", .clear_selection },
            .{ "search-forward", .search_forward },
            .{ "search-backward", .search_backward },
            .{ "search-next", .search_next },
            .{ "search-prev", .search_prev },
            .{ "open", .open_file },
            .{ "write", .write_file },
            .{ "w", .write_file },
            .{ "save-as", .save_as },
            .{ "q", .quit },
            .{ "quit", .quit },
        });
        
        return map.get(str);
    }
};