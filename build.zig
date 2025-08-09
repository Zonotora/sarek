const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sarek",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // System dependencies
    exe.linkSystemLibrary("poppler-glib");
    exe.linkSystemLibrary("cairo");
    exe.linkSystemLibrary("gtk+-3.0");
    exe.linkSystemLibrary("glib-2.0");
    exe.linkSystemLibrary("gobject-2.0");
    exe.linkLibC();

    // Add include paths for system libraries
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/poppler/glib" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/gtk-3.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}