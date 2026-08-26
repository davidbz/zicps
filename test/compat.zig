//! The sweep: every set in a directory, booted headless and looked at.
//!
//! `zig build compat -- roms` boots each set with the board file beside it (or
//! the one that ships), runs it for a fixed number of frames and says what
//! happened: whether the 68000 halted, whether the picture is blank, how long
//! it has been still, and whether anything came out of the mixer.
//!
//! Nothing here is pinned, named or failed. It is triage over a library of 194
//! boards of which seven have ever been booted, and its whole job is to say
//! where to point a window. A set that comes out of it looking wrong is what
//! `video_diff.zig` and the replay harness are for.
//!
//! Two readings need reading carefully. A board in attract mode is silent on
//! purpose — a CPS-1 board's demo sounds are off at the factory settings it
//! runs on here (§5.1), and a QSound board's are off in a battery nobody has
//! set up — so the sweep puts a coin in and presses start, and `silent` after
//! that is a reading worth having. And a set drawing its own RAM test is a
//! still picture that is not a blank one, which is why the stillness is
//! counted in frames rather than answered yes or no.
//!
//! 194 boards is worth `-Doptimize=ReleaseFast`: a debug build runs about six
//! seconds a set, and a fast one about one.

const std = @import("std");
const board = @import("board");
const boards = @import("boards");
const cps = @import("cps");
const scheduler = @import("scheduler");

const usage = "usage: compat <directory of sets> [--frames N]";

/// Twenty seconds: long enough for a board to finish its own memory test, sit
/// through whatever legal notice it opens with, take a coin and start a game,
/// and short enough that 194 of them is one coffee. At 900 the seven sets here
/// were all drawing but `mercs` had not made a sound yet, which is the sort of
/// reading a short run invents.
const default_frames = 1200;

/// A coin goes in a third of the way through the run, and start is pressed from
/// then on, over and over, each press held the few frames a hand would hold it.
///
/// Repeating it is the point. Pressed once, `sf2` and `cawing` were still on
/// their legal notice, took the credit, reached their title screens and sat
/// there — and a title screen is a still picture, which is the reading that
/// would have been believed. What a board does with a credit in it is the half
/// worth hearing, and it is where a set that boots and then hangs shows it.
const coin_hold = 10;
const start_gap = 40;
const start_period = 120;

/// What the sweep saw. Every field is a reading rather than a verdict: the
/// summary at the bottom is the only place anything is called out.
const Result = struct {
    frames: u32 = 0,
    halted_pc: ?u32 = null,
    /// The picture was one flat colour on every frame of the run. Not the last
    /// frame alone: attract modes fade through black, and a set caught
    /// mid-fade is not a set that never drew.
    blank: bool = false,
    /// Frames since the picture last changed, at the end of the run.
    still: u32 = 0,
    peak: u32 = 0,

    /// Whether this one is worth pointing a window at.
    fn flagged(r: Result) bool {
        return r.halted_pc != null or r.blank or r.still == r.frames;
    }
};

/// The panel this frame: nothing, a coin, or start.
fn panelAt(frame: u32, frames: u32) u8 {
    const coin_at = frames / 3;
    if (frame >= coin_at and frame < coin_at + coin_hold) return cps.Panel.coin1.mask();
    const since = std.math.sub(u32, frame, coin_at + start_gap) catch return 0;
    return if (since % start_period < coin_hold) cps.Panel.start1.mask() else 0;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.skip();
    var dir_path: ?[]const u8 = null;
    var frames: u32 = default_frames;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            const count = args.next() orelse fatal("--frames wants a number\n{s}", .{usage});
            frames = std.fmt.parseInt(u32, count, 10) catch
                fatal("--frames wants a number, got `{s}`", .{count});
        } else if (dir_path == null) {
            dir_path = arg;
        } else fatal("{s}", .{usage});
    }
    const path = dir_path orelse fatal("{s}", .{usage});

    const names = try list(arena, io, path);
    if (names.len == 0) fatal("no sets in {s}: a set is a directory or a .zip of chip images", .{path});

    // One machine, reused: two thirds of a megabyte, and nothing about a set
    // survives `startMachine` into the next one.
    const c = try arena.create(cps.Cps);
    c.* = .{ .board = .{}, .rom = .{ .program = &.{}, .gfx = &.{}, .audio = &.{}, .qsound = &.{}, .oki = &.{} } };

    std.debug.print("{d} sets in {s}, {d} frames each\n\n", .{ names.len, path, frames });
    std.debug.print("{s: <16}{s: >7}  {s: <10}{s: >7}  {s}\n", .{ "set", "frames", "picture", "still", "sound" });

    var flagged: usize = 0;
    var refused: usize = 0;
    for (names) |name| {
        const set = try std.fs.path.join(arena, &.{ path, name });
        defer arena.free(set);

        var diag = board.Diag{};
        var machine = boards.loadSet(arena, io, set, null, &diag) catch {
            std.debug.print("{s: <16}{s: >7}  {s}\n", .{ trim(name), "-", diag.message() });
            refused += 1;
            continue;
        };
        defer machine.deinit(arena);

        const r = run(c, &machine, frames);
        report(name, r);
        if (r.flagged()) flagged += 1;
    }

    std.debug.print("\n{d} booted, {d} refused, {d} worth a window\n", .{
        names.len - refused,
        refused,
        flagged,
    });
    // Silence is not counted above: a game that wants a second coin, or a
    // board whose battery has never been set up, has reasons to be quiet that
    // are not this emulator's.
    std.debug.print("blank, halted, or still for the whole run is what `worth a window` counts\n", .{});
}

/// Every set in the directory, in name order: a `.zip` is a set, and so is a
/// directory, because a set unpacked is a directory of chip images and nothing
/// about one says so from the outside.
fn list(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err|
        fatal("cannot read {s} ({t})\n{s}", .{ path, err, usage });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const keep = switch (entry.kind) {
            .directory => true,
            // Everything else beside a set is a sidecar this program wrote:
            // `.board`, `.nv`, `.st1`, `.png`.
            .file => std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".zip"),
            else => false,
        };
        if (keep) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.sort.pdq([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.order(u8, l, r) == .lt;
}

/// Boots one set and watches it. The mixer is drained every frame whether or
/// not anyone is listening: the ring is finite, and a run that let it fill
/// would be a different machine from the one being swept.
fn run(c: *cps.Cps, m: *const boards.Machine, frames: u32) Result {
    c.* = .{ .board = m.b, .rom = m.rom };
    var cpu: scheduler.Cpu = .{};
    scheduler.reset(c, &cpu);

    var r = Result{ .blank = true };
    var last = picture(c);
    var changed: u32 = 0;
    while (r.frames < frames and !cpu.halted) {
        c.inputs = .{ .panel = panelAt(r.frames, frames) };
        scheduler.runFrame(c, &cpu);
        r.frames += 1;
        while (c.mixer.pop()) |f| {
            r.peak = @max(r.peak, @max(@abs(@as(i32, f.l)), @abs(@as(i32, f.r))));
        }
        const now = picture(c);
        if (now != last) changed = r.frames;
        last = now;
        if (r.blank and !flat(c)) r.blank = false;
    }
    if (cpu.halted) r.halted_pc = cpu.pc;
    r.still = r.frames - changed;
    return r;
}

/// What the picture hashes to, which is the cheapest way to ask whether it
/// moved. A hash is enough because nothing here says how it differs.
fn picture(c: *const cps.Cps) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&c.v.fb));
}

/// One colour from corner to corner: a board that never drew, or one that
/// cleared the screen and stopped.
fn flat(c: *const cps.Cps) bool {
    for (c.v.fb) |pixel| {
        if (pixel != c.v.fb[0]) return false;
    }
    return true;
}

fn report(name: []const u8, r: Result) void {
    if (r.halted_pc) |pc| {
        std.debug.print("{s: <16}{d: >7}  the 68000 halted at pc={x:0>6}\n", .{ trim(name), r.frames, pc });
        return;
    }
    var still: [16]u8 = undefined;
    var sound: [24]u8 = undefined;
    std.debug.print("{s: <16}{d: >7}  {s: <10}{s: >7}  {s}\n", .{
        trim(name),
        r.frames,
        if (r.blank) "BLANK" else "drawing",
        std.fmt.bufPrint(&still, "{d}", .{r.still}) catch "?",
        if (r.peak == 0) "silent" else std.fmt.bufPrint(&sound, "peak {d}", .{r.peak}) catch "?",
    });
}

/// A set's name without the `.zip`, because the column is 16 characters wide
/// and four of them being an extension every row shares helps nobody.
fn trim(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    return if (std.ascii.eqlIgnoreCase(ext, ".zip")) name[0 .. name.len - ext.len] else name;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a picture that never changes is still for the whole run" {
    // The three readings the sweep is made of, on a machine that is not one:
    // stillness is frames since the last change, so a run that never changed
    // is still for every frame of it, which is what `flagged` looks for.
    const never = Result{ .frames = 900, .still = 900 };
    const moving = Result{ .frames = 900, .still = 3 };
    try testing.expect(never.flagged());
    try testing.expect(!moving.flagged());
    try testing.expect((Result{ .frames = 900, .still = 3, .blank = true }).flagged());
    try testing.expect((Result{ .frames = 12, .still = 1, .halted_pc = 0x400 }).flagged());
}

test "a coin goes in once, and start is pressed again and again after it" {
    // The panel is a level and not an edge, so a mask left on is a coin slot
    // wedged open and a start button nobody ever lets go of. What this counts
    // is presses, which means every one of them has to end.
    var coins: u32 = 0;
    var starts: u32 = 0;
    var last: u8 = 0;
    for (0..900) |frame| {
        const now = panelAt(@intCast(frame), 900);
        if (now != last) {
            if (now == cps.Panel.coin1.mask()) coins += 1;
            if (now == cps.Panel.start1.mask()) starts += 1;
        }
        last = now;
    }
    // Nothing at all before the coin, then one coin and start ever after.
    try testing.expectEqual(@as(u8, 0), panelAt(299, 900));
    try testing.expectEqual(@as(u32, 1), coins);
    try testing.expectEqual(@as(u32, 1 + (900 - 340 - 1) / start_period), starts);
    try testing.expectEqual(cps.Panel.start1.mask(), panelAt(340, 900));
    try testing.expectEqual(@as(u8, 0), panelAt(340 + coin_hold, 900));
}

test "a blank picture is one colour corner to corner" {
    const c = try testing.allocator.create(cps.Cps);
    defer testing.allocator.destroy(c);
    c.* = .{ .board = .{}, .rom = .{ .program = &.{}, .gfx = &.{}, .audio = &.{}, .qsound = &.{}, .oki = &.{} } };

    try testing.expect(flat(c));
    // Not black: a screen cleared to the background colour is just as blank,
    // and the last pixel is as good a place to break it as any.
    @memset(&c.v.fb, 0xff00_3366);
    try testing.expect(flat(c));
    const hashed = picture(c);
    c.v.fb[c.v.fb.len - 1] = 0;
    try testing.expect(!flat(c));
    try testing.expect(picture(c) != hashed);
}

test "a set's name loses its extension and a directory keeps its own" {
    try testing.expectEqualStrings("dino", trim("dino.zip"));
    try testing.expectEqualStrings("dino", trim("dino.ZIP"));
    try testing.expectEqualStrings("sf2.set", trim("sf2.set"));
}
