const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Emulation and frontend-data modules, in dependency order. None of these
    // may import raylib: DESIGN.md §3.2 makes that a property of the build
    // graph rather than of anyone's discipline, and `main.zig` will be the
    // only module that touches a display.
    const audio = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    const snow = b.addModule("snow", .{
        .root_source_file = b.path("src/ui/snow.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A fast compile-only pass over everything, for editors (zls) and CI:
    // catches type errors without linking or running anything.
    const check_step = b.step("check", "Check that everything compiles");

    // --- tests ---------------------------------------------------------------
    const test_step = b.step("test", "Run unit and headless regression tests");

    const audio_tests = b.addTest(.{ .root_module = audio });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
    check_step.dependOn(&audio_tests.step);

    const snow_tests = b.addTest(.{ .root_module = snow });
    test_step.dependOn(&b.addRunArtifact(snow_tests).step);
    check_step.dependOn(&snow_tests.step);
}
