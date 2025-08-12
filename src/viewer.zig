const std = @import("std");
const backend_mod = @import("backends/backend.zig");
const poppler = @import("backends/poppler.zig");
const keybindings = @import("input/keybindings.zig");
const commands = @import("input/commands.zig");
const Command = @import("input/commands.zig").Command;

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("cairo.h");
});

const MARGIN_LEFT: f64 = 0.0;
const MARGIN_RIGHT: f64 = 0.0;
const MARGIN_TOP: f64 = 0.0;
const MARGIN_BOTTOM: f64 = 0.0;
const PAGE_OFFSET: f64 = 0.0;

const PAGE_VISIBLE_BUFFER: u32 = 100;
const MAX_PAGES_PER_ROW: u32 = 6;

const WINDOW_WIDTH: f64 = 800;
const WINDOW_HEIGHT: f64 = 640;

const ScrollDirection = enum {
    UP,
    DOWN,
};

const FitMode = enum {
    NONE,
    FIT_PAGE,
    FIT_WIDTH,
};

const Dimension = struct { width: f64, height: f64 };

const TocMode = enum {
    HIDDEN,
    VISIBLE,
};

const CommandMode = enum {
    NORMAL,
    COMMAND,
};

const VisualMode = enum {
    NONE,
    VISUAL,      // Character-wise visual selection
    VISUAL_LINE, // Line-wise visual selection (for future)
};

const TextCursor = struct {
    page: u32,
    char_index: u32,  // Character index within the page
    x: f64,          // Screen X position
    y: f64,          // Screen Y position
    visible: bool,

    pub fn init() TextCursor {
        return TextCursor{
            .page = 0,
            .char_index = 0,
            .x = 0,
            .y = 0,
            .visible = true,
        };
    }
};

const TocDirection = enum {
    UP,
    DOWN,
};

const SelectionState = enum {
    NONE,
    SELECTING,
    SELECTED,
};

const TextSelectionInfo = struct {
    state: SelectionState,
    start_page: u32,
    start_x: f64,
    start_y: f64,
    end_page: u32,
    end_x: f64,
    end_y: f64,
    selection_rect: backend_mod.TextRect,
    selected_text: []u8,
    allocator: ?std.mem.Allocator,

    pub fn init() TextSelectionInfo {
        return TextSelectionInfo{
            .state = .NONE,
            .start_page = 0,
            .start_x = 0,
            .start_y = 0,
            .end_page = 0,
            .end_x = 0,
            .end_y = 0,
            .selection_rect = backend_mod.TextRect{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 },
            .selected_text = &[_]u8{},
            .allocator = null,
        };
    }

    pub fn deinit(self: *TextSelectionInfo) void {
        if (self.allocator) |allocator| {
            if (self.selected_text.len > 0) {
                allocator.free(self.selected_text);
                self.selected_text = &[_]u8{};
            }
        }
    }

    pub fn clear(self: *TextSelectionInfo) void {
        self.deinit();
        self.state = .NONE;
    }
};

pub const Viewer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend_impl: *poppler.PopplerBackend,
    backend: backend_mod.Backend,
    keybindings: keybindings.KeyBindings,

    // File info
    filename: []u8, // Just the basename for display
    full_path: []u8, // Full path for saving

    width: f64,
    height: f64,

    // State
    current_page: u32,
    total_pages: u32,
    scale: f64,
    fit_mode: FitMode,

    // TOC state
    toc_entries: std.ArrayList(backend_mod.TocEntry),
    toc_mode: TocMode,
    toc_selected_index: u32,

    // Text selection state
    text_selection: TextSelectionInfo,
    highlights: std.ArrayList(backend_mod.Highlight),

    // Multi-page rendering state
    scroll_y: f64,
    page_spacing: f64,
    pages_per_row: u32, // Number of pages to display side by side

    // Page layout cache
    row_max_heights: std.ArrayList(f64),
    page_heights: std.ArrayList(f64),
    page_widths: std.ArrayList(f64), // Page widths for layout
    page_y_positions: std.ArrayList(f64), // Y positions for each page (row-based)
    page_x_positions: std.ArrayList(f64), // X positions for each page

    // Command line mode state
    command_mode: CommandMode,
    command_buffer: std.ArrayList(u8),
    command_cursor: usize,

    // Text cursor for vim-like navigation
    text_cursor: TextCursor,
    find_char: ?u8,        // Last character searched for with f/F
    find_direction: i8,    // 1 for forward, -1 for backward
    find_mode: ?commands.Command, // Current find mode (f, F, t, T) waiting for character
    page_text_cache: std.AutoHashMap(u32, []u8), // Cache of extracted text per page

    // Visual mode state
    visual_mode: VisualMode,
    visual_start_cursor: TextCursor, // Starting position of visual selection
    visual_selection_rect: backend_mod.TextRect, // Current visual selection rectangle

    // GTK widgets
    window: ?*c.GtkWidget,
    drawing_area: ?*c.GtkWidget,
    scrolled_window: ?*c.GtkWidget,

    pub fn init(allocator: std.mem.Allocator, pdf_path: []const u8) !Self {
        const backend_impl = try allocator.create(poppler.PopplerBackend);
        backend_impl.* = poppler.PopplerBackend.init(allocator);

        var backend_interface = backend_impl.backend();

        try backend_interface.open(pdf_path);
        const total_pages = backend_interface.getPageCount();

        if (total_pages == 0) {
            allocator.destroy(backend_impl);
            return error.InvalidPdf;
        }

        var row_max_heights = std.ArrayList(f64).init(allocator);
        var page_heights = std.ArrayList(f64).init(allocator);
        var page_widths = std.ArrayList(f64).init(allocator);
        var page_y_positions = std.ArrayList(f64).init(allocator);
        var page_x_positions = std.ArrayList(f64).init(allocator);

        // Store both full path and filename
        const full_path_copy = try std.fs.cwd().realpathAlloc(allocator, pdf_path);
        const filename = std.fs.path.basename(pdf_path);
        const filename_copy = try allocator.dupe(u8, filename);

        // Pre-calculate page dimensions for layout
        for (0..total_pages) |i| {
            const page_info = backend_interface.getPageInfo(@intCast(i)) catch {
                row_max_heights.deinit();
                page_heights.deinit();
                page_widths.deinit();
                page_y_positions.deinit();
                page_x_positions.deinit();
                allocator.free(filename_copy);
                allocator.free(full_path_copy);
                allocator.destroy(backend_impl);
                return error.InvalidPdf;
            };
            try row_max_heights.append(page_info.height);
            try page_heights.append(page_info.height);
            try page_widths.append(page_info.width);
            try page_y_positions.append(0); // Will be calculated later
            try page_x_positions.append(0); // Will be calculated later
        }

        return Self{
            .allocator = allocator,
            .backend_impl = backend_impl,
            .backend = backend_interface,
            .keybindings = keybindings.KeyBindings.init(allocator),
            .filename = filename_copy,
            .full_path = full_path_copy,
            .width = WINDOW_WIDTH,
            .height = WINDOW_HEIGHT,
            .current_page = 0,
            .total_pages = total_pages,
            .scale = 1.0,
            .fit_mode = .NONE,
            .toc_entries = std.ArrayList(backend_mod.TocEntry).init(allocator),
            .toc_mode = .HIDDEN,
            .toc_selected_index = 0,
            .text_selection = blk: {
                var selection = TextSelectionInfo.init();
                selection.allocator = allocator;
                break :blk selection;
            },
            .highlights = std.ArrayList(backend_mod.Highlight).init(allocator),
            .scroll_y = 0.0,
            .page_spacing = PAGE_OFFSET,
            .pages_per_row = 2,
            .row_max_heights = row_max_heights,
            .page_heights = page_heights,
            .page_widths = page_widths,
            .page_y_positions = page_y_positions,
            .page_x_positions = page_x_positions,
            .command_mode = .NORMAL,
            .command_buffer = std.ArrayList(u8).init(allocator),
            .command_cursor = 0,
            .text_cursor = TextCursor.init(),
            .find_char = null,
            .find_direction = 1,
            .find_mode = null,
            .page_text_cache = std.AutoHashMap(u32, []u8).init(allocator),
            .visual_mode = .NONE,
            .visual_start_cursor = TextCursor.init(),
            .visual_selection_rect = backend_mod.TextRect{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 },
            .window = null,
            .drawing_area = null,
            .scrolled_window = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.backend.deinit();
        self.keybindings.deinit();
        self.allocator.free(self.filename);
        self.allocator.free(self.full_path);

        // Clean up TOC entries
        for (self.toc_entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.toc_entries.deinit();

        // Clean up text selection
        self.text_selection.deinit();

        // Clean up highlights
        for (self.highlights.items) |*highlight| {
            highlight.deinit(self.allocator);
        }
        self.highlights.deinit();

        self.row_max_heights.deinit();
        self.page_heights.deinit();
        self.page_widths.deinit();
        self.page_y_positions.deinit();
        self.page_x_positions.deinit();
        self.command_buffer.deinit();
        
        // Clean up text cache
        var iterator = self.page_text_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.page_text_cache.deinit();
        
        self.allocator.destroy(self.backend_impl);
    }

    pub fn run(self: *Self) !void {
        // Initialize GTK
        _ = c.gtk_init(null, null);

        // Create window
        self.window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
        if (self.window == null) return error.GtkInitFailed;

        c.gtk_window_set_title(@ptrCast(self.window), "Sarek PDF Viewer");
        c.gtk_window_set_default_size(@ptrCast(self.window), 800, 600);

        // Create scrolled window for multi-page view
        self.scrolled_window = c.gtk_scrolled_window_new(null, null);
        if (self.scrolled_window == null) return error.GtkInitFailed;

        // Configure scrolled window
        c.gtk_scrolled_window_set_policy(@ptrCast(self.scrolled_window), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);

        // Create drawing area
        self.drawing_area = c.gtk_drawing_area_new();
        if (self.drawing_area == null) return error.GtkInitFailed;

        // Initialize page positions with current scale
        self.recalculatePagePositions();

        self.updateDrawingAreaSize();

        c.gtk_container_add(@ptrCast(self.scrolled_window), self.drawing_area);
        c.gtk_container_add(@ptrCast(self.window), self.scrolled_window);

        // Connect signals
        _ = c.g_signal_connect_data(self.window, "destroy", @ptrCast(&onDestroy), null, null, 0);
        _ = c.g_signal_connect_data(self.drawing_area, "draw", @ptrCast(&onDraw), self, null, 0);
        _ = c.g_signal_connect_data(self.window, "configure-event", @ptrCast(&onWindowResize), self, null, 0);

        // Add scroll event handling to force redraw on mouse wheel scroll
        c.gtk_widget_add_events(self.drawing_area, c.GDK_SCROLL_MASK);
        _ = c.g_signal_connect_data(self.drawing_area, "scroll-event", @ptrCast(&onScroll), self, null, 0);

        // Add key event handling
        c.gtk_widget_add_events(self.window, c.GDK_KEY_PRESS_MASK);
        _ = c.g_signal_connect_data(self.window, "key_press_event", @ptrCast(&onKeyPress), self, null, 0);

        // Add mouse event handling for text selection
        c.gtk_widget_add_events(self.drawing_area, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK);
        _ = c.g_signal_connect_data(self.drawing_area, "button-press-event", @ptrCast(&onButtonPress), self, null, 0);
        _ = c.g_signal_connect_data(self.drawing_area, "button-release-event", @ptrCast(&onButtonRelease), self, null, 0);
        _ = c.g_signal_connect_data(self.drawing_area, "motion-notify-event", @ptrCast(&onMotionNotify), self, null, 0);

        // Make window focusable for key events
        c.gtk_widget_set_can_focus(self.window, 1);
        c.gtk_widget_grab_focus(self.window);

        // Initialize text cursor
        self.initializeCursor();

        // Show all widgets
        c.gtk_widget_show_all(self.window);

        // Start main loop
        c.gtk_main();
    }

    fn executeCommand(self: *Self, command: commands.Command) void {
        // Handle TOC-specific navigation when TOC is visible
        if (self.toc_mode == .VISIBLE) {
            switch (command) {
                .next_page => {
                    self.tocNavigate(.DOWN);
                    return;
                },
                .prev_page => {
                    self.tocNavigate(.UP);
                    return;
                },
                .toggle_toc, .toc_select => {
                    // Fall through to normal handling
                },
                else => {
                    // Ignore other commands when TOC is visible
                    return;
                },
            }
        }

        switch (command) {
            .next_page => {
                self.current_page += self.pages_per_row;
                if (self.current_page >= self.total_pages) self.current_page = self.total_pages - 1;
                self.moveCursorToPage(self.current_page);
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .prev_page => {
                self.current_page = if (self.pages_per_row > self.current_page) 0 else self.current_page - self.pages_per_row;
                self.moveCursorToPage(self.current_page);
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .first_page => {
                self.current_page = 0;
                self.moveCursorToPage(self.current_page);
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .last_page => {
                self.current_page = self.total_pages - 1;
                self.moveCursorToPage(self.current_page);
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .zoom_in => {
                self.fit_mode = .NONE; // Disable fit mode when manually zooming
                self.scale = @min(self.scale * 1.2, 5.0);
                self.updateDrawingAreaSize();
                self.updateCursorPosition();
                self.redraw();
            },
            .zoom_out => {
                self.fit_mode = .NONE; // Disable fit mode when manually zooming
                self.scale = @max(self.scale / 1.2, 0.1);
                self.updateDrawingAreaSize();
                self.updateCursorPosition();
                self.redraw();
            },
            .zoom_original => {
                self.fit_mode = .NONE; // Disable fit mode when manually zooming
                self.scale = 1.0;
                self.updateDrawingAreaSize();
                self.updateCursorPosition();
                self.redraw();
            },
            .zoom_fit_page => {
                self.zoomFitPage();
                self.updateDrawingAreaSize();
                self.updateCursorPosition();
                self.redraw();
            },
            .zoom_fit_width => {
                self.zoomFitWidth();
                self.updateDrawingAreaSize();
                self.updateCursorPosition();
                self.redraw();
            },
            .quit => {
                c.gtk_main_quit();
            },
            .scroll_up => {
                self.scroll(ScrollDirection.UP);
            },
            .scroll_down => {
                self.scroll(ScrollDirection.DOWN);
            },
            .increase_pages_per_row => {
                if (self.pages_per_row < MAX_PAGES_PER_ROW) {
                    self.pages_per_row += 1;
                    self.updateDrawingAreaSize();
                    self.redraw();
                    std.debug.print("Pages per row: {}\n", .{self.pages_per_row});
                }
            },
            .decrease_pages_per_row => {
                if (self.pages_per_row > 1) {
                    self.pages_per_row -= 1;
                    self.updateDrawingAreaSize();
                    self.redraw();
                    std.debug.print("Pages per row: {}\n", .{self.pages_per_row});
                }
            },
            .single_page_mode => {
                self.pages_per_row = 1;
                self.updateDrawingAreaSize();
                self.redraw();
                std.debug.print("Single page mode\n", .{});
            },
            .double_page_mode => {
                self.pages_per_row = 2;
                self.updateDrawingAreaSize();
                self.redraw();
                std.debug.print("Double page mode\n", .{});
            },
            .refresh => {
                self.updateDrawingAreaSize();
                self.redraw();
            },
            .toggle_toc => {
                self.toggleToc();
            },
            .toc_up => {
                if (self.toc_mode == .VISIBLE) {
                    self.tocNavigate(.UP);
                }
            },
            .toc_down => {
                if (self.toc_mode == .VISIBLE) {
                    self.tocNavigate(.DOWN);
                }
            },
            .toc_select => {
                if (self.toc_mode == .VISIBLE) {
                    self.tocSelect();
                }
            },
            .save_highlight => {
                self.saveCurrentHighlight();
            },
            .clear_selection => {
                self.clearTextSelection();
            },
            .open_file => {
                // TODO: Fix me
            },
            .write_file => {
                // TODO: Fix me
            },
            .save_as => {
                // TODO: Fix me
            },
            .cursor_word_next => {
                self.moveCursorWordNext();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_word_back => {
                self.moveCursorWordBack();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_word_end => {
                self.moveCursorWordEnd();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_line_start => {
                self.moveCursorLineStart();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_line_end => {
                self.moveCursorLineEnd();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_repeat_find => {
                if (self.find_char) |char| {
                    _ = self.moveCursorToChar(char, self.find_direction == 1);
                    if (self.visual_mode != .NONE) self.updateVisualSelection();
                    self.redraw();
                }
            },
            .cursor_repeat_find_back => {
                if (self.find_char) |char| {
                    _ = self.moveCursorToChar(char, self.find_direction == -1);
                    if (self.visual_mode != .NONE) self.updateVisualSelection();
                    self.redraw();
                }
            },
            .cursor_char_find, .cursor_char_find_back, .cursor_char_till, .cursor_char_till_back => {
                // These commands need a character input, set find mode
                self.find_mode = command;
                std.debug.print("Waiting for character input for command: {}\n", .{command});
            },
            .enter_visual_mode => {
                self.enterVisualMode();
            },
            .exit_visual_mode => {
                self.exitVisualMode();
            },
            .cursor_left => {
                self.moveCursorLeft();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_right => {
                self.moveCursorRight();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_up => {
                self.moveCursorUp();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            .cursor_down => {
                self.moveCursorDown();
                if (self.visual_mode != .NONE) self.updateVisualSelection();
                self.redraw();
            },
            else => {
                // TODO: Implement remaining commands
                std.debug.print("Command not implemented: {}\n", .{command});
            },
        }
    }

    fn recalculatePagePositions(self: *Self) void {
        // TODO: The last page is not drawn properly when fit to page/width.
        var current_y: f64 = 0;
        var current_x: f64 = MARGIN_LEFT;

        var total_width: f64 = 0;
        var row_width: f64 = 0;
        var row_height: f64 = 0;
        var last_row: u32 = 0;

        for (0..self.total_pages) |i| {
            const page = @as(u32, @intCast(i));
            const row = page / self.pages_per_row;
            const last_page = i == self.total_pages - 1;

            if (row != last_row or i == self.total_pages - 1) {
                const index = if (last_page) row else row - 1;
                self.row_max_heights.items[index] = row_height;
                total_width = @max(total_width, row_width);

                row_width = 0;
                row_height = 0;
            }

            row_height = @max(row_height, self.page_heights.items[i] * self.scale) + PAGE_OFFSET;
            row_width += self.page_widths.items[i] * self.scale + PAGE_OFFSET;

            last_row = row;
        }

        row_height = 0;

        const row_max_width = total_width / @as(f64, @floatFromInt(self.pages_per_row));
        const window_x_offset = @max(0, self.width - total_width) / 2;
        // std.debug.print("row_max_height={}", .{row_max_width});

        for (0..self.total_pages) |i| {
            const page = @as(u32, @intCast(i));
            const row = page / self.pages_per_row;
            const col = page % self.pages_per_row;

            const page_width = self.page_widths.items[i] * self.scale;
            const page_height = self.page_heights.items[i] * self.scale;
            const page_x_offset = (row_max_width - page_width) / 2;
            const page_y_offset = (self.row_max_heights.items[row] - page_height) / 2;
            // std.debug.print("i={} {d:.2} {d:.2}\n", .{ i, self.row_max_heights.items[row], page_height });

            if (col == 0) {
                // First page in row - reset X and calculate Y
                current_x = MARGIN_LEFT;
                if (row > 0) {
                    current_y += row_height + self.page_spacing;
                }
                row_height = 0; // Reset for new row

                current_x += window_x_offset;
            }

            // Add top margin if first page
            if (row == 0 and col == 0) {
                current_y += MARGIN_TOP;
            }

            // Set positions for this page
            self.page_y_positions.items[i] = current_y + page_y_offset;
            self.page_x_positions.items[i] = current_x + page_x_offset;

            // Update row height to max height in this row
            row_height = @max(row_height, page_height);

            // Advance X position for next page in row
            current_x += page_width + 2 * page_x_offset + PAGE_OFFSET;
        }
    }

    fn updateDrawingAreaSize(self: *Self) void {
        switch (self.fit_mode) {
            .FIT_PAGE => self.zoomFitPage(),
            .FIT_WIDTH => self.zoomFitWidth(),
            .NONE => {},
        }
        // Recalculate positions with new scale
        self.recalculatePagePositions();

        // Calculate total dimensions
        var total_height: f64 = 0;
        var total_width: f64 = WINDOW_WIDTH; // Minimum width

        for (0..self.total_pages) |i| {
            const page_bottom = self.page_y_positions.items[i] + (self.page_heights.items[i] * self.scale);
            total_height = @max(total_height, page_bottom);

            // Find the maximum X position + page width
            const page_right = self.page_x_positions.items[i] + (self.page_widths.items[i] * self.scale);
            total_width = @max(total_width, page_right + MARGIN_RIGHT); // Add right margin
        }

        if (self.drawing_area) |area| {
            c.gtk_widget_set_size_request(area, @intFromFloat(total_width), @intFromFloat(total_height));
        }
    }

    fn redraw(self: *Self) void {
        if (self.drawing_area) |area| {
            c.gtk_widget_queue_draw(area);
        }
    }

    fn getPageYPosition(self: *Self, page: u32) f64 {
        if (page >= self.total_pages) return 0;
        return self.page_y_positions.items[page];
    }

    fn getVisiblePageRange(self: *Self) struct { first: u32, last: u32 } {
        if (self.scrolled_window == null) return .{ .first = 0, .last = @min(2, self.total_pages - 1) };

        const scrolled = self.scrolled_window.?;
        const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));
        if (vadjustment == null) return .{ .first = 0, .last = @min(2, self.total_pages - 1) };

        const vadj = vadjustment.?;
        const scroll_top = c.gtk_adjustment_get_value(vadj);
        const viewport_height = c.gtk_adjustment_get_page_size(vadj);
        const scroll_bottom = scroll_top + viewport_height;

        var first_visible: ?u32 = null;
        var last_visible: u32 = 0;

        for (0..self.total_pages) |page_idx| {
            const page = @as(u32, @intCast(page_idx));
            const page_height = self.page_heights.items[page_idx] * self.scale;
            const page_top = self.page_y_positions.items[page_idx];
            const page_bottom = page_top + page_height;

            // Check if page is visible (overlaps with viewport with buffer)
            if (page_bottom >= scroll_top - PAGE_VISIBLE_BUFFER and page_top <= scroll_bottom + PAGE_VISIBLE_BUFFER) {
                if (first_visible == null) {
                    first_visible = page;
                }
                last_visible = page;
            }
        }

        return .{ .first = first_visible orelse 0, .last = @min(last_visible, self.total_pages - 1) };
    }

    fn scrollToPage(self: *Self, page: u32) void {
        if (page >= self.total_pages) return;

        const y_position = self.getPageYPosition(page);

        if (self.scrolled_window) |scrolled| {
            const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));
            if (vadjustment) |vadj| {
                c.gtk_adjustment_set_value(vadj, y_position);
            }
        }
    }

    fn scroll(self: *Self, direction: ScrollDirection) void {
        _ = self;
        _ = direction;
        // if (self.scrolled_window) |scrolled| {
        //     const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));
        //     if (vadjustment) |vadj| {
        //         const current_val = c.gtk_adjustment_get_value(vadj);
        //         const step = c.gtk_adjustment_get_step_increment(vadj);
        //         const increment = switch (direction) {
        //             .UP => current_val - step * 3,
        //             .DOWN => current_val + step * 3,
        //         };
        //         c.gtk_adjustment_set_value(vadj, increment);

        //         // Update current page
        //         // self.page_heights
        //         std.debug.print("curr={} step={}\n", .{ current_val, step });
        //     }
        // }
    }

    fn getViewportSize(self: *Self) Dimension {
        // Try to get the actual viewport size from the scrolled window
        if (self.scrolled_window) |scrolled| {
            const hadjustment = c.gtk_scrolled_window_get_hadjustment(@ptrCast(scrolled));
            const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));

            var viewport_width: f64 = WINDOW_WIDTH;
            var viewport_height: f64 = WINDOW_HEIGHT;

            if (hadjustment) |hadj| {
                const page_size = c.gtk_adjustment_get_page_size(hadj);
                if (page_size > 0) {
                    viewport_width = page_size;
                }
            }

            if (vadjustment) |vadj| {
                const page_size = c.gtk_adjustment_get_page_size(vadj);
                if (page_size > 0) {
                    viewport_height = page_size;
                }
            }

            // std.debug.print("w={} h={}\n", .{ @as(u64, @intFromFloat(viewport_width)), @as(u64, @intFromFloat(viewport_height)) });

            return .{ .width = viewport_width, .height = viewport_height };
        }

        // Fallback to window size if available
        if (self.window) |window| {
            var width: c_int = undefined;
            var height: c_int = undefined;
            c.gtk_window_get_size(@ptrCast(window), &width, &height);
            if (width > 0 and height > 0) {
                return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
            }
        }

        // Default fallback size
        return .{ .width = WINDOW_WIDTH, .height = WINDOW_HEIGHT };
    }

    fn zoomFitPage(self: *Self) void {
        if (self.current_page >= self.total_pages) return;

        self.fit_mode = .FIT_PAGE;

        const index = self.current_page / self.pages_per_row;
        const end = index + self.pages_per_row;

        var width: f64 = 0;
        var height: f64 = 0;

        for (index..end) |page_num| {
            const page_info = self.backend.getPageInfo(@intCast(page_num)) catch return;
            width += page_info.width;
            height = @max(height, page_info.height);
        }

        const available_width = self.width - (MARGIN_LEFT + MARGIN_RIGHT);
        const available_height = self.height - (MARGIN_TOP + MARGIN_BOTTOM);

        if (available_width <= 0 or available_height <= 0) return;

        // Calculate scale to fit both width and height
        const width_scale = available_width / width;
        const height_scale = available_height / height;

        // Use the smaller scale to ensure the entire page fits
        self.scale = @max(0.1, @min(5.0, @min(width_scale, height_scale)));

        // std.debug.print("Zoom fit page: scale = {d:.2}\n", .{self.scale});
    }

    fn zoomFitWidth(self: *Self) void {
        if (self.current_page >= self.total_pages) return;

        self.fit_mode = .FIT_WIDTH; // Set fit mode

        const page_info = self.backend.getPageInfo(self.current_page) catch return;

        const available_width = self.width - (MARGIN_LEFT + MARGIN_RIGHT);

        if (available_width <= 0) return;

        // For multi-page layouts, consider the total width of all pages in a row
        var total_row_width: f64 = 0;
        const current_row = self.current_page / self.pages_per_row;
        const pages_in_row = @min(self.pages_per_row, self.total_pages - current_row * self.pages_per_row);

        for (0..pages_in_row) |i| {
            const page_idx = current_row * self.pages_per_row + i;
            if (page_idx < self.total_pages) {
                const page_width = self.page_widths.items[page_idx];
                total_row_width += page_width;
                if (i > 0) total_row_width += PAGE_OFFSET; // Add margin between pages
            }
        }

        if (total_row_width > 0) {
            self.scale = @max(0.1, @min(5.0, available_width / total_row_width));
        } else {
            self.scale = @max(0.1, @min(5.0, available_width / page_info.width));
        }
        // std.debug.print("Zoom fit width: scale = {d:.2}\n", .{self.scale});
    }

    fn drawStatusBar(self: *Self, ctx: *c.cairo_t) void {
        // Get the current scroll position and viewport size
        var scroll_top: f64 = 0;
        var viewport_height: f64 = self.height;

        if (self.scrolled_window) |scrolled| {
            const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));
            if (vadjustment) |vadj| {
                scroll_top = c.gtk_adjustment_get_value(vadj);
                viewport_height = c.gtk_adjustment_get_page_size(vadj);
            }
        }

        // Set up status bar styling
        const status_bar_height: f64 = 20.0;
        const margin: f64 = 5.0;
        const font_size: f64 = 12.0;

        // Calculate status bar position relative to the current viewport
        const status_bar_y = scroll_top + viewport_height - status_bar_height;

        // Clear the status bar area first with the background color
        c.cairo_save(ctx);
        c.cairo_set_source_rgb(ctx, 0.9, 0.9, 0.9); // Same as main background
        c.cairo_rectangle(ctx, 0, status_bar_y, self.width, status_bar_height);
        c.cairo_fill(ctx);

        // Draw status bar background (semi-transparent dark background)
        c.cairo_set_source_rgba(ctx, 0.2, 0.2, 0.2, 0.8);
        c.cairo_rectangle(ctx, 0, status_bar_y, self.width, status_bar_height);
        c.cairo_fill(ctx);

        // Set up text properties
        c.cairo_set_source_rgb(ctx, 1.0, 1.0, 1.0); // White text
        c.cairo_select_font_face(ctx, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(ctx, font_size);

        if (self.command_mode == .COMMAND) {
            self.drawCommandLine(ctx, status_bar_y, status_bar_height, margin);
        } else {
            self.drawStatusBarInfo(ctx, status_bar_y, status_bar_height, margin);
        }

        c.cairo_restore(ctx);
    }

    fn drawStatusBarPageNumber(self: *Self, ctx: *c.cairo_t, y: f64, height: f64, margin: f64) void {
        // Create and draw page info in bottom right (like Zathura: "page/total")
        var page_info_buf: [64]u8 = undefined;
        const page_info_str = std.fmt.bufPrintZ(page_info_buf[0..], "[{}/{}]", .{ self.current_page + 1, self.total_pages }) catch "?/?";

        // Get text width to position it at the right edge
        var text_extents: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(ctx, page_info_str.ptr, &text_extents);
        const text_width = text_extents.width;

        c.cairo_move_to(ctx, self.width - text_width - margin, y + height - margin);
        c.cairo_show_text(ctx, page_info_str.ptr);
    }

    fn drawStatusBarInfo(self: *Self, ctx: *c.cairo_t, y: f64, height: f64, margin: f64) void {
        // Draw normal status bar

        // Draw filename in bottom left (viewport-relative position)
        c.cairo_move_to(ctx, margin, y + height - margin);
        c.cairo_show_text(ctx, self.full_path.ptr);

        self.drawStatusBarPageNumber(ctx, y, height, margin);
    }

    fn drawCommandLine(self: *Self, ctx: *c.cairo_t, y: f64, height: f64, margin: f64) void {
        // Draw command prompt ":"
        c.cairo_move_to(ctx, margin, y + height - margin);
        c.cairo_show_text(ctx, ":");

        // Get the width of the colon to position the command text
        var colon_extents: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(ctx, ":", &colon_extents);
        const colon_width = colon_extents.width;

        // Draw command text
        const command_x = margin + colon_width + 2; // 2px space after colon
        c.cairo_move_to(ctx, command_x, y + height - margin);

        // Convert command buffer to null-terminated string for Cairo
        var text_buf: [512]u8 = undefined;
        const command_len = @min(self.command_buffer.items.len, text_buf.len - 1);
        @memcpy(text_buf[0..command_len], self.command_buffer.items[0..command_len]);
        text_buf[command_len] = 0; // null terminate

        c.cairo_show_text(ctx, text_buf[0..command_len :0].ptr);

        // Draw cursor
        if (self.command_cursor <= self.command_buffer.items.len) {
            const cursor_pos = @min(self.command_cursor, text_buf.len - 1);
            text_buf[cursor_pos] = 0;

            // Get text width up to cursor position
            var cursor_extents: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(ctx, text_buf[0..cursor_pos :0].ptr, &cursor_extents);
            const cursor_x = command_x + cursor_extents.width;

            // Draw cursor as a vertical line
            c.cairo_set_line_width(ctx, 1.0);
            c.cairo_move_to(ctx, cursor_x, y + 2);
            c.cairo_line_to(ctx, cursor_x, y + height - 2);
            c.cairo_stroke(ctx);
        }

        self.drawStatusBarPageNumber(ctx, y, height, margin);
    }

    fn toggleToc(self: *Self) void {
        switch (self.toc_mode) {
            .HIDDEN => {
                // Try to extract TOC if we haven't done it yet
                if (self.toc_entries.items.len == 0) {
                    self.extractToc() catch {
                        std.debug.print("Failed to extract TOC or no TOC available\n", .{});
                        return;
                    };
                }
                if (self.toc_entries.items.len > 0) {
                    self.toc_mode = .VISIBLE;
                    self.toc_selected_index = 0;
                    std.debug.print("TOC opened\n", .{});
                } else {
                    std.debug.print("No TOC available in this document\n", .{});
                }
            },
            .VISIBLE => {
                self.toc_mode = .HIDDEN;
                std.debug.print("TOC closed\n", .{});
            },
        }
        self.redraw();
    }

    fn tocNavigate(self: *Self, direction: TocDirection) void {
        if (self.toc_entries.items.len == 0) return;

        switch (direction) {
            .UP => {
                if (self.toc_selected_index > 0) {
                    self.toc_selected_index -= 1;
                }
            },
            .DOWN => {
                if (self.toc_selected_index < self.toc_entries.items.len - 1) {
                    self.toc_selected_index += 1;
                }
            },
        }
        self.redraw();
    }

    fn tocSelect(self: *Self) void {
        if (self.toc_entries.items.len == 0 or self.toc_selected_index >= self.toc_entries.items.len) {
            return;
        }

        const selected_entry = &self.toc_entries.items[self.toc_selected_index];

        // Navigate to the selected page
        self.current_page = selected_entry.page;
        self.scrollToPage(self.current_page);

        // Close TOC
        self.toc_mode = .HIDDEN;
        self.redraw();

        std.debug.print("Navigated to page {} ({s})\n", .{ selected_entry.page + 1, selected_entry.title });
    }

    fn extractToc(self: *Self) !void {
        // Use the backend to extract real TOC from the PDF
        try self.backend.extractToc(self.allocator, &self.toc_entries);

        // Clamp page numbers to valid range
        for (self.toc_entries.items) |*entry| {
            entry.page = @min(entry.page, self.total_pages - 1);
        }

        std.debug.print("Extracted {} TOC entries\n", .{self.toc_entries.items.len});
    }

    fn drawTocOverlay(self: *Self, ctx: *c.cairo_t) void {
        if (self.toc_entries.items.len == 0) return;

        // Get viewport info for positioning
        var scroll_top: f64 = 0;
        var viewport_height: f64 = self.height;

        if (self.scrolled_window) |scrolled| {
            const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));
            if (vadjustment) |vadj| {
                scroll_top = c.gtk_adjustment_get_value(vadj);
                viewport_height = c.gtk_adjustment_get_page_size(vadj);
            }
        }

        // Draw semi-transparent background covering the entire viewport
        c.cairo_save(ctx);
        c.cairo_set_source_rgba(ctx, 0.1, 0.1, 0.1, 0.9); // Dark background
        c.cairo_rectangle(ctx, 0, scroll_top, self.width, viewport_height);
        c.cairo_fill(ctx);

        // TOC styling
        const margin: f64 = 20.0;
        const line_height: f64 = 25.0;
        const font_size: f64 = 14.0;
        const indent_per_level: f64 = 20.0;

        // Calculate visible TOC area
        const toc_x = margin;
        const toc_y = scroll_top + margin;
        const toc_width = self.width - 2 * margin;
        const toc_height = viewport_height - 2 * margin;

        // Draw TOC background
        c.cairo_set_source_rgba(ctx, 0.2, 0.2, 0.2, 0.95);
        c.cairo_rectangle(ctx, toc_x, toc_y, toc_width, toc_height);
        c.cairo_fill(ctx);

        // Draw TOC border
        c.cairo_set_source_rgb(ctx, 0.6, 0.6, 0.6);
        c.cairo_set_line_width(ctx, 1.0);
        c.cairo_rectangle(ctx, toc_x, toc_y, toc_width, toc_height);
        c.cairo_stroke(ctx);

        // Draw title
        c.cairo_set_source_rgb(ctx, 1.0, 1.0, 1.0);
        c.cairo_select_font_face(ctx, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(ctx, font_size + 2);

        const title = "Table of Contents";
        c.cairo_move_to(ctx, toc_x + 10, toc_y + 25);
        c.cairo_show_text(ctx, title.ptr);

        // Calculate how many entries can fit in the visible area
        const available_height = toc_height - 50; // Leave space for title and margins
        const max_visible_entries: u32 = @intFromFloat(available_height / line_height);

        // Calculate scroll offset for TOC entries
        var toc_scroll_offset: u32 = 0;
        if (self.toc_selected_index >= max_visible_entries) {
            toc_scroll_offset = self.toc_selected_index - max_visible_entries + 1;
        }

        // Set up text properties for entries
        c.cairo_select_font_face(ctx, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(ctx, font_size);

        // Draw TOC entries
        var y_pos = toc_y + 50; // Start after title
        const end_idx = @min(toc_scroll_offset + max_visible_entries, @as(u32, @intCast(self.toc_entries.items.len)));

        for (toc_scroll_offset..end_idx) |i| {
            const entry = &self.toc_entries.items[i];
            const is_selected = (i == self.toc_selected_index);

            // Draw selection highlight
            if (is_selected) {
                c.cairo_set_source_rgba(ctx, 0.4, 0.4, 0.6, 0.7);
                c.cairo_rectangle(ctx, toc_x + 5, y_pos - line_height + 5, toc_width - 10, line_height);
                c.cairo_fill(ctx);
            }

            // Set text color
            if (is_selected) {
                c.cairo_set_source_rgb(ctx, 1.0, 1.0, 1.0); // White for selected
            } else {
                c.cairo_set_source_rgb(ctx, 0.9, 0.9, 0.9); // Light gray for unselected
            }

            // Calculate indentation based on level
            const indent = @as(f64, @floatFromInt(entry.level)) * indent_per_level;

            // Draw the title
            c.cairo_move_to(ctx, toc_x + 10 + indent, y_pos);
            c.cairo_show_text(ctx, entry.title.ptr);

            // Draw page number on the right
            var page_buf: [16]u8 = undefined;
            const page_str = std.fmt.bufPrintZ(page_buf[0..], "{}", .{entry.page + 1}) catch "?";

            var text_extents: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(ctx, page_str.ptr, &text_extents);
            const page_x = toc_x + toc_width - text_extents.width - 15;

            c.cairo_move_to(ctx, page_x, y_pos);
            c.cairo_show_text(ctx, page_str.ptr);

            y_pos += line_height;
        }

        // Draw navigation instructions at the bottom
        c.cairo_set_source_rgb(ctx, 0.7, 0.7, 0.7);
        c.cairo_set_font_size(ctx, 10);
        const instructions = "j/k: navigate, Enter: select, Tab: close";
        c.cairo_move_to(ctx, toc_x + 10, toc_y + toc_height - 10);
        c.cairo_show_text(ctx, instructions.ptr);

        c.cairo_restore(ctx);
    }

    // Text Selection Functions
    fn screenToPdfCoordinates(self: *Self, screen_x: f64, screen_y: f64) ?struct { page: u32, pdf_x: f64, pdf_y: f64 } {
        // Find which page the coordinates are on
        for (0..self.total_pages) |page_idx| {
            const page = @as(u32, @intCast(page_idx));
            const page_x = self.page_x_positions.items[page_idx];
            const page_y = self.page_y_positions.items[page_idx];
            const page_width = self.page_widths.items[page_idx] * self.scale;
            const page_height = self.page_heights.items[page_idx] * self.scale;

            if (screen_x >= page_x and screen_x <= page_x + page_width and
                screen_y >= page_y and screen_y <= page_y + page_height)
            {
                // Convert to PDF coordinates (unscaled)
                const pdf_x = (screen_x - page_x) / self.scale;
                const pdf_y = (screen_y - page_y) / self.scale;

                std.debug.print("Screen coords ({},{}) on page {} -> PDF coords ({},{}) (scale={})\n", .{ screen_x, screen_y, page, pdf_x, pdf_y, self.scale });

                return .{ .page = page, .pdf_x = pdf_x, .pdf_y = pdf_y };
            }
        }
        std.debug.print("Screen coords ({},{}) not on any page\n", .{ screen_x, screen_y });
        return null;
    }

    fn startTextSelection(self: *Self, screen_x: f64, screen_y: f64) void {
        if (self.screenToPdfCoordinates(screen_x, screen_y)) |coords| {
            self.text_selection.clear();
            self.text_selection.state = .SELECTING;
            self.text_selection.start_page = coords.page;
            self.text_selection.start_x = coords.pdf_x;
            self.text_selection.start_y = coords.pdf_y;
            self.text_selection.end_page = coords.page;
            self.text_selection.end_x = coords.pdf_x;
            self.text_selection.end_y = coords.pdf_y;
            self.updateSelectionRect();
            self.redraw();
        }
    }

    fn updateTextSelection(self: *Self, screen_x: f64, screen_y: f64) void {
        if (self.text_selection.state != .SELECTING) return;

        if (self.screenToPdfCoordinates(screen_x, screen_y)) |coords| {
            self.text_selection.end_page = coords.page;
            self.text_selection.end_x = coords.pdf_x;
            self.text_selection.end_y = coords.pdf_y;
            self.updateSelectionRect();
            self.redraw();
        }
    }

    fn finishTextSelection(self: *Self) void {
        if (self.text_selection.state == .SELECTING) {
            self.text_selection.state = .SELECTED;
            self.extractSelectedText();
            self.redraw();
        }
    }

    fn updateSelectionRect(self: *Self) void {
        // Create selection rectangle from start and end coordinates
        const min_x = @min(self.text_selection.start_x, self.text_selection.end_x);
        const max_x = @max(self.text_selection.start_x, self.text_selection.end_x);
        const min_y = @min(self.text_selection.start_y, self.text_selection.end_y);
        const max_y = @max(self.text_selection.start_y, self.text_selection.end_y);

        self.text_selection.selection_rect = backend_mod.TextRect{
            .x1 = min_x,
            .y1 = min_y,
            .x2 = max_x,
            .y2 = max_y,
        };
    }

    fn extractSelectedText(self: *Self) void {
        // Extract text from the selected area
        const page = self.text_selection.start_page; // For now, assume single-page selection

        std.debug.print("Extracting text from page {} at rect: ({},{}) to ({},{})\n", .{ page, self.text_selection.selection_rect.x1, self.text_selection.selection_rect.y1, self.text_selection.selection_rect.x2, self.text_selection.selection_rect.y2 });

        const text = self.backend.getTextForArea(self.allocator, page, self.text_selection.selection_rect) catch {
            std.debug.print("Failed to extract selected text\n", .{});
            return;
        };

        // Free previous selection
        self.text_selection.deinit();
        self.text_selection.selected_text = text;

        std.debug.print("Selected text: '{s}' (length: {})\n", .{ text, text.len });
    }

    fn drawTextSelection(self: *Self, ctx: *c.cairo_t) void {
        if (self.text_selection.state == .NONE) return;

        const page = self.text_selection.start_page;
        if (page >= self.total_pages) return;

        // Get page position and scale
        const page_x = self.page_x_positions.items[page];
        const page_y = self.page_y_positions.items[page];

        // Save context
        c.cairo_save(ctx);

        // Translate to page position
        c.cairo_translate(ctx, page_x, page_y);

        // Set selection highlight color
        const bg_color = backend_mod.HighlightColor{ .r = 0.3, .g = 0.6, .b = 1.0, .a = 0.3 };
        const glyph_color = backend_mod.HighlightColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        // Render selection using backend
        self.backend.renderTextSelection(page, ctx, self.scale, self.text_selection.selection_rect, glyph_color, bg_color) catch |err| {
            std.debug.print("Error rendering text selection: {}\n", .{err});
        };

        // Restore context
        c.cairo_restore(ctx);
    }

    fn saveCurrentHighlight(self: *Self) void {
        if (self.text_selection.state != .SELECTED) {
            std.debug.print("No text selected to highlight\n", .{});
            return;
        }

        std.debug.print("Saving highlight:\n", .{});
        std.debug.print("  Original file: {s}\n", .{self.full_path});
        std.debug.print("  Selected text: '{s}'\n", .{self.text_selection.selected_text});
        std.debug.print("  Page: {}, Rect: ({},{}) to ({},{})\n", .{ self.text_selection.start_page, self.text_selection.selection_rect.x1, self.text_selection.selection_rect.y1, self.text_selection.selection_rect.x2, self.text_selection.selection_rect.y2 });

        // Use yellow as default highlight color
        const highlight_color = backend_mod.HighlightColor{ .r = 1.0, .g = 1.0, .b = 0.596, .a = 0.6 };

        // Create the annotation
        const page = self.text_selection.start_page;
        self.backend.createHighlightAnnotation(page, self.text_selection.selection_rect, highlight_color, self.text_selection.selected_text) catch |err| {
            std.debug.print("Failed to create highlight annotation: {}\n", .{err});
            return;
        };

        // Create a new filename for the annotated version
        var output_path = std.ArrayList(u8).init(self.allocator);
        defer output_path.deinit();

        // Check if full_path already has "_annotated" suffix
        const annotated_suffix = "_annotated.pdf";
        if (std.mem.endsWith(u8, self.full_path, annotated_suffix)) {
            // Already has suffix, just overwrite
            output_path.appendSlice(self.full_path) catch {
                std.debug.print("Out of memory creating output path\n", .{});
                return;
            };
        } else if (std.mem.endsWith(u8, self.full_path, ".pdf")) {
            // Remove .pdf and add _annotated.pdf
            const base_name = self.full_path[0 .. self.full_path.len - 4];
            output_path.appendSlice(base_name) catch {
                std.debug.print("Out of memory creating output path\n", .{});
                return;
            };
            output_path.appendSlice(annotated_suffix) catch {
                std.debug.print("Out of memory creating output path\n", .{});
                return;
            };
        } else {
            // No .pdf extension, just add suffix
            output_path.appendSlice(self.full_path) catch {
                std.debug.print("Out of memory creating output path\n", .{});
                return;
            };
            output_path.appendSlice("_annotated.pdf") catch {
                std.debug.print("Out of memory creating output path\n", .{});
                return;
            };
        }

        // Save the document with the new annotation
        self.backend.saveDocument(output_path.items) catch |err| {
            std.debug.print("Failed to save document to {s}: {}\n", .{ output_path.items, err });
            return;
        };

        std.debug.print("Highlight saved to: {s}\n", .{output_path.items});

        std.debug.print("Highlight saved to PDF!\n", .{});

        // Clear the current selection
        self.clearTextSelection();
    }

    fn clearTextSelection(self: *Self) void {
        self.text_selection.clear();
        self.redraw();
        std.debug.print("Text selection cleared\n", .{});
    }

    // Command mode functions
    fn enterCommandMode(self: *Self) void {
        self.command_mode = .COMMAND;
        self.command_buffer.clearRetainingCapacity();
        self.command_cursor = 0;
        self.redraw();
        std.debug.print("Entered command mode\n", .{});
    }

    fn exitCommandMode(self: *Self) void {
        self.command_mode = .NORMAL;
        self.command_buffer.clearRetainingCapacity();
        self.command_cursor = 0;
        self.redraw();
        std.debug.print("Exited command mode\n", .{});
    }

    fn handleCommandModeInput(self: *Self, keyval: u32, modifiers: u32) bool {
        _ = modifiers; // suppress unused parameter warning

        // TODO: Need to properly map keybindings to keycodes
        switch (keyval) {
            27 => { // Escape
                self.exitCommandMode();
                return true;
            },
            65293 => { // Enter/Return
                self.executeCommandLine();
                return true;
            },
            65288 => { // Backspace
                if (self.command_buffer.items.len > 0 and self.command_cursor > 0) {
                    _ = self.command_buffer.orderedRemove(self.command_cursor - 1);
                    self.command_cursor -= 1;
                    self.redraw();
                }
                return true;
            },
            65361 => { // Left arrow
                if (self.command_cursor > 0) {
                    self.command_cursor -= 1;
                    self.redraw();
                }
                return true;
            },
            65363 => { // Right arrow
                if (self.command_cursor < self.command_buffer.items.len) {
                    self.command_cursor += 1;
                    self.redraw();
                }
                return true;
            },
            else => {
                // Handle printable characters
                if (keyval >= 32 and keyval <= 126) { // ASCII printable range
                    const char: u8 = @intCast(keyval);
                    self.command_buffer.insert(self.command_cursor, char) catch return true;
                    self.command_cursor += 1;
                    self.redraw();
                    return true;
                }
                return false;
            },
        }
    }

    fn executeCommandLine(self: *Self) void {
        const command_text = self.command_buffer.items;
        std.debug.print("Executing command: '{s}'\n", .{command_text});

        if (command_text.len == 0) {
            self.exitCommandMode();
            return;
        }

        var parts = std.mem.splitScalar(u8, command_text, ' ');
        // TODO: Support multiple parts
        const command_name = parts.next() orelse {
            self.exitCommandMode();
            return;
        };

        // Handle numeric commands (goto page)
        // if (std.fmt.parseInt(u32, command_name, 10)) |page_num| {
        //     if (page_num > 0 and page_num <= self.total_pages) {
        //         self.current_page = page_num - 1;
        //         self.scrollToPage(self.current_page);
        //         self.redraw();
        //     }
        //     self.exitCommandMode();
        //     return;
        // } else |_| {}

        // Try to parse as a regular command
        if (Command.fromString(command_name)) |command| {
            self.executeCommand(command);
            self.exitCommandMode();
            return;
        }

        std.debug.print("Unknown command: '{s}'\n", .{command_name});
        self.exitCommandMode();
    }

    // Text cursor functions
    fn getPageText(self: *Self, page: u32) ![]const u8 {
        if (page >= self.total_pages) return &[_]u8{};
        
        // Check cache first
        if (self.page_text_cache.get(page)) |cached_text| {
            return cached_text;
        }

        // Extract text from page
        const text = self.backend.getTextForPage(self.allocator, page) catch |err| {
            std.debug.print("Failed to extract text from page {}: {}\n", .{ page, err });
            return &[_]u8{};
        };

        // Cache the text
        try self.page_text_cache.put(page, text);
        return text;
    }

    fn initializeCursor(self: *Self) void {
        // Position cursor at first character of first page
        self.text_cursor.page = 0;
        self.text_cursor.char_index = 0;
        self.updateCursorPosition();
        std.debug.print("Cursor initialized at page {}, char {}\n", .{ self.text_cursor.page, self.text_cursor.char_index });
    }

    fn updateCursorPosition(self: *Self) void {
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0 or self.text_cursor.char_index >= page_text.len) {
            self.text_cursor.visible = false;
            return;
        }

        // Get character position using backend
        const char_rect = self.backend.getCharacterRect(self.text_cursor.page, self.text_cursor.char_index) catch {
            self.text_cursor.visible = false;
            return;
        };

        // Convert to screen coordinates
        const page_x = self.page_x_positions.items[self.text_cursor.page];
        const page_y = self.page_y_positions.items[self.text_cursor.page];
        
        self.text_cursor.x = page_x + (char_rect.x1 * self.scale);
        self.text_cursor.y = page_y + (char_rect.y1 * self.scale);
        self.text_cursor.visible = true;
    }

    fn moveCursorToChar(self: *Self, target_char: u8, forward: bool) bool {
        const page_text = self.getPageText(self.text_cursor.page) catch return false;
        
        if (page_text.len == 0) return false;

        var search_start = self.text_cursor.char_index;
        if (forward and search_start < page_text.len - 1) {
            search_start += 1;
        } else if (!forward and search_start > 0) {
            search_start -= 1;
        } else {
            return false;
        }

        var found_index: ?u32 = null;
        
        if (forward) {
            for (search_start..page_text.len) |i| {
                if (page_text[i] == target_char) {
                    found_index = @intCast(i);
                    break;
                }
            }
        } else {
            var i = search_start;
            while (i > 0) {
                i -= 1;
                if (page_text[i] == target_char) {
                    found_index = @intCast(i);
                    break;
                }
            }
        }

        if (found_index) |index| {
            self.text_cursor.char_index = index;
            self.updateCursorPosition();
            return true;
        }

        return false;
    }

    fn moveCursorWordNext(self: *Self) void {
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0) {
            // Move to next page if current page has no text
            self.moveCursorToNextPage();
            return;
        }
        
        if (self.text_cursor.char_index >= page_text.len) {
            // At end of page, move to next page
            self.moveCursorToNextPage();
            return;
        }

        var i = self.text_cursor.char_index;
        
        // Skip current word
        while (i < page_text.len and isWordChar(page_text[i])) {
            i += 1;
        }
        
        // Skip whitespace
        while (i < page_text.len and isWhitespace(page_text[i])) {
            i += 1;
        }

        if (i >= page_text.len) {
            // Reached end of page, move to next page
            self.moveCursorToNextPage();
        } else {
            self.text_cursor.char_index = i;
            self.updateCursorPosition();
        }
    }

    fn moveCursorWordBack(self: *Self) void {
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0) {
            // Move to previous page if current page has no text
            self.moveCursorToPrevPage();
            return;
        }
        
        if (self.text_cursor.char_index == 0) {
            // At beginning of page, move to previous page
            self.moveCursorToPrevPage();
            return;
        }

        var i = self.text_cursor.char_index;
        
        // Move back one position
        if (i > 0) i -= 1;
        
        // Skip whitespace
        while (i > 0 and isWhitespace(page_text[i])) {
            i -= 1;
        }
        
        // Skip current word
        while (i > 0 and isWordChar(page_text[i])) {
            i -= 1;
        }
        
        // Adjust to start of word if we went too far
        if (i > 0 and !isWordChar(page_text[i])) {
            i += 1;
        }

        self.text_cursor.char_index = i;
        self.updateCursorPosition();
    }

    fn moveCursorWordEnd(self: *Self) void {
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0 or self.text_cursor.char_index >= page_text.len) return;

        var i = self.text_cursor.char_index;
        
        // If at whitespace, skip to next word
        if (isWhitespace(page_text[i])) {
            while (i < page_text.len and isWhitespace(page_text[i])) {
                i += 1;
            }
        }
        
        // Move to end of current word
        while (i < page_text.len - 1 and isWordChar(page_text[i + 1])) {
            i += 1;
        }

        self.text_cursor.char_index = @min(i, @as(u32, @intCast(page_text.len)) - 1);
        self.updateCursorPosition();
    }

    fn moveCursorLineStart(self: *Self) void {
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0) return;

        var i = self.text_cursor.char_index;
        
        // Find start of current line
        while (i > 0 and page_text[i - 1] != '\n') {
            i -= 1;
        }

        self.text_cursor.char_index = i;
        self.updateCursorPosition();
    }

    fn moveCursorLineEnd(self: *Self) void {
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0) return;

        var i = self.text_cursor.char_index;
        
        // Find end of current line
        while (i < page_text.len and page_text[i] != '\n') {
            i += 1;
        }
        
        // Step back one if we hit a newline
        if (i > 0 and i < page_text.len and page_text[i] == '\n') {
            i -= 1;
        }

        self.text_cursor.char_index = @min(i, @as(u32, @intCast(page_text.len)) - 1);
        self.updateCursorPosition();
    }

    fn moveCursorToPage(self: *Self, page: u32) void {
        if (page >= self.total_pages) return;
        
        self.text_cursor.page = page;
        self.text_cursor.char_index = 0; // Start at beginning of page
        self.updateCursorPosition();
    }

    fn handleFindModeInput(self: *Self, char: u8) void {
        if (self.find_mode) |mode| {
            switch (mode) {
                .cursor_char_find => {
                    self.find_char = char;
                    self.find_direction = 1;
                    _ = self.moveCursorToChar(char, true);
                    if (self.visual_mode != .NONE) self.updateVisualSelection();
                    self.redraw();
                },
                .cursor_char_find_back => {
                    self.find_char = char;
                    self.find_direction = -1;
                    _ = self.moveCursorToChar(char, false);
                    if (self.visual_mode != .NONE) self.updateVisualSelection();
                    self.redraw();
                },
                .cursor_char_till => {
                    self.find_char = char;
                    self.find_direction = 1;
                    if (self.moveCursorToChar(char, true)) {
                        // Move one position back to stop before the character
                        if (self.text_cursor.char_index > 0) {
                            self.text_cursor.char_index -= 1;
                            self.updateCursorPosition();
                        }
                    }
                    if (self.visual_mode != .NONE) self.updateVisualSelection();
                    self.redraw();
                },
                .cursor_char_till_back => {
                    self.find_char = char;
                    self.find_direction = -1;
                    if (self.moveCursorToChar(char, false)) {
                        // Move one position forward to stop before the character
                        const page_text = self.getPageText(self.text_cursor.page) catch return;
                        if (self.text_cursor.char_index + 1 < page_text.len) {
                            self.text_cursor.char_index += 1;
                            self.updateCursorPosition();
                        }
                    }
                    if (self.visual_mode != .NONE) self.updateVisualSelection();
                    self.redraw();
                },
                else => {},
            }
            self.find_mode = null; // Clear find mode after processing
        }
    }

    fn moveCursorToNextPage(self: *Self) void {
        if (self.text_cursor.page + 1 < self.total_pages) {
            self.moveCursorToPage(self.text_cursor.page + 1);
            self.scrollToPage(self.text_cursor.page);
            self.redraw();
        }
    }

    fn moveCursorToPrevPage(self: *Self) void {
        if (self.text_cursor.page > 0) {
            const prev_page = self.text_cursor.page - 1;
            self.text_cursor.page = prev_page;
            
            // Position cursor at end of previous page
            const page_text = self.getPageText(prev_page) catch {
                self.text_cursor.char_index = 0;
                self.updateCursorPosition();
                return;
            };
            
            if (page_text.len > 0) {
                self.text_cursor.char_index = @as(u32, @intCast(page_text.len)) - 1;
            } else {
                self.text_cursor.char_index = 0;
            }
            
            self.updateCursorPosition();
            self.scrollToPage(self.text_cursor.page);
            self.redraw();
        }
    }
    
    // Helper functions
    fn isWordChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
    }
    
    fn isWhitespace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }

    fn drawTextCursor(self: *Self, ctx: *c.cairo_t) void {
        if (!self.text_cursor.visible) return;

        // Get current scroll position for visibility check
        var scroll_top: f64 = 0;
        var viewport_height: f64 = self.height;
        
        if (self.scrolled_window) |scrolled| {
            const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));
            if (vadjustment) |vadj| {
                scroll_top = c.gtk_adjustment_get_value(vadj);
                viewport_height = c.gtk_adjustment_get_page_size(vadj);
            }
        }

        // Check if cursor is in visible area
        if (self.text_cursor.y < scroll_top or self.text_cursor.y > scroll_top + viewport_height) {
            return;
        }

        // Save cairo state
        c.cairo_save(ctx);

        // Set cursor appearance
        c.cairo_set_source_rgb(ctx, 1.0, 0.0, 0.0); // Red cursor
        c.cairo_set_line_width(ctx, 2.0);

        // Draw cursor as a vertical line
        const cursor_height: f64 = 12.0; // Height of cursor line
        c.cairo_move_to(ctx, self.text_cursor.x, self.text_cursor.y);
        c.cairo_line_to(ctx, self.text_cursor.x, self.text_cursor.y + cursor_height);
        c.cairo_stroke(ctx);

        // Draw small cursor block at the base
        c.cairo_rectangle(ctx, self.text_cursor.x - 2, self.text_cursor.y + cursor_height - 2, 4, 2);
        c.cairo_fill(ctx);

        // Restore cairo state
        c.cairo_restore(ctx);
    }

    // Visual mode functions
    fn enterVisualMode(self: *Self) void {
        self.visual_mode = .VISUAL;
        self.visual_start_cursor = self.text_cursor;
        self.updateVisualSelection();
        std.debug.print("Entered visual mode\n", .{});
        self.redraw();
    }

    fn exitVisualMode(self: *Self) void {
        self.visual_mode = .NONE;
        self.visual_selection_rect = backend_mod.TextRect{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 };
        std.debug.print("Exited visual mode\n", .{});
        self.redraw();
    }

    fn updateVisualSelection(self: *Self) void {
        if (self.visual_mode == .NONE) return;

        // Calculate selection rectangle from visual_start_cursor to current text_cursor
        const start_rect = self.backend.getCharacterRect(self.visual_start_cursor.page, self.visual_start_cursor.char_index) catch {
            return;
        };
        
        const end_rect = self.backend.getCharacterRect(self.text_cursor.page, self.text_cursor.char_index) catch {
            return;
        };

        // Create selection rectangle spanning from start to end
        self.visual_selection_rect = backend_mod.TextRect{
            .x1 = @min(start_rect.x1, end_rect.x1),
            .y1 = @min(start_rect.y1, end_rect.y1),
            .x2 = @max(start_rect.x2, end_rect.x2),
            .y2 = @max(start_rect.y2, end_rect.y2),
        };
    }

    // hjkl navigation functions
    fn moveCursorLeft(self: *Self) void {
        if (self.text_cursor.char_index > 0) {
            self.text_cursor.char_index -= 1;
            self.updateCursorPosition();
        } else if (self.text_cursor.page > 0) {
            // Move to end of previous page
            self.moveCursorToPrevPage();
        }
    }

    fn moveCursorRight(self: *Self) void {
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (self.text_cursor.char_index + 1 < page_text.len) {
            self.text_cursor.char_index += 1;
            self.updateCursorPosition();
        } else if (self.text_cursor.page + 1 < self.total_pages) {
            // Move to beginning of next page
            self.moveCursorToNextPage();
        }
    }

    fn moveCursorUp(self: *Self) void {
        // For now, implement as moving to previous line start
        // A more sophisticated implementation would maintain column position
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0) return;

        var i = self.text_cursor.char_index;
        
        // Go to start of current line
        while (i > 0 and page_text[i - 1] != '\n') {
            i -= 1;
        }
        
        // If we're already at line start, go to previous line
        if (i == self.text_cursor.char_index and i > 0) {
            i -= 1; // Step back to previous line
            // Find start of that line
            while (i > 0 and page_text[i - 1] != '\n') {
                i -= 1;
            }
        }

        self.text_cursor.char_index = i;
        self.updateCursorPosition();
    }

    fn moveCursorDown(self: *Self) void {
        // For now, implement as moving to next line start
        const page_text = self.getPageText(self.text_cursor.page) catch return;
        
        if (page_text.len == 0) return;

        var i = self.text_cursor.char_index;
        
        // Find end of current line
        while (i < page_text.len and page_text[i] != '\n') {
            i += 1;
        }
        
        // Move to start of next line
        if (i < page_text.len and page_text[i] == '\n') {
            i += 1;
        }

        if (i >= page_text.len) {
            // Move to next page if at end
            self.moveCursorToNextPage();
        } else {
            self.text_cursor.char_index = i;
            self.updateCursorPosition();
        }
    }

    fn drawVisualSelection(self: *Self, ctx: *c.cairo_t) void {
        if (self.visual_mode == .NONE) return;

        // Only draw selection if we're on the same page as the selection
        // For multi-page selections, we'd need more complex logic
        if (self.visual_start_cursor.page != self.text_cursor.page) return;

        const page_x = self.page_x_positions.items[self.text_cursor.page];
        const page_y = self.page_y_positions.items[self.text_cursor.page];

        // Save context
        c.cairo_save(ctx);

        // Translate to page position
        c.cairo_translate(ctx, page_x, page_y);

        // Set selection color (light blue with transparency)
        const bg_color = backend_mod.HighlightColor{ .r = 0.4, .g = 0.7, .b = 1.0, .a = 0.3 };
        const glyph_color = backend_mod.HighlightColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        // Render visual selection using backend
        self.backend.renderTextSelection(self.text_cursor.page, ctx, self.scale, self.visual_selection_rect, glyph_color, bg_color) catch |err| {
            std.debug.print("Error rendering visual selection: {}\n", .{err});
        };

        // Restore context
        c.cairo_restore(ctx);
    }
};

const GdkEventButton = extern struct {
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

fn onButtonPress(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));
    const button_event: *GdkEventButton = @ptrCast(@alignCast(event.?));

    // Handle left mouse button for text selection
    if (button_event.button == 1) { // Left button
        viewer.startTextSelection(button_event.x, button_event.y);
        return 1; // Event handled
    }

    return 0; // Event not handled
}

fn onButtonRelease(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));
    const button_event: *GdkEventButton = @ptrCast(@alignCast(event.?));

    // Handle left mouse button release
    if (button_event.button == 1) { // Left button
        viewer.finishTextSelection();
        return 1; // Event handled
    }

    return 0; // Event not handled
}

fn onMotionNotify(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));
    const motion_event: *GdkEventButton = @ptrCast(@alignCast(event.?)); // Reuse button struct as it has x,y

    // Update text selection if we're currently selecting
    viewer.updateTextSelection(motion_event.x, motion_event.y);

    return 0; // Let other handlers process this event too
}

fn onDestroy(_: *c.GtkWidget, _: ?*anyopaque) callconv(.C) void {
    c.gtk_main_quit();
}

const GdkEventConfigure = extern struct {
    type: GdkEventType,
    window: ?*anyopaque,
    send_event: i8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

fn onWindowResize(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));
    // _ = event;
    const gdk_event: *GdkEventConfigure = @ptrCast(@alignCast(event.?));

    // Debug output to see resize events
    // std.debug.print("Window resized to {}x{}\n", .{ gdk_event.width, gdk_event.height });

    viewer.width = @as(f64, @floatFromInt(gdk_event.width));
    viewer.height = @as(f64, @floatFromInt(gdk_event.height));

    viewer.updateDrawingAreaSize();
    viewer.redraw();

    return 0; // Let other handlers process this event too
}

pub const GdkEventType = enum(c_int) {
    GDK_NOTHING = -1, // Special null event
    GDK_DELETE = 0,
    GDK_DESTROY = 1,
    GDK_EXPOSE = 2,
    GDK_MOTION_NOTIFY = 3,
    GDK_BUTTON_PRESS = 4,
    GDK_2BUTTON_PRESS = 5,
    // GDK_DOUBLE_BUTTON_PRESS = 5, // Alias
    GDK_3BUTTON_PRESS = 6,
    // GDK_TRIPLE_BUTTON_PRESS = 6, // Alias
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
    // 30 skipped in GDK
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

const GdkModifierMask = enum(u32) {
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

const GdkEventKey = extern struct {
    type: GdkEventType, // The event type (enum or int in Zig, according to the C definition)
    window: *anyopaque, // Pointer field => pointer in Zig
    send_event: i8, // gint8 => i8
    time: u32, // guint32 => u32
    state: u32, // GdkModifierType => u32 (modifier state, not a pointer!)
    keyval: u32, // guint => u32, usually used for key codes in GDK
    length: i32, // gint => i32
    string: [*c]u8, // gchar* => C pointer to u8 (or i8 if you want signed chars)
    hardware_keycode: u16, // guint16 => u16
    group: u8, // guint8 => u8
    is_modifier: bool, // guint is_modifier : 1 => u1 (single bit field)
};

fn onKeyPress(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));
    const gdk_event: *GdkEventKey = @ptrCast(@alignCast(event.?));

    // Extract key information
    const keyval = gdk_event.keyval;
    const modifiers = gdk_event.state;

    // Debug output
    std.debug.print("keyval={} modifiers={} hardware_keycode={} mode={}\n", .{ keyval, modifiers, gdk_event.hardware_keycode, viewer.command_mode });

    // Handle command mode input
    if (viewer.command_mode == .COMMAND) {
        return if (viewer.handleCommandModeInput(keyval, modifiers)) 1 else 0;
    }

    // Handle find mode input (waiting for character after f/F/t/T)
    if (viewer.find_mode != null) {
        if (keyval >= 32 and keyval <= 126) { // ASCII printable range
            const char: u8 = @intCast(keyval);
            viewer.handleFindModeInput(char);
            return 1;
        } else if (keyval == 27) { // Escape - cancel find mode
            viewer.find_mode = null;
            return 1;
        }
        return 0;
    }

    // Handle escape key
    if (keyval == 27) { // Escape
        if (viewer.visual_mode != .NONE) {
            viewer.exitVisualMode();
            return 1;
        }
    }

    // Handle colon key to enter command mode
    if (keyval == ':') {
        viewer.enterCommandMode();
        return 1;
    }

    // Handle j/k keys differently in visual mode vs normal mode
    if (viewer.visual_mode != .NONE) {
        // In visual mode, j/k should move cursor up/down
        if (keyval == 'j') {
            viewer.executeCommand(.cursor_down);
            return 1;
        } else if (keyval == 'k') {
            viewer.executeCommand(.cursor_up);
            return 1;
        }
    }

    // Look up command using the keybinding system
    if (viewer.keybindings.getCommand(keyval, modifiers)) |command| {
        std.debug.print("Executing command: {}\n", .{command});
        viewer.executeCommand(command);
        return 1; // Event handled
    } else {
        std.debug.print("No command found for keyval={} modifiers={}\n", .{ keyval, modifiers });
        return 0; // Event not handled
    }
}

const GdkEventScroll = extern struct {
    type: GdkEventType,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    state: u32, // if the pointer can be null; else without '?'
    direction: c.GdkScrollDirection,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
    delta_x: f64,
    delta_y: f64,
    is_stop: bool, // replaces guint is_stop : 1;
};

fn onScroll(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));

    const gdk_event: *GdkEventScroll = @ptrCast(@alignCast(event.?));
    const ctrl_pressed = (gdk_event.state & c.GDK_CONTROL_MASK) != 0;

    if (ctrl_pressed) {
        switch (gdk_event.direction) {
            c.GDK_SCROLL_UP => viewer.executeCommand(.zoom_in),
            c.GDK_SCROLL_DOWN => viewer.executeCommand(.zoom_out),
            c.GDK_SCROLL_SMOOTH => {
                if (gdk_event.delta_y >= 0) {
                    viewer.executeCommand(.zoom_in);
                } else {
                    viewer.executeCommand(.zoom_out);
                }
            },
            else => {},
        }
    }

    // Update current_page based on the visible page range after scrolling
    // We need to delay this slightly to let GTK update the scroll position first
    _ = c.g_idle_add(@ptrCast(&updateCurrentPageFromScroll), user_data);

    // Force a complete redraw to ensure status bar is properly positioned
    viewer.redraw();

    return 0; // Let GTK handle the actual scrolling
}

fn updateCurrentPageFromScroll(user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));

    // Get the currently visible page range
    const visible_range = viewer.getVisiblePageRange();

    // Update current_page to the first visible page
    viewer.current_page = visible_range.first;

    // Trigger another redraw to update the status bar with the new page number
    viewer.redraw();

    return 0; // Don't repeat this idle callback
}

fn onDraw(_: *c.GtkWidget, ctx: *c.cairo_t, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));

    // Clear background to light gray
    c.cairo_set_source_rgb(ctx, 0.9, 0.9, 0.9);
    c.cairo_paint(ctx);

    // Get visible page range for performance
    const visible_range = viewer.getVisiblePageRange();

    // Only render visible pages + small buffer
    for (visible_range.first..visible_range.last + 1) |page_idx| {
        const page = @as(u32, @intCast(page_idx));
        const page_height = viewer.page_heights.items[page_idx] * viewer.scale;

        // Calculate this page's position
        const page_y = viewer.getPageYPosition(page);
        const page_x = viewer.page_x_positions.items[page_idx];

        // Save the current transform
        c.cairo_save(ctx);

        // Translate to the page position
        c.cairo_translate(ctx, page_x, page_y);

        // Draw white background for the page
        const page_info = viewer.backend.getPageInfo(page) catch {
            c.cairo_restore(ctx);
            continue;
        };

        const page_width = page_info.width * viewer.scale;

        c.cairo_set_source_rgb(ctx, 1.0, 1.0, 1.0);
        c.cairo_rectangle(ctx, 0, 0, page_width, page_height);
        c.cairo_fill(ctx);

        // Draw subtle border
        c.cairo_set_source_rgb(ctx, 0.7, 0.7, 0.7);
        c.cairo_set_line_width(ctx, 1.0);
        c.cairo_rectangle(ctx, 0, 0, page_width, page_height);
        c.cairo_stroke(ctx);

        // Render the page content
        viewer.backend.renderPage(page, ctx, viewer.scale) catch |err| {
            std.debug.print("Error rendering page {}: {}\n", .{ page, err });
        };

        // Restore the transform
        c.cairo_restore(ctx);
    }

    // Draw text selection if active
    viewer.drawTextSelection(ctx);

    // Draw visual selection if in visual mode
    viewer.drawVisualSelection(ctx);

    // Draw text cursor
    viewer.drawTextCursor(ctx);

    // Draw status bar at the bottom of the viewport (like Zathura) - only once, outside the page loop
    viewer.drawStatusBar(ctx);

    // Draw TOC overlay if visible
    if (viewer.toc_mode == .VISIBLE) {
        viewer.drawTocOverlay(ctx);
    }

    return 0;
}
