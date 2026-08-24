//! The video chips: CPS-A (DL-0311) and CPS-B-21 (DL-0921).
//!
//! Two register files and the tilemap renderer. The CPS-A file is fixed across
//! boards; the CPS-B file is mapped by a PAL on the B-board, so where each of
//! its registers lives is in the board file rather than here, and the two reads
//! that answer with something other than a latched value — the board ID and the
//! multiplier — are the protection a game checks before it will boot.
//!
//! Rendering is per line and back to front, straight into the framebuffer.
//! Nothing here allocates, nothing here knows what a window is: the frontend
//! and the headless runner take the same array of pixels.
//!
//! Sprites, the starfields, the CPS-B layer control and its priority masks are
//! M2's; at M1 the three tilemaps are drawn in a fixed order.

const std = @import("std");
const board = @import("board");

/// The picture, in dots. 512 dots by 262 lines at an 8 MHz pixel clock is
/// 59.6374 Hz, and lines 16..239 of each frame are the visible 224.
pub const dots_per_line = 512;
pub const lines_per_frame = 262;
pub const first_visible_dot = 64;
pub const first_visible_line = 16;
pub const width = 384;
pub const height = 224;

/// Graphics RAM: name tables, the object list, the row-scroll table and the
/// palette source, at 0x900000.
pub const gfxram_bytes = 0x30000;
/// A base register can point past the RAM that is actually there; the chip
/// decodes 18 bits of it and no more.
pub const gfxram_mask = 0x3ffff;

/// Six pages of 32 palettes of 16 entries, copied out of graphics RAM when the
/// palette base register is written.
pub const palette_pages = 6;
pub const palette_colors = 16;
pub const palette_page_entries = 32 * palette_colors;
pub const palette_entries = palette_pages * palette_page_entries;
pub const palette_page_bytes = palette_page_entries * 2;

/// Games clear the picture to the last entry of the last page and expect it to
/// show through everywhere nothing is drawn.
pub const background_entry = palette_entries - 1;

/// CPS-A register file, at word offsets from 0x800100.
pub const a_regs_bytes = 0x40;
pub const obj_base = 0x00;
pub const scroll1_base = 0x02;
pub const scroll2_base = 0x04;
pub const scroll3_base = 0x06;
pub const rowscroll_base = 0x08;
pub const palette_base = 0x0a;
pub const scroll1_x = 0x0c;
pub const scroll1_y = 0x0e;
pub const scroll2_x = 0x10;
pub const scroll2_y = 0x12;
pub const scroll3_x = 0x14;
pub const scroll3_y = 0x16;
pub const stars1_x = 0x18;
pub const stars1_y = 0x1a;
pub const stars2_x = 0x1c;
pub const stars2_y = 0x1e;
pub const rowscroll_offset = 0x20;
pub const video_control = 0x22;

/// A base register holds its address divided by 256, and the chip ignores the
/// bits below its region's alignment — which some games leave set.
pub const base_granularity = 256;
pub const name_table_align = 0x4000;
pub const palette_align = 0x400;

/// What an undecoded address on either register file reads back as.
pub const open_bus = 0xffff;

pub const Video = struct {
    a: [a_regs_bytes / 2]u16 = @splat(0),
    b: [board.cps_b_bytes / 2]u16 = @splat(0),
    gfxram: [gfxram_bytes]u8 = @splat(0),
    /// Palette RAM: the copy the chip took out of graphics RAM, as the 68000
    /// wrote it — brightness, red, green and blue, a nibble each.
    palette: [palette_entries]u16 = @splat(0),
    /// The same entries through the DAC, so the renderer never does arithmetic
    /// per pixel that it could have done per palette write.
    colors: [palette_entries]u32 = @splat(0),
    /// RGBA, one word of the picture per pixel, handed to the frontend as a
    /// texture and to the headless runner as bytes to hash.
    fb: [width * height]u32 = @splat(0),
};

pub fn readA(v: *const Video, offset: u8) u16 {
    if (offset >= a_regs_bytes) return open_bus;
    return v.a[offset / 2];
}

/// The palette is not written by the CPU: the chip copies it out of graphics
/// RAM, and writing the base register is what sets that copy going.
pub fn writeA(v: *Video, b: *const board.Board, offset: u8, value: u16, mask: u16) void {
    if (offset >= a_regs_bytes) return;
    merge(&v.a[offset / 2], value, mask);
    // Either half of the register: the chip sees the write, not the word.
    if (offset / 2 == palette_base / 2) copyPalette(v, b);
}

/// The CPS-B file answers three ways: the board's ID register, the two halves
/// of the multiplier's product, and — for everything else — whatever was last
/// written there.
pub fn readB(v: *const Video, b: *const board.Board, offset: u8) u16 {
    if (offset >= board.cps_b_bytes) return open_bus;
    if (same(b.id_offset, offset)) return b.id_value;

    const product = multiply(v, b);
    if (same(b.mult_result_lo, offset)) return @truncate(product);
    if (same(b.mult_result_hi, offset)) return @truncate(product >> 16);
    return v.b[offset / 2];
}

pub fn writeB(v: *Video, offset: u8, value: u16, mask: u16) void {
    if (offset >= board.cps_b_bytes) return;
    merge(&v.b[offset / 2], value, mask);
}

/// 16x16 into 32, read back in halves. A board whose PAL does not decode the
/// factors has no multiplier, and its product is never asked for.
fn multiply(v: *const Video, b: *const board.Board) u32 {
    const f1 = b.mult_factor1 orelse return 0;
    const f2 = b.mult_factor2 orelse return 0;
    return @as(u32, v.b[f1 / 2]) * @as(u32, v.b[f2 / 2]);
}

fn same(reg: board.Reg, offset: u8) bool {
    return reg != null and reg.? == offset;
}

/// A 68000 byte write drives one half of the data bus; the other half keeps
/// whatever the register held.
fn merge(reg: *u16, value: u16, mask: u16) void {
    reg.* = (reg.* & ~mask) | (value & mask);
}

// --------------------------------------------------------------- the palette

/// A palette entry's nibbles, low to high: blue, green, red, brightness.
const blue_shift = 0;
const green_shift = 4;
const red_shift = 8;
const bright_shift = 12;
const nibble_mask = 0x0f;
/// A nibble spread over a byte is `n * 0x11`; brightness runs from a third of
/// that to all of it, which is what dividing by the largest brightness does.
const nibble_to_byte = 0x11;
const bright_floor = 0x0f;
const bright_step = 2;
const bright_full = bright_floor + nibble_mask * bright_step;

/// Copies the palette out of graphics RAM, one page per enabled bit of the
/// board's palette control register.
///
/// The quirk (DESIGN.md §7.1): a page whose bit is clear is skipped, but the
/// *source* only starts advancing once something has been copied — so a clear
/// bit 0 does not lose page 0, it lands its colours in the first page that is
/// enabled. Later clear bits really do skip.
pub fn copyPalette(v: *Video, b: *const board.Board) void {
    const ctrl = if (b.palette_control) |offset| v.b[offset / 2] else 0;
    const start = base(v, palette_base, palette_align);
    var src = start;

    for (0..palette_pages) |page| {
        if (ctrl & (@as(u16, 1) << @intCast(page)) == 0) {
            if (src != start) src += palette_page_bytes;
            continue;
        }
        for (0..palette_page_entries) |i| {
            const entry = gfxWord(v, src + @as(u32, @intCast(i * 2)));
            v.palette[page * palette_page_entries + i] = entry;
            v.colors[page * palette_page_entries + i] = toRgba(entry);
        }
        src += palette_page_bytes;
    }
}

/// 12-bit colour with a 4-bit brightness over it. Brightness zero is a third of
/// full rather than black, which is what the board's resistor ladder does.
fn toRgba(entry: u16) u32 {
    const bright: u32 = bright_floor + @as(u32, entry >> bright_shift & nibble_mask) * bright_step;
    const r = component(entry >> red_shift, bright);
    const g = component(entry >> green_shift, bright);
    const b = component(entry >> blue_shift, bright);
    return 0xff00_0000 | b << 16 | g << 8 | r;
}

fn component(nibble: u16, bright: u32) u32 {
    return @as(u32, nibble & nibble_mask) * nibble_to_byte * bright / bright_full;
}

fn base(v: *const Video, reg: u8, comptime alignment: u32) u32 {
    const addr = @as(u32, v.a[reg / 2]) * base_granularity;
    return addr & ~@as(u32, alignment - 1) & gfxram_mask;
}

fn gfxWord(v: *const Video, addr: u32) u16 {
    if (addr + 1 >= gfxram_bytes) return 0;
    return std.mem.readInt(u16, v.gfxram[addr..][0..2], .big);
}

// -------------------------------------------------------------- the tilemaps

/// Colour 15 of a tile is transparent. Unpopulated graphics ROM decodes to it
/// everywhere, so a tile that is not there is invisible rather than garbage.
pub const transparent_pen = 15;

/// Every name table is 64 tiles square, whatever size its tiles are, and every
/// entry is a code word and an attribute word.
pub const name_tiles = 64;
const name_column_bits = 6;
const bytes_per_name = 4;

/// The attribute word: five bits of colour, then the two flips. Bits 7 and 8
/// pick the priority group, which is M2's.
const color_mask = 0x1f;
const flip_x_bit = 0x20;
const flip_y_bit = 0x40;

/// One tilemap layer, as data. The three instances below are the whole of what
/// distinguishes scroll1 from scroll3.
const Tilemap = struct {
    layer: board.Layer,
    /// Tile edge, in pixels.
    size: u32,
    /// Tiles down one column strip of the name table: consecutive entries run
    /// *down* the screen, 256 pixels' worth, before stepping right.
    strip_bits: u5,
    /// Where one tile's pixels start in the decoded graphics, and where one row
    /// of them does. Not `size * size` for the 8x8 layer: the graphics ROM
    /// always hands over sixteen pixels a row, so two 8x8 tiles share each one.
    tile_pixels: u32,
    row_pixels: u32,
    /// Odd columns of that shared row are the right-hand eight pixels.
    paired: bool,
    base_reg: u8,
    scroll_x_reg: u8,
    scroll_y_reg: u8,
    code_mask: u16,
    /// The palette page the layer's colours are taken from.
    page: u32,
    /// A code is shifted this far before the board's bank table sees it: the
    /// table is written in units of the smallest tile.
    bank_shift: u3,
};

const scroll1 = Tilemap{
    .layer = .scroll1,
    .size = 8,
    .strip_bits = 5,
    .tile_pixels = 128,
    .row_pixels = 16,
    .paired = true,
    .base_reg = scroll1_base,
    .scroll_x_reg = scroll1_x,
    .scroll_y_reg = scroll1_y,
    .code_mask = 0xffff,
    .page = 1,
    .bank_shift = 0,
};

const scroll2 = Tilemap{
    .layer = .scroll2,
    .size = 16,
    .strip_bits = 4,
    .tile_pixels = 256,
    .row_pixels = 16,
    .paired = false,
    .base_reg = scroll2_base,
    .scroll_x_reg = scroll2_x,
    .scroll_y_reg = scroll2_y,
    .code_mask = 0xffff,
    .page = 2,
    .bank_shift = 1,
};

const scroll3 = Tilemap{
    .layer = .scroll3,
    .size = 32,
    .strip_bits = 3,
    .tile_pixels = 1024,
    .row_pixels = 32,
    .paired = false,
    .base_reg = scroll3_base,
    .scroll_x_reg = scroll3_x,
    .scroll_y_reg = scroll3_y,
    .code_mask = 0x3fff,
    .page = 3,
    .bank_shift = 3,
};

/// Back to front. Which layer actually sits where is in the CPS-B layer
/// control, and reading it — with the layer enables and the priority masks —
/// is M2's.
const layer_order = [_]Tilemap{ scroll3, scroll2, scroll1 };

/// Draws one line of the picture. Scroll registers are read here rather than
/// latched at the top of the frame, which is what makes a mid-frame write to
/// them move the rest of the screen and nothing above it.
pub fn renderLine(v: *Video, b: *const board.Board, gfx: []const u8, line: u32) void {
    if (line < first_visible_line or line >= first_visible_line + height) return;
    const y = line - first_visible_line;
    @memset(v.fb[y * width ..][0..width], v.colors[background_entry]);
    inline for (layer_order) |m| drawTilemap(v, b, gfx, m, line, y);
}

fn drawTilemap(v: *Video, b: *const board.Board, gfx: []const u8, comptime m: Tilemap, line: u32, y: u32) void {
    const table = base(v, m.base_reg, name_table_align);
    const map_mask = m.size * name_tiles - 1;
    const tile_mask = m.size - 1;
    const wy = (line + v.a[m.scroll_y_reg / 2]) & map_mask;
    const row = wy / m.size;

    var x: u32 = 0;
    while (x < width) {
        const wx = (first_visible_dot + x + v.a[m.scroll_x_reg / 2]) & map_mask;
        const col = wx / m.size;
        const tx = wx & tile_mask;
        const span = @min(m.size - tx, width - x);
        defer x += span;

        const entry = table + nameOffset(m, row, col) * bytes_per_name;
        const code = gfxWord(v, entry) & m.code_mask;
        const attr = gfxWord(v, entry + 2);

        const mapped = bankMap(b, m.layer, m.bank_shift, code) orelse continue;
        const flip_x = attr & flip_x_bit != 0;
        const ty = if (attr & flip_y_bit != 0) tile_mask - (wy & tile_mask) else wy & tile_mask;
        const half: u32 = if (m.paired and col & 1 != 0) m.size else 0;
        const src = mapped * m.tile_pixels + ty * m.row_pixels + half;
        const color = m.page * palette_page_entries + @as(u32, attr & color_mask) * palette_colors;

        for (0..span) |i| {
            const px = tx + @as(u32, @intCast(i));
            const pen = gfxPixel(gfx, src + if (flip_x) tile_mask - px else px);
            if (pen == transparent_pen) continue;
            v.fb[y * width + x + i] = v.colors[color + pen];
        }
    }
}

fn nameOffset(comptime m: Tilemap, row: u32, col: u32) u32 {
    const strip = @as(u32, 1) << m.strip_bits;
    return (row & (strip - 1)) |
        ((col & (name_tiles - 1)) << m.strip_bits) |
        ((row & (name_tiles - 1) & ~(strip - 1)) << name_column_bits);
}

/// A tile code is not an address. The B-board's PAL switches banks of graphics
/// under the video chip, and which bank a code lands in is what the board file
/// records (DESIGN.md §8.1). A code no range claims draws nothing at all.
fn bankMap(b: *const board.Board, layer: board.Layer, shift: u3, code: u16) ?u32 {
    const wide = @as(u32, code) << shift;
    const wanted = @as(u8, 1) << @intFromEnum(layer);
    for (b.gfxRanges()) |range| {
        if (wide < range.start or wide > range.end or range.types & wanted == 0) continue;
        const size = b.bank_sizes[range.bank];
        if (size == 0) return null;
        var start: u32 = 0;
        for (b.bank_sizes[0..range.bank]) |s| start += s;
        return (start +% (wide & (size - 1))) >> shift;
    }
    return null;
}

fn gfxPixel(gfx: []const u8, at: u32) u8 {
    if (at >= gfx.len) return transparent_pen;
    return gfx[at];
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "the CPS-B file answers the two reads a game checks before it boots" {
    var b = board.Board{
        .id_offset = 0x0e,
        .id_value = 0x0c00,
        .mult_factor1 = 0x00,
        .mult_factor2 = 0x02,
        .mult_result_lo = 0x04,
        .mult_result_hi = 0x06,
    };
    var v = Video{};

    try testing.expectEqual(@as(u16, 0x0c00), readB(&v, &b, 0x0e));
    // The ID register is not RAM: writing it changes nothing.
    writeB(&v, 0x0e, 0x1234, 0xffff);
    try testing.expectEqual(@as(u16, 0x0c00), readB(&v, &b, 0x0e));

    writeB(&v, 0x00, 0x1234, 0xffff);
    writeB(&v, 0x02, 0x5678, 0xffff);
    try testing.expectEqual(@as(u16, 0x0060), readB(&v, &b, 0x04));
    try testing.expectEqual(@as(u16, 0x0626), readB(&v, &b, 0x06));

    // A board with no multiplier keeps those offsets as plain registers.
    b.mult_factor1 = null;
    b.mult_result_lo = null;
    b.mult_result_hi = null;
    writeB(&v, 0x04, 0xbeef, 0xffff);
    try testing.expectEqual(@as(u16, 0xbeef), readB(&v, &b, 0x04));
}

test "a byte write leaves the other half of the register alone" {
    var v = Video{};
    const b = board.Board{};
    writeA(&v, &b, scroll1_x, 0xffff, 0xffff);
    writeA(&v, &b, scroll1_x, 0x1200, 0xff00);
    try testing.expectEqual(@as(u16, 0x12ff), readA(&v, scroll1_x));
    try testing.expectEqual(@as(u16, open_bus), readA(&v, a_regs_bytes));
}

/// The smallest board that can draw: one bank covering every code, every layer
/// taking its graphics from it, and a palette control the tests can poke.
const test_palette_control = 0x0c;

fn plainBoard() board.Board {
    var b = board.Board{
        .palette_control = test_palette_control,
        .bank_sizes = .{ 0x10000, 0, 0, 0 },
        .range_count = 1,
    };
    b.ranges[0] = .{
        .types = (1 << @intFromEnum(board.Layer.scroll1)) |
            (1 << @intFromEnum(board.Layer.scroll2)) |
            (1 << @intFromEnum(board.Layer.scroll3)),
        .start = 0,
        .end = 0xffff,
        .bank = 0,
    };
    return b;
}

/// Puts a palette page's worth of entries into graphics RAM at `at`, entry `i`
/// holding `i` at full brightness so a copied page is recognisable by value.
fn seedPalettePage(v: *Video, at: u32, tag: u16) void {
    for (0..palette_page_entries) |i| {
        std.mem.writeInt(u16, v.gfxram[at + i * 2 ..][0..2], tag + @as(u16, @intCast(i)), .big);
    }
}

test "the palette is copied a page at a time, and an unset first bit does not skip page 0" {
    var v = Video{};
    const b = plainBoard();
    const at = 0x10000;

    for (0..palette_pages) |page| {
        seedPalettePage(&v, at + @as(u32, @intCast(page)) * palette_page_bytes, @intCast(0x1000 * (page + 1)));
    }
    writeB(&v, test_palette_control, 0x3f, 0xffff);
    writeA(&v, &b, palette_base, @intCast(at / base_granularity), 0xffff);

    // Every page enabled: each lands where it came from.
    for (0..palette_pages) |page| {
        try testing.expectEqual(@as(u16, @intCast(0x1000 * (page + 1))), v.palette[page * palette_page_entries]);
    }

    // Bit 0 clear: page 0's colours are not lost, they land in page 2 — the
    // first page that *is* enabled. Page 3 then takes its own.
    writeB(&v, test_palette_control, 0x3c, 0xffff);
    writeA(&v, &b, palette_base, @intCast(at / base_granularity), 0xffff);
    try testing.expectEqual(@as(u16, 0x1000), v.palette[2 * palette_page_entries]);
    try testing.expectEqual(@as(u16, 0x2000), v.palette[3 * palette_page_entries]);

    // A clear bit after something has been copied really does skip: page 4 is
    // untouched and keeps what the run above left in it.
    writeB(&v, test_palette_control, 0x2f, 0xffff);
    writeA(&v, &b, palette_base, @intCast(at / base_granularity), 0xffff);
    try testing.expectEqual(@as(u16, 0x1000), v.palette[0]);
    try testing.expectEqual(@as(u16, 0x3000), v.palette[2 * palette_page_entries]);
    try testing.expectEqual(@as(u16, 0x6000), v.palette[5 * palette_page_entries]);
    // Skipped means skipped: page 4 still holds what the run above left there.
    try testing.expectEqual(@as(u16, 0x3000), v.palette[4 * palette_page_entries]);
}

test "brightness scales a colour, and zero brightness is a third rather than black" {
    try testing.expectEqual(@as(u32, 0xff00_0000), toRgba(0xf000));
    try testing.expectEqual(@as(u32, 0xffff_ffff), toRgba(0xffff));
    // The same colour at the bottom of the brightness range keeps a third of it.
    try testing.expectEqual(@as(u32, 0xff00_0055), toRgba(0x0f00));
    try testing.expectEqual(@as(u32, 0xff00_00ff), toRgba(0xff00));
}

/// Graphics where every eight pixels are one solid colour, that group's own
/// index modulo fifteen — so the two halves of a shared sixteen-pixel row
/// differ, and colour 15 never turns up by accident.
const blank_tile_pixels = 1024;

fn stripedGfx(gfx: []u8) void {
    for (gfx, 0..) |*pixel, i| pixel.* = @intCast(i / 8 % transparent_pen);
    // Code 0 is blank at all three tile sizes, so a layer a test is not using —
    // its name table left at zero — draws nothing over the one it is.
    @memset(gfx[0..blank_tile_pixels], transparent_pen);
}

/// The colour `stripedGfx` puts at a given pixel of the decoded graphics.
fn striped(at: u32) u32 {
    return at / 8 % transparent_pen;
}

/// Writes one name table entry, `col` tiles across and `row` down.
fn poke(v: *Video, comptime m: Tilemap, table: u32, row: u32, col: u32, code: u16, attr: u16) void {
    const at = table + nameOffset(m, row, col) * bytes_per_name;
    std.mem.writeInt(u16, v.gfxram[at..][0..2], code, .big);
    std.mem.writeInt(u16, v.gfxram[at + 2 ..][0..2], attr, .big);
}

/// Points the three layers at name tables of their own and gives every palette
/// entry its own index as a colour, so a drawn pixel names the entry it came
/// from.
fn ready(v: *Video) void {
    v.a[scroll1_base / 2] = 0x9000;
    v.a[scroll2_base / 2] = 0x9040;
    v.a[scroll3_base / 2] = 0x9080;
    for (0..palette_entries) |i| v.colors[i] = @intCast(i);
}

/// The codes the tests draw with, and where each one's graphics start. Blanking
/// code 0 costs every other code inside that same first thousand pixels, so a
/// test tile has to start past them.
const tile1 = blank_tile_pixels / scroll1.tile_pixels;
const tile2 = blank_tile_pixels / scroll2.tile_pixels + 1;
const tile3 = 1;
const at1 = tile1 * scroll1.tile_pixels;
const at2 = tile2 * scroll2.tile_pixels;
const at3 = tile3 * scroll3.tile_pixels + first_visible_line % scroll3.size * scroll3.row_pixels;

/// Where the layers' name tables land in graphics RAM, given `ready`.
const scroll1_table = 0x0000;
const scroll2_table = 0x4000;
const scroll3_table = 0x8000;

fn expectPixel(v: *const Video, page: u32, color: u32, at: u32, x: u32, y: u32) !void {
    const want = page * palette_page_entries + color * palette_colors + striped(at);
    try testing.expectEqual(want, v.fb[y * width + x]);
}

test "a tile is fetched from the name table and drawn through its own palette" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    // The visible picture starts at dot 64, so screen x 0 is tile column 8.
    const row = first_visible_line / scroll1.size;
    poke(&v, scroll1, scroll1_table, row, 8, tile1, 7);
    poke(&v, scroll1, scroll1_table, row, 9, tile1, 7);
    renderLine(&v, &b, &gfx, first_visible_line);

    // Tile 3, row 0, through colour 7 of the scroll1 page.
    try expectPixel(&v, scroll1.page, 7, at1, 0, 0);
    // Column 9 is odd, so it is the *right* half of the same sixteen-pixel row
    // of graphics rather than a second copy of the left.
    try expectPixel(&v, scroll1.page, 7, at1 + 8, 8, 0);
    // Column 10 is past what was poked: code 0, which is blank.
    try testing.expectEqual(@as(u32, background_entry), v.fb[16]);

    // One line down is the tile's second row, a row of graphics further on.
    renderLine(&v, &b, &gfx, first_visible_line + 1);
    try expectPixel(&v, scroll1.page, 7, at1 + scroll1.row_pixels, 0, 1);
}

test "a 32x32 tile takes two rows of graphics per line, and 16x16 takes one" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    poke(&v, scroll2, scroll2_table, first_visible_line / scroll2.size, 4, tile2, 0);
    poke(&v, scroll3, scroll3_table, first_visible_line / scroll3.size, 2, tile3, 0);

    // Both cover screen x 0, and scroll2 is drawn over scroll3.
    renderLine(&v, &b, &gfx, first_visible_line);
    try expectPixel(&v, scroll2.page, 0, at2, 0, 0);

    // With scroll2's tile blanked, scroll3's shows through: its rows are thirty
    // two pixels of graphics, not sixteen, so its tile 1 starts four times as
    // far in.
    @memset(gfx[at2..][0..scroll2.tile_pixels], transparent_pen);
    renderLine(&v, &b, &gfx, first_visible_line);
    try expectPixel(&v, scroll3.page, 0, at3, 0, 0);
}

test "scrolling moves the map under the window, and the map wraps" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    const row = first_visible_line / scroll1.size;
    poke(&v, scroll1, scroll1_table, row, 9, tile1, 7);
    renderLine(&v, &b, &gfx, first_visible_line);
    const unscrolled = v.fb[scroll1.size];
    try testing.expect(unscrolled != background_entry);

    // Eight pixels of scroll brings column 9 to the left edge, holding on to
    // which half of the shared graphics row it takes.
    v.a[scroll1_x / 2] = scroll1.size;
    renderLine(&v, &b, &gfx, first_visible_line);
    try testing.expectEqual(unscrolled, v.fb[0]);

    // The map is 64 tiles square, so a whole map's worth of scroll either way
    // lands back on the same tile.
    const map = scroll1.size * name_tiles;
    v.a[scroll1_x / 2] = scroll1.size + map;
    renderLine(&v, &b, &gfx, first_visible_line);
    try testing.expectEqual(unscrolled, v.fb[0]);
    v.a[scroll1_x / 2] = @bitCast(@as(i16, @intCast(scroll1.size)) -% @as(i16, @intCast(map)));
    renderLine(&v, &b, &gfx, first_visible_line);
    try testing.expectEqual(unscrolled, v.fb[0]);

    // Scrolling down shows the next row of the tile, and one tile of scroll
    // shows the row of the map below.
    v.a[scroll1_x / 2] = scroll1.size;
    v.a[scroll1_y / 2] = 1;
    renderLine(&v, &b, &gfx, first_visible_line);
    try expectPixel(&v, scroll1.page, 7, at1 + scroll1.row_pixels + 8, 0, 0);
    v.a[scroll1_y / 2] = scroll1.size;
    renderLine(&v, &b, &gfx, first_visible_line);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);
}

test "the flips turn a tile over, and an unclaimed code draws nothing" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    const row = first_visible_line / scroll1.size;
    poke(&v, scroll1, scroll1_table, row, 8, tile1, flip_y_bit);
    renderLine(&v, &b, &gfx, first_visible_line);
    // Flipped vertically, the first line of the tile shows its last row.
    try expectPixel(&v, scroll1.page, 0, at1 + 7 * scroll1.row_pixels, 0, 0);

    // Flip X, on a layer whose tiles are wider than one group of graphics: the
    // left edge of the tile shows what its right edge would have.
    poke(&v, scroll1, scroll1_table, row, 8, 0, 0);
    poke(&v, scroll2, scroll2_table, first_visible_line / scroll2.size, 4, tile2, flip_x_bit);
    renderLine(&v, &b, &gfx, first_visible_line);
    try expectPixel(&v, scroll2.page, 0, at2 + scroll2.size - 1, 0, 0);

    // A code past every range in the board file is not a tile at all, so the
    // background shows through rather than some other board's graphics.
    var narrow = plainBoard();
    narrow.ranges[0].end = 1;
    renderLine(&v, &narrow, &gfx, first_visible_line);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);
}

test "colour 15 is transparent, so the background shows through" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = @splat(transparent_pen);
    ready(&v);

    renderLine(&v, &b, &gfx, first_visible_line);
    renderLine(&v, &b, &gfx, first_visible_line + height - 1);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);
    try testing.expectEqual(@as(u32, background_entry), v.fb[width * height - 1]);

    // Lines outside the picture are not lines at all.
    v.colors[background_entry] = 0;
    renderLine(&v, &b, &gfx, first_visible_line - 1);
    renderLine(&v, &b, &gfx, first_visible_line + height);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);
    try testing.expectEqual(@as(u32, background_entry), v.fb[width * height - 1]);
}
