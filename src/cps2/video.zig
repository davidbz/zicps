//! CPS-2's half of the video hardware: the object list the board keeps in RAM
//! of its own, the ranking the object output latch carries, and the order the
//! passes go down in. The tilemaps, the palette and the register files are the
//! chip pair, not the board, and live in `common/video.zig`.
//!
//! What moved is where the sprites sit. CPS-1 draws its object list in one of
//! the four CPS-B layer slots, so every sprite on the screen is over the same
//! two tilemaps and under the same one. CPS-2 draws all of its sprites last,
//! over every tilemap, and settles the order a pixel at a time: each of the
//! three tilemap passes leaves a bit in the priority plane, and a sprite's own
//! three-bit priority picks the mask that says which of those bits it goes
//! under. The layer slot the object list still names is only there to say where
//! in the ranking the sprites are; the tilemaps close up behind it.

const std = @import("std");
const board = @import("board");
/// The CPS-A/CPS-B pair the whole family shares. This file is CPS-2's half.
const chip = @import("video");
const cps2 = @import("cps2");

const Line = chip.Line;
const width = chip.width;
const height = chip.height;
const first_visible_dot = chip.first_visible_dot;
const first_visible_line = chip.first_visible_line;
const transparent_pen = chip.transparent_pen;
const palette_colors = chip.palette_colors;
const color_mask = chip.color_mask;
const gfxPixel = chip.gfxPixel;

/// The object list: 1024 sprites of four words — X, Y, code, attribute. It is
/// 8 KiB of the board's own RAM rather than a window into graphics RAM, and the
/// chip draws from its own copy of it, taken at vblank.
const obj_words = cps2.objram_bytes / 2;
const sprite_words = 4;
const sprite_size = 16;
const sprite_pixels = sprite_size * sprite_size;
/// The list ends at the first entry whose Y word is 0x8000 or over, or whose
/// attribute word has 0xff on top.
const end_y = 0x8000;
const end_attr = 0xff00;
/// Sprite coordinates are ten bits here, not CPS-1's nine.
const sprite_pos_mask = 0x3ff;
/// The top three bits of X are the sprite's priority, and two bits of Y are the
/// top of its code: 0x40000 tiles, where CPS-1 addressed 0x10000 through a bank
/// mapper.
const sprite_priority_shift = 13;
const code_high_mask = 0x6000;
const code_high_shift = 3;
/// Bit 7 of the attribute word asks for the offsets in the output latch to be
/// added to this sprite — which is how a game shifts a whole layer of them
/// without rewriting the list, as Marvel vs. Capcom's ending credits do.
const offset_bit = 0x0080;
/// A sprite can be a block of up to sixteen tiles each way, counted from zero.
const block_x_mask = 0x0f00;
const block_x_shift = 8;
const block_y_mask = 0xf000;
const block_y_shift = 12;
/// Across a block the code's low nibble wraps: a block never runs out of its
/// own row of sixteen codes. Down it, each row of tiles is a whole such row on.
const block_wrap = 0x0f;
const block_row_step = 0x10;

/// The object output latch, by word. Three of the six say nothing this needs:
/// one is an object base the hardware does not appear to use, and two are only
/// ever written with the handful of values MAME lists.
const obj_pri_word = 0x04 / 2;
const obj_x_word = 0x08 / 2;
const obj_y_word = 0x0a / 2;
/// What the two offsets hold when a game is panning nothing: where the top left
/// of the visible picture is, which is the same corner the tilemaps scroll
/// against.
const home_x_offset = first_visible_dot;
const home_y_offset = first_visible_line;

/// The bit each tilemap pass leaves in the priority plane, front pass last.
const pass_bits = [_]u8{ 1, 2, 4 };
/// What a drawn sprite pixel leaves there: past every value a tilemap can put
/// down, so a sprite in front of this one is never cut by a layer this one has
/// already covered.
const sprite_drawn = 31;

/// Draws one line of the picture. As on CPS-1 the scroll registers are read
/// here rather than latched at the top of the frame, so a mid-frame write to
/// them moves the rest of the screen and nothing above it. The object list and
/// its ranking are the other way round: both are whatever the last vblank took.
pub fn renderLine(c: *cps2.Machine, line: u32) void {
    if (line < first_visible_line or line >= first_visible_line + height) return;

    var l = chip.beginLine(&c.v);
    const order = layerOrder(chip.layerControl(&c.v, &c.board), c.pri_ctrl);
    for (order.layers, pass_bits) |which, bit| {
        chip.drawLayer(&c.v, &c.board, c.rom.gfx, &l, line, which, .{ .pass = bit });
    }
    drawSprites(c, &l, line, order.masks);

    chip.emit(&c.v, &l, line);
}

/// Takes the chip's copy of the object list, and the ranking that goes with it.
/// The board does this at vblank, which is why a sprite the 68000 writes now is
/// on screen next frame — and why a game fills the far bank of object RAM and
/// then flips: the near bank is the one being read.
pub fn latchObjects(c: *cps2.Machine) void {
    c.obj = c.objram[c.objram_bank];
    c.pri_ctrl = c.output[obj_pri_word];
}

// ---------------------------------------------------------------- the order

/// The three tilemap passes and the eight sprite masks.
const Order = struct {
    layers: [pass_bits.len]board.Layer,
    /// Indexed by a sprite's priority: which values of the priority plane that
    /// sprite is *hidden* under, as a bit each. Plane value 0 is bare
    /// background, 1 is the back pass alone, 3 is the back two, and so on.
    masks: [8]u8,
};

/// Works out the order out of the CPS-B layer control and the priority word the
/// output latch held at vblank. Four bits of that word per layer say how high
/// that layer ranks; a sprite of priority `i` goes under every layer ranked `i`
/// or higher, and the masks are that statement turned into plane values.
///
/// A sprite of priority 0 is under everything including the background, so it
/// is not drawn at all. That is what the hardware does and what games expect of
/// it: priority 0 is how a sprite is parked without taking it off the list.
fn layerOrder(control: u16, pri_ctrl: u16) Order {
    var layers: [chip.layer_slots]board.Layer = undefined;
    var rank: [chip.layer_slots]u8 = undefined;
    for (&layers, &rank, 0..) |*layer, *r, slot| {
        layer.* = chip.slotLayer(control, slot);
        const shift: u4 = @intCast(@as(u8, @intFromEnum(layer.*)) * 4);
        r.* = @truncate(pri_ctrl >> shift & 0xf);
    }

    // Take the object list out of the order: the slots behind it shuffle up and
    // the sprites fall to the back, where the pass loop ignores them. Their own
    // rank is not lost — it is the rank of what the sprites were in front of
    // that the masks are built from.
    for (0..pass_bits.len) |i| {
        if (layers[i] != .sprites) continue;
        layers[i] = layers[i + 1];
        rank[i] = rank[i + 1];
        layers[i + 1] = .sprites;
    }

    var masks: [8]u8 = undefined;
    // A plane value with more than one pass in it takes the front pass's word
    // for it, unless a pass in front of another one also outranks it — then the
    // sprite is over the pair. These three are that reading of the six ways two
    // passes can overlap.
    var mask0: u8 = 0xaa;
    var mask1: u8 = 0xcc;
    if (rank[0] > rank[1]) mask0 &= ~@as(u8, 0x88);
    if (rank[0] > rank[2]) mask0 &= ~@as(u8, 0xa0);
    if (rank[1] > rank[2]) mask1 &= ~@as(u8, 0xc0);

    masks[0] = 0xff;
    for (masks[1..], 1..) |*mask, i| {
        // Under all three: hidden wherever anything drew, which is every plane
        // value but bare background.
        if (i <= rank[0] and i <= rank[1] and i <= rank[2]) {
            mask.* = 0xfe;
            continue;
        }
        mask.* = 0;
        if (i <= rank[0]) mask.* |= mask0;
        if (i <= rank[1]) mask.* |= mask1;
        if (i <= rank[2]) mask.* |= 0xf0;
    }
    return .{ .layers = layers[0..pass_bits.len].*, .masks = masks };
}

// -------------------------------------------------------------- the sprites

/// One entry of the list as the chip reads it, with the two words that are
/// really three fields each already taken apart.
const Sprite = struct {
    x: u32,
    y: u32,
    code: u32,
    color: u32,
    priority: u3,
    flip_x: bool,
    flip_y: bool,
    nx: u32,
    ny: u32,
};

/// Sprites are drawn last of the list first, so the first entry a game writes
/// ends up on top of the ones after it.
fn drawSprites(c: *cps2.Machine, l: *Line, line: u32, masks: [8]u8) void {
    var i = lastSprite(c);
    while (i >= 0) : (i -= sprite_words) {
        drawSprite(c, l, line, masks, decode(c, @intCast(i)));
    }
}

/// The list is 1024 entries long but ends early, at the first end marker — the
/// entry *before* which is the last one drawn.
fn lastSprite(c: *const cps2.Machine) i32 {
    var at: u32 = 0;
    while (at < obj_words) : (at += sprite_words) {
        if (objWord(c, at + 1) >= end_y or objWord(c, at + 3) >= end_attr) {
            return @as(i32, @intCast(at)) - sprite_words;
        }
    }
    return obj_words - sprite_words;
}

fn objWord(c: *const cps2.Machine, word: u32) u16 {
    return std.mem.readInt(u16, c.obj[word * 2 ..][0..2], .big);
}

fn decode(c: *const cps2.Machine, at: u32) Sprite {
    const x = objWord(c, at);
    const y = objWord(c, at + 1);
    const attr = objWord(c, at + 3);

    // A game that is panning nothing leaves the latch holding where the corner
    // of the picture is, and every sprite then sits at the coordinate it says.
    // Anything else moves the whole plane by the difference. A sprite that asks
    // for the offset back cancels the pan and is placed against that corner
    // instead, which is how a game shifts one layer of sprites and not the
    // rest.
    const asks = attr & offset_bit != 0;
    const x_offset = home_x_offset -% c.output[obj_x_word] +% if (asks) c.output[obj_x_word] else 0;
    const y_offset = home_y_offset -% c.output[obj_y_word] +% if (asks) c.output[obj_y_word] else 0;

    return .{
        .x = x +% x_offset,
        .y = y +% y_offset,
        .code = @as(u32, objWord(c, at + 2)) + (@as(u32, y & code_high_mask) << code_high_shift),
        .color = @as(u32, attr & color_mask) * palette_colors,
        .priority = @truncate(x >> sprite_priority_shift),
        .flip_x = attr & chip.flip_x_bit != 0,
        .flip_y = attr & chip.flip_y_bit != 0,
        .nx = ((attr & block_x_mask) >> block_x_shift) + 1,
        .ny = ((attr & block_y_mask) >> block_y_shift) + 1,
    };
}

/// One entry: a 16x16 tile, or a block of up to 16 by 16 of them from
/// consecutive codes. Only the tiles this line crosses are drawn.
fn drawSprite(c: *cps2.Machine, l: *Line, line: u32, masks: [8]u8, s: Sprite) void {
    var down: u32 = 0;
    while (down < s.ny) : (down += 1) {
        const sy = (s.y + down * sprite_size) & sprite_pos_mask;
        if (line < sy or line >= sy + sprite_size) continue;
        const ty = if (s.flip_y) sprite_size - 1 - (line - sy) else line - sy;
        const row = if (s.flip_y) s.ny - 1 - down else down;

        var across: u32 = 0;
        while (across < s.nx) : (across += 1) {
            const sx = (s.x + across * sprite_size) & sprite_pos_mask;
            const col = if (s.flip_x) s.nx - 1 - across else across;
            drawRow(c, l, masks, s, blockCode(s, col, row), sx, ty);
        }
    }
}

/// Which code a tile of a block draws. The nibble wrap is only on the pass with
/// neither flip, which is where MAME found it needed and where the CPS-1 code
/// wants it too; a flipped block counts straight through instead.
fn blockCode(s: Sprite, col: u32, row: u32) u32 {
    const at = if (s.flip_x or s.flip_y)
        s.code + col
    else
        (s.code & ~@as(u32, block_wrap)) + ((s.code + col) & block_wrap);
    return at + block_row_step * row;
}

fn drawRow(c: *cps2.Machine, l: *Line, masks: [8]u8, s: Sprite, tile: u32, sx: u32, ty: u32) void {
    const src = tile * sprite_pixels + ty * sprite_size;
    const mask = masks[s.priority];

    for (0..sprite_size) |px| {
        const dot = sx + px;
        if (dot < first_visible_dot or dot >= first_visible_dot + width) continue;
        const dx = dot - first_visible_dot;
        const at: u32 = @intCast(if (s.flip_x) sprite_size - 1 - px else px);
        const pen = gfxPixel(c.rom.gfx, src + at);
        if (pen == transparent_pen) continue;

        // A sprite pixel a layer covers is still a sprite pixel: it claims the
        // plane whether or not it is the one seen there.
        const under = l.prio[dx];
        const hidden = under < masks.len and mask >> @intCast(under) & 1 != 0;
        l.prio[dx] = sprite_drawn;
        if (!hidden) l.color[dx] = c.v.colors[s.color + pen];
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A board with nothing on it but the layer control, which is all the sprite
/// tests need: the tilemaps stay off, so the priority plane is whatever the
/// test puts in it.
const test_layer_control = 0x00;
/// Back to front: scroll1, the object list, scroll2, scroll3.
const test_order = 1 << 6 | 0 << 8 | 2 << 10 | 3 << 12;

fn plainMachine(gfx: []u8) cps2.Machine {
    var c = cps2.Machine{
        .board = .{ .system = .cps2, .layer_control = test_layer_control },
        .rom = .empty,
    };
    c.rom.gfx = gfx;
    c.v.b[test_layer_control / 2] = test_order;
    // Every palette entry holding its own index, so a drawn pixel names the
    // entry it came out of.
    for (0..chip.palette_entries) |i| c.v.colors[i] = @intCast(i);
    return c;
}

/// Writes one object list entry into the bank the CPU has, in words.
fn object(c: *cps2.Machine, at: u32, x: u16, y: u16, code: u16, attr: u16) void {
    const bank = &c.objram[c.objram_bank];
    for ([_]u16{ x, y, code, attr }, 0..) |word, i| {
        std.mem.writeInt(u16, bank[(at + i) * 2 ..][0..2], word, .big);
    }
}

/// Graphics whose every pixel names its own index modulo the transparent pen,
/// so a drawn pixel says where in the ROM it was read from.
fn stripedGfx(gfx: []u8) void {
    for (gfx, 0..) |*pixel, i| pixel.* = @intCast(i % transparent_pen);
}

/// A sprite of priority 1 at the top left of the visible picture: coordinates
/// are in the same 1024-dot space the tilemaps scroll in, where that corner is
/// (64, 16) and not the origin.
const sprite_x = 1 << sprite_priority_shift | first_visible_dot;
const sprite_y = first_visible_line;

test "the object list ends at the first marker in it" {
    var gfx: [0x100]u8 = @splat(0);
    var c = plainMachine(&gfx);

    // A list with no marker at all runs to the end of the RAM.
    try testing.expectEqual(@as(i32, obj_words - sprite_words), lastSprite(&c));

    object(&c, 0, 0, 0, 0, 0);
    object(&c, 4, 0, 0x8000, 0, 0);
    latchObjects(&c);
    try testing.expectEqual(@as(i32, 0), lastSprite(&c));

    // The attribute marker ends it just the same, and an entry that is itself
    // the first is a list with nothing in it.
    object(&c, 0, 0, 0, 0, 0xff00);
    latchObjects(&c);
    try testing.expectEqual(@as(i32, -4), lastSprite(&c));
}

test "the chip draws the bank the CPU flipped away from, as of the last vblank" {
    var gfx: [0x100]u8 = @splat(0);
    var c = plainMachine(&gfx);

    // A game fills the far bank through 0x708000 and then flips to it.
    cps2.write16(&c, cps2.objram1_lo, 0x1234);
    cps2.write16(&c, cps2.objram_bank_lo, 1);
    // Nothing is on screen until the vblank edge takes the copy.
    try testing.expectEqual(@as(u16, 0), objWord(&c, 0));
    latchObjects(&c);
    try testing.expectEqual(@as(u16, 0x1234), objWord(&c, 0));

    // And the ranking comes with it: a write after the edge waits its turn.
    c.output[obj_pri_word] = 0x4210;
    try testing.expectEqual(@as(u16, 0), c.pri_ctrl);
    latchObjects(&c);
    try testing.expectEqual(@as(u16, 0x4210), c.pri_ctrl);
}

test "the object slot comes out of the order and the rest are ranked" {
    // Pinned against MAME's own `render_layers` — mame0289 cps2.cpp, compiled
    // and run for these two words.
    const order = layerOrder(test_order, 0x4210);
    try testing.expectEqual([_]board.Layer{ .scroll1, .scroll2, .scroll3 }, order.layers);
    try testing.expectEqual([_]u8{ 0xff, 0xfe, 0xfc, 0xf0, 0xf0, 0, 0, 0 }, order.masks);

    // The same layers with the back one ranked over the two in front of it: a
    // sprite is over the pair wherever the front pass drew alone.
    const over = layerOrder(test_order, 0x2140);
    try testing.expectEqual([_]u8{ 0xff, 0xfe, 0xf2, 0x02, 0x02, 0, 0, 0 }, over.masks);
}

test "a sprite lands where the offsets put it, flipped and blocked as asked" {
    var gfx: [0x2000]u8 = undefined;
    stripedGfx(&gfx);
    var c = plainMachine(&gfx);
    c.output[obj_x_word] = home_x_offset;
    c.output[obj_y_word] = home_y_offset;
    const masks = [_]u8{0} ** 8;

    // Priority 1, at the top left of the visible picture, one tile of code 1.
    object(&c, 0, sprite_x, sprite_y, 1, 0);
    object(&c, sprite_words, 0, end_y, 0, 0);
    latchObjects(&c);

    var l = chip.beginLine(&c.v);
    drawSprites(&c, &l, first_visible_line, masks);
    for (0..sprite_size) |x| {
        try testing.expectEqual(@as(u32, @intCast((sprite_pixels + x) % transparent_pen)), l.color[x]);
    }
    // And nothing outside the tile.
    try testing.expectEqual(c.v.colors[chip.background_entry], l.color[sprite_size]);

    // Flipped across, the same row reads back the other way round.
    object(&c, 0, sprite_x, sprite_y, 1, chip.flip_x_bit);
    latchObjects(&c);
    l = chip.beginLine(&c.v);
    drawSprites(&c, &l, first_visible_line, masks);
    for (0..sprite_size) |x| {
        const at = sprite_pixels + sprite_size - 1 - x;
        try testing.expectEqual(@as(u32, @intCast(at % transparent_pen)), l.color[x]);
    }

    // A block two tiles across draws the next code beside the first, and its
    // low nibble wraps inside its own row of sixteen: code 0x0f is followed by
    // code 0x00, not 0x10.
    object(&c, 0, sprite_x, sprite_y, 0x0f, 0x0100);
    latchObjects(&c);
    l = chip.beginLine(&c.v);
    drawSprites(&c, &l, first_visible_line, masks);
    try testing.expectEqual(@as(u32, 0x0f * sprite_pixels % transparent_pen), l.color[0]);
    try testing.expectEqual(@as(u32, 0), l.color[sprite_size]);

    // The offsets pan the whole object plane: eight less across the latch is
    // eight further right on screen.
    c.output[obj_x_word] = home_x_offset - 8;
    object(&c, 0, sprite_x, sprite_y, 1, 0);
    latchObjects(&c);
    l = chip.beginLine(&c.v);
    drawSprites(&c, &l, first_visible_line, masks);
    try testing.expectEqual(c.v.colors[chip.background_entry], l.color[7]);
    try testing.expectEqual(@as(u32, sprite_pixels % transparent_pen), l.color[8]);

    // A sprite that asks for the offset back cancels the pan, and is placed
    // against the corner of the picture rather than in the chip's own space.
    object(&c, 0, 1 << sprite_priority_shift, 0, 1, offset_bit);
    latchObjects(&c);
    l = chip.beginLine(&c.v);
    drawSprites(&c, &l, first_visible_line, masks);
    try testing.expectEqual(@as(u32, sprite_pixels % transparent_pen), l.color[0]);
}

test "a sprite is hidden under the passes its mask names and drawn over the rest" {
    var gfx: [0x2000]u8 = undefined;
    stripedGfx(&gfx);
    var c = plainMachine(&gfx);
    c.output[obj_x_word] = home_x_offset;
    c.output[obj_y_word] = home_y_offset;

    object(&c, 0, sprite_x, sprite_y, 1, 0);
    object(&c, sprite_words, 0, end_y, 0, 0);
    latchObjects(&c);

    // Hidden under the back pass, over the front two: mask 0x02 is plane value
    // 1, the back pass drawing alone.
    var l = chip.beginLine(&c.v);
    l.prio[0] = 1;
    l.prio[1] = 2;
    l.prio[2] = 3;
    const tilemap = c.v.colors[chip.background_entry];
    l.color[0] = tilemap;
    l.color[1] = tilemap;
    l.color[2] = tilemap;

    var masks = [_]u8{0} ** 8;
    masks[1] = 0x02;
    drawSprites(&c, &l, first_visible_line, masks);

    try testing.expectEqual(tilemap, l.color[0]);
    try testing.expectEqual(@as(u32, (sprite_pixels + 1) % transparent_pen), l.color[1]);
    try testing.expectEqual(@as(u32, (sprite_pixels + 2) % transparent_pen), l.color[2]);
    // Drawn or not, the pixel is the sprites' now.
    try testing.expectEqual(@as(u8, sprite_drawn), l.prio[0]);
}

test "a line of the picture is the object list over the layers, ranked" {
    var gfx: [0x2000]u8 = undefined;
    stripedGfx(&gfx);
    var c = plainMachine(&gfx);
    c.output[obj_x_word] = home_x_offset;
    c.output[obj_y_word] = home_y_offset;
    // Every layer ranked over a priority-1 sprite: mask 0xfe, which hides it
    // under anything a pass drew and leaves it over bare background.
    c.output[obj_pri_word] = 0x4210;
    object(&c, 0, sprite_x, sprite_y, 1, 0);
    object(&c, sprite_words, 0, end_y, 0, 0);
    latchObjects(&c);

    // The tilemaps are off here, so what reaches the framebuffer is the sprite
    // over the background, and only on the sixteen lines it covers.
    renderLine(&c, first_visible_line);
    renderLine(&c, first_visible_line + sprite_size);
    try testing.expectEqual(@as(u32, sprite_pixels % transparent_pen), c.v.fb[0]);
    try testing.expectEqual(c.v.colors[chip.background_entry], c.v.fb[sprite_size * width]);
}
