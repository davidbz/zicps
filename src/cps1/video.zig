//! CPS-1's half of the video hardware: the object list, the starfields, the
//! protection registers a CPS-B PAL answers, and the order the four passes go
//! down in. The tilemaps, the palette and the register files themselves are the
//! chip pair, not the board, and live in `common/video.zig`.

const std = @import("std");
const board = @import("board");
/// The CPS-A/CPS-B pair the whole family shares. This file is CPS-1's half.
const chip = @import("video");

const Video = chip.Video;
const Line = chip.Line;
const Tilemap = chip.Tilemap;
const width = chip.width;
const height = chip.height;
const first_visible_dot = chip.first_visible_dot;
const first_visible_line = chip.first_visible_line;
const lines_per_frame = chip.lines_per_frame;
const transparent_pen = chip.transparent_pen;
const background_entry = chip.background_entry;
const palette_pages = chip.palette_pages;
const palette_colors = chip.palette_colors;
const palette_page_entries = chip.palette_page_entries;
const palette_page_bytes = chip.palette_page_bytes;
const flip_x_bit = chip.flip_x_bit;
const flip_y_bit = chip.flip_y_bit;
const color_mask = chip.color_mask;
const scroll1 = chip.scroll1;
const scroll2 = chip.scroll2;
const scroll3 = chip.scroll3;
const base = chip.base;
const bankMap = chip.bankMap;
const enabled = chip.enabled;
const gfxPixel = chip.gfxPixel;
const nameOffset = chip.nameOffset;
const toRgba = chip.toRgba;
const writeA = chip.writeA;
const readB = chip.readB;
const writeB = chip.writeB;

/// The object list: 256 sprites of four words — X, Y, code, attribute. The chip
/// draws from its own copy, taken at vblank, so a game can build the next
/// frame's sprites over the top of the one being drawn.
const obj_words = chip.obj_bytes / 2;
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

/// Draws one line of the picture. Scroll registers are read here rather than
/// latched at the top of the frame, which is what makes a mid-frame write to
/// them move the rest of the screen and nothing above it.
///
/// CPS-1 draws its object list from one of the four layer slots, so the sprites
/// go down somewhere in the middle of the tilemaps rather than over all of them.
pub fn renderLine(v: *Video, b: *const board.Board, gfx: []const u8, line: u32, frame: u64) void {
    if (line < first_visible_line or line >= first_visible_line + height) return;

    var l = chip.beginLine(v);
    drawStars(v, b, gfx, &l, line, frame);

    const control = chip.layerControl(v, b);
    for (0..chip.layer_slots) |slot| {
        const which = chip.slotLayer(control, slot);
        if (which == .sprites) {
            drawSprites(v, b, gfx, &l, line);
            continue;
        }
        // Only the layer the sprites are drawn straight after can cut back
        // through them, so only that one leaves a mask behind.
        const masks = slot + 1 < chip.layer_slots and chip.slotLayer(control, slot + 1) == .sprites;
        chip.drawLayer(v, b, gfx, &l, line, which, masks);
    }

    chip.emit(v, &l, line);
}

/// Takes the chip's copy of the object list. The board does this at vblank, and
/// it is why a sprite the 68000 writes now is on screen next frame.
pub fn latchObjects(v: *Video) void {
    const at = base(v, chip.obj_base, chip.obj_align);
    for (&v.obj, 0..) |*byte, i| {
        const from = at + @as(u32, @intCast(i));
        byte.* = if (from < chip.gfxram_bytes) v.gfxram[from] else 0;
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
    .{ .enable = .stars1, .x_reg = chip.stars2_x, .y_reg = chip.stars2_y, .half = star_row_pixels / 2, .page = 5 },
    .{ .enable = .stars2, .x_reg = chip.stars1_x, .y_reg = chip.stars1_y, .half = 0, .page = 4 },
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
    try testing.expectEqual(@as(u16, chip.open_bus), readB(&v, &b, 0x36));
    try testing.expectEqual(@as(u16, chip.open_bus), readB(&v, &b, 0x38));

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
    writeA(&v, &b, chip.scroll1_x, 0xffff, 0xffff);
    writeA(&v, &b, chip.scroll1_x, 0x1200, 0xff00);
    try testing.expectEqual(@as(u16, 0x12ff), chip.readA(&v, chip.scroll1_x));
    try testing.expectEqual(@as(u16, chip.open_bus), chip.readA(&v, chip.a_regs_bytes));
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
    writeA(&v, &b, chip.palette_base, @intCast(at / chip.base_granularity), 0xffff);

    // Every page enabled: each lands where it came from.
    for (0..palette_pages) |page| {
        try testing.expectEqual(@as(u16, @intCast(0x1000 * (page + 1))), v.palette[page * palette_page_entries]);
    }

    // Bit 0 clear: page 0's colours are not lost, they land in page 2 — the
    // first page that *is* enabled. Page 3 then takes its own.
    writeB(&v, &b, test_palette_control, 0x3c, 0xffff);
    writeA(&v, &b, chip.palette_base, @intCast(at / chip.base_granularity), 0xffff);
    try testing.expectEqual(@as(u16, 0x1000), v.palette[2 * palette_page_entries]);
    try testing.expectEqual(@as(u16, 0x2000), v.palette[3 * palette_page_entries]);

    // A clear bit after something has been copied really does skip: page 4 is
    // untouched and keeps what the run above left in it.
    writeB(&v, &b, test_palette_control, 0x2f, 0xffff);
    writeA(&v, &b, chip.palette_base, @intCast(at / chip.base_granularity), 0xffff);
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
    const at = table + nameOffset(m, row, col) * chip.bytes_per_name;
    std.mem.writeInt(u16, v.gfxram[at..][0..2], code, .big);
    std.mem.writeInt(u16, v.gfxram[at + 2 ..][0..2], attr, .big);
}

/// Points the three layers at name tables of their own and gives every palette
/// entry its own index as a colour, so a drawn pixel names the entry it came
/// from.
fn ready(v: *Video) void {
    v.a[chip.scroll1_base / 2] = 0x9000;
    v.a[chip.scroll2_base / 2] = 0x9040;
    v.a[chip.scroll3_base / 2] = 0x9080;
    v.a[chip.obj_base / 2] = 0x9000 + object_table / chip.base_granularity;
    v.a[chip.video_control / 2] = chip.scroll2_on | chip.scroll3_on;
    v.b[test_layer_control / 2] = test_order | test_tilemaps_on;
    for (0..chip.palette_entries) |i| v.colors[i] = @intCast(i);
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
    v.a[chip.scroll1_x / 2] = scroll1.size;
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try testing.expectEqual(unscrolled, v.fb[0]);

    // The map is 64 tiles square, so a whole map's worth of scroll either way
    // lands back on the same tile.
    const map = scroll1.size * chip.name_tiles;
    v.a[chip.scroll1_x / 2] = scroll1.size + map;
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try testing.expectEqual(unscrolled, v.fb[0]);
    v.a[chip.scroll1_x / 2] = @bitCast(@as(i16, @intCast(scroll1.size)) -% @as(i16, @intCast(map)));
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try testing.expectEqual(unscrolled, v.fb[0]);

    // Scrolling down shows the next row of the tile, and one tile of scroll
    // shows the row of the map below.
    v.a[chip.scroll1_x / 2] = scroll1.size;
    v.a[chip.scroll1_y / 2] = 1;
    renderLine(&v, &b, &gfx, first_visible_line, 0);
    try expectPixel(&v, scroll1.page, 7, at1 + scroll1.row_pixels + 8, 0, 0);
    v.a[chip.scroll1_y / 2] = scroll1.size;
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
    poke(&v, scroll2, scroll2_table, line / scroll2.size, 4, tile2, group << chip.priority_group_shift);
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
    v.a[chip.rowscroll_base / 2] = 0x9000 + table / chip.base_granularity;
    std.mem.writeInt(u16, v.gfxram[table + line * 2 ..][0..2], scroll2.size, .big);

    // The table is not read until the video control bit says so.
    renderLine(&v, &b, &gfx, line, 0);
    try testing.expectEqual(@as(u32, background_entry), v.fb[0]);

    v.a[chip.video_control / 2] |= chip.rowscroll_on;
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

    v.a[chip.video_control / 2] |= chip.flip_screen;
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
    v.a[chip.stars1_y / 2] = star_rows - 1;
    renderLine(&v, &b, &gfx, line + 1, 0);
    try testing.expectEqual(@as(u32, 4 * palette_page_entries), v.fb[width + dot]);
}

test "the raster counters reload at the top of the frame and fire at their line" {
    var v = Video{};
    const b = plainBoard();

    // The reload the board comes up with never reaches zero inside a frame.
    for (0..lines_per_frame) |line| try testing.expect(!chip.rasterDue(&v, &b, @intCast(line)));

    writeB(&v, &b, test_raster[0].?, 100, 0xffff);
    for (0..lines_per_frame) |line| {
        try testing.expectEqual(line == 100, chip.rasterDue(&v, &b, @intCast(line)));
    }
    // And again the next frame: the counter is reloaded at line 0, not left
    // wherever the last frame stopped it.
    for (0..lines_per_frame) |line| {
        try testing.expectEqual(line == 100, chip.rasterDue(&v, &b, @intCast(line)));
    }

    // The counter reads back live, and the top bit of a write reloads it there
    // and then rather than at the top of the next frame.
    _ = chip.rasterDue(&v, &b, 0);
    _ = chip.rasterDue(&v, &b, 1);
    try testing.expectEqual(@as(u16, 99), readB(&v, &b, test_raster[0].?));
    writeB(&v, &b, test_raster[0].?, chip.raster_reload_now | 10, 0xffff);
    try testing.expectEqual(@as(u16, 10), readB(&v, &b, test_raster[0].?));
    for (2..12) |line| try testing.expectEqual(line == 11, chip.rasterDue(&v, &b, @intCast(line)));

    // The second counter is its own: a board with two of them can interrupt
    // twice a frame.
    writeB(&v, &b, test_raster[1].?, 50, 0xffff);
    try testing.expect(!chip.rasterDue(&v, &b, 0));
    for (1..50) |line| _ = chip.rasterDue(&v, &b, @intCast(line));
    try testing.expect(chip.rasterDue(&v, &b, 50));
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
