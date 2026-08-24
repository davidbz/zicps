//! The video chips' state: CPS-A (DL-0311) and CPS-B-21 (DL-0921).
//!
//! At M0 this is data and two register files. The CPS-A file is fixed across
//! boards; the CPS-B file is mapped by a PAL on the B-board, so where each of
//! its registers lives is in the board file rather than here, and the two reads
//! that answer with something other than a latched value — the board ID and the
//! multiplier — are the protection a game checks before it will boot.
//!
//! Rendering arrives at M1. What is here is what the bus has to be able to
//! reach today.

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

/// Six pages of 32 palettes of 16 entries, copied out of graphics RAM when the
/// palette base register is written.
pub const palette_pages = 6;
pub const palette_page_entries = 32 * 16;
pub const palette_entries = palette_pages * palette_page_entries;

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

/// What an undecoded address on either register file reads back as.
pub const open_bus = 0xffff;

pub const Video = struct {
    a: [a_regs_bytes / 2]u16 = @splat(0),
    b: [board.cps_b_bytes / 2]u16 = @splat(0),
    gfxram: [gfxram_bytes]u8 = @splat(0),
    palette: [palette_entries]u16 = @splat(0),
    /// RGBA, one word of the picture per pixel, handed to the frontend as a
    /// texture and to the headless runner as bytes to hash.
    fb: [width * height]u32 = @splat(0),
};

pub fn readA(v: *const Video, offset: u8) u16 {
    if (offset >= a_regs_bytes) return open_bus;
    return v.a[offset / 2];
}

pub fn writeA(v: *Video, offset: u8, value: u16, mask: u16) void {
    if (offset >= a_regs_bytes) return;
    merge(&v.a[offset / 2], value, mask);
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
    writeA(&v, scroll1_x, 0xffff, 0xffff);
    writeA(&v, scroll1_x, 0x1200, 0xff00);
    try testing.expectEqual(@as(u16, 0x12ff), readA(&v, scroll1_x));
    try testing.expectEqual(@as(u16, open_bus), readA(&v, a_regs_bytes));
}
