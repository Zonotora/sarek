const std = @import("std");
const backend_mod = @import("backends/backend.zig");
const poppler = @import("backends/poppler.zig");
const keybindings = @import("input/keybindings.zig");
const commands = @import("input/commands.zig");

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("cairo.h");
});

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

    // GTK widgets
    window: ?*c.GtkWidget,
    drawing_area: ?*c.GtkWidget,

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

        return Self{
            .allocator = allocator,
            .backend_impl = backend_impl,
            .backend = backend_interface,
            .keybindings = keybindings.KeyBindings.init(allocator),
            .current_page = 0,
            .total_pages = total_pages,
            .scale = 1.0,
            .window = null,
            .drawing_area = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.backend.deinit();
        self.keybindings.deinit();
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

        // Create drawing area
        self.drawing_area = c.gtk_drawing_area_new();
        if (self.drawing_area == null) return error.GtkInitFailed;

        c.gtk_container_add(@ptrCast(self.window), self.drawing_area);

        // Connect signals
        _ = c.g_signal_connect_data(self.window, "destroy", @ptrCast(&onDestroy), null, null, 0);
        _ = c.g_signal_connect_data(self.drawing_area, "draw", @ptrCast(&onDraw), self, null, 0);

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
                if (self.current_page + 1 < self.total_pages) {
                    self.current_page += 1;
                    self.redraw();
                }
            },
            .prev_page => {
                if (self.current_page > 0) {
                    self.current_page -= 1;
                    self.redraw();
                }
            },
            .first_page => {
                self.current_page = 0;
                self.redraw();
            },
            .last_page => {
                self.current_page = self.total_pages - 1;
                self.redraw();
            },
            .zoom_in => {
                self.scale = @min(self.scale * 1.2, 5.0);
                self.redraw();
            },
            .zoom_out => {
                self.scale = @max(self.scale / 1.2, 0.1);
                self.redraw();
            },
            .zoom_original => {
                self.scale = 1.0;
                self.redraw();
            },
            .quit => {
                c.gtk_main_quit();
            },
            .refresh => {
                self.redraw();
            },
            else => {
                // TODO: Implement remaining commands
                std.debug.print("Command not implemented: {}\n", .{command});
            },
        }
    }

    fn redraw(self: *Self) void {
        if (self.drawing_area) |area| {
            c.gtk_widget_queue_draw(area);
        }
    }
};

fn onDestroy(_: *c.GtkWidget, _: ?*anyopaque) callconv(.C) void {
    c.gtk_main_quit();
}

fn onKeyPress(_: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));
    _ = viewer;
    _ = event;

    // For now, implement a simple test - 'q' to quit, 'j' for next page, 'k' for prev page
    // This is a simplified version until we can properly handle the GTK events
    // In a real implementation, we'd extract keyval from the event

    // Hardcode some basic commands for testing
    // viewer.executeCommand(.quit); // This will at least test the quit functionality

    return 1; // Event handled
}

fn onDraw(_: *c.GtkWidget, ctx: *c.cairo_t, user_data: ?*anyopaque) callconv(.C) c.gboolean {
    const viewer: *Viewer = @ptrCast(@alignCast(user_data));

    // Clear background to white
    c.cairo_set_source_rgb(ctx, 1.0, 1.0, 1.0);
    c.cairo_paint(ctx);

    // Render the current page
    viewer.backend.renderPage(viewer.current_page, ctx, viewer.scale) catch |err| {
        std.debug.print("Error rendering page: {}\n", .{err});
        return 0;
    };

    return 0;
}
