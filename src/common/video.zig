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
//! What is drawn where is not fixed: the CPS-B layer control names, in four
//! two-bit slots, which of the three tilemaps and the object list takes each of
//! the four passes back to front, and the priority masks say which pens of the
//! tilemap under the sprites cut back through them.

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

/// The video control register's bits. The two layer bits are an extra gate on
/// top of the CPS-B layer enables: those layers need both.
pub const rowscroll_on = 1 << 0;
pub const scroll2_on = 1 << 2;
pub const scroll3_on = 1 << 3;
pub const flip_screen = 1 << 15;

/// A base register holds its address divided by 256, and the chip ignores the
/// bits below its region's alignment — which some games leave set.
pub const base_granularity = 256;
pub const name_table_align = 0x4000;
pub const palette_align = 0x400;
pub const obj_align = 0x800;
pub const rowscroll_align = 0x800;

/// The object list: 256 sprites of four words — X, Y, code, attribute. The chip
/// draws from its own copy, taken at vblank, so a game can build the next
/// frame's sprites over the top of the one being drawn.
pub const obj_bytes = 0x800;

/// The row-scroll table: one word of extra scroll2 X per line of its map.
const rowscroll_entries = 0x800 / 2;

/// The layer control register: four two-bit slots, back to front, each naming a
/// `board.Layer` — 0 is the object list, 1 to 3 the tilemaps.
pub const layer_slots = 4;
const layer_slot_shift = 6;
const layer_slot_bits = 2;
const layer_slot_mask = (1 << layer_slot_bits) - 1;

/// The two raster counters are reloaded at the top of the frame and counted
/// down a line at a time; level 4 is the one of them reaching zero. Out of
/// reset they hold the largest value there is, which in 262 lines never
/// arrives, so nothing fires until a game asks for it.
const raster_max = 0x1ff;
/// Bit 15 of a write reloads that counter there and then.
pub const raster_reload_now = 0x8000;

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
    /// The object list as the chip has it: graphics RAM as it stood at the last
    /// vblank, not as it stands now.
    obj: [obj_bytes]u8 = @splat(0),
    raster_reload: [2]u16 = @splat(raster_max),
    raster_counter: [2]u16 = @splat(raster_max),
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

/// Every register in the file reads back what was last written to it, except
/// the four the board's PAL answers instead: a raster register reads back where
/// the beam is rather than the reload value it was given, the ID register reads
/// the number that board was given, and the multiplier's product comes back in
/// halves. Which offsets those are is the board file's, and a board whose PAL
/// decodes none of them — a CPS-2 board decodes only the multiplier — asks for
/// none of this.
pub fn readB(v: *const Video, b: *const board.Board, offset: u8) u16 {
    if (offset >= board.cps_b_bytes) return open_bus;
    if (same(b.id_offset, offset)) return b.id_value;

    // The bus serves the six-button register itself; player 3 and player 4 are
    // wired to nothing, and an input nobody is pressing reads high — which the
    // last value written to the register is not, and a game polling them would
    // believe it.
    if (same(b.in2_offset, offset) or same(b.in3_offset, offset)) return open_bus;

    const product = multiply(v, b);
    if (same(b.mult_result_lo, offset)) return @truncate(product);
    if (same(b.mult_result_hi, offset)) return @truncate(product >> 16);

    for (b.raster_line, 0..) |reg, i| {
        if (same(reg, offset)) return v.raster_counter[i];
    }
    return v.b[offset / 2];
}

/// 16x16 into 32, read back in halves. A board whose PAL does not decode the
/// factors has no multiplier, and its product is never asked for.
fn multiply(v: *const Video, b: *const board.Board) u32 {
    const f1 = b.mult_factor1 orelse return 0;
    const f2 = b.mult_factor2 orelse return 0;
    return @as(u32, v.b[f1 / 2]) * @as(u32, v.b[f2 / 2]);
}

pub fn writeB(v: *Video, b: *const board.Board, offset: u8, value: u16, mask: u16) void {
    if (offset >= board.cps_b_bytes) return;
    merge(&v.b[offset / 2], value, mask);

    for (b.raster_line, 0..) |reg, i| {
        if (!same(reg, offset)) continue;
        v.raster_reload[i] = v.b[offset / 2] & raster_max;
        if (v.b[offset / 2] & raster_reload_now != 0) v.raster_counter[i] = v.raster_reload[i];
    }
}

/// Steps the raster counters by a line and says whether one of them has come
/// round to zero, which is the board's level 4.
pub fn rasterDue(v: *Video, b: *const board.Board, line: u32) bool {
    var due = false;
    for (b.raster_line, 0..) |reg, i| {
        if (reg == null) continue;
        v.raster_counter[i] = if (line == 0) v.raster_reload[i] else (v.raster_counter[i] -% 1) & raster_max;
        due = due or v.raster_counter[i] == 0;
    }
    return due;
}

pub fn same(reg: board.Reg, offset: u8) bool {
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
/// The quirk: a page whose bit is clear is skipped, but the
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
pub fn toRgba(entry: u16) u32 {
    const bright: u32 = bright_floor + @as(u32, entry >> bright_shift & nibble_mask) * bright_step;
    const r = component(entry >> red_shift, bright);
    const g = component(entry >> green_shift, bright);
    const b = component(entry >> blue_shift, bright);
    return 0xff00_0000 | b << 16 | g << 8 | r;
}

fn component(nibble: u16, bright: u32) u32 {
    return @as(u32, nibble & nibble_mask) * nibble_to_byte * bright / bright_full;
}

pub fn base(v: *const Video, reg: u8, comptime alignment: u32) u32 {
    const addr = @as(u32, v.a[reg / 2]) * base_granularity;
    return addr & ~@as(u32, alignment - 1) & gfxram_mask;
}

pub fn gfxWord(v: *const Video, addr: u32) u16 {
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
pub const bytes_per_name = 4;

/// The attribute word: five bits of colour, the two flips, then two bits
/// picking which of the board's four priority masks this tile obeys.
pub const color_mask = 0x1f;
pub const flip_x_bit = 0x20;
pub const flip_y_bit = 0x40;
pub const priority_group_shift = 7;

/// One tilemap layer, as data. The three instances below are the whole of what
/// distinguishes scroll1 from scroll3.
pub const Tilemap = struct {
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
    /// Which of the board's layer-enable masks turns this layer on, and which
    /// bit of the video control register has to agree. Scroll1 has no second
    /// gate, and takes zero.
    enable: board.Enable,
    control_bit: u16,
    /// Only scroll2 is row-scrolled.
    rowscrolled: bool,
};

pub const scroll1 = Tilemap{
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
    .enable = .scroll1,
    .control_bit = 0,
    .rowscrolled = false,
};

pub const scroll2 = Tilemap{
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
    .enable = .scroll2,
    .control_bit = scroll2_on,
    .rowscrolled = true,
};

pub const scroll3 = Tilemap{
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
    .enable = .scroll3,
    .control_bit = scroll3_on,
    .rowscrolled = false,
};

const tilemaps = [_]Tilemap{ scroll1, scroll2, scroll3 };

/// One line's working picture, and the priority plane the sprites are settled
/// against.
pub const Line = struct {
    color: [width]u32,
    /// What the tilemaps left under the object list. CPS-1 writes one bit, set
    /// where the layer the sprites are drawn straight after put down a pen its
    /// board calls high; CPS-2 writes a bit per pass and leaves the comparing
    /// to the sprite masks.
    prio: [width]u8,
};

/// What a tilemap pass leaves behind in the priority plane.
pub const Priority = union(enum) {
    /// Nothing is settled against this pass: it is under the sprites whole.
    none,
    /// CPS-1: mark the pens this tile's priority group calls high, so the
    /// sprites drawn next skip them.
    pens,
    /// CPS-2: mark the pass itself, and leave the pens alone. Which sprites a
    /// pass covers is not a property of the tile there but of the ranking in
    /// the object latch, so it is `primasks` that settles it and not this.
    pass: u8,
};

/// A blank line, in the colour the last palette entry holds: what the picture
/// is where nothing draws.
pub fn beginLine(v: *const Video) Line {
    return .{ .color = @splat(v.colors[background_entry]), .prio = @splat(0) };
}

/// Draws whichever of the three tilemaps the layer names, or nothing if it
/// names the object list. Each map is its own comptime shape, so the dispatch
/// is a compile-time match and not a switch per line.
pub fn drawLayer(v: *Video, b: *const board.Board, gfx: []const u8, l: *Line, line: u32, which: board.Layer, prio: Priority) void {
    inline for (tilemaps) |m| {
        if (which == m.layer) drawTilemap(v, b, gfx, m, l, line, prio);
    }
}

/// Scans the finished line out into the framebuffer.
///
/// Flip screen inverts the counters that scan the picture out, and the visible
/// window is centred in the 512 by 256 space they count over — so turning the
/// whole line round, into the line as far from the bottom as this one is from
/// the top, is the same picture the board would show.
pub fn emit(v: *Video, l: *const Line, line: u32) void {
    const y = line - first_visible_line;
    const flipped = v.a[video_control / 2] & flip_screen != 0;
    const dst = v.fb[(if (flipped) height - 1 - y else y) * width ..][0..width];
    if (!flipped) {
        @memcpy(dst, &l.color);
        return;
    }
    for (dst, 0..) |*pixel, i| pixel.* = l.color[width - 1 - i];
}

/// Which layer the CPS-B layer control puts in a given pass, back to front.
pub fn slotLayer(control: u16, slot: usize) board.Layer {
    const shift: u4 = @intCast(layer_slot_shift + slot * layer_slot_bits);
    return @enumFromInt((control >> shift) & layer_slot_mask);
}

pub fn layerControl(v: *const Video, b: *const board.Board) u16 {
    const offset = b.layer_control orelse return 0;
    return v.b[offset / 2];
}

pub fn enabled(v: *const Video, b: *const board.Board, which: board.Enable) bool {
    return layerControl(v, b) & b.layer_enable[@intFromEnum(which)] != 0;
}

/// The pens of a tile in this priority group that are drawn over the sprites. A
/// group whose register the board's PAL does not decode has none, which is how
/// a board with nothing above its sprites is written down.
fn priorityMask(v: *const Video, b: *const board.Board, group: u2) u16 {
    const offset = b.priority[group] orelse return 0;
    return v.b[offset / 2];
}

/// Scroll2's X can be given a word per line out of the row-scroll table, which
/// is what bends a road or ripples water without the CPU touching a register.
fn scrollX(v: *const Video, comptime m: Tilemap, line: u32) u32 {
    const scroll = v.a[m.scroll_x_reg / 2];
    if (!m.rowscrolled or v.a[video_control / 2] & rowscroll_on == 0) return scroll;
    const table = base(v, rowscroll_base, rowscroll_align);
    const i = (line + v.a[rowscroll_offset / 2]) & (rowscroll_entries - 1);
    return scroll +% gfxWord(v, table + i * 2);
}

fn drawTilemap(v: *Video, b: *const board.Board, gfx: []const u8, comptime m: Tilemap, l: *Line, line: u32, prio: Priority) void {
    if (m.control_bit != 0 and v.a[video_control / 2] & m.control_bit == 0) return;
    if (!enabled(v, b, m.enable)) return;

    const table = base(v, m.base_reg, name_table_align);
    const map_mask = m.size * name_tiles - 1;
    const tile_mask = m.size - 1;
    const wy = (line + v.a[m.scroll_y_reg / 2]) & map_mask;
    const row = wy / m.size;
    const scroll = scrollX(v, m, line);

    var x: u32 = 0;
    while (x < width) {
        const wx = (first_visible_dot + x + scroll) & map_mask;
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
        const high = if (prio == .pens) priorityMask(v, b, @truncate(attr >> priority_group_shift)) else 0;

        for (0..span) |i| {
            const px = tx + @as(u32, @intCast(i));
            const pen = gfxPixel(gfx, src + if (flip_x) tile_mask - px else px);
            if (pen == transparent_pen) continue;
            switch (prio) {
                .none => {},
                .pens => l.prio[x + i] = @intFromBool(high >> @intCast(pen) & 1 != 0),
                .pass => |bit| l.prio[x + i] |= bit,
            }
            l.color[x + i] = v.colors[color + pen];
        }
    }
}

pub fn nameOffset(comptime m: Tilemap, row: u32, col: u32) u32 {
    const strip = @as(u32, 1) << m.strip_bits;
    return (row & (strip - 1)) |
        ((col & (name_tiles - 1)) << m.strip_bits) |
        ((row & (name_tiles - 1) & ~(strip - 1)) << name_column_bits);
}

/// A tile code is not an address. The B-board's PAL switches banks of graphics
/// under the video chip, and which bank a code lands in is what the board file
/// records. A code no range claims draws nothing at all.
pub fn bankMap(b: *const board.Board, layer: board.Layer, shift: u3, code: u16) ?u32 {
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

pub fn gfxPixel(gfx: []const u8, at: u32) u8 {
    if (at >= gfx.len) return transparent_pen;
    return gfx[at];
}
