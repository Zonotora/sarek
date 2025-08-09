const std = @import("std");
const backend = @import("backend.zig");
const Backend = backend.Backend;
const PdfError = backend.PdfError;
const PageInfo = backend.PageInfo;

const c = @cImport({
    @cInclude("poppler.h");
    @cInclude("cairo.h");
});

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

    fn deinit(ptr: *anyopaque) void {
        close(ptr);
    }
};
