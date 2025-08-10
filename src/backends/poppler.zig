const std = @import("std");
const backend_mod = @import("backend.zig");
const Backend = backend_mod.Backend;
const PdfError = backend_mod.PdfError;
const PageInfo = backend_mod.PageInfo;

const c = @cImport({
    @cInclude("poppler.h");
    @cInclude("cairo.h");
});

const PopplerDest = struct {
    type: u8,
    page: c_int,
};

pub const PopplerBackend = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    document: ?*c.PopplerDocument,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .document = null,
        };
    }

    pub fn backend(self: *Self) Backend {
        return Backend{
            .ptr = self,
            .vtable = &.{
                .open = open,
                .close = close,
                .get_page_count = getPageCount,
                .get_page_info = getPageInfo,
                .render_page = renderPage,
                .extract_toc = extractToc,
                .get_text_layout = getTextLayout,
                .get_text_for_area = getTextForArea,
                .render_text_selection = renderTextSelection,
                .deinit = deinit,
            },
        };
    }

    fn open(ptr: *anyopaque, path: []const u8) PdfError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const real_path = std.fs.cwd().realpathAlloc(self.allocator, path) catch return PdfError.FileNotFound;
        defer self.allocator.free(real_path);

        // Create null-terminated string for C API
        const c_path = self.allocator.dupeZ(u8, real_path) catch return PdfError.OutOfMemory;
        defer self.allocator.free(c_path);

        var error_ptr: ?*c.GError = null;
        const uri = c.g_filename_to_uri(c_path.ptr, null, &error_ptr);
        if (uri == null) {
            if (error_ptr) |err| {
                c.g_error_free(err);
            }
            return PdfError.FileNotFound;
        }
        defer c.g_free(uri);

        self.document = c.poppler_document_new_from_file(uri, null, &error_ptr);

        if (self.document == null) {
            if (error_ptr) |err| {
                c.g_error_free(err);
            }
            return PdfError.InvalidPdf;
        }
    }

    fn close(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.document) |doc| {
            c.g_object_unref(doc);
            self.document = null;
        }
    }

    fn getPageCount(ptr: *anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.document) |doc| {
            return @intCast(c.poppler_document_get_n_pages(doc));
        }
        return 0;
    }

    fn getPageInfo(ptr: *anyopaque, page: u32) PdfError!PageInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const doc = self.document orelse return PdfError.InvalidPdf;

        const poppler_page = c.poppler_document_get_page(doc, @intCast(page));
        if (poppler_page == null) {
            return PdfError.PageOutOfRange;
        }
        defer c.g_object_unref(poppler_page);

        var width: f64 = undefined;
        var height: f64 = undefined;
        c.poppler_page_get_size(poppler_page, &width, &height);

        return PageInfo{
            .width = width,
            .height = height,
        };
    }

    fn renderPage(ptr: *anyopaque, page: u32, cairo_ctx: *anyopaque, scale: f64) PdfError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const doc = self.document orelse return PdfError.InvalidPdf;

        const page_count = c.poppler_document_get_n_pages(doc);
        if (page >= page_count) {
            return PdfError.PageOutOfRange;
        }

        const poppler_page = c.poppler_document_get_page(doc, @intCast(page));
        if (poppler_page == null) {
            return PdfError.PageOutOfRange;
        }
        defer c.g_object_unref(poppler_page);

        const ctx: *c.cairo_t = @ptrCast(@alignCast(cairo_ctx));

        c.cairo_scale(ctx, scale, scale);
        c.poppler_page_render(poppler_page, ctx);

        if (c.cairo_status(ctx) != c.CAIRO_STATUS_SUCCESS) {
            return PdfError.RenderError;
        }
    }

    fn extractToc(ptr: *anyopaque, allocator: std.mem.Allocator, toc_entries: *std.ArrayList(backend_mod.TocEntry)) PdfError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const doc = self.document orelse return PdfError.InvalidPdf;

        // Get the document outline (TOC)
        const outline = c.poppler_index_iter_new(doc);
        if (outline == null) {
            // No TOC available in this document
            // TODO: Use some kind of heuristics instead of index
            return;
        }

        // Recursively extract TOC entries
        try extractTocFromOutline(outline, allocator, toc_entries, 0);
    }

    fn extractTocFromOutline(outline: ?*c.PopplerIndexIter, allocator: std.mem.Allocator, toc_entries: *std.ArrayList(backend_mod.TocEntry), level: u32) PdfError!void {
        if (outline == null) return;

        const iter = outline.?;

        // Iterate through all entries at this level
        while (true) {
            const action = c.poppler_index_iter_get_action(iter);
            const title = action.*.goto_dest.title;
            if (title != null) {
                // Get the title string
                const title_len = std.mem.len(title);
                const title_copy = try allocator.alloc(u8, title_len);
                @memcpy(title_copy, title[0..title_len]);

                // Get the destination page
                var page: u32 = 0;
                const dest: *PopplerDest = @ptrCast(@alignCast(&action.*.goto_dest.dest));

                // Poppler uses 1-based pages
                page = @intCast(@max(0, dest.page - 1));

                // Add the TOC entry
                try toc_entries.append(.{
                    .title = title_copy,
                    .page = page,
                    .level = level,
                });
            }

            // Check for child entries
            const child_iter = c.poppler_index_iter_get_child(iter);
            if (child_iter != null) {
                try extractTocFromOutline(child_iter, allocator, toc_entries, level + 1);
                c.poppler_index_iter_free(child_iter);
            }

            // Move to next sibling
            if (c.poppler_index_iter_next(iter) == 0) {
                break; // No more siblings
            }
        }
    }

    fn getTextLayout(ptr: *anyopaque, allocator: std.mem.Allocator, page: u32, layout: *backend_mod.TextLayout) backend_mod.PdfError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const doc = self.document orelse return backend_mod.PdfError.InvalidPdf;

        const poppler_page = c.poppler_document_get_page(doc, @intCast(page));
        if (poppler_page == null) {
            return backend_mod.PdfError.PageOutOfRange;
        }
        defer c.g_object_unref(poppler_page);

        // Get text layout from Poppler
        var rectangles: ?*c.PopplerRectangle = null;
        var n_rectangles: c_uint = 0;
        const success = c.poppler_page_get_text_layout(poppler_page, &rectangles, &n_rectangles);
        
        if (success == 0 or rectangles == null or n_rectangles == 0) {
            layout.rectangles = &[_]backend_mod.TextRect{};
            layout.text = &[_]u8{};
            return;
        }
        defer c.g_free(rectangles);

        // Get page text
        const text_cstr = c.poppler_page_get_text(poppler_page);
        if (text_cstr == null) {
            layout.rectangles = &[_]backend_mod.TextRect{};
            layout.text = &[_]u8{};
            return;
        }
        defer c.g_free(text_cstr);

        // Convert text to Zig string
        const text_len = std.mem.len(text_cstr);
        const text_copy = try allocator.alloc(u8, text_len);
        @memcpy(text_copy, text_cstr[0..text_len]);

        // Convert rectangles to our format
        const zig_rectangles = try allocator.alloc(backend_mod.TextRect, n_rectangles);
        
        for (0..n_rectangles) |i| {
            const poppler_rect = @as([*]c.PopplerRectangle, @ptrCast(rectangles))[i];
            zig_rectangles[i] = backend_mod.TextRect{
                .x1 = poppler_rect.x1,
                .y1 = poppler_rect.y1,
                .x2 = poppler_rect.x2,
                .y2 = poppler_rect.y2,
            };
        }

        layout.rectangles = zig_rectangles;
        layout.text = text_copy;
    }

    fn getTextForArea(ptr: *anyopaque, allocator: std.mem.Allocator, page: u32, area: backend_mod.TextRect) backend_mod.PdfError![]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const doc = self.document orelse return backend_mod.PdfError.InvalidPdf;

        const poppler_page = c.poppler_document_get_page(doc, @intCast(page));
        if (poppler_page == null) {
            return backend_mod.PdfError.PageOutOfRange;
        }
        defer c.g_object_unref(poppler_page);

        // Create Poppler rectangle from our area
        var poppler_area = c.PopplerRectangle{
            .x1 = area.x1,
            .y1 = area.y1,
            .x2 = area.x2,
            .y2 = area.y2,
        };

        // Extract text for the specified area
        const text_cstr = c.poppler_page_get_text_for_area(poppler_page, &poppler_area);
        if (text_cstr == null) {
            return try allocator.alloc(u8, 0);
        }
        defer c.g_free(text_cstr);

        // Copy text to managed memory
        const text_len = std.mem.len(text_cstr);
        const text_copy = try allocator.alloc(u8, text_len);
        @memcpy(text_copy, text_cstr[0..text_len]);
        
        return text_copy;
    }

    fn renderTextSelection(ptr: *anyopaque, page: u32, cairo_ctx: *anyopaque, scale: f64, selection: backend_mod.TextRect, glyph_color: backend_mod.HighlightColor, bg_color: backend_mod.HighlightColor) backend_mod.PdfError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const doc = self.document orelse return backend_mod.PdfError.InvalidPdf;

        const poppler_page = c.poppler_document_get_page(doc, @intCast(page));
        if (poppler_page == null) {
            return backend_mod.PdfError.PageOutOfRange;
        }
        defer c.g_object_unref(poppler_page);

        const ctx: *c.cairo_t = @ptrCast(@alignCast(cairo_ctx));

        // Scale the context
        c.cairo_scale(ctx, scale, scale);

        // Convert our selection rectangle to Poppler format
        var poppler_selection = c.PopplerRectangle{
            .x1 = selection.x1,
            .y1 = selection.y1,
            .x2 = selection.x2,
            .y2 = selection.y2,
        };

        // Convert colors to Poppler format (0-65535 range)
        var poppler_glyph_color = c.PopplerColor{
            .red = @as(u16, @intFromFloat(glyph_color.r * 65535.0)),
            .green = @as(u16, @intFromFloat(glyph_color.g * 65535.0)),
            .blue = @as(u16, @intFromFloat(glyph_color.b * 65535.0)),
        };

        var poppler_bg_color = c.PopplerColor{
            .red = @as(u16, @intFromFloat(bg_color.r * 65535.0)),
            .green = @as(u16, @intFromFloat(bg_color.g * 65535.0)),
            .blue = @as(u16, @intFromFloat(bg_color.b * 65535.0)),
        };

        // Render the selection
        c.poppler_page_render_selection(poppler_page, ctx, &poppler_selection, null, c.POPPLER_SELECTION_GLYPH, &poppler_glyph_color, &poppler_bg_color);

        if (c.cairo_status(ctx) != c.CAIRO_STATUS_SUCCESS) {
            return backend_mod.PdfError.RenderError;
        }
    }

    fn deinit(ptr: *anyopaque) void {
        close(ptr);
    }
};
