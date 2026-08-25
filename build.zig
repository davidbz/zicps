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

    const audio = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kabuki = b.addModule("kabuki", .{
        .root_source_file = b.path("src/kabuki.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "board", .module = board }},
    });

    const qsound = b.addModule("qsound", .{
        .root_source_file = b.path("src/qsound.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "audio", .module = audio }},
    });

    // The sound board: its own Z80, its own view of its own ROM, its own chip.
    // The 68000 side reaches it through shared RAM and nothing else, which is
    // what the hardware does too.
    const soundboard = b.addModule("soundboard", .{
        .root_source_file = b.path("src/soundboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "kabuki", .module = kabuki },
            .{ .name = "qsound", .module = qsound },
            .{ .name = "z80", .module = z80.module("z80") },
        },
    });

    const cps = b.addModule("cps", .{
        .root_source_file = b.path("src/cps.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "romset", .module = romset },
            .{ .name = "video", .module = video },
            .{ .name = "audio", .module = audio },
            .{ .name = "soundboard", .module = soundboard },
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
            .{ .name = "audio", .module = audio },
            .{ .name = "soundboard", .module = soundboard },
            .{ .name = "qsound", .module = qsound },
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

    const snow = b.addModule("snow", .{
        .root_source_file = b.path("src/ui/snow.zig"),
        .target = target,
        .optimize = optimize,
    });

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
            .{ .name = "audio", .module = audio },
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
            .{ .name = "video", .module = video },
            .{ .name = "scheduler", .module = scheduler },
            .{ .name = "kabuki", .module = kabuki },
            .{ .name = "soundboard", .module = soundboard },
            .{ .name = "qsound", .module = qsound },
            .{ .name = "audio", .module = audio },
        },
    });

    // The scoreboard of DESIGN.md §9: the acceptance ROM's pages, walked and
    // scored, one line each. It is the system tests filtered down to that one
    // test rather than a file of its own — the ROM that has to be built to run
    // it is already there.
    const scoreboard = b.addTest(.{ .root_module = system_tests, .filters = &.{"scoreboard"} });
    const testrom_step = b.step("testrom", "Score every page of the acceptance ROM");
    testrom_step.dependOn(&b.addRunArtifact(scoreboard).step);

    // The differential check of DESIGN.md §9 M4: the same register log driven
    // into this core and into ctr's qsound-hle, diffed sample by sample. The
    // reference is fetched into gitignored testdata/, so it is wired up only
    // when it is actually there and a fresh checkout stays green without it.
    const qsound_ref = b.step("qsound-ref", "Diff the QSound core against qsound-hle");
    const reference = "testdata/qsound-hle";
    if (b.build_root.handle.access(b.graph.io, reference ++ "/qsound.c", .{})) |_| {
        const ref_module = b.createModule(.{
            .root_source_file = b.path("test/qsound_ref_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // The reference shifts negative values on purpose (the DSP wraps,
            // and so does its model); C calls that undefined and the default
            // sanitiser traps it. Diffing it means running it as written.
            .sanitize_c = .off,
            .imports = &.{.{ .name = "qsound", .module = qsound }},
        });
        ref_module.addIncludePath(b.path(reference));
        // The reference is compiled exactly as fetched, checksum and all, so
        // the flags bend to it rather than the other way round: it is 2018 C
        // with two missing returns and an implicit `abs`, none of which reach
        // the code being diffed.
        ref_module.addCSourceFile(.{
            .file = b.path(reference ++ "/qsound.c"),
            .flags = &.{ "-std=gnu99", "-Wno-return-type", "-Wno-implicit-function-declaration" },
        });
        const ref_test = b.addTest(.{ .root_module = ref_module });
        const run_ref = b.addRunArtifact(ref_test);
        qsound_ref.dependOn(&run_ref.step);
        test_step.dependOn(&run_ref.step);
        check_step.dependOn(&ref_test.step);
    } else |_| {
        qsound_ref.dependOn(&b.addFail(
            "no reference to diff against: run tools/fetch_qsound_reference.sh first",
        ).step);
    }

    const modules = [_]*std.Build.Module{
        board, romset, video,  cps,        scheduler, input,      config,
        audio, kabuki, qsound, soundboard, snow,      exe_module, system_tests,
    };
    for (modules) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check_step.dependOn(&tests.step);
    }
}
