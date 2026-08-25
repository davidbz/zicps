//! The Kabuki custom: two views of the sound ROM (DESIGN.md §7.2).
//!
//! The sound board's Z80 sits behind a custom whose decryption differs between
//! an opcode fetch and a data read, with the key in the same battery-backed RAM
//! the rest of the board file comes out of. The same address answers two
//! different bytes depending on what the CPU is doing, so this is not "decrypt
//! the ROM": it is a pure function run once at load into two buffers.
//!
//! The transform is a chain of conditional swaps of adjacent bit pairs,
//! rotations and one XOR. Which pairs are swapped is decided by the address,
//! and the two views differ only in how the address is folded into that
//! selector — which is the whole of the opcode/data split.

const std = @import("std");
const board = @import("board");

pub const Kabuki = board.Kabuki;

/// Which side of the custom is asking.
pub const View = enum { op, data };

/// The fold that turns an address into the sixteen swap decisions. A data
/// read's address is inverted through this mask and offset by one; an opcode's
/// goes in as it is.
const data_fold = 0x1fc0;

fn select(key: Kabuki, addr: u16, view: View) u16 {
    return switch (view) {
        .op => addr +% key.addr,
        .data => (addr ^ data_fold) +% key.addr +% 1,
    };
}

/// Swaps bits 2p and 2p+1.
fn swapPair(v: u8, pair: u2) u8 {
    const shift: u3 = @as(u3, pair) * 2;
    const bits = (v >> shift) & 3;
    const swapped = ((bits & 1) << 1) | (bits >> 1);
    return (v & ~(@as(u8, 3) << shift)) | (swapped << shift);
}

/// Four conditional pair swaps. Each nibble of `key` names the bit of `sel`
/// that decides one pair; `reversed` is which end of the key the first pair
/// takes its nibble from, which is the only difference between the two swap
/// steps of the chain.
fn bitswap(src: u8, key: u16, sel: u8, reversed: bool) u8 {
    var v = src;
    for (0..4) |p| {
        const nibble: u4 = @intCast(if (reversed) (3 - p) * 4 else p * 4);
        const bit: u3 = @truncate(key >> nibble);
        if (sel & (@as(u8, 1) << bit) != 0) v = swapPair(v, @intCast(p));
    }
    return v;
}

/// The low half of the selector drives the swaps around the XOR, the high half
/// the two after it. Both halves of each swap key are used, low half first.
pub fn decodeByte(key: Kabuki, addr: u16, view: View, src: u8) u8 {
    const sel = select(key, addr, view);
    const lo: u8 = @truncate(sel);
    const hi: u8 = @truncate(sel >> 8);

    var v = bitswap(src, @truncate(key.swap1), lo, false);
    v = std.math.rotl(u8, v, 1);
    v = bitswap(v, @truncate(key.swap1 >> 16), lo, true);
    v ^= key.xor;
    v = std.math.rotl(u8, v, 1);
    v = bitswap(v, @truncate(key.swap2), hi, true);
    v = std.math.rotl(u8, v, 1);
    return bitswap(v, @truncate(key.swap2 >> 16), hi, false);
}

/// The same chain backwards. A pair swap is its own inverse, so only the
/// rotations and the order change. This is how a board is *written* rather
/// than read, which is what lets this project encrypt a sound ROM of its own
/// to test the decryption against (DESIGN.md §10).
pub fn encodeByte(key: Kabuki, addr: u16, view: View, plain: u8) u8 {
    const sel = select(key, addr, view);
    const lo: u8 = @truncate(sel);
    const hi: u8 = @truncate(sel >> 8);

    var v = bitswap(plain, @truncate(key.swap2 >> 16), hi, false);
    v = std.math.rotr(u8, v, 1);
    v = bitswap(v, @truncate(key.swap2), hi, true);
    v = std.math.rotr(u8, v, 1);
    v ^= key.xor;
    v = bitswap(v, @truncate(key.swap1 >> 16), lo, true);
    v = std.math.rotr(u8, v, 1);
    return bitswap(v, @truncate(key.swap1), lo, false);
}

/// Decodes a whole ROM into the two buffers the bus reads from. The address a
/// byte is decoded for is where the Z80 sees it, so `op` and `data` are as
/// long as the window and start where it does.
pub fn decode(key: Kabuki, src: []const u8, op: []u8, data: []u8) void {
    std.debug.assert(op.len == src.len and data.len == src.len);
    for (src, 0..) |byte, i| {
        const addr: u16 = @intCast(i);
        op[i] = decodeByte(key, addr, .op, byte);
        data[i] = decodeByte(key, addr, .data, byte);
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// Cadillacs and Dinosaurs' key, as `board.zig`'s parser test uses it: a real
/// dino_key is worth more here than an invented one, because the swap keys are
/// permutations and a made-up pair would not exercise the same paths.
const dino_key = Kabuki{ .swap1 = 0x76543210, .swap2 = 0x24601357, .addr = 0x4343, .xor = 0x43 };

test "what the custom encrypts, the custom decrypts" {
    for ([_]View{ .op, .data }) |view| {
        var addr: u16 = 0;
        while (addr < 0x8000) : (addr += 0x111) {
            for ([_]u8{ 0x00, 0x01, 0x43, 0x7f, 0x80, 0xc9, 0xff }) |plain| {
                const cipher = encodeByte(dino_key, addr, view, plain);
                try testing.expectEqual(plain, decodeByte(dino_key, addr, view, cipher));
            }
        }
    }
}

test "the two views are two different bytes, so a test cannot pass by ignoring them" {
    var differ: usize = 0;
    for (0..0x100) |addr| {
        const src: u8 = @intCast(addr);
        const a = decodeByte(dino_key, @intCast(addr), .op, src);
        const b = decodeByte(dino_key, @intCast(addr), .data, src);
        if (a != b) differ += 1;
    }
    // Not every address happens to disagree; the great majority do.
    try testing.expect(differ > 0xc0);
}

test "0x00 encrypts to a byte with as many ones as the dino_key has" {
    // The weakness the custom is known for, and a check on the bit chain: with
    // no bits set to permute, all that is left of a zero is the XOR.
    const cipher = encodeByte(dino_key, 0x1234, .op, 0x00);
    try testing.expectEqual(@popCount(dino_key.xor), @popCount(cipher));
}

test "a whole ROM decodes into two buffers" {
    var src: [0x100]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @intCast(i);

    var op: [0x100]u8 = undefined;
    var data: [0x100]u8 = undefined;
    decode(dino_key, &src, &op, &data);

    for (src, 0..) |byte, i| {
        try testing.expectEqual(decodeByte(dino_key, @intCast(i), .op, byte), op[i]);
        try testing.expectEqual(decodeByte(dino_key, @intCast(i), .data, byte), data[i]);
    }
}
