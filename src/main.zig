const std = @import("std");
const viewer = @import("ui/viewer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <pdf-file>\n", .{args[0]});
        return;
    }

    const pdf_path = args[1];

    var pdf_viewer = viewer.Viewer.init(allocator, pdf_path) catch |err| {
        std.debug.print("Error initializing viewer: {}\n", .{err});
        return;
    };
    defer pdf_viewer.deinit();

    try pdf_viewer.run();
}
