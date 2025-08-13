const std = @import("std");
const backend_mod = @import("../backends/backend.zig");

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("cairo.h");
});

pub const TocMode = enum {
    HIDDEN,
    VISIBLE,
};

pub const TocDirection = enum {
    UP,
    DOWN,
};

pub const TocState = struct {
    entries: std.ArrayList(backend_mod.TocEntry),
    mode: TocMode,
    selected_index: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TocState {
        return TocState{
            .entries = std.ArrayList(backend_mod.TocEntry).init(allocator),
            .mode = .HIDDEN,
            .selected_index = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TocState) void {
        // Clean up TOC entries
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn toggle(self: *TocState, backend: *backend_mod.Backend, total_pages: u32) void {
        switch (self.mode) {
            .HIDDEN => {
                // Try to extract TOC if we haven't done it yet
                if (self.entries.items.len == 0) {
                    self.extract(backend, total_pages) catch {
                        std.debug.print("Failed to extract TOC or no TOC available\n", .{});
                        return;
                    };
                }
                if (self.entries.items.len > 0) {
                    self.mode = .VISIBLE;
                    self.selected_index = 0;
                    std.debug.print("TOC opened\n", .{});
                } else {
                    std.debug.print("No TOC available in this document\n", .{});
                }
            },
            .VISIBLE => {
                self.mode = .HIDDEN;
                std.debug.print("TOC closed\n", .{});
            },
        }
    }

    pub fn navigate(self: *TocState, direction: TocDirection) void {
        if (self.entries.items.len == 0) return;

        switch (direction) {
            .UP => {
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                }
            },
            .DOWN => {
                if (self.selected_index < self.entries.items.len - 1) {
                    self.selected_index += 1;
                }
            },
        }
    }

    pub fn select(self: *TocState) ?u32 {
        if (self.entries.items.len == 0 or self.selected_index >= self.entries.items.len) {
            return null;
        }

        const selected_entry = &self.entries.items[self.selected_index];

        // Close TOC
        self.mode = .HIDDEN;

        std.debug.print("Navigated to page {} ({s})\n", .{ selected_entry.page + 1, selected_entry.title });
        return selected_entry.page;
    }

    fn extract(self: *TocState, backend: *backend_mod.Backend, total_pages: u32) !void {
        // Use the backend to extract real TOC from the PDF
        try backend.extractToc(self.allocator, &self.entries);

        // Clamp page numbers to valid range
        for (self.entries.items) |*entry| {
            std.debug.print("page={} title={s}\n", .{ entry.page, entry.title });
            entry.page = @min(entry.page, total_pages - 1);
        }

        std.debug.print("Extracted {} TOC entries\n", .{self.entries.items.len});
    }

    pub fn drawOverlay(self: *TocState, ctx: *c.cairo_t, width: f64, height: f64, scrolled_window: ?*c.GtkWidget) void {
        if (self.entries.items.len == 0) return;

        // Get viewport info for positioning
        var scroll_top: f64 = 0;
        var viewport_height: f64 = height;

        if (scrolled_window) |scrolled| {
            const vadjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scrolled));
            if (vadjustment) |vadj| {
                scroll_top = c.gtk_adjustment_get_value(vadj);
                viewport_height = c.gtk_adjustment_get_page_size(vadj);
            }
        }

        // Draw semi-transparent background covering the entire viewport
        c.cairo_save(ctx);
        c.cairo_set_source_rgba(ctx, 0.1, 0.1, 0.1, 0.9); // Dark background
        c.cairo_rectangle(ctx, 0, scroll_top, width, viewport_height);
        c.cairo_fill(ctx);

        // TOC styling
        const margin: f64 = 20.0;
        const line_height: f64 = 25.0;
        const font_size: f64 = 14.0;
        const indent_per_level: f64 = 20.0;

        // Calculate visible TOC area
        const toc_x = margin;
        const toc_y = scroll_top + margin;
        const toc_width = width - 2 * margin;
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
        if (self.selected_index >= max_visible_entries) {
            toc_scroll_offset = self.selected_index - max_visible_entries + 1;
        }

        // Set up text properties for entries
        c.cairo_select_font_face(ctx, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(ctx, font_size);

        // Draw TOC entries
        var y_pos = toc_y + 50; // Start after title
        const end_idx = @min(toc_scroll_offset + max_visible_entries, @as(u32, @intCast(self.entries.items.len)));

        for (toc_scroll_offset..end_idx) |i| {
            const entry = &self.entries.items[i];
            const is_selected = (i == self.selected_index);

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
};
