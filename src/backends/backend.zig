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

pub const TextRect = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
};

pub const TextSelection = struct {
    page: u32,
    start_rect: TextRect,
    end_rect: TextRect,
    text: []u8,
    
    pub fn deinit(self: *TextSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const HighlightColor = struct {
    r: f64,
    g: f64, 
    b: f64,
    a: f64,
};

pub const Highlight = struct {
    id: u32,
    page: u32,
    selection_rect: TextRect,
    color: HighlightColor,
    text: []u8,
    
    pub fn deinit(self: *Highlight, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const TextLayout = struct {
    rectangles: []TextRect,
    text: []u8,
    
    pub fn deinit(self: *TextLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.rectangles);
        allocator.free(self.text);
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
        get_text_layout: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, page: u32, layout: *TextLayout) PdfError!void,
        get_text_for_area: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, page: u32, area: TextRect) PdfError![]u8,
        get_text_for_page: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, page: u32) PdfError![]u8,
        get_character_rect: *const fn (ptr: *anyopaque, page: u32, char_index: u32) PdfError!TextRect,
        render_text_selection: *const fn (ptr: *anyopaque, page: u32, cairo_ctx: *anyopaque, scale: f64, selection: TextRect, glyph_color: HighlightColor, bg_color: HighlightColor) PdfError!void,
        create_highlight_annotation: *const fn (ptr: *anyopaque, page: u32, selection: TextRect, color: HighlightColor, text: []const u8) PdfError!void,
        save_document: *const fn (ptr: *anyopaque, path: []const u8) PdfError!void,
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

    pub fn getTextLayout(self: Self, allocator: std.mem.Allocator, page: u32, layout: *TextLayout) PdfError!void {
        return self.vtable.get_text_layout(self.ptr, allocator, page, layout);
    }

    pub fn getTextForArea(self: Self, allocator: std.mem.Allocator, page: u32, area: TextRect) PdfError![]u8 {
        return self.vtable.get_text_for_area(self.ptr, allocator, page, area);
    }

    pub fn getTextForPage(self: Self, allocator: std.mem.Allocator, page: u32) PdfError![]u8 {
        return self.vtable.get_text_for_page(self.ptr, allocator, page);
    }

    pub fn getCharacterRect(self: Self, page: u32, char_index: u32) PdfError!TextRect {
        return self.vtable.get_character_rect(self.ptr, page, char_index);
    }

    pub fn renderTextSelection(self: Self, page: u32, cairo_ctx: *anyopaque, scale: f64, selection: TextRect, glyph_color: HighlightColor, bg_color: HighlightColor) PdfError!void {
        return self.vtable.render_text_selection(self.ptr, page, cairo_ctx, scale, selection, glyph_color, bg_color);
    }

    pub fn createHighlightAnnotation(self: Self, page: u32, selection: TextRect, color: HighlightColor, text: []const u8) PdfError!void {
        return self.vtable.create_highlight_annotation(self.ptr, page, selection, color, text);
    }

    pub fn saveDocument(self: Self, path: []const u8) PdfError!void {
        return self.vtable.save_document(self.ptr, path);
    }

    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.ptr);
    }
};