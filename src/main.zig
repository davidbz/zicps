//! The program. Until M5 it is the headless runner and nothing else: render N
//! frames with no window, hash the machine, exit. DESIGN.md §6.1 calls this
//! the backbone of testing rather than a debug feature, which is why it is the
//! first thing that exists and has to keep working forever.
//!
//! This is also the only file allowed to reach raylib when the window arrives,
//! and the build graph is what enforces that rather than anyone remembering.

const std = @import("std");
const builtin = @import("builtin");
const board = @import("board");
const romset = @import("romset");
const cps = @import("cps");
const scheduler = @import("scheduler");
const video = @import("video");
const audio = @import("audio");
const input = @import("input");
const config = @import("config");

/// A board file is text a person typed; a replay log is one word per frame.
const max_board_bytes = 64 << 10;
const max_replay_bytes = 16 << 20;

/// One frame of the control panel, little-endian: both players' buttons and the
/// panel's six inputs. Wider than zigesis's word because this machine has two
/// six-button players and a coin door.
const log_frame_bytes = 4;
const log_pad2_shift = cps.button_count;
const log_panel_shift = 2 * cps.button_count;

fn pack(in: cps.Inputs) u32 {
    return @as(u32, in.pad[0]) |
        @as(u32, in.pad[1]) << log_pad2_shift |
        @as(u32, in.panel) << log_panel_shift;
}

fn unpack(word: u32) cps.Inputs {
    const pad_mask = (@as(u32, 1) << cps.button_count) - 1;
    return .{
        .pad = .{
            @truncate(word & pad_mask),
            @truncate((word >> log_pad2_shift) & pad_mask),
        },
        .panel = @truncate(word >> log_panel_shift),
    };
}

/// A recorded input log. Past the end reads as nothing held, so a short log
/// runs a long test without special-casing.
const Replay = struct {
    log: []const u8,

    fn at(r: Replay, frame: u32) cps.Inputs {
        const offset = @as(usize, frame) * log_frame_bytes;
        if (offset + log_frame_bytes > r.log.len) return .{};
        return unpack(std.mem.readInt(u32, r.log[offset..][0..log_frame_bytes], .little));
    }
};

/// What a user error exits with. The message has already been printed and says
/// more than a Zig stack trace would.
fn fail() noreturn {
    std.process.exit(1);
}

/// The command line, once. Every refusal here has already said what was wrong,
/// so nothing in this struct needs checking again.
const Options = struct {
    set: []const u8,
    board: ?[]const u8 = null,
    replay: ?[]const u8 = null,
    frames: ?u32 = null,
    every_frame: bool = false,
};

/// The value an option takes, or a message and no exit code worth reading a
/// stack trace for.
fn value(args: *std.process.Args.Iterator, flag: []const u8) []const u8 {
    return args.next() orelse {
        std.debug.print("{s} wants a value after it\n", .{flag});
        fail();
    };
}

/// `--help` prints and exits rather than returning, so the caller has an
/// `Options` or nothing.
fn parseArgs(args: *std.process.Args.Iterator) Options {
    // Empty until the set is given, which an empty argument could not name
    // anyway.
    var o = Options{ .set = "" };

    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--hash")) {
            o.every_frame = true;
        } else if (std.mem.eql(u8, arg, "--board")) {
            o.board = value(args, arg);
        } else if (std.mem.eql(u8, arg, "--replay")) {
            o.replay = value(args, arg);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const count = value(args, arg);
            o.frames = std.fmt.parseInt(u32, count, 10) catch {
                std.debug.print("--frames wants a number of frames, got `{s}`\n", .{count});
                fail();
            };
        } else if (o.set.len == 0) {
            o.set = arg;
        } else {
            std.debug.print("ignoring extra argument {s}\n", .{arg});
        }
    }

    if (o.set.len == 0) {
        usage();
        fail();
    }
    return o;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    const o = parseArgs(&args);
    const set = o.set;

    // The board file lives beside the set under the set's own name, whether the
    // set is a directory or a zip.
    var default_board: [std.fs.max_path_bytes]u8 = undefined;
    const board_file = o.board orelse try beside(&default_board, set, ".board");

    var diag = board.Diag{};
    const cwd = std.Io.Dir.cwd();

    const text = cwd.readFileAlloc(io, board_file, gpa, .limited(max_board_bytes)) catch |err| {
        std.debug.print("no board file at {s} ({t}).\n" ++
            "A CPS-1.5 board keeps its configuration in battery-backed RAM, so zicps needs\n" ++
            "one describing this board before it can run the set. See DESIGN.md §8.1.\n", .{ board_file, err });
        fail();
    };
    defer gpa.free(text);

    const b = board.parse(text, &diag) catch {
        std.debug.print("{s}: {s}\n", .{ board_file, diag.message() });
        fail();
    };

    var rom = romset.load(gpa, io, cwd, set, &b, &diag) catch {
        std.debug.print("{s}: {s}\n", .{ set, diag.message() });
        fail();
    };
    defer rom.deinit(gpa);

    // Two thirds of a megabyte of RAM, registers and framebuffer: too much for
    // the stack, and allocated exactly once.
    const c = try gpa.create(cps.Cps);
    defer gpa.destroy(c);
    c.* = .{ .board = b, .rom = rom };

    var cpu: scheduler.Cpu = .{};
    scheduler.reset(c, &cpu);

    const n = o.frames orelse {
        std.debug.print("the window arrives at M5; for now, run with --frames N\n", .{});
        fail();
    };
    try headless(io, gpa, c, &cpu, n, o.replay, o.every_frame);
}

fn headless(
    io: std.Io,
    gpa: std.mem.Allocator,
    c: *cps.Cps,
    cpu: *scheduler.Cpu,
    n: u32,
    replay_path: ?[]const u8,
    every_frame: bool,
) !void {
    const replay: ?Replay = if (replay_path) |p| .{
        .log = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)) catch |err| {
            std.debug.print("cannot read replay {s}: {t}\n", .{ p, err });
            fail();
        },
    } else null;
    defer if (replay) |r| gpa.free(r.log);

    var sound = Sound{};
    var frame: u32 = 0;
    while (frame < n and !cpu.halted) : (frame += 1) {
        if (replay) |r| c.inputs = r.at(frame);
        scheduler.runFrame(c, cpu);
        sound.drain(&c.mixer);
        if (every_frame) report(c, cpu, &sound, frame + 1);
    }
    if (!every_frame) report(c, cpu, &sound, frame);

    if (cpu.halted) {
        std.debug.print("the 68000 halted at pc={x:0>6} sr={x:0>4} after {d} frames\n", .{ cpu.pc, @as(u16, @bitCast(cpu.sr)), frame });
        fail();
    }
}

/// The sound that came out, hashed as it goes past. With no window there is no
/// device to pace against, so the sample count is what says the machine ran at
/// the right speed: a frame is worth 48000/59.6374 of them and nothing else.
///
/// Draining is not optional even when nobody is listening. The ring is finite,
/// and a run that never emptied it would quietly start dropping frames a fifth
/// of a second in, which is a different machine from the one being tested.
const Sound = struct {
    h: std.hash.Wyhash = .init(0),
    frames: u64 = 0,

    fn drain(s: *Sound, m: *audio.Mixer) void {
        while (m.pop()) |f| : (s.frames += 1) s.h.update(std.mem.asBytes(&f));
    }
};

fn report(c: *const cps.Cps, cpu: *const scheduler.Cpu, sound: *const Sound, frame: u32) void {
    // A copy, because finishing the hash consumes it and the run goes on.
    var h = sound.h;
    std.debug.print("frame {d} hash={x:0>16} audio={x:0>16} samples={d}\n", .{
        frame,
        scheduler.hash(c, cpu),
        h.final(),
        sound.frames,
    });
}

/// `sets/dino.zip`, `sets/dino` and the `sets/dino/` a shell completes a
/// directory to all look beside themselves for `sets/dino.board`.
fn beside(buf: []u8, path: []const u8, suffix: []const u8) ![]const u8 {
    // What basename splits on, which on Windows is both slashes and not just
    // `sep_str`. A backslash is a legal character in a POSIX file name, so the
    // set only widens where it really is a separator.
    const seps = if (builtin.os.tag == .windows)
        std.fs.path.sep_str_windows ++ std.fs.path.sep_str_posix
    else
        std.fs.path.sep_str_posix;
    const trimmed = std.mem.trimEnd(u8, path, seps);
    const name = std.fs.path.basename(trimmed);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        return std.fmt.bufPrint(buf, "{s}{s}", .{ trimmed, suffix });
    return std.fmt.bufPrint(buf, "{s}{s}", .{ trimmed[0 .. trimmed.len - (name.len - dot)], suffix });
}

fn usage() void {
    std.debug.print(
        \\usage: zicps <rom-set> [options]
        \\
        \\  <rom-set>          a directory of chip images, or a zip of the same
        \\  --board <path>     the board file (default: the set's path with .board)
        \\  --frames N         run N frames with no window and print a state hash
        \\  --replay <path>    drive the controls from a recorded input log
        \\  --hash             print a hash every frame, not only the last
        \\
    , .{});
}

const testing = std.testing;

test "an input log round-trips every bit the machine can be handed" {
    const in = cps.Inputs{
        .pad = .{ cps.Button.up.mask() | cps.Button.b6.mask(), cps.Button.left.mask() },
        .panel = cps.Panel.coin1.mask() | cps.Panel.test_switch.mask(),
    };
    try testing.expectEqual(in, unpack(pack(in)));

    // A log that runs out reads as nothing held, so a short log runs a long
    // test without a special case.
    var word: [log_frame_bytes]u8 = undefined;
    std.mem.writeInt(u32, &word, pack(in), .little);
    const r = Replay{ .log = &word };
    try testing.expectEqual(in, r.at(0));
    try testing.expectEqual(cps.Inputs{}, r.at(1));
}

test "the board file is looked for beside the set, under the set's own name" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("sets/dino.board", try beside(&buf, "sets/dino.zip", ".board"));
    try testing.expectEqualStrings("sets/dino.board", try beside(&buf, "sets/dino", ".board"));
    // A dot in a directory on the way there is not the set's extension.
    try testing.expectEqualStrings("my.sets/dino.board", try beside(&buf, "my.sets/dino", ".board"));
}

test "a set named with a trailing slash still finds its board file" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("sets/dino.board", try beside(&buf, "sets/dino/", ".board"));
}
