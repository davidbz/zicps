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
const video = @import("video");
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
    swapWords(&file);
    return file;
}

/// A 16-bit ROM holds each word low byte first, which is what `word` mode undoes.
fn swapWords(file: []u8) void {
    var i: usize = 0;
    while (i + 1 < file.len) : (i += 2) std.mem.swap(u8, &file[i], &file[i + 1]);
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

// -------------------------------------------------- M1: the drawing test ROM

/// The M1 acceptance ROM (DESIGN.md §10). It fills graphics RAM with a palette
/// and three name tables, points the CPS-A registers at them and spins while
/// the video chip draws. Every write is one entry of a table the program walks,
/// so the program is nine instructions long whatever the table holds.
///
///     0x400:  lea     ($000600).l, a0
///     next:   move.l  (a0)+, d0        ; where to write, zero for the end
///             beq.s   done
///             movea.l d0, a1
///             move.w  (a0)+, (a1)
///             bra.s   next
///     done:   bra.s   done
const draw_table = 0x600;
const draw_bytes = 0x1000;
const draw_words = [_]u16{
    0x41f9, draw_table >> 16, draw_table & 0xffff,
    0x2018, 0x6706,           0x2240,
    0x3298, 0x60f6,           0x60fe,
};

/// The graphics ROM the set carries: 0x2000 packed bytes, four bits a pixel.
const gfx_bytes = 0x2000;
/// One bank of 8x8 tiles' worth of it, which is what a gfx_bank range counts in.
const gfx_tiles = gfx_bytes * romset.pixels_per_byte / 128;

const draw_board_file = std.fmt.comptimePrint(
    \\# the board the M1 acceptance ROM runs on: one bank, every layer in it
    \\version = 1
    \\layer_control   = 0x12
    \\priority        = 0x14 0x16 0x08 0x0a
    \\palette_control = 0x{x}
    \\bank_sizes = 0x{x} 0 0 0
    \\gfx_bank = sprites|scroll1|scroll2|scroll3 0x00000 0x{x} 0
    \\program = 0x000000 0x{x} word draw.rom
    \\gfx     = 0x000000 0x{x} byte tiles.bin
    \\
, .{ palette_control, gfx_tiles, gfx_tiles - 1, draw_bytes, gfx_bytes });

const palette_control = 0x0c;

/// Where in graphics RAM the ROM puts things, and what it points the layers at.
const palette_src = 0x14000;
const name_tables = [3]u32{ 0x00000, 0x04000, 0x08000 };
const base_regs = [3]u8{ video.scroll1_base, video.scroll2_base, video.scroll3_base };
const scroll_regs = [3][2]u8{
    .{ video.scroll1_x, video.scroll1_y },
    .{ video.scroll2_x, video.scroll2_y },
    .{ video.scroll3_x, video.scroll3_y },
};
/// Deliberately odd, so nothing lands on a tile boundary by luck.
const scrolls = [3][2]u16{ .{ 5, 3 }, .{ 9, 7 }, .{ 17, 13 } };

/// Worked out here from the hardware rather than borrowed from the renderer,
/// so the two have to agree: consecutive entries run *down* a strip of the
/// name table before stepping across it.
const tile_sizes = [3]u32{ 8, 16, 32 };
const strip_bits = [3]u5{ 5, 4, 3 };

fn nameOffset(bits: u5, row: u32, col: u32) u32 {
    const strip = @as(u32, 1) << bits;
    return (row & (strip - 1)) | ((col & 63) << bits) | ((row & 63 & ~(strip - 1)) << 6);
}

/// Full brightness, the page in the red nibble and the pen in the other two, so
/// no two pages share a colour and a pixel says which layer drew it.
fn paletteEntry(page: u32, pen: u32) u16 {
    return 0xf000 | @as(u16, @intCast(page)) << 8 | @as(u16, @intCast(pen)) << 4 | @as(u16, @intCast(pen));
}

const background_color = 0xf00f;

/// How many tiles of each layer the ROM pokes, each way.
const block = 4;
const max_pokes = 256;

const Script = struct {
    pokes: [max_pokes][2]u32 = undefined,
    n: usize = 0,

    fn add(s: *Script, addr: u32, value: u16) void {
        s.pokes[s.n] = .{ addr, value };
        s.n += 1;
    }
    fn gfxram(s: *Script, at: u32, value: u16) void {
        s.add(cps.gfxram_lo + at, value);
    }
    fn rega(s: *Script, offset: u8, value: u16) void {
        s.add(cps.cps_a_lo + @as(u32, offset), value);
    }
};

fn drawScript() Script {
    var s = Script{};

    // The palette source: colour 0 of the page each tilemap draws through, and
    // the entry the picture is cleared to.
    for (1..4) |page| {
        for (0..video.palette_colors) |pen| {
            s.gfxram(palette_src + @as(u32, @intCast(page)) * video.palette_page_bytes + @as(u32, @intCast(pen)) * 2, paletteEntry(@intCast(page), @intCast(pen)));
        }
    }
    s.gfxram(palette_src + video.background_entry * 2, background_color);

    // A block of tiles in each name table, at whatever part of the map that
    // layer's scroll brings to the top left of the picture.
    for (0..3) |layer| {
        const size = tile_sizes[layer];
        const first_col = (video.first_visible_dot + scrolls[layer][0]) / size;
        const first_row = (video.first_visible_line + scrolls[layer][1]) / size;
        for (0..block) |dr| {
            for (0..block) |dc| {
                const i: u32 = @intCast(dr * block + dc);
                const at = name_tables[layer] + nameOffset(strip_bits[layer], first_row + @as(u32, @intCast(dr)), first_col + @as(u32, @intCast(dc))) * 4;
                // Codes above 15 are past the smallest layer's reach, and every
                // pair of attribute bits is one of the two flips.
                s.gfxram(at, @intCast(1 + i % 15));
                s.gfxram(at + 2, @intCast(i % 4 * 0x20));
            }
        }
    }

    for (0..3) |layer| {
        s.rega(base_regs[layer], @intCast((cps.gfxram_lo + name_tables[layer]) / 256));
        s.rega(scroll_regs[layer][0], scrolls[layer][0]);
        s.rega(scroll_regs[layer][1], scrolls[layer][1]);
    }

    // Every page enabled, then the palette base — writing it is what sets the
    // copy out of graphics RAM going, so it goes last.
    s.add(cps.cps_b_lo + palette_control, (1 << video.palette_pages) - 1);
    s.rega(video.palette_base, (cps.gfxram_lo + palette_src) / 256);
    return s;
}

fn drawImage() [draw_bytes]u8 {
    var region: [draw_bytes]u8 = @splat(romset.blank);
    std.mem.writeInt(u32, region[0..4], initial_sp, .big);
    std.mem.writeInt(u32, region[4..8], reset_pc, .big);
    for (draw_words, 0..) |word, i| {
        std.mem.writeInt(u16, region[reset_pc + i * 2 ..][0..2], word, .big);
    }

    const s = drawScript();
    var at: usize = draw_table;
    for (s.pokes[0..s.n]) |poke| {
        std.mem.writeInt(u32, region[at..][0..4], poke[0], .big);
        std.mem.writeInt(u16, region[at + 4 ..][0..2], @intCast(poke[1]), .big);
        at += 6;
    }
    std.mem.writeInt(u32, region[at..][0..4], 0, .big);

    var file = region;
    swapWords(&file);
    return file;
}

/// The inverse of `romset.decodeRow`: four planes a byte each, pixel 0 in the
/// high bit of every one of them.
fn encodeRow(pens: *const [romset.pixels_per_row]u8, dst: *[romset.bytes_per_row]u8) void {
    dst.* = @splat(0);
    for (0..8) |x| {
        const bit: u3 = @intCast(7 - x);
        for (0..4) |plane| {
            const shift: u3 = @intCast(plane);
            dst[plane] |= (pens[x] >> shift & 1) << bit;
            dst[4 + plane] |= (pens[8 + x] >> shift & 1) << bit;
        }
    }
}

/// Graphics whose every pen can be worked out from where it is, packed the way
/// the board's own ROMs are.
fn tilesImage() [gfx_bytes]u8 {
    var file: [gfx_bytes]u8 = @splat(0);
    var pens: [romset.pixels_per_row]u8 = undefined;
    var at: usize = 0;
    while (at < gfx_bytes) : (at += romset.bytes_per_row) {
        const row = at / romset.bytes_per_row;
        for (&pens, 0..) |*pen, x| pen.* = @intCast((row + x) % video.palette_colors);
        encodeRow(&pens, file[at..][0..romset.bytes_per_row]);
    }
    return file;
}

fn writeDrawSet(dir: std.Io.Dir) !void {
    const program = drawImage();
    const tiles = tilesImage();
    try dir.writeFile(testing.io, .{ .sub_path = "draw.rom", .data = &program });
    try dir.writeFile(testing.io, .{ .sub_path = "tiles.bin", .data = &tiles });
    try dir.writeFile(testing.io, .{ .sub_path = "draw.board", .data = draw_board_file });
}

/// True if any pixel of the picture came out of the given palette page. The
/// three tilemaps draw through three pages of their own, so this is what says
/// a layer put something on screen rather than the one above it doing it all.
fn drewFrom(c: *const cps.Cps, page: u32) bool {
    for (c.v.fb) |pixel| {
        for (0..video.palette_colors) |pen| {
            if (pixel == c.v.colors[page * video.palette_page_entries + pen]) return true;
        }
    }
    return false;
}

fn lineHash(c: *const cps.Cps, y: u32) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(c.v.fb[y * video.width ..][0..video.width]));
}

test "a packed graphics row survives the trip out and back" {
    const pens = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 15, 14, 13, 12, 11, 10, 9, 8 };
    var packed_row: [romset.bytes_per_row]u8 = undefined;
    var back: [romset.pixels_per_row]u8 = undefined;
    encodeRow(&pens, &packed_row);
    romset.decodeRow(&packed_row, &back);
    try testing.expectEqualSlices(u8, &pens, &back);
}

test "the test ROM draws its three tilemaps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDrawSet(tmp.dir);

    var diag = board.Diag{};
    const b = try board.parse(draw_board_file, &diag);
    var rom = romset.load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag) catch |err| {
        std.debug.print("unexpected: {s}\n", .{diag.message()});
        return err;
    };
    defer rom.deinit(testing.allocator);

    const c = try testing.allocator.create(cps.Cps);
    defer testing.allocator.destroy(c);
    c.* = .{ .board = b, .rom = rom };

    var cpu: scheduler.Cpu = .{};
    scheduler.reset(c, &cpu);
    scheduler.runFrame(c, &cpu);
    scheduler.runFrame(c, &cpu);
    try testing.expect(!cpu.halted);

    // The palette came out of graphics RAM, page by page.
    try testing.expectEqual(paletteEntry(1, 0), c.v.palette[video.palette_page_entries]);
    try testing.expectEqual(@as(u16, background_color), c.v.palette[video.background_entry]);

    // All three layers drew, and none of them covered the picture entirely.
    for (1..4) |page| try testing.expect(drewFrom(c, @intCast(page)));
    try testing.expect(!drewFrom(c, 0));

    // And it draws the same picture every time. A line hash tells you *where*
    // a change went in, which one number for the whole frame does not.
    try testing.expectEqual(@as(u64, 0x2b5440f92df27212), lineHash(c, 0));
    try testing.expectEqual(@as(u64, 0xb4d0a8cc769b7347), lineHash(c, video.height / 4));
    try testing.expectEqual(@as(u64, 0x3609507e1ea25e85), lineHash(c, video.height / 2));
    try testing.expectEqual(@as(u64, 0xd0f8365cf1db83c7), lineHash(c, video.height - 1));
    try testing.expectEqual(@as(u64, 0x51198d5210da3aac), scheduler.hash(c, &cpu));
}
