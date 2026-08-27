const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z68k = b.dependency("z68k", .{ .target = target, .optimize = optimize });
    const z80 = b.dependency("z80", .{ .target = target, .optimize = optimize });

    // Emulation and frontend-data modules, in dependency order. None of these
    // may import raylib: that is a property of the build graph rather than of
    // anyone's discipline, and `main.zig` and `ui/shell.zig` are the only
    // modules that touch a display. A module can only reach what is wired into
    // it here, so a stray `@import("raylib")` in the emulation core does not
    // compile.
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

    const ym2151 = b.addModule("ym2151", .{
        .root_source_file = b.path("src/ym2151.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "audio", .module = audio }},
    });

    const oki = b.addModule("oki", .{
        .root_source_file = b.path("src/oki.zig"),
        .target = target,
        .optimize = optimize,
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
            .{ .name = "ym2151", .module = ym2151 },
            .{ .name = "oki", .module = oki },
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
            .{ .name = "ym2151", .module = ym2151 },
            .{ .name = "oki", .module = oki },
        },
    });

    const state = b.addModule("state", .{
        .root_source_file = b.path("src/state.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cps", .module = cps },
            .{ .name = "scheduler", .module = scheduler },
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

    // The board files that ship with this build. The list is
    // generated beside them and holds nothing but `@embedFile`s, so a board
    // file that changes rebuilds what carries it; everything that is not a
    // table lives in `src/boards.zig`.
    const board_list = b.createModule(.{
        .root_source_file = b.path("boards/list.zig"),
        .target = target,
        .optimize = optimize,
    });

    const boards = b.addModule("boards", .{
        .root_source_file = b.path("src/boards.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "romset", .module = romset },
            .{ .name = "list", .module = board_list },
        },
    });

    const snow = b.addModule("snow", .{
        .root_source_file = b.path("src/ui/snow.zig"),
        .target = target,
        .optimize = optimize,
    });

    // raylib is a lazy dependency, but zicps always needs it: the call below
    // still runs on every build after a fresh clone, because a build script
    // cannot see which step was asked for. The window is built at the bottom
    // of this file, once the test and check steps it hangs off exist.
    const raylib_dep = b.lazyDependency("raylib", .{
        .target = target,
        .optimize = optimize,
        // Nothing here draws a mesh, and rmodels is the bulk of the build.
        .rmodels = false,
    });

    // A fast compile-only pass over everything, for editors (zls) and CI:
    // catches type errors without linking or running anything.
    const check_step = b.step("check", "Check that everything compiles");

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
            .{ .name = "state", .module = state },
        },
    });

    // The scoreboard: the acceptance ROM's pages, walked and scored, one line
    // each. It is the system tests filtered down to that one test rather than a
    // file of its own — the ROM that has to be built to run it is already there.
    const scoreboard = b.addTest(.{ .root_module = system_tests, .filters = &.{"scoreboard"} });
    const testrom_step = b.step("testrom", "Score every page of the acceptance ROM");
    testrom_step.dependOn(&b.addRunArtifact(scoreboard).step);

    // The differential check: the same register log driven
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

    // The same arrangement for the OPM, against nukeykt's Nuked-OPM.
    const opm_ref = b.step("opm-ref", "Diff the YM2151 core against Nuked-OPM");
    const opm_reference = "testdata/Nuked-OPM";
    if (b.build_root.handle.access(b.graph.io, opm_reference ++ "/opm.c", .{})) |_| {
        const opm_module = b.createModule(.{
            .root_source_file = b.path("test/opm_ref_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // The reference is a gate-level model and shifts negative values
            // throughout, which C calls undefined and the sanitiser traps.
            .sanitize_c = .off,
            .imports = &.{.{ .name = "ym2151", .module = ym2151 }},
        });
        opm_module.addIncludePath(b.path(opm_reference));
        opm_module.addCSourceFile(.{
            .file = b.path(opm_reference ++ "/opm.c"),
            .flags = &.{"-std=gnu99"},
        });
        const opm_test = b.addTest(.{ .root_module = opm_module });
        const run_opm = b.addRunArtifact(opm_test);
        opm_ref.dependOn(&run_opm.step);
        test_step.dependOn(&run_opm.step);
        check_step.dependOn(&opm_test.step);
    } else |_| {
        opm_ref.dependOn(&b.addFail(
            "no reference to diff against: run tools/fetch_opm_reference.sh first",
        ).step);
    }

    const modules = [_]*std.Build.Module{
        board,  romset, video,  cps,        scheduler, input,  config,
        audio,  kabuki, qsound, soundboard, snow,      boards, system_tests,
        ym2151, oki,    state,
    };
    for (modules) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check_step.dependOn(&tests.step);
    }

    // --- the sweep -----------------------------------------------------------
    // `zig build compat -- <directory of sets>`: boot every set that is there
    // and report what happened. Nothing it prints is a gate — it needs ROMs
    // this repo may not have, and it is triage rather than a test — so it is
    // its own step and no part of `test`. Its own arithmetic is unit-tested.
    const compat_module = b.createModule(.{
        .root_source_file = b.path("test/compat.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "boards", .module = boards },
            .{ .name = "cps", .module = cps },
            .{ .name = "scheduler", .module = scheduler },
        },
    });
    const compat = b.addExecutable(.{ .name = "compat", .root_module = compat_module });
    const sweep = b.addRunArtifact(compat);
    sweep.setCwd(b.path("."));
    if (b.args) |args| sweep.addArgs(args);
    b.step("compat", "Boot every set in a directory and report what happened").dependOn(&sweep.step);

    // The video state differential: MAME's graphics RAM and register
    // file, rendered by this renderer. Also run by hand, against a dump that
    // is gitignored, and also gating nothing.
    const video_diff_module = b.createModule(.{
        .root_source_file = b.path("test/video_diff.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "boards", .module = boards },
            .{ .name = "cps", .module = cps },
            .{ .name = "video", .module = video },
        },
    });
    const video_diff = b.addExecutable(.{ .name = "video_diff", .root_module = video_diff_module });
    const diff_run = b.addRunArtifact(video_diff);
    diff_run.setCwd(b.path("."));
    if (b.args) |args| diff_run.addArgs(args);
    b.step("video-diff", "Render a MAME video-state dump with this renderer").dependOn(&diff_run.step);

    for ([_]*std.Build.Module{ compat_module, video_diff_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check_step.dependOn(&tests.step);
    }

    // --- the board library ---------------------------------------------------
    // The boards under `boards/` are transcribed from MAME's CPS-1 tables by a
    // tool run by hand, and its output is committed: `zig build boards -- <mame
    // source dir>`. Nothing below runs during an ordinary build, and the tool
    // is built for whatever the rest is, because regenerating a table on a
    // machine that cannot run the result is not a thing anyone does.
    const boards_tool = b.addExecutable(.{
        .name = "mame_to_board",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mame_to_board.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "board", .module = board },
                .{ .name = "romset", .module = romset },
            },
        }),
    });
    const generate = b.addRunArtifact(boards_tool);
    generate.setCwd(b.path("."));
    if (b.args) |args| generate.addArgs(args);
    b.step("boards", "Rewrite boards/ from MAME's CPS-1 tables").dependOn(&generate.step);
    check_step.dependOn(&boards_tool.step);

    // --- the program ---------------------------------------------------------
    // The window, and the only two modules allowed to reach raylib.
    // Everything above is wired without it and tested without a display.
    const raylib = raylib_dep orelse return;

    // The menu's arithmetic is testable without a window; the drawing is not.
    // This links raylib because `shell.zig` imports its header, and runs
    // nothing that needs a display.
    const shell = b.createModule(.{
        .root_source_file = b.path("src/ui/shell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // raylib.h comes in through @cImport
        .imports = &.{
            .{ .name = "config", .module = config },
            .{ .name = "input", .module = input },
        },
    });
    shell.linkLibrary(raylib.artifact("raylib"));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "board", .module = board },
            .{ .name = "romset", .module = romset },
            .{ .name = "cps", .module = cps },
            .{ .name = "scheduler", .module = scheduler },
            .{ .name = "video", .module = video },
            .{ .name = "audio", .module = audio },
            .{ .name = "input", .module = input },
            .{ .name = "config", .module = config },
            .{ .name = "state", .module = state },
            .{ .name = "snow", .module = snow },
            .{ .name = "boards", .module = boards },
            .{ .name = "shell", .module = shell },
        },
    });
    exe_module.linkLibrary(raylib.artifact("raylib"));

    const exe = b.addExecutable(.{ .name = "zicps", .root_module = exe_module });
    // ponytail: zig folds raylib's system libs (libGL.so, libX11.so, ...) into
    // libraylib.a as archive members (ziglang/zig#20476). LLD warns once per
    // member, and the build runner turns any unexpected linker stderr into a
    // failed step — even though the same libraries are already on the link
    // line as -lGL -lX11 ... and the link is fine. The self-hosted ELF linker
    // skips them silently, but only ELF: the COFF and MachO backends cannot
    // link this yet, so those keep LLD. Drop this once zig stops archiving
    // .so paths.
    const lld = target.result.os.tag != .linux;
    if (!lld) exe.use_lld = false;
    b.installArtifact(exe);
    check_step.dependOn(&exe.step);

    for ([_]*std.Build.Module{ shell, exe_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        if (!lld) tests.use_lld = false;
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check_step.dependOn(&tests.step);
    }

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path(".")); // roms/ is resolved relative to the project
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zicps").dependOn(&run.step);
}
