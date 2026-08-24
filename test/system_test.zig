//! M0's acceptance, as a test: a set and its board file load, the 68000 runs
//! from its reset vector, and two runs of the same input log are identical.
//!
//! The set here is built in a temporary directory out of a program the test
//! assembles by hand, so this proves the whole path — board file, ROM set,
//! bus, scheduler — without a single byte anyone else owns.

const std = @import("std");
const board = @import("board");
const romset = @import("romset");
const cps = @import("cps");
const scheduler = @import("scheduler");

const testing = std.testing;

/// A program that reads the controls every pass and folds them into RAM, so
/// the machine's state depends on the whole history of the input log and not
/// just on the last frame of it.
///
///     loop: move.w ($800000).l, d0   ; the player controls
///           move.w d0, ($ff0000).l   ; this frame's word
///           add.w  d0, d1            ; and every frame's, added up
///           move.w d1, ($ff0002).l
///           bra.b  loop
const program_words = [_]u16{
    0x3039, 0x0080, 0x0000,
    0x33c0, 0x00ff, 0x0000,
    0xd240, 0x33c1, 0x00ff,
    0x0002, 0x60ea,
};
const reset_pc = 0x400;
const initial_sp = 0x00ff0000;
const program_bytes = 0x800;

const board_file = std.fmt.comptimePrint(
    \\# a board file for the program this test assembles
    \\version = 1
    \\layer_control   = 0x12
    \\priority        = 0x14 0x16 0x08 0x0a
    \\palette_control = 0x0c
    \\gfx_bank = sprites|scroll1|scroll2|scroll3 0x00000 0x07fff 0
    \\program = 0x000000 0x{x} word test.rom
    \\
, .{program_bytes});

/// Builds the program ROM's region image, then hands back the *file*: a 16-bit
/// ROM holds each word low byte first, which is what `word` mode undoes.
fn romImage() [program_bytes]u8 {
    var region: [program_bytes]u8 = @splat(romset.blank);
    std.mem.writeInt(u32, region[0..4], initial_sp, .big);
    std.mem.writeInt(u32, region[4..8], reset_pc, .big);
    for (program_words, 0..) |word, i| {
        std.mem.writeInt(u16, region[reset_pc + i * 2 ..][0..2], word, .big);
    }

    var file = region;
    var i: usize = 0;
    while (i + 1 < file.len) : (i += 2) {
        file[i] = region[i + 1];
        file[i + 1] = region[i];
    }
    return file;
}

fn writeSet(dir: std.Io.Dir) !void {
    const image = romImage();
    try dir.writeFile(testing.io, .{ .sub_path = "test.rom", .data = &image });
    try dir.writeFile(testing.io, .{ .sub_path = "test.board", .data = board_file });
}

fn loadSet(tmp: *std.testing.TmpDir) !romset.Set {
    var diag = board.Diag{};
    const b = try board.parse(board_file, &diag);
    return romset.load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag) catch |err| {
        std.debug.print("unexpected: {s}\n", .{diag.message()});
        return err;
    };
}

/// One frame of the control panel, packed the way an input log holds it.
fn logWord(pad1: u16, panel: u8) u32 {
    return @as(u32, pad1) | @as(u32, panel) << (2 * cps.button_count);
}

fn run(gpa: std.mem.Allocator, rom: romset.Set, b: board.Board, log: []const u32, frames: u32) !u64 {
    const c = try gpa.create(cps.Cps);
    defer gpa.destroy(c);
    c.* = .{ .board = b, .rom = rom };

    var cpu: scheduler.Cpu = .{};
    scheduler.reset(c, &cpu);
    try testing.expectEqual(@as(u32, reset_pc), cpu.pc);
    try testing.expectEqual(@as(u32, initial_sp), cpu.a[7]);

    for (0..frames) |frame| {
        const word = if (frame < log.len) log[frame] else 0;
        c.inputs = .{
            .pad = .{ @truncate(word), @truncate(word >> cps.button_count) },
            .panel = @truncate(word >> (2 * cps.button_count)),
        };
        scheduler.runFrame(c, &cpu);
    }
    try testing.expect(!cpu.halted);
    return scheduler.hash(c, &cpu);
}

test "a set and its board file load, and the 68000 runs from its reset vector" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSet(tmp.dir);

    var rom = try loadSet(&tmp);
    defer rom.deinit(testing.allocator);

    var diag = board.Diag{};
    const b = try board.parse(board_file, &diag);

    const c = try testing.allocator.create(cps.Cps);
    defer testing.allocator.destroy(c);
    c.* = .{ .board = b, .rom = rom };

    var cpu: scheduler.Cpu = .{};
    scheduler.reset(c, &cpu);
    try testing.expectEqual(@as(u32, reset_pc), cpu.pc);
    try testing.expectEqual(@as(u32, initial_sp), cpu.a[7]);

    // One frame of it, and the program has put the controls where it was told.
    c.inputs.pad[0] = cps.Button.up.mask();
    scheduler.runFrame(c, &cpu);
    try testing.expectEqual(cps.read16(c, cps.in1_lo), cps.read16(c, cps.ram_lo));
}

test "two runs of the same input log are bit-identical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSet(tmp.dir);

    var rom = try loadSet(&tmp);
    defer rom.deinit(testing.allocator);

    var diag = board.Diag{};
    const b = try board.parse(board_file, &diag);

    const frames = 30;
    const log = [_]u32{
        logWord(cps.Button.up.mask(), 0),
        logWord(cps.Button.up.mask() | cps.Button.b1.mask(), 0),
        logWord(0, cps.Panel.coin1.mask()),
        logWord(cps.Button.left.mask() | cps.Button.b6.mask(), cps.Panel.start1.mask()),
    };

    const first = try run(testing.allocator, rom, b, &log, frames);
    const second = try run(testing.allocator, rom, b, &log, frames);
    try testing.expectEqual(first, second);

    // And the log is genuinely driving the machine: a different one lands
    // somewhere else. Without this the test above passes on a machine that
    // ignores its inputs entirely.
    const other = [_]u32{logWord(cps.Button.down.mask(), 0)};
    try testing.expect(try run(testing.allocator, rom, b, &other, frames) != first);
}
