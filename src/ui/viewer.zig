const std = @import("std");
const backend_mod = @import("../backends/backend.zig");
const poppler = @import("../backends/poppler.zig");
const keybindings = @import("../input/keybindings.zig");
const commands = @import("../input/commands.zig");
const Command = @import("../input/commands.zig").Command;
const gtk = @import("../window/gtk.zig");
const toc = @import("toc.zig");

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

const CommandMode = enum {
    NORMAL,
    COMMAND,
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
    toc_state: toc.TocState,

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
            .keybindings = keybindings.KeyBindings.init(allocator), // TODO: Handle potential error from init
            .filename = filename_copy,
            .full_path = full_path_copy,
            .width = WINDOW_WIDTH,
            .height = WINDOW_HEIGHT,
            .current_page = 0,
            .total_pages = total_pages,
            .scale = 1.0,
            .fit_mode = .NONE,
            .toc_state = toc.TocState.init(allocator),
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
        self.toc_state.deinit();

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
        self.allocator.destroy(self.backend_impl);
    }

    pub fn run(self: *Self) !void {
        // TODO: Decouple GTK from viewer
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

        // Set up event handler
        const event_handler = gtk.EventHandler.init(self);
        gtk.setEventHandler(event_handler);

        // Connect signals
        _ = c.g_signal_connect_data(self.window, "destroy", @ptrCast(&gtk.onDestroy), null, null, 0);
        _ = c.g_signal_connect_data(self.drawing_area, "draw", @ptrCast(&onDraw), self, null, 0);
        _ = c.g_signal_connect_data(self.window, "configure-event", @ptrCast(&gtk.onWindowResize), self, null, 0);

        // Add scroll event handling to force redraw on mouse wheel scroll
        c.gtk_widget_add_events(self.drawing_area, c.GDK_SCROLL_MASK);
        _ = c.g_signal_connect_data(self.drawing_area, "scroll-event", @ptrCast(&gtk.onScroll), self, null, 0);

        // Add key event handling
        c.gtk_widget_add_events(self.window, c.GDK_KEY_PRESS_MASK);
        _ = c.g_signal_connect_data(self.window, "key_press_event", @ptrCast(&gtk.onKeyPress), self, null, 0);

        // Add mouse event handling for text selection
        c.gtk_widget_add_events(self.drawing_area, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK);
        _ = c.g_signal_connect_data(self.drawing_area, "button-press-event", @ptrCast(&gtk.onButtonPress), self, null, 0);
        _ = c.g_signal_connect_data(self.drawing_area, "button-release-event", @ptrCast(&gtk.onButtonRelease), self, null, 0);
        _ = c.g_signal_connect_data(self.drawing_area, "motion-notify-event", @ptrCast(&gtk.onMotionNotify), self, null, 0);

        // Make window focusable for key events
        c.gtk_widget_set_can_focus(self.window, 1);
        c.gtk_widget_grab_focus(self.window);

        // Show all widgets
        c.gtk_widget_show_all(self.window);

        // Start main loop
        c.gtk_main();
    }

    fn executeCommand(self: *Self, command: commands.Command) void {
        // Handle TOC-specific navigation when TOC is visible
        if (self.toc_state.mode == .VISIBLE) {
            switch (command) {
                .next_page => {
                    self.toc_state.navigate(.DOWN);
                    self.redraw();
                    return;
                },
                .prev_page => {
                    self.toc_state.navigate(.UP);
                    self.redraw();
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
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .prev_page => {
                self.current_page = if (self.pages_per_row > self.current_page) 0 else self.current_page - self.pages_per_row;
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .first_page => {
                self.current_page = 0;
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .last_page => {
                self.current_page = self.total_pages - 1;
                self.scrollToPage(self.current_page);
                self.redraw();
            },
            .zoom_in => {
                self.fit_mode = .NONE; // Disable fit mode when manually zooming
                self.scale = @min(self.scale * 1.2, 5.0);
                self.updateDrawingAreaSize();
                self.redraw();
            },
            .zoom_out => {
                self.fit_mode = .NONE; // Disable fit mode when manually zooming
                self.scale = @max(self.scale / 1.2, 0.1);
                self.updateDrawingAreaSize();
                self.redraw();
            },
            .zoom_original => {
                self.fit_mode = .NONE; // Disable fit mode when manually zooming
                self.scale = 1.0;
                self.updateDrawingAreaSize();
                self.redraw();
            },
            .zoom_fit_page => {
                self.zoomFitPage();
                self.updateDrawingAreaSize();
                self.redraw();
            },
            .zoom_fit_width => {
                self.zoomFitWidth();
                self.updateDrawingAreaSize();
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
                self.toc_state.toggle(&self.backend, self.total_pages);
                self.redraw();
            },
            .toc_up => {
                if (self.toc_state.mode == .VISIBLE) {
                    self.toc_state.navigate(.UP);
                    self.redraw();
                }
            },
            .toc_down => {
                if (self.toc_state.mode == .VISIBLE) {
                    self.toc_state.navigate(.DOWN);
                    self.redraw();
                }
            },
            .toc_select => {
                if (self.toc_state.mode == .VISIBLE) {
                    if (self.toc_state.select()) |page| {
                        self.current_page = page;
                        self.scrollToPage(self.current_page);
                        self.redraw();
                    }
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

    pub fn handleCommandModeInput(self: *Self, keyName: keybindings.KeyName, value: u32) bool {
        switch (keyName) {
            .ESCAPE => { // Escape
                self.exitCommandMode();
                return true;
            },
            .ENTER => { // Enter/Return
                self.executeCommandLine();
                return true;
            },
            .BACKSPACE => { // Backspace
                if (self.command_buffer.items.len > 0 and self.command_cursor > 0) {
                    _ = self.command_buffer.orderedRemove(self.command_cursor - 1);
                    self.command_cursor -= 1;
                    self.redraw();
                }
                return true;
            },
            .ARROW_LEFT => { // Left arrow
                if (self.command_cursor > 0) {
                    self.command_cursor -= 1;
                    self.redraw();
                }
                return true;
            },
            .ARROW_RIGHT => { // Right arrow
                if (self.command_cursor < self.command_buffer.items.len) {
                    self.command_cursor += 1;
                    self.redraw();
                }
                return true;
            },
            else => {
                // Handle printable characters
                // TODO: Refactor
                if (value >= 32 and value <= 126) { // ASCII printable range
                    const char: u8 = @intCast(value);
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

    // Event handler methods for gtk.EventHandler interface
    pub fn onButtonPress(self: *Self, event: *gtk.GdkEventButton) bool {
        // Handle left mouse button for text selection
        if (event.button == 1) { // Left button
            self.startTextSelection(event.x, event.y);
            return true; // Event handled
        }
        return false; // Event not handled
    }

    pub fn onButtonRelease(self: *Self, event: *gtk.GdkEventButton) bool {
        // Handle left mouse button release
        if (event.button == 1) { // Left button
            self.finishTextSelection();
            return true; // Event handled
        }
        return false; // Event not handled
    }

    pub fn onMotionNotify(self: *Self, event: *gtk.GdkEventButton) bool {
        // Update text selection if we're currently selecting
        self.updateTextSelection(event.x, event.y);
        return false; // Let other handlers process this event too
    }

    pub fn onKeyPress(self: *Self, event: *gtk.GdkEventKey) bool {
        const keyName = keybindings.gdkKeyvalToKeyName(event.keyval);
        const modifiers = keybindings.gdkModifiersToFlags(event.state);

        std.debug.print("Keypress key={} modifiers={}\n", .{ keyName, modifiers });

        // Handle command mode input
        if (self.command_mode == .COMMAND) {
            return self.handleCommandModeInput(keyName, event.keyval);
        }

        // Handle colon key to enter command mode
        if (keyName == .COLON) {
            self.enterCommandMode();
            return true;
        }

        // Look up command using the keybinding system
        if (self.keybindings.getCommand(keyName, modifiers)) |command| {
            std.debug.print("Executing command: {}\n", .{command});
            self.executeCommand(command);
            return true; // Event handled
        } else {
            std.debug.print("No command found for key={} modifiers={}\n", .{ keyName, modifiers });
            return false; // Event not handled
        }
    }

    pub fn onScroll(self: *Self, event: *gtk.GdkEventScroll) bool {
        const ctrl_pressed = (event.state & c.GDK_CONTROL_MASK) != 0;

        if (ctrl_pressed) {
            switch (event.direction) {
                c.GDK_SCROLL_UP => self.executeCommand(.zoom_in),
                c.GDK_SCROLL_DOWN => self.executeCommand(.zoom_out),
                c.GDK_SCROLL_SMOOTH => {
                    if (event.delta_y >= 0) {
                        self.executeCommand(.zoom_in);
                    } else {
                        self.executeCommand(.zoom_out);
                    }
                },
                else => {},
            }
        }

        // Update current_page based on the visible page range after scrolling
        // We need to delay this slightly to let GTK update the scroll position first
        _ = c.g_idle_add(@ptrCast(&updateCurrentPageFromScroll), self);

        // Force a complete redraw to ensure status bar is properly positioned
        self.redraw();

        return false; // Let GTK handle the actual scrolling
    }

    pub fn onWindowResize(self: *Self, event: *gtk.GdkEventConfigure) bool {
        self.width = @as(f64, @floatFromInt(event.width));
        self.height = @as(f64, @floatFromInt(event.height));

        self.updateDrawingAreaSize();
        self.redraw();

        return false; // Let other handlers process this event too
    }
};

// Helper function for updateCurrentPageFromScroll
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

    // Draw status bar at the bottom of the viewport (like Zathura) - only once, outside the page loop
    viewer.drawStatusBar(ctx);

    // Draw TOC overlay if visible
    if (viewer.toc_state.mode == .VISIBLE) {
        viewer.toc_state.drawOverlay(ctx, viewer.width, viewer.height, viewer.scrolled_window);
    }

    return 0;
}
