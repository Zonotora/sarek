const std = @import("std");
const backend_mod = @import("backends/backend.zig");
const poppler = @import("backends/poppler.zig");
const keybindings = @import("input/keybindings.zig");
const commands = @import("input/commands.zig");

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

pub const Viewer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend_impl: *poppler.PopplerBackend,
    backend: backend_mod.Backend,
    keybindings: keybindings.KeyBindings,

    // State
    current_page: u32,
    total_pages: u32,
    scale: f64,
    fit_mode: FitMode,

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

        // Pre-calculate page dimensions for layout
        for (0..total_pages) |i| {
            const page_info = backend_interface.getPageInfo(@intCast(i)) catch {
                page_heights.deinit();
                page_widths.deinit();
                page_y_positions.deinit();
                page_x_positions.deinit();
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
            .current_page = 0,
            .total_pages = total_pages,
            .scale = 1.0,
            .fit_mode = .NONE,
            .scroll_y = 0.0,
            .page_spacing = PAGE_OFFSET,
            .pages_per_row = 2,
            .row_max_heights = row_max_heights,
            .page_heights = page_heights,
            .page_widths = page_widths,
            .page_y_positions = page_y_positions,
            .page_x_positions = page_x_positions,
            .window = null,
            .drawing_area = null,
            .scrolled_window = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.backend.deinit();
        self.keybindings.deinit();
        self.row_max_heights.deinit();
        self.page_heights.deinit();
        self.page_widths.deinit();
        self.page_y_positions.deinit();
        self.page_x_positions.deinit();
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

        // _ = c.g_signal_connect_data(self.window, "scroll_event", @ptrCast(&onScroll), self, null, 0);

        // Add key event handling
        c.gtk_widget_add_events(self.window, c.GDK_KEY_PRESS_MASK);
        _ = c.g_signal_connect_data(self.window, "key_press_event", @ptrCast(&onKeyPress), self, null, 0);

        // Make window focusable for key events
        c.gtk_widget_set_can_focus(self.window, 1);
        c.gtk_widget_grab_focus(self.window);

        // Show all widgets
        c.gtk_widget_show_all(self.window);

        // Start main loop
        c.gtk_main();
    }

    fn executeCommand(self: *Self, command: commands.Command) void {
        switch (command) {
            .next_page => {
                self.current_page += self.pages_per_row;
                if (self.current_page >= self.total_pages) self.current_page = self.total_pages - 1;
                self.scrollToPage(self.current_page);
            },
            .prev_page => {
                self.current_page = if (self.pages_per_row > self.current_page) 0 else self.current_page - self.pages_per_row;
                self.scrollToPage(self.current_page);
            },
            .first_page => {
                self.current_page = 0;
                self.scrollToPage(self.current_page);
            },
            .last_page => {
                self.current_page = self.total_pages - 1;
                self.scrollToPage(self.current_page);
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
            else => {
                // TODO: Implement remaining commands
                std.debug.print("Command not implemented: {}\n", .{command});
            },
        }
    }

    fn recalculatePagePositions(self: *Self) void {
        var current_y: f64 = 0;
        var current_x: f64 = MARGIN_LEFT;

        var total_width: f64 = 0;
        var row_width: f64 = 0;
        var row_height: f64 = 0;
        var last_row: u32 = 0;

        for (0..self.total_pages) |i| {
            const page = @as(u32, @intCast(i));
            const row = page / self.pages_per_row;

            if (row != last_row) {
                self.row_max_heights.items[row - 1] = row_height;
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

        for (0..self.total_pages) |i| {
            const page = @as(u32, @intCast(i));
            const row = page / self.pages_per_row;
            const col = page % self.pages_per_row;

            const page_width = self.page_widths.items[i] * self.scale;
            const page_height = self.page_heights.items[i] * self.scale;
            const page_x_offset = (row_max_width - page_width) / 2;
            const page_y_offset = (self.row_max_heights.items[row] - page_height) / 2;
            std.debug.print("i={} {d:.2} {d:.2}\n", .{ i, self.row_max_heights.items[row], page_height });

            if (col == 0) {
                // First page in row - reset X and calculate Y
                current_x = MARGIN_LEFT;
                if (row > 0) {
                    current_y += row_height + self.page_spacing;
                }
                row_height = 0; // Reset for new row
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

        const page_info = self.backend.getPageInfo(self.current_page) catch return;
        const viewport = self.getViewportSize();

        // TODO: Not sure we should take y-margins into account
        const available_width = viewport.width - (MARGIN_LEFT + MARGIN_RIGHT);
        const available_height = viewport.height; // - (MARGIN_TOP + MARGIN_BOTTOM);

        if (available_width <= 0 or available_height <= 0) return;

        // Calculate scale to fit both width and height
        const width_scale = available_width / page_info.width;
        const height_scale = available_height / page_info.height;

        // Use the smaller scale to ensure the entire page fits
        self.scale = @max(0.1, @min(5.0, @min(width_scale, height_scale)));

        // std.debug.print("Zoom fit page: scale = {d:.2}\n", .{self.scale});
    }

    fn zoomFitWidth(self: *Self) void {
        if (self.current_page >= self.total_pages) return;

        self.fit_mode = .FIT_WIDTH; // Set fit mode

        const page_info = self.backend.getPageInfo(self.current_page) catch return;
        const viewport = self.getViewportSize();

        const available_width = viewport.width - (MARGIN_LEFT + MARGIN_RIGHT);

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
};

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
    std.debug.print("Window resized to {}x{}\n", .{ gdk_event.width, gdk_event.height });

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
    std.debug.print("keyval={} modifiers={} hardware_keycode={}\n", .{ keyval, modifiers, gdk_event.hardware_keycode });

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
    state: ?*anyopaque, // if the pointer can be null; else without '?'
    direction: c.GdkScrollDirection,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
    delta_x: f64,
    delta_y: f64,
    is_stop: bool, // replaces guint is_stop : 1;
};

fn onScroll(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;

    const gdk_event: *GdkEventScroll = @ptrCast(@alignCast(event.?));
    std.debug.print("{}\n", .{gdk_event});

    // std.debug.print("scroll", .{});
    return 1;
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

        // Add page number label
        c.cairo_save(ctx);
        c.cairo_set_source_rgb(ctx, 0.3, 0.3, 0.3);
        c.cairo_select_font_face(ctx, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(ctx, 12.0);

        // Create page number string
        var page_num_buf: [32]u8 = undefined;
        const page_num_str = std.fmt.bufPrintZ(page_num_buf[0..], "Page {}", .{page + 1}) catch "Page ?";

        c.cairo_move_to(ctx, page_x, page_y + page_height + 25);
        c.cairo_show_text(ctx, page_num_str.ptr);
        c.cairo_restore(ctx);
    }

    return 0;
}
