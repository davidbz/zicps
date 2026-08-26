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
const rowscroll_on = 1 << 0;
const scroll2_on = 1 << 2;
const scroll3_on = 1 << 3;
const flip_screen = 1 << 15;

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
const obj_words = obj_bytes / 2;
const sprite_words = 4;
const sprite_size = 16;
const sprite_pixels = sprite_size * sprite_size;
/// The list ends at the first entry whose attribute word has 0xff on top.
const end_marker = 0xff00;
/// Sprite coordinates are nine bits, in the same 512-dot space the tilemaps
/// scroll in.
const sprite_pos_mask = 0x1ff;
/// A sprite can be a block of up to sixteen tiles each way, counted from zero.
const block_x_mask = 0x0f00;
const block_x_shift = 8;
const block_y_mask = 0xf000;
const block_y_shift = 12;
/// Across a block the code's low nibble wraps: a block never runs out of its
/// own row of sixteen codes. Down it, each row of tiles is a whole such row on.
const block_wrap = 0x0f;
const block_row_step = 0x10;

/// The row-scroll table: one word of extra scroll2 X per line of its map.
const rowscroll_entries = 0x800 / 2;

/// The layer control register: four two-bit slots, back to front, each naming a
/// `board.Layer` — 0 is the object list, 1 to 3 the tilemaps.
const layer_slots = 4;
const layer_slot_shift = 6;
const layer_slot_bits = 2;
const layer_slot_mask = (1 << layer_slot_bits) - 1;

/// The two raster counters are reloaded at the top of the frame and counted
/// down a line at a time; level 4 is the one of them reaching zero. Out of
/// reset they hold the largest value there is, which in 262 lines never
/// arrives, so nothing fires until a game asks for it.
const raster_max = 0x1ff;
/// Bit 15 of a write reloads that counter there and then.
const raster_reload_now = 0x8000;

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

/// The CPS-B file answers three ways: the board's ID register, the two halves
/// of the multiplier's product, and — for everything else — whatever was last
/// written there.
pub fn readB(v: *const Video, b: *const board.Board, offset: u8) u16 {
    if (offset >= board.cps_b_bytes) return open_bus;
    if (same(b.id_offset, offset)) return b.id_value;

    // The extra controls a C-board maps into this window. The bus serves the
    // six-button register itself; player 3 and player 4 are wired to nothing,
    // and an input nobody is pressing reads high — which the last value
    // written to the register is not, and a game polling them would believe it.
    if (same(b.in2_offset, offset) or same(b.in3_offset, offset)) return open_bus;

    const product = multiply(v, b);
    if (same(b.mult_result_lo, offset)) return @truncate(product);
    if (same(b.mult_result_hi, offset)) return @truncate(product >> 16);

    // A raster register reads back where the beam is, not what was written to
    // it: the counter, not the reload value.
    for (b.raster_line, 0..) |reg, i| {
        if (same(reg, offset)) return v.raster_counter[i];
    }
    return v.b[offset / 2];
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

/// Takes the chip's copy of the object list. The board does this at vblank, and
/// it is why a sprite the 68000 writes now is on screen next frame.
pub fn latchObjects(v: *Video) void {
    const at = base(v, obj_base, obj_align);
    for (&v.obj, 0..) |*byte, i| {
        const from = at + @as(u32, @intCast(i));
        byte.* = if (from < gfxram_bytes) v.gfxram[from] else 0;
    }
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

/// The attribute word: five bits of colour, the two flips, then two bits
/// picking which of the board's four priority masks this tile obeys.
const color_mask = 0x1f;
const flip_x_bit = 0x20;
const flip_y_bit = 0x40;
const priority_group_shift = 7;

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
    /// Which of the board's layer-enable masks turns this layer on, and which
    /// bit of the video control register has to agree. Scroll1 has no second
    /// gate, and takes zero.
    enable: board.Enable,
    control_bit: u16,
    /// Only scroll2 is row-scrolled.
    rowscrolled: bool,
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
    .enable = .scroll1,
    .control_bit = 0,
    .rowscrolled = false,
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
    .enable = .scroll2,
    .control_bit = scroll2_on,
    .rowscrolled = true,
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
    .enable = .scroll3,
    .control_bit = scroll3_on,
    .rowscrolled = false,
};

const tilemaps = [_]Tilemap{ scroll1, scroll2, scroll3 };

/// One line's worth of working picture, and which of its pixels the sprites are
/// not allowed to touch.
const Line = struct {
    color: [width]u32,
    /// Set for a pixel where the tilemap immediately under the object list drew
    /// a pen the board's priority mask calls high.
    over: [width]bool,
};

/// Draws one line of the picture. Scroll registers are read here rather than
/// latched at the top of the frame, which is what makes a mid-frame write to
/// them move the rest of the screen and nothing above it.
pub fn renderLine(v: *Video, b: *const board.Board, gfx: []const u8, line: u32, frame: u64) void {
    if (line < first_visible_line or line >= first_visible_line + height) return;

    var l = Line{ .color = @splat(v.colors[background_entry]), .over = @splat(false) };
    drawStars(v, b, gfx, &l, line, frame);

    const control = layerControl(v, b);
    for (0..layer_slots) |slot| {
        const which = slotLayer(control, slot);
        if (which == .sprites) {
            drawSprites(v, b, gfx, &l, line);
            continue;
        }
        // Only the layer the sprites are drawn straight after can cut back
        // through them, so only that one leaves a mask behind.
        const masks = slot + 1 < layer_slots and slotLayer(control, slot + 1) == .sprites;
        inline for (tilemaps) |m| {
            if (which == m.layer) drawTilemap(v, b, gfx, m, &l, line, masks);
        }
    }

    // Flip screen inverts the counters that scan the picture out, and the
    // visible window is centred in the 512 by 256 space they count over — so
    // turning the whole line round, into the line as far from the bottom as
    // this one is from the top, is the same picture the board would show.
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
fn slotLayer(control: u16, slot: usize) board.Layer {
    const shift: u4 = @intCast(layer_slot_shift + slot * layer_slot_bits);
    return @enumFromInt((control >> shift) & layer_slot_mask);
}

fn layerControl(v: *const Video, b: *const board.Board) u16 {
    const offset = b.layer_control orelse return 0;
    return v.b[offset / 2];
}

fn enabled(v: *const Video, b: *const board.Board, which: board.Enable) bool {
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

fn drawTilemap(v: *Video, b: *const board.Board, gfx: []const u8, comptime m: Tilemap, l: *Line, line: u32, masks: bool) void {
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
        const high = if (masks) priorityMask(v, b, @truncate(attr >> priority_group_shift)) else 0;

        for (0..span) |i| {
            const px = tx + @as(u32, @intCast(i));
            const pen = gfxPixel(gfx, src + if (flip_x) tile_mask - px else px);
            if (pen == transparent_pen) continue;
            l.color[x + i] = v.colors[color + pen];
            if (masks) l.over[x + i] = high >> @intCast(pen) & 1 != 0;
        }
    }
}

// --------------------------------------------------------------- the sprites

/// Sprites are drawn last of the list first, so the first entry a game writes
/// ends up on top of the ones after it.
fn drawSprites(v: *Video, b: *const board.Board, gfx: []const u8, l: *Line, line: u32) void {
    var i = lastSprite(v);
    while (i >= 0) : (i -= sprite_words) {
        const at: u32 = @intCast(i);
        drawSprite(v, b, gfx, l, line, objWord(v, at), objWord(v, at + 1), objWord(v, at + 2), objWord(v, at + 3));
    }
}

/// The list is 256 entries long but ends early, at the first attribute word
/// with 0xff on top — the entry *before* which is the last one drawn.
fn lastSprite(v: *const Video) i32 {
    var at: u32 = 0;
    while (at < obj_words) : (at += sprite_words) {
        if (objWord(v, at + 3) & end_marker == end_marker) return @as(i32, @intCast(at)) - sprite_words;
    }
    return obj_words - sprite_words;
}

fn objWord(v: *const Video, word: u32) u16 {
    return std.mem.readInt(u16, v.obj[word * 2 ..][0..2], .big);
}

/// One entry: a 16x16 tile, or a block of up to 16 by 16 of them from
/// consecutive codes. Only the tiles this line crosses are drawn.
fn drawSprite(v: *Video, b: *const board.Board, gfx: []const u8, l: *Line, line: u32, x: u16, y: u16, code: u16, attr: u16) void {
    const first = bankMap(b, .sprites, scroll2.bank_shift, code) orelse return;
    const nx: u32 = ((attr & block_x_mask) >> block_x_shift) + 1;
    const ny: u32 = ((attr & block_y_mask) >> block_y_shift) + 1;
    const flip_x = attr & flip_x_bit != 0;
    const flip_y = attr & flip_y_bit != 0;
    const color = @as(u32, attr & color_mask) * palette_colors;

    for (0..ny) |down| {
        const sy = (@as(u32, y) + down * sprite_size) & sprite_pos_mask;
        if (line < sy or line >= sy + sprite_size) continue;
        const ty = if (flip_y) sprite_size - 1 - (line - sy) else line - sy;
        const block_row = if (flip_y) ny - 1 - down else down;

        for (0..nx) |across| {
            const sx = (@as(u32, x) + across * sprite_size) & sprite_pos_mask;
            const block_col = if (flip_x) nx - 1 - across else across;
            const tile = (first & ~@as(u32, block_wrap)) +
                ((first +% block_col) & block_wrap) +
                block_row_step * block_row;
            const src: u32 = @intCast(tile * sprite_pixels + ty * sprite_size);

            for (0..sprite_size) |px| {
                const dot = sx + px;
                if (dot < first_visible_dot or dot >= first_visible_dot + width) continue;
                const dx = dot - first_visible_dot;
                if (l.over[dx]) continue;
                const at: u32 = @intCast(if (flip_x) sprite_size - 1 - px else px);
                const pen = gfxPixel(gfx, src + at);
                if (pen == transparent_pen) continue;
                l.color[dx] = v.colors[color + pen];
            }
        }
    }
}

// ------------------------------------------------------------- the starfields

/// The starfields are 0x1000 entries of eight bytes, and only the first byte of
/// each half is read: 4096 possible stars in sixteen columns of 256 rows, one
/// row of which is one line of the picture. The data is graphics ROM, so what
/// the chip reads as a byte of star is the low plane of eight decoded pixels.
const star_entries = 0x1000;
const star_rows = 256;
const star_columns = star_entries / star_rows;
const star_column_step = 32;
const star_rows_per_code = 8;
const star_row_pixels = 16;
const star_pos_mask = 0x1ff;
/// A star byte is eight pixels of the low plane, highest bit first.
const star_byte_pixels = 8;
/// The low five bits of an entry are how far into its column the star sits;
/// the one value 0x0f means no star at all.
const star_no_star = 0x0f;
const star_x_mask = 0x1f;
const star_color_mask = 0xe0;
const star_color_shift = 1;
/// Stars are twinkled by walking the colour on a frame in sixteen, and a star
/// with the top bit set walks fifteen so the two fields drift apart.
const star_twinkle_frames = 16;
const star_twinkle_span = 16;
const star_twinkle_odd = 15;
const star_twinkle_alt = 0x80;

/// One field's registers, half of the star row, and palette page. The enables
/// cross over: the bit MAME's tables call stars1 turns on the field that
/// scrolls with the STARS2 registers, and it is left as found rather than
/// tidied into something that would no longer match a board file.
const Starfield = struct {
    enable: board.Enable,
    x_reg: u8,
    y_reg: u8,
    half: u32,
    page: u32,
};

const starfields = [_]Starfield{
    .{ .enable = .stars1, .x_reg = stars2_x, .y_reg = stars2_y, .half = star_row_pixels / 2, .page = 5 },
    .{ .enable = .stars2, .x_reg = stars1_x, .y_reg = stars1_y, .half = 0, .page = 4 },
};

fn drawStars(v: *Video, b: *const board.Board, gfx: []const u8, l: *Line, line: u32, frame: u64) void {
    inline for (starfields) |f| {
        if (enabled(v, b, f.enable)) drawStarfield(v, b, gfx, l, line, frame, f);
    }
}

fn drawStarfield(v: *Video, b: *const board.Board, gfx: []const u8, l: *Line, line: u32, frame: u64, comptime f: Starfield) void {
    const row = (line + v.a[f.y_reg / 2]) & (star_rows - 1);
    const twinkle: u32 = @intCast(frame / star_twinkle_frames);

    for (0..@as(u32, star_columns)) |column| {
        const offs = column * star_rows + row;
        const code = bankMap(b, .stars, 0, @intCast(offs / star_rows_per_code)) orelse continue;
        const row_pixels: u32 = @intCast((offs % star_rows_per_code) * star_row_pixels);
        const star = starByte(gfx, code * scroll1.tile_pixels + row_pixels + f.half);
        if (star & star_x_mask == star_no_star) continue;

        const dot = (column * star_column_step -% v.a[f.x_reg / 2] + (star & star_x_mask)) & star_pos_mask;
        if (dot < first_visible_dot or dot >= first_visible_dot + width) continue;

        const span: u32 = if (star & star_twinkle_alt != 0) star_twinkle_odd else star_twinkle_span;
        const entry = (star & star_color_mask) >> star_color_shift;
        l.color[dot - first_visible_dot] = v.colors[f.page * palette_page_entries + entry + twinkle % span];
    }
}

/// The star bytes are graphics ROM read as bytes rather than as tiles, and this
/// build keeps graphics decoded: the byte is the low plane of the eight pixels
/// it was unpacked into, highest bit first.
///
/// Graphics that are not there read as no star. `gfxPixel` answers a code past
/// the end of the ROM with the transparent pen, whose low bit is set, so going
/// through it here would turn an unpopulated bank into a wall of stars.
fn starByte(gfx: []const u8, at: u32) u32 {
    if (at + star_byte_pixels > gfx.len) return star_no_star;
    var bits: u32 = 0;
    for (0..star_byte_pixels) |i| {
        bits |= @as(u32, gfx[at + i] & 1) << @intCast(star_byte_pixels - 1 - i);
    }
    return bits;
}

fn nameOffset(comptime m: Tilemap, row: u32, col: u32) u32 {
    const strip = @as(u32, 1) << m.strip_bits;
    return (row & (strip - 1)) |
        ((col & (name_tiles - 1)) << m.strip_bits) |
        ((row & (name_tiles - 1) & ~(strip - 1)) << name_column_bits);
}

/// A tile code is not an address. The B-board's PAL switches banks of graphics
/// under the video chip, and which bank a code lands in is what the board file
/// records. A code no range claims draws nothing at all.
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
    writeB(&v, &b, 0x0e, 0x1234, 0xffff);
    try testing.expectEqual(@as(u16, 0x0c00), readB(&v, &b, 0x0e));

    writeB(&v, &b, 0x00, 0x1234, 0xffff);
    writeB(&v, &b, 0x02, 0x5678, 0xffff);
    try testing.expectEqual(@as(u16, 0x0060), readB(&v, &b, 0x04));
    try testing.expectEqual(@as(u16, 0x0626), readB(&v, &b, 0x06));

    // A four-player board's extra inputs are not registers either, and read
    // as a panel with nobody at it.
    b.in2_offset = 0x36;
    b.in3_offset = 0x38;
    writeB(&v, &b, 0x36, 0x0000, 0xffff);
    try testing.expectEqual(@as(u16, open_bus), readB(&v, &b, 0x36));
    try testing.expectEqual(@as(u16, open_bus), readB(&v, &b, 0x38));

    // A board with no multiplier keeps those offsets as plain registers.
    b.mult_factor1 = null;
    b.mult_result_lo = null;
    b.mult_result_hi = null;
    writeB(&v, &b, 0x04, 0xbeef, 0xffff);
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
/// taking its graphics from it, a palette control the tests can poke, and one
/// enable bit each so a test can turn a layer off the way a game would.
const test_palette_control = 0x0c;
const test_layer_control = 0x00;
const test_priority = [4]board.Reg{ 0x02, 0x04, 0x06, 0x08 };
const test_raster = [2]board.Reg{ 0x10, 0x12 };
const test_enables = [board.enable_count]u16{ 0x01, 0x02, 0x04, 0x08, 0x10 };
/// The three tilemaps only: a test that wants a starfield turns one on itself,
/// because star data and tile data are the same bytes read two different ways.
const test_tilemaps_on = 0x07;
/// Back to front: scroll3, scroll2, the object list, scroll1.
const test_order = 3 << 6 | 2 << 8 | 0 << 10 | 1 << 12;

fn plainBoard() board.Board {
    var b = board.Board{
        .layer_control = test_layer_control,
        .priority = test_priority,
        .palette_control = test_palette_control,
        .layer_enable = test_enables,
        .raster_line = test_raster,
        .bank_sizes = .{ 0x10000, 0, 0, 0 },
        .range_count = 1,
    };
    b.ranges[0] = .{
        .types = (1 << @intFromEnum(board.Layer.sprites)) |
            (1 << @intFromEnum(board.Layer.scroll1)) |
            (1 << @intFromEnum(board.Layer.scroll2)) |
            (1 << @intFromEnum(board.Layer.scroll3)) |
            (1 << @intFromEnum(board.Layer.stars)),
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
    writeB(&v, &b, test_palette_control, 0x3f, 0xffff);
    writeA(&v, &b, palette_base, @intCast(at / base_granularity), 0xffff);

    // Every page enabled: each lands where it came from.
    for (0..palette_pages) |page| {
        try testing.expectEqual(@as(u16, @intCast(0x1000 * (page + 1))), v.palette[page * palette_page_entries]);
    }

    // Bit 0 clear: page 0's colours are not lost, they land in page 2 — the
    // first page that *is* enabled. Page 3 then takes its own.
    writeB(&v, &b, test_palette_control, 0x3c, 0xffff);
    writeA(&v, &b, palette_base, @intCast(at / base_granularity), 0xffff);
    try testing.expectEqual(@as(u16, 0x1000), v.palette[2 * palette_page_entries]);
    try testing.expectEqual(@as(u16, 0x2000), v.palette[3 * palette_page_entries]);

    // A clear bit after something has been copied really does skip: page 4 is
    // untouched and keeps what the run above left in it.
    writeB(&v, &b, test_palette_control, 0x2f, 0xffff);
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
    v.a[obj_base / 2] = 0x9000 + object_table / base_granularity;
    v.a[video_control / 2] = scroll2_on | scroll3_on;
    v.b[test_layer_control / 2] = test_order | test_tilemaps_on;
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
    renderLine(&v, &b, &gfx, first_visible_line, 0);

    // Tile 3, row 0, through colour 7 of the scroll1 page.
    try expectPixel(&v, scroll1.page, 7, at1, 0, 0);
    // Column 9 is odd, so it is the *right* half of the same sixteen-pixel row
    // of graphics rather than a second copy of the left.
    try expectPixel(&v, scroll1.page, 7, at1 + 8, 8, 0);
    // Column 10 is past what was poked: code 0, which is blank.
    try testing.expectEqual(@as(u32, background_entry), v.fb[16]);

    // One line down is the tile's second row, a row of graphics further on.
    renderLine(&v, &b, &gfx, first_visible_line + 1, 0);
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
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try expectPixel(&v, scroll2.page, 0, at2, 0, 0);

    // With scroll2's tile blanked, scroll3's shows through: its rows are thirty
    // two pixels of graphics, not sixteen, so its tile 1 starts four times as
    // far in.
    @memset(gfx[at2..][0..scroll2.tile_pixels], transparent_pen);
    renderLine(&v, &b, &gfx, first_visible_line, 0);
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
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    const unscrolled = v.fb[scroll1.size];
    try testing.expect(unscrolled != background_entry);

    // Eight pixels of scroll brings column 9 to the left edge, holding on to
    // which half of the shared graphics row it takes.
    v.a[scroll1_x / 2] = scroll1.size;
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try testing.expectEqual(unscrolled, v.fb[0]);

    // The map is 64 tiles square, so a whole map's worth of scroll either way
    // lands back on the same tile.
    const map = scroll1.size * name_tiles;
    v.a[scroll1_x / 2] = scroll1.size + map;
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try testing.expectEqual(unscrolled, v.fb[0]);
    v.a[scroll1_x / 2] = @bitCast(@as(i16, @intCast(scroll1.size)) -% @as(i16, @intCast(map)));
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try testing.expectEqual(unscrolled, v.fb[0]);

    // Scrolling down shows the next row of the tile, and one tile of scroll
    // shows the row of the map below.
    v.a[scroll1_x / 2] = scroll1.size;
    v.a[scroll1_y / 2] = 1;
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try expectPixel(&v, scroll1.page, 7, at1 + scroll1.row_pixels + 8, 0, 0);
    v.a[scroll1_y / 2] = scroll1.size;
    renderLine(&v, &b, &gfx, first_visible_line, 0);
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
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    // Flipped vertically, the first line of the tile shows its last row.
    try expectPixel(&v, scroll1.page, 0, at1 + 7 * scroll1.row_pixels, 0, 0);

    // Flip X, on a layer whose tiles are wider than one group of graphics: the
    // left edge of the tile shows what its right edge would have.
    poke(&v, scroll1, scroll1_table, row, 8, 0, 0);
    poke(&v, scroll2, scroll2_table, first_visible_line / scroll2.size, 4, tile2, flip_x_bit);
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try expectPixel(&v, scroll2.page, 0, at2 + scroll2.size - 1, 0, 0);

    // A code past every range in the board file is not a tile at all, so the
    // background shows through rather than some other board's graphics.
    var narrow = plainBoard();
    narrow.ranges[0].end = 1;
    renderLine(&v, &narrow, &gfx, first_visible_line, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);
}

test "colour 15 is transparent, so the background shows through" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = @splat(transparent_pen);
    ready(&v);

    renderLine(&v, &b, &gfx, first_visible_line, 0);
    renderLine(&v, &b, &gfx, first_visible_line + height - 1, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);
    try testing.expectEqual(@as(u32, background_entry), v.fb[width * height - 1]);

    // Lines outside the picture are not lines at all.
    v.colors[background_entry] = 0;
    renderLine(&v, &b, &gfx, first_visible_line - 1, 0);
    renderLine(&v, &b, &gfx, first_visible_line + height, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);
    try testing.expectEqual(@as(u32, background_entry), v.fb[width * height - 1]);
}

/// Where `ready` leaves the object list, and one entry of it.
const object_table = 0xc000;

fn object(v: *Video, i: u32, x: u16, y: u16, code: u16, attr: u16) void {
    const at = object_table + i * sprite_words * 2;
    for ([_]u16{ x, y, code, attr }, 0..) |word, w| {
        std.mem.writeInt(u16, v.gfxram[at + @as(u32, @intCast(w)) * 2 ..][0..2], word, .big);
    }
}

/// A sprite code past the blank first tile, and where its graphics start.
const sprite_code = blank_tile_pixels / sprite_pixels;
const sprite_gfx = sprite_code * sprite_pixels;

test "sprites are drawn from the latched list, and the first entry ends up on top" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    const line = first_visible_line;
    object(&v, 0, first_visible_dot, line, sprite_code, 3);
    object(&v, 1, first_visible_dot, line, sprite_code, 4);
    object(&v, 2, 0, 0, 0, end_marker);

    // Nothing yet: the chip draws its own copy, and takes it at vblank.
    renderLine(&v, &b, &gfx, line, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);

    latchObjects(&v);
    renderLine(&v, &b, &gfx, line, 0);
    // The list is drawn backwards, so entry 0's colour is the one left on top.
    try expectPixel(&v, 0, 3, sprite_gfx, 0, 0);

    // Everything from the end marker on is not a sprite: entry 2 has one, so a
    // third sprite written after it never appears.
    object(&v, 3, first_visible_dot + sprite_size, line, sprite_code, 5);
    latchObjects(&v);
    renderLine(&v, &b, &gfx, line, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[sprite_size]);

    // A sprite is sixteen lines tall and no more.
    renderLine(&v, &b, &gfx, line + sprite_size - 1, 0);
    try expectPixel(&v, 0, 3, sprite_gfx + (sprite_size - 1) * sprite_size, 0, sprite_size - 1);
    renderLine(&v, &b, &gfx, line + sprite_size, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[sprite_size * width]);
}

test "a sprite flips both ways, and a block takes the codes after it" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    const line = first_visible_line;
    object(&v, 0, first_visible_dot, line, sprite_code, flip_x_bit);
    object(&v, 1, 0, 0, 0, end_marker);
    latchObjects(&v);
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, 0, 0, sprite_gfx + sprite_size - 1, 0, 0);

    // Flipped vertically, the sprite's first line shows its last row.
    object(&v, 0, first_visible_dot, line, sprite_code, flip_y_bit);
    latchObjects(&v);
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, 0, 0, sprite_gfx + (sprite_size - 1) * sprite_size, 0, 0);

    // A two-wide block draws the code after it in the tile to its right, and
    // the block wraps inside the code's own group of sixteen.
    object(&v, 0, first_visible_dot, line, sprite_code, 1 << block_x_shift);
    latchObjects(&v);
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, 0, 0, sprite_gfx, 0, 0);
    try expectPixel(&v, 0, 0, sprite_gfx + sprite_pixels, sprite_size, 0);
}

test "the layer under the object list keeps its high pens over the sprites" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    // Scroll2 is the slot straight under the sprites, and its tile covers the
    // first sixteen pixels of the line in two eight-pixel colours.
    const line = first_visible_line;
    const group = 2;
    poke(&v, scroll2, scroll2_table, line / scroll2.size, 4, tile2, group << priority_group_shift);
    object(&v, 0, first_visible_dot, line, sprite_code, 0);
    object(&v, 1, 0, 0, 0, end_marker);
    latchObjects(&v);

    // No mask: the sprite is drawn over the whole tile.
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, 0, 0, sprite_gfx, 0, 0);

    // With the tile's first pen called high, that half of it comes back over
    // the sprite and the other half does not.
    v.b[test_priority[group].? / 2] = @as(u16, 1) << @intCast(striped(at2));
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, scroll2.page, 0, at2, 0, 0);
    try expectPixel(&v, 0, 0, sprite_gfx + 8, 8, 0);

    // A layer that is not the one under the sprites has no say: move scroll2
    // down a slot, leaving scroll3 as the pass the object list follows, and the
    // same mask over the same tile stops meaning anything.
    v.b[test_layer_control / 2] = 2 << 6 | 3 << 8 | 0 << 10 | 1 << 12 | test_tilemaps_on;
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, 0, 0, sprite_gfx, 0, 0);
}

test "row scroll gives scroll2 a scroll of its own on every line" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    const table = 0x10000;
    const line = first_visible_line;
    poke(&v, scroll2, scroll2_table, line / scroll2.size, 5, tile2, 0);
    v.a[rowscroll_base / 2] = 0x9000 + table / base_granularity;
    std.mem.writeInt(u16, v.gfxram[table + line * 2 ..][0..2], scroll2.size, .big);

    // The table is not read until the video control bit says so.
    renderLine(&v, &b, &gfx, line, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);

    v.a[video_control / 2] |= rowscroll_on;
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, scroll2.page, 0, at2, 0, 0);

    // It is that line's entry and no other: the line below takes its own, which
    // is still zero.
    renderLine(&v, &b, &gfx, line + 1, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[width]);

    // And it is scroll2's alone — scroll1 draws where it always did.
    poke(&v, scroll1, scroll1_table, line / scroll1.size, 9, tile1, 0);
    renderLine(&v, &b, &gfx, line, 0);
    try expectPixel(&v, scroll1.page, 0, at1 + 8, scroll1.size, 0);
}

test "flip screen turns the whole picture round" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    stripedGfx(&gfx);
    ready(&v);

    const line = first_visible_line;
    poke(&v, scroll1, scroll1_table, line / scroll1.size, 8, tile1, 0);
    renderLine(&v, &b, &gfx, line, 0);
    const first = v.fb[0];
    try testing.expect(first != background_entry);

    v.a[video_control / 2] |= flip_screen;
    renderLine(&v, &b, &gfx, line, 0);
    // The top left pixel of the picture comes out at the bottom right.
    try testing.expectEqual(first, v.fb[height * width - 1]);
}

/// Writes the eight pens whose low plane spells one byte of the starfield.
fn putStar(gfx: []u8, at: u32, byte: u8) void {
    for (0..8) |i| gfx[at + i] = byte >> @intCast(7 - i) & 1;
}

fn noStars(gfx: []u8) void {
    var at: u32 = 0;
    while (at < gfx.len) : (at += 8) putStar(gfx, at, star_no_star);
}

test "a starfield draws a star a column, and walks its colour with the frame" {
    var v = Video{};
    const b = plainBoard();
    var gfx: [0x8000]u8 = undefined;
    noStars(&gfx);
    ready(&v);

    // The third column of the field, on the first visible line: one entry of
    // eight bytes per code, one row of the column per entry.
    const line = first_visible_line;
    const column = 2;
    const offs = column * star_rows + line;
    const at = offs / star_rows_per_code * scroll1.tile_pixels + offs % star_rows_per_code * star_row_pixels;
    const star = 0x05;
    putStar(&gfx, at, star);

    // The tilemaps read the same bytes as tiles, and star data is not blank in
    // the way tile data is, so this page is the starfield and nothing else.
    v.b[test_layer_control / 2] = test_order;

    // Nothing until the field is enabled, and it is the enable the board file
    // calls stars2 that turns on the field in the first half of the row.
    renderLine(&v, &b, &gfx, line, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[star]);

    v.b[test_layer_control / 2] |= test_enables[@intFromEnum(board.Enable.stars2)];
    renderLine(&v, &b, &gfx, line, 0);
    const dot = column * star_column_step + star - first_visible_dot;
    try testing.expectEqual(@as(u32, 4 * palette_page_entries), v.fb[dot]);

    // Sixteen frames on, the star has walked one colour up its palette.
    renderLine(&v, &b, &gfx, line, star_twinkle_frames);
    try testing.expectEqual(@as(u32, 4 * palette_page_entries + 1), v.fb[dot]);

    // The field scrolls as a whole: moved one row back, the same star is drawn
    // one line further down the picture.
    v.a[stars1_y / 2] = star_rows - 1;
    renderLine(&v, &b, &gfx, line + 1, 0);
    try testing.expectEqual(@as(u32, 4 * palette_page_entries), v.fb[width + dot]);
}

test "the raster counters reload at the top of the frame and fire at their line" {
    var v = Video{};
    const b = plainBoard();

    // The reload the board comes up with never reaches zero inside a frame.
    for (0..lines_per_frame) |line| try testing.expect(!rasterDue(&v, &b, @intCast(line)));

    writeB(&v, &b, test_raster[0].?, 100, 0xffff);
    for (0..lines_per_frame) |line| {
        try testing.expectEqual(line == 100, rasterDue(&v, &b, @intCast(line)));
    }
    // And again the next frame: the counter is reloaded at line 0, not left
    // wherever the last frame stopped it.
    for (0..lines_per_frame) |line| {
        try testing.expectEqual(line == 100, rasterDue(&v, &b, @intCast(line)));
    }

    // The counter reads back live, and the top bit of a write reloads it there
    // and then rather than at the top of the next frame.
    _ = rasterDue(&v, &b, 0);
    _ = rasterDue(&v, &b, 1);
    try testing.expectEqual(@as(u16, 99), readB(&v, &b, test_raster[0].?));
    writeB(&v, &b, test_raster[0].?, raster_reload_now | 10, 0xffff);
    try testing.expectEqual(@as(u16, 10), readB(&v, &b, test_raster[0].?));
    for (2..12) |line| try testing.expectEqual(line == 11, rasterDue(&v, &b, @intCast(line)));

    // The second counter is its own: a board with two of them can interrupt
    // twice a frame.
    writeB(&v, &b, test_raster[1].?, 50, 0xffff);
    try testing.expect(!rasterDue(&v, &b, 0));
    for (1..50) |line| _ = rasterDue(&v, &b, @intCast(line));
    try testing.expect(rasterDue(&v, &b, 50));
}

test "graphics that are not there are not stars either" {
    var v = Video{};
    const b = plainBoard();
    // Short enough that the star codes of the later columns run off the end.
    var gfx: [0x8000]u8 = undefined;
    noStars(&gfx);
    ready(&v);

    v.b[test_layer_control / 2] = test_order | test_enables[@intFromEnum(board.Enable.stars2)];
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    for (0..width) |x| try testing.expectEqual(@as(u32, background_entry), v.fb[x]);
}
