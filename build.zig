const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z68k = b.dependency("z68k", .{ .target = target, .optimize = optimize });
    const z80 = b.dependency("z80", .{ .target = target, .optimize = optimize });

    // Emulation and frontend-data modules, in dependency order. None of these
    // may import raylib: DESIGN.md §3.2 makes that a property of the build
    // graph rather than of anyone's discipline, and `main.zig` (with
    // `ui/shell.zig` from M5) will be the only module that touches a display.
    // A module can only reach what is wired into it here, so a stray
    // `@import("raylib")` in the emulation core does not compile.
    const board = b.addModule("board", .{
        .root_source_file = b.path("src/board.zig"),
        .target = target,
        .optimize = optimize,
    });

    const romset = b.addModule("romset", .{
        .root_source_file = b.path("src/romset.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "board", .module = board }},
    });

    const video = b.addModule("video", .{
        .root_source_file = b.path("src/video.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "board", .module = board }},
    });

    const cps = b.addModule("cps", .{
        .root_source_file = b.path("src/cps.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "romset", .module = romset },
            .{ .name = "video", .module = video },
        },
    });

    const scheduler = b.addModule("scheduler", .{
        .root_source_file = b.path("src/scheduler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "m68k", .module = z68k.module("m68k") },
            .{ .name = "cps", .module = cps },
            .{ .name = "video", .module = video },
        },
    });

    const input = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cps", .module = cps }},
    });

    const config = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "input", .module = input }},
    });

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

    // The sound board's Z80 arrives with M3. It is wired now so that the
    // dependency is real rather than a line in a manifest nothing reads.
    _ = z80;

    // --- the program ---------------------------------------------------------
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "romset", .module = romset },
            .{ .name = "cps", .module = cps },
            .{ .name = "scheduler", .module = scheduler },
            .{ .name = "video", .module = video },
            .{ .name = "input", .module = input },
            .{ .name = "config", .module = config },
        },
    });
    const exe = b.addExecutable(.{ .name = "zicps", .root_module = exe_module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zicps").dependOn(&run.step);

    // A fast compile-only pass over everything, for editors (zls) and CI:
    // catches type errors without linking or running anything.
    const check_step = b.step("check", "Check that everything compiles");
    check_step.dependOn(&exe.step);

    // --- tests ---------------------------------------------------------------
    const test_step = b.step("test", "Run unit and headless regression tests");

    const system_tests = b.createModule(.{
        .root_source_file = b.path("test/system_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "romset", .module = romset },
            .{ .name = "cps", .module = cps },
            .{ .name = "scheduler", .module = scheduler },
        },
    });

    const modules = [_]*std.Build.Module{
        board, romset, video, cps, scheduler, input, config, audio, snow, exe_module, system_tests,
    };
    for (modules) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check_step.dependOn(&tests.step);
    }
}
