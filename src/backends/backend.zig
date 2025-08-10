const std = @import("std");

pub const PdfError = error{
    FileNotFound,
    InvalidPdf,
    PageOutOfRange,
    RenderError,
    OutOfMemory,
};

pub const PageInfo = struct {
    width: f64,
    height: f64,
};

pub const TocEntry = struct {
    title: []u8,
    page: u32,
    level: u32,
    
    pub fn deinit(self: *TocEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
    }
};

pub const Backend = struct {
    const Self = @This();
    
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ptr: *anyopaque, path: []const u8) PdfError!void,
        close: *const fn (ptr: *anyopaque) void,
        get_page_count: *const fn (ptr: *anyopaque) u32,
        get_page_info: *const fn (ptr: *anyopaque, page: u32) PdfError!PageInfo,
        render_page: *const fn (ptr: *anyopaque, page: u32, cairo_ctx: *anyopaque, scale: f64) PdfError!void,
        extract_toc: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, toc_entries: *std.ArrayList(TocEntry)) PdfError!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn open(self: Self, path: []const u8) PdfError!void {
        return self.vtable.open(self.ptr, path);
    }

    pub fn close(self: Self) void {
        self.vtable.close(self.ptr);
    }

    pub fn getPageCount(self: Self) u32 {
        return self.vtable.get_page_count(self.ptr);
    }

    pub fn getPageInfo(self: Self, page: u32) PdfError!PageInfo {
        return self.vtable.get_page_info(self.ptr, page);
    }

    pub fn renderPage(self: Self, page: u32, cairo_ctx: *anyopaque, scale: f64) PdfError!void {
        return self.vtable.render_page(self.ptr, page, cairo_ctx, scale);
    }

    pub fn extractToc(self: Self, allocator: std.mem.Allocator, toc_entries: *std.ArrayList(TocEntry)) PdfError!void {
        return self.vtable.extract_toc(self.ptr, allocator, toc_entries);
    }

    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.ptr);
    }
};