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
    \\layer_enable    = 0x01 0x02 0x04 0x08 0x10
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

// ------------------------------------------------ M2: the acceptance test ROM

/// The acceptance ROM (DESIGN.md §10). It fills graphics RAM with a palette,
/// three name tables, an object list and a row-scroll table, points the CPS
/// registers at them and spins while the video chip draws.
///
/// Which *scene* it sets up comes from the controls, read once at reset: one
/// ROM holds every page the chip can be asked for, so a regression has a name
/// and not just a hash. Every write is one entry of a table the program walks,
/// so the program is fourteen instructions long whatever the table holds.
///
///     0x400:  lea     ($000600).l, a1  ; the page table
///             move.w  ($800000).l, d0  ; the controls, active low
///             not.w   d0
///             andi.w  #7, d0
///             lsl.w   #2, d0
///             movea.l (0,a1,d0.w), a0  ; this page's list of writes
///     next:   move.l  (a0)+, d0        ; where to write, zero for the end
///             beq.s   done
///             movea.l d0, a1
///             move.w  (a0)+, (a1)
///             bra.s   next
///     done:   move.w  #$2000, sr       ; the page is up: interrupts on
///     spin:   bra.s   spin
const draw_table = 0x600;
const draw_lists = 0x680;
const draw_bytes = 0x4000;
/// Exceptions push, so this one's stack cannot sit at the very bottom of RAM.
const draw_sp = cps.ram_lo + 0x1000;

/// The scenes the ROM can be asked for, in the order the controls select them.
const Page = enum { tilemaps, sprites, priority, order, rowscroll, stars, flip, raster };
const page_count = @typeInfo(Page).@"enum".fields.len;

comptime {
    // The program masks the controls down to a page, which needs a power of two.
    std.debug.assert(page_count & (page_count - 1) == 0);
}

const draw_words = [_]u16{
    0x43f9, draw_table >> 16, draw_table & 0xffff,
    0x3039, cps.in1_lo >> 16, cps.in1_lo & 0xffff,
    0x4640, 0x0240,           page_count - 1,
    0xe548, 0x2071,           0x0000,
    0x2018, 0x6706,           0x2240,
    0x3298, 0x60f6,           0x46fc,
    0x2000, 0x60fe,
};

/// The two handlers, and the autovectors they hang off: vector 24 plus the
/// level, four bytes each from the bottom of the vector table.
const autovector_base = 24;
const vector_bytes = 4;
const vblank_handler = 0x500;
const raster_handler = 0x520;
/// A word of ROM the vblank handler puts back into the scroll register, so a
/// page that moves it mid-frame still starts every frame from the same place.
/// Scroll3 is the one the raster page moves: its tiles are the ones still being
/// drawn by the line the interrupt is programmed for.
const scroll_home = 0x540;
const raster_reg_addr = cps.cps_a_lo + video.scroll3_x;

///     move.w (scroll_home).l, (scroll3_x).l
///     rte
const vblank_words = [_]u16{
    0x33f9,                scroll_home >> 16,        scroll_home & 0xffff,
    raster_reg_addr >> 16, raster_reg_addr & 0xffff, 0x4e73,
};

/// The raster page's whole point: a scroll register written from the level 4
/// handler moves the rest of the screen and nothing above it.
///
///     move.w #$0088, (scroll3_x).l
///     rte
const raster_line = 100;
const raster_scroll_x = 0x88;
const raster_words = [_]u16{
    0x33fc,                raster_scroll_x,
    raster_reg_addr >> 16, raster_reg_addr & 0xffff,
    0x4e73,
};

/// The graphics ROM the set carries: tiles, and then the starfield data. The
/// chip reads the star region as bytes rather than as tiles — one byte per
/// eight pixels' worth of the low plane — which is what those rows are built
/// to hold, so they need a bank of their own and a range of their own.
const gfx_tile_bytes = 0x4000;
const gfx_star_bytes = 0x8000;
const gfx_bytes = gfx_tile_bytes + gfx_star_bytes;
/// Banks of 8x8 tiles' worth of each, which is what a gfx_bank range counts in.
const gfx_tiles = gfx_tile_bytes * romset.pixels_per_byte / 128;
const gfx_stars = gfx_star_bytes * romset.pixels_per_byte / 128;

/// Where the CPS-B's registers are on this board. Nothing may collide: the
/// raster counters read back live, so a priority mask parked on one of them
/// would fire an interrupt every frame.
const layer_control = 0x00;
const priority_regs = [video.priority_groups]u8{ 0x02, 0x04, 0x06, 0x08 };
const palette_control = 0x0a;
const raster_regs = [2]u8{ 0x10, 0x12 };

/// The five layer-enable masks, in the order the board file lists them.
const enable_bits = [board.enable_count]u16{ 0x01, 0x02, 0x04, 0x08, 0x10 };

fn enable(which: board.Enable) u16 {
    return enable_bits[@intFromEnum(which)];
}

const tilemaps_on = enable(.scroll1) | enable(.scroll2) | enable(.scroll3);
const stars_on = enable(.stars1) | enable(.stars2);

/// The CPS-A video control bits this ROM uses, written down here from the
/// hardware rather than borrowed from the renderer.
const rowscroll_on = 1 << 0;
const scroll2_on = 1 << 2;
const scroll3_on = 1 << 3;
const flip_on = 1 << 15;
const layers_on = scroll2_on | scroll3_on;

/// Back to front, two bits a slot from bit 6, and slot 0 is the pass nearest
/// the background. Layer 0 is the object list.
fn layerOrder(slots: [4]board.Layer) u16 {
    var control: u16 = 0;
    for (slots, 0..) |layer, slot| {
        control |= @as(u16, @intFromEnum(layer)) << @intCast(6 + slot * 2);
    }
    return control;
}

const draw_board_file = std.fmt.comptimePrint(
    \\# the board the M2 acceptance ROM runs on: tiles in one bank, stars in another
    \\version = 1
    \\layer_control   = 0x{x:0>2}
    \\priority        = 0x{x:0>2} 0x{x:0>2} 0x{x:0>2} 0x{x:0>2}
    \\palette_control = 0x{x:0>2}
    \\raster_line     = 0x{x:0>2} 0x{x:0>2}
    \\layer_enable    = 0x{x} 0x{x} 0x{x} 0x{x} 0x{x}
    \\bank_sizes = 0x{x} 0x{x} 0 0
    \\gfx_bank = sprites|scroll1|scroll2|scroll3 0x00000 0x{x} 0
    \\gfx_bank = stars 0x00000 0x{x} 1
    \\program = 0x000000 0x{x} word draw.rom
    \\gfx     = 0x000000 0x{x} byte tiles.bin
    \\
, .{
    layer_control,
    priority_regs[0],
    priority_regs[1],
    priority_regs[2],
    priority_regs[3],
    palette_control,
    raster_regs[0],
    raster_regs[1],
    enable_bits[0],
    enable_bits[1],
    enable_bits[2],
    enable_bits[3],
    enable_bits[4],
    gfx_tiles,
    gfx_stars,
    gfx_tiles - 1,
    gfx_stars - 1,
    draw_bytes,
    gfx_bytes,
});

/// Where in graphics RAM the ROM puts things, and what it points the chip at.
const palette_src = 0x14000;
const name_tables = [3]u32{ 0x00000, 0x04000, 0x08000 };
const object_list = 0x18000;
const rowscroll_table = 0x1c000;

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
/// The first tile of the graphics is blank, so a name table that has not been
/// written draws nothing. It is a whole 32x32 tile's worth, which is where the
/// three layers' code ranges start: each is that far in, in its own tile size.
const blank_pixels = 1024;
const tile_pixels = [3]u32{ 128, 256, 1024 };
const code_bases = [3]u32{ blank_pixels / tile_pixels[0], blank_pixels / tile_pixels[1], blank_pixels / tile_pixels[2] };
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

/// A red nibble no palette page has, so the picture's untouched pixels count
/// for nobody.
const background_page = 7;
const background_color = 0xf000 | background_page << 8 | 0x0f;

/// How many tiles of each layer the ROM pokes, each way.
const block = 4;
const max_pokes = 512;

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
    fn regb(s: *Script, offset: u8, value: u16) void {
        s.add(cps.cps_b_lo + @as(u32, offset), value);
    }
};

/// A block of tiles in one name table, at whatever part of the map that
/// layer's scroll brings to the top left of the picture. Each layer takes its
/// codes from a range of its own, all of them above the blank first tile.
fn tileBlock(s: *Script, layer: usize, extra_attr: u16) void {
    const size = tile_sizes[layer];
    const first_col = (video.first_visible_dot + scrolls[layer][0]) / size;
    const first_row = (video.first_visible_line + scrolls[layer][1]) / size;
    for (0..block) |dr| {
        for (0..block) |dc| {
            const i: u32 = @intCast(dr * block + dc);
            const at = name_tables[layer] + nameOffset(strip_bits[layer], first_row + @as(u32, @intCast(dr)), first_col + @as(u32, @intCast(dc))) * 4;
            // Every pair of attribute bits is one of the two flips.
            s.gfxram(at, @intCast(code_bases[layer] + i));
            s.gfxram(at + 2, @as(u16, @intCast(i % 4 * 0x20)) | extra_attr);
        }
    }
}

/// Everything every page wants: the palette, the three tilemaps, and an object
/// list that is empty until a page fills one in — the chip latches the list
/// every frame whatever a page wanted, so it must at least start with its end.
fn commonPokes(s: *Script) void {
    for (0..video.palette_pages) |page| {
        for (0..video.palette_colors) |pen| {
            s.gfxram(palette_src + @as(u32, @intCast(page)) * video.palette_page_bytes + @as(u32, @intCast(pen)) * 2, paletteEntry(@intCast(page), @intCast(pen)));
        }
    }
    s.gfxram(palette_src + video.background_entry * 2, background_color);

    for (0..3) |layer| tileBlock(s, layer, 0);
    for (0..3) |layer| {
        s.rega(base_regs[layer], @intCast((cps.gfxram_lo + name_tables[layer]) / 256));
        s.rega(scroll_regs[layer][0], scrolls[layer][0]);
        s.rega(scroll_regs[layer][1], scrolls[layer][1]);
    }

    s.rega(video.obj_base, (cps.gfxram_lo + object_list) / 256);
    s.gfxram(object_list + 6, sprite_end);
}

/// The object list the sprite pages put up: one plain sprite, one of each flip,
/// and a 2x2 block, all inside the tilemaps' corner so priority has something
/// to argue about.
const sprite_x = 100;
const sprite_y = 40;
const sprite_step = 40;
const sprite_flip_x = 0x20;
const sprite_flip_y = 0x40;
const sprite_block_2x2 = 0x1100;
const sprite_end = 0xff00;
const sprite_entry_bytes = 8;

const sprite_list = [_][4]u16{
    .{ sprite_x, sprite_y, 4, 0 },
    .{ sprite_x + sprite_step, sprite_y, 6, sprite_flip_x },
    .{ sprite_x + 2 * sprite_step, sprite_y, 6, sprite_flip_y },
    .{ sprite_x, sprite_y + sprite_step, 8, sprite_block_2x2 },
    .{ 0, 0, 0, sprite_end },
};

fn spritePokes(s: *Script) void {
    for (sprite_list, 0..) |sprite, i| {
        for (sprite, 0..) |word, w| {
            s.gfxram(object_list + @as(u32, @intCast(i * sprite_entry_bytes + w * 2)), word);
        }
    }
}

/// The pens scroll2 keeps above the sprites, and the group of masks it obeys.
const priority_group = 1;
const priority_pens = 0x00f0;

fn priorityPokes(s: *Script) void {
    s.regb(priority_regs[priority_group], priority_pens);
    tileBlock(s, 1, priority_group << 7);
}

/// A different scroll on each of the first thirty-two lines of the picture,
/// which only scroll2 gets.
const rowscroll_lines = 32;
const rowscroll_step = 2;

fn rowscrollPokes(s: *Script) void {
    s.rega(video.rowscroll_base, (cps.gfxram_lo + rowscroll_table) / 256);
    s.rega(video.rowscroll_offset, 0);
    for (0..rowscroll_lines) |i| {
        const line: u32 = @intCast(video.first_visible_line + i);
        s.gfxram(rowscroll_table + line * 2, @intCast(i * rowscroll_step));
    }
}

fn starPokes(s: *Script) void {
    s.rega(video.stars1_x, 0);
    s.rega(video.stars1_y, 0);
    s.rega(video.stars2_x, 0);
    s.rega(video.stars2_y, 0);
}

/// The palette base goes last: writing it is what sets the copy out of graphics
/// RAM going, and the palette control has to say which pages by then.
fn finishPokes(s: *Script, control: u16, video_control: u16) void {
    s.regb(palette_control, (1 << video.palette_pages) - 1);
    s.regb(layer_control, control);
    s.rega(video.video_control, video_control);
    s.rega(video.palette_base, (cps.gfxram_lo + palette_src) / 256);
}

fn pageScript(page: Page) Script {
    var s = Script{};
    commonPokes(&s);

    var control = layerOrder(.{ .scroll3, .scroll2, .sprites, .scroll1 }) | tilemaps_on;
    var video_control: u16 = layers_on;
    switch (page) {
        .tilemaps => {},
        .sprites => spritePokes(&s),
        .priority => {
            spritePokes(&s);
            priorityPokes(&s);
        },
        // Sprites over everything and scroll2 off: what changes is only which
        // slot each layer is drawn in, and which of them is drawn at all.
        .order => {
            spritePokes(&s);
            control = layerOrder(.{ .scroll3, .scroll1, .scroll2, .sprites }) | (tilemaps_on & ~enable(.scroll2));
        },
        .rowscroll => {
            rowscrollPokes(&s);
            video_control |= rowscroll_on;
        },
        // The tilemaps off, so what is left on screen is starfield and nothing
        // else — two of them, at two different places in each column.
        .stars => {
            starPokes(&s);
            control = layerOrder(.{ .scroll3, .scroll2, .sprites, .scroll1 }) | stars_on;
        },
        .flip => video_control |= flip_on,
        .raster => s.regb(raster_regs[0], raster_line),
    }

    finishPokes(&s, control, video_control);
    return s;
}

fn drawImage() [draw_bytes]u8 {
    var region: [draw_bytes]u8 = @splat(romset.blank);
    std.mem.writeInt(u32, region[0..4], draw_sp, .big);
    std.mem.writeInt(u32, region[4..8], reset_pc, .big);
    std.mem.writeInt(u32, region[(autovector_base + scheduler.vint_level) * vector_bytes ..][0..4], vblank_handler, .big);
    std.mem.writeInt(u32, region[(autovector_base + scheduler.rint_level) * vector_bytes ..][0..4], raster_handler, .big);

    for ([_]struct { u32, []const u16 }{
        .{ reset_pc, &draw_words },
        .{ vblank_handler, &vblank_words },
        .{ raster_handler, &raster_words },
    }) |part| {
        for (part[1], 0..) |word, i| {
            std.mem.writeInt(u16, region[part[0] + i * 2 ..][0..2], word, .big);
        }
    }
    std.mem.writeInt(u16, region[scroll_home..][0..2], scrolls[2][0], .big);

    var at: usize = draw_lists;
    for (0..page_count) |page| {
        std.mem.writeInt(u32, region[draw_table + page * 4 ..][0..4], @intCast(at), .big);
        const s = pageScript(@enumFromInt(page));
        for (s.pokes[0..s.n]) |poke| {
            std.mem.writeInt(u32, region[at..][0..4], poke[0], .big);
            std.mem.writeInt(u16, region[at + 4 ..][0..2], @intCast(poke[1]), .big);
            at += 6;
        }
        std.mem.writeInt(u32, region[at..][0..4], 0, .big);
        at += 4;
    }

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

/// One star in each field every sixteen rows, in different rows of the column
/// so the two fields can be told apart, and a value of 15 everywhere else --
/// which is what the chip reads as no star at all.
const star_period = 16;
const star_none = 0x0f;
const star_field1 = 0x05;
const star_field2 = 0x0a;
const star_rows = 256;

fn starByte(row: usize, half: usize) u8 {
    const phase = row % star_period;
    if (half == 0) return if (phase == 0) star_field1 else star_none;
    return if (phase == star_period / 2) star_field2 else star_none;
}

/// Graphics whose every pen can be worked out from where it is, packed the way
/// the board's own ROMs are. Past the tiles the same rows carry the starfield,
/// whose low plane is the only one the chip looks at.
fn tilesImage() [gfx_bytes]u8 {
    var file: [gfx_bytes]u8 = @splat(0);
    var pens: [romset.pixels_per_row]u8 = undefined;
    var at: usize = 0;
    while (at < gfx_bytes) : (at += romset.bytes_per_row) {
        const row = at / romset.bytes_per_row;
        if (at < blank_pixels / romset.pixels_per_byte) {
            pens = @splat(video.transparent_pen);
        } else if (at < gfx_tile_bytes) {
            for (&pens, 0..) |*pen, x| pen.* = @intCast((row + x) % video.palette_colors);
        } else {
            const star = (row - gfx_tile_bytes / romset.bytes_per_row) % star_rows;
            for (&pens, 0..) |*pen, x| {
                pen.* = starByte(star, x / 8) >> @intCast(7 - x % 8) & 1;
            }
        }
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

/// Where a finished pixel came from: the ROM's palette puts the page number in
/// the red nibble and nothing else does, so the red byte of a pixel names the
/// layer that drew it. A nibble spread over a byte is `n * 0x11`.
const red_mask = 0xff;
const nibble_to_byte = 0x11;

fn scores(c: *const cps.Cps) [video.palette_pages]u32 {
    var out: [video.palette_pages]u32 = @splat(0);
    for (c.v.fb) |pixel| {
        const red = pixel & red_mask;
        if (red % nibble_to_byte != 0) continue;
        const page = red / nibble_to_byte;
        if (page < out.len) out[page] += 1;
    }
    return out;
}

fn lineHash(c: *const cps.Cps, y: u32) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(c.v.fb[y * video.width ..][0..video.width]));
}

/// The last line of the picture the tilemaps reach, which is also the one the
/// raster page's interrupt has already moved by.
const deepest_line = 90;

/// Frames enough for every page to be up: the object list is latched at the
/// vblank of the frame the program writes it in, and the raster counters are
/// reloaded at the top of the frame after they are programmed.
const page_frames = 3;

fn runPage(c: *cps.Cps, cpu: *scheduler.Cpu, page: Page) void {
    scheduler.reset(c, cpu);
    c.inputs.pad[0] = @intFromEnum(page);
    for (0..page_frames) |_| scheduler.runFrame(c, cpu);
}

fn loadDrawSet(tmp: *std.testing.TmpDir) !struct { board.Board, romset.Set } {
    try writeDrawSet(tmp.dir);
    var diag = board.Diag{};
    const b = try board.parse(draw_board_file, &diag);
    const rom = romset.load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag) catch |err| {
        std.debug.print("unexpected: {s}\n", .{diag.message()});
        return err;
    };
    return .{ b, rom };
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
    const b, var rom = try loadDrawSet(&tmp);
    defer rom.deinit(testing.allocator);

    const c = try testing.allocator.create(cps.Cps);
    defer testing.allocator.destroy(c);
    c.* = .{ .board = b, .rom = rom };

    var cpu: scheduler.Cpu = .{};
    runPage(c, &cpu, .tilemaps);
    try testing.expect(!cpu.halted);

    // The palette came out of graphics RAM, page by page.
    try testing.expectEqual(paletteEntry(1, 0), c.v.palette[video.palette_page_entries]);
    try testing.expectEqual(@as(u16, background_color), c.v.palette[video.background_entry]);

    // A line hash tells you *where* a change went in, which one number for the
    // whole frame does not.
    try testing.expectEqual(@as(u64, 0x1c2c7ba44d8be823), lineHash(c, 0));
    try testing.expectEqual(@as(u64, 0x6ceb819b9eb530ab), lineHash(c, video.height / 4));
    try testing.expectEqual(@as(u64, 0x81ab78cfc115a054), lineHash(c, deepest_line));
    try testing.expectEqual(@as(u64, 0x3a4921c820735f9f), lineHash(c, video.height - 1));
}

/// What a page of the ROM is worth: how many pixels of the finished picture
/// came out of each palette page, and the hash of the machine that drew it.
/// The scoreboard fails on a move in either direction — a layer that stopped
/// drawing and a layer that started covering the others are the same bug.
const Pin = struct {
    scores: [video.palette_pages]u32,
    hash: u64,
};

const pinned = [page_count]Pin{
    .{ .scores = .{ 0, 783, 2208, 7500, 0, 0 }, .hash = 0xa1ba1ce80fdea3b5 },
    .{ .scores = .{ 1680, 783, 1984, 6358, 0, 0 }, .hash = 0x0b4794d3aac4de77 },
    .{ .scores = .{ 1616, 783, 2048, 6358, 0, 0 }, .hash = 0x1a5b6a697ab5abfb },
    .{ .scores = .{ 1680, 783, 0, 8217, 0, 0 }, .hash = 0xfe76b153fcd62961 },
    .{ .scores = .{ 0, 783, 1488, 8176, 0, 0 }, .hash = 0xaf1996147408ccc3 },
    .{ .scores = .{ 0, 0, 0, 0, 168, 168 }, .hash = 0x5414d109c56e8b2e },
    .{ .scores = .{ 0, 783, 2208, 7500, 0, 0 }, .hash = 0xcc5be77cc0917442 },
    .{ .scores = .{ 0, 783, 2208, 6042, 0, 0 }, .hash = 0x20d7b22651c2f20c },
};

test "scoreboard: every page of the test ROM draws what it drew" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const b, var rom = try loadDrawSet(&tmp);
    defer rom.deinit(testing.allocator);

    const c = try testing.allocator.create(cps.Cps);
    defer testing.allocator.destroy(c);
    c.* = .{ .board = b, .rom = rom };
    var cpu: scheduler.Cpu = .{};

    // The whole table first, then the pins: a run that fails is worth looking
    // at whole, and one that passes is worth no words at all.
    var table: [page_count]Pin = undefined;
    for (0..page_count) |i| {
        const page: Page = @enumFromInt(i);
        runPage(c, &cpu, page);
        try testing.expect(!cpu.halted);
        table[i] = .{ .scores = scores(c), .hash = scheduler.hash(c, &cpu) };
    }

    if (!std.meta.eql(pinned, table)) {
        std.debug.print("\n{s:<10} {s:<7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7}  {s}\n", .{ "page", "", "sprites", "scroll1", "scroll2", "scroll3", "stars1", "stars2", "hash" });
        for (0..page_count) |i| {
            for ([2]struct { []const u8, Pin }{ .{ "pinned", pinned[i] }, .{ "drew", table[i] } }) |row| {
                const s = row[1].scores;
                std.debug.print("{s:<10} {s:<7} {d:>7} {d:>7} {d:>7} {d:>7} {d:>7} {d:>7}  {x:0>16}\n", .{ @tagName(@as(Page, @enumFromInt(i))), row[0], s[0], s[1], s[2], s[3], s[4], s[5], row[1].hash });
            }
        }
    }
    for (pinned, table) |want, got| try testing.expectEqual(want, got);

    // What the pins mean, so a change to them has to be argued for rather than
    // just pasted in: flip screen turns the picture round and paints exactly
    // the same pixels, the raster page pulls scroll3 out from under the rest of
    // the frame, and the starfield page draws stars and no tiles.
    try testing.expectEqual(table[@intFromEnum(Page.tilemaps)].scores, table[@intFromEnum(Page.flip)].scores);
    try testing.expect(table[@intFromEnum(Page.raster)].scores[3] < table[@intFromEnum(Page.tilemaps)].scores[3]);
    try testing.expect(table[@intFromEnum(Page.stars)].scores[4] > 0 and table[@intFromEnum(Page.stars)].scores[5] > 0);
    try testing.expectEqual(@as(u32, 0), table[@intFromEnum(Page.stars)].scores[1]);
    // Sprites draw through page 0, and only where the tilemap above them has
    // no priority pen of its own.
    try testing.expect(table[@intFromEnum(Page.sprites)].scores[0] > 0);
    try testing.expect(table[@intFromEnum(Page.priority)].scores[0] < table[@intFromEnum(Page.sprites)].scores[0]);
}
