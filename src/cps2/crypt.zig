//! CPS-2's opcode encryption, and the twenty-byte key that undoes it.
//!
//! The B-board carries a battery-backed key. Everything the 68000 *fetches* is
//! enciphered with it; everything it *reads* is in clear, which is why the CPU
//! needs a second view of the same ROM rather than a decoded copy in place.
//! `machine.zig` hands z68k that second view through `setProgram`.
//!
//! The cipher is two four-round Feistel networks, broken by Andreas Naive and
//! written up by Nicola Salmoria: the low sixteen bits of the address go
//! through the first network under the 64-bit master key, the result becomes
//! the key for the second, and the second enciphers the word. So every word at
//! the same address modulo 0x10000 shares a key schedule, and the whole region
//! is decrypted once at load in that order — 65,536 schedules rather than one
//! per word.
//!
//! The s-boxes were chosen so that an all-ones key is what a board with a flat
//! battery does: `readKey` gives one for a set with no key file, and the board
//! loads and says so rather than being refused.

const std = @import("std");

/// What the key ROM holds. MAME's region is padded to 0x20; only the first
/// twenty bytes are the key.
pub const key_bytes = 20;

pub const Key = struct {
    /// The 64-bit master key, high word first.
    master: [2]u32,
    /// The word addresses the encryption covers, inclusive — a `>= lower and
    /// <= upper` pair, and `upper` is one past the region's last word because
    /// MAME's is too and a board file's set has to decrypt the same way.
    lower: u32,
    upper: u32,
    /// The battery is gone: the key reads as erased and only the top 64 KiB is
    /// nominally covered, which for every real program ROM means nothing is
    /// decrypted at all and the board shows its own error screen.
    dead: bool,
};

/// Reads the key ROM. A region that is missing or short is read as erased,
/// because that is what a board whose battery has run down holds.
pub fn readKey(bytes: []const u8) Key {
    var decoded: [10]u16 = @splat(0);
    for (0..decoded.len * 16) |b| {
        // The key is wired to the ROM through a rotation: bit b of the key
        // comes from bit (317 - b) mod 160 of what the chip holds.
        const bit = (317 - b) % 160;
        const byte: u8 = if (bit / 8 < bytes.len) bytes[bit / 8] else 0xff;
        if ((byte >> @intCast((bit ^ 7) % 8)) & 1 != 0)
            decoded[b / 16] |= @as(u16, 0x8000) >> @intCast(b % 16);
    }

    // decoded[4..7] are the watchdog instruction, decoded[7] and decoded[8] are
    // constants, and decoded[9] is how much of the program the key covers.
    const master = [2]u32{
        (@as(u32, decoded[0]) << 16) | decoded[1],
        (@as(u32, decoded[2]) << 16) | decoded[3],
    };
    if (decoded[9] == 0xffff) return .{
        .master = master,
        .lower = 0xff0000 / 2,
        .upper = 0xffffff / 2,
        .dead = true,
    };
    const upper = (((~@as(u32, decoded[9]) & 0x3ff) << 14) | 0x3fff) + 1;
    return .{ .master = master, .lower = 0, .upper = upper / 2, .dead = false };
}

/// Decrypts `rom` into `dec`, both the program region as the 68000 reads it:
/// big-endian words, same length. Outside the key's range the word is copied,
/// so `dec` is a complete second program either way.
pub fn decrypt(rom: []const u8, dec: []u8, key: Key) void {
    std.debug.assert(rom.len == dec.len);
    const words = rom.len / 2;

    var key1 = expand(fn1_key_bits, key.master);
    // The s-boxes with fewer than six inputs take the missing bits from the
    // key, and these are them.
    tweak(&key1[0], 1, 4);
    tweak(&key1[0], 2, 5);
    tweak(&key1[0], 8, 11);
    tweak(&key1[1], 0, 5);
    tweak(&key1[1], 8, 11);
    tweak(&key1[2], 1, 5);
    tweak(&key1[2], 8, 11);

    for (0..0x10000) |i| {
        const seed = feistel(@intCast(i), fn1_group_a, fn1_group_b, &fn1_rounds, key1);
        var subkey = expandSubkey(seed);
        subkey[0] ^= key.master[0];
        subkey[1] ^= key.master[1];

        var key2 = expand(fn2_key_bits, subkey);
        tweak(&key2[0], 0, 5);
        tweak(&key2[0], 6, 11);
        tweak(&key2[1], 0, 5);
        tweak(&key2[1], 1, 4);
        tweak(&key2[2], 2, 5);
        tweak(&key2[2], 3, 4);
        tweak(&key2[2], 7, 11);
        tweak(&key2[3], 1, 5);

        var a = i;
        while (a < words) : (a += 0x10000) {
            const word = std.mem.readInt(u16, rom[a * 2 ..][0..2], .big);
            const plain = if (a >= key.lower and a <= key.upper)
                feistel(word, fn2_group_a, fn2_group_b, &fn2_rounds, key2)
            else
                word;
            std.mem.writeInt(u16, dec[a * 2 ..][0..2], plain, .big);
        }
    }
}

// ------------------------------------------------------------ the two networks

/// Which bit of the word each half of the network is built from. The two halves
/// together are every bit of the sixteen, in an order that is part of the key
/// schedule rather than anything meaningful.
const fn1_group_a = [8]u4{ 10, 4, 6, 7, 2, 13, 15, 14 };
const fn1_group_b = [8]u4{ 0, 1, 3, 5, 8, 9, 11, 12 };
const fn2_group_a = [8]u4{ 6, 0, 2, 13, 1, 4, 14, 7 };
const fn2_group_b = [8]u4{ 3, 5, 9, 10, 8, 15, 12, 11 };

fn gather(val: u16, comptime bits: [8]u4) u8 {
    var out: u8 = 0;
    for (bits, 0..) |bit, i| out |= @as(u8, @intCast((val >> bit) & 1)) << @intCast(i);
    return out;
}

fn scatter(val: u8, comptime bits: [8]u4) u16 {
    var out: u16 = 0;
    for (bits, 0..) |bit, i| out |= @as(u16, (val >> @intCast(i)) & 1) << bit;
    return out;
}

/// One round: four s-boxes over the same eight bits, each taking six bits of
/// the round key and contributing two bits of the result.
fn round(in: u8, boxes: *const [4]Optimised, key: u32) u8 {
    var out: u8 = 0;
    for (boxes, 0..) |*box, i| {
        const sub: u6 = @truncate(key >> @intCast(i * 6));
        out |= box.output[box.input_lookup[in] ^ sub];
    }
    return out;
}

fn feistel(val: u16, comptime a: [8]u4, comptime b: [8]u4, rounds: *const [4][4]Optimised, key: [4]u32) u16 {
    var l = gather(val, b);
    var r = gather(val, a);
    l ^= round(r, &rounds[0], key[0]);
    r ^= round(l, &rounds[1], key[1]);
    l ^= round(r, &rounds[2], key[2]);
    r ^= round(l, &rounds[3], key[3]);
    return scatter(l, a) | scatter(r, b);
}

// ------------------------------------------------------------ the key schedule

/// Spreads the 64-bit key over the four 24-bit round keys, one bit at a time.
/// Bits repeat: the table is a selection, not a permutation.
fn expand(comptime bits: [96]u8, src: [2]u32) [4]u32 {
    var out: [4]u32 = @splat(0);
    for (bits, 0..) |bit, i|
        out[i / 24] |= ((src[bit / 32] >> @intCast(bit % 32)) & 1) << @intCast(i % 24);
    return out;
}

/// The first network's sixteen-bit result, blown back up to 64 bits. Each row
/// of the table is a permutation of the seed's bits.
fn expandSubkey(seed: u16) [2]u32 {
    var out: [2]u32 = @splat(0);
    for (subkey_bits, 0..) |bit, i|
        out[i / 32] |= @as(u32, (seed >> @intCast(bit)) & 1) << @intCast(i % 32);
    return out;
}

/// One of the fixups that feed a key bit to an s-box input the word does not
/// reach. Order matters: each reads the value the one before it left.
fn tweak(key: *u32, from: u5, to: u5) void {
    key.* ^= ((key.* >> from) & 1) << to;
}

// ----------------------------------------------------------------- the s-boxes

/// An s-box as the hardware has it: six inputs, two outputs, sixty-four
/// entries. An input of -1 is a bit that comes from the key alone.
const Sbox = struct {
    table: [64]u8,
    inputs: [6]i8,
    outputs: [2]u8,
};

/// The same box turned into two lookups, which is how it is actually run: the
/// eight input bits pick a six-bit index, the round key is XORed into that, and
/// the table entry is already positioned in the byte it contributes to.
const Optimised = struct {
    input_lookup: [256]u8,
    output: [64]u8,
};

fn optimise(comptime boxes: [4]Sbox) [4]Optimised {
    @setEvalBranchQuota(200_000);
    var out: [4]Optimised = undefined;
    for (boxes, &out) |box, *o| {
        for (&o.input_lookup, 0..) |*slot, val| {
            slot.* = 0;
            for (box.inputs, 0..) |in, i| {
                if (in < 0) continue;
                slot.* |= @as(u8, @intCast((val >> @intCast(in)) & 1)) << @intCast(i);
            }
        }
        for (&o.output, box.table) |*slot, entry| {
            slot.* = 0;
            if (entry & 1 != 0) slot.* |= @as(u8, 1) << @intCast(box.outputs[0]);
            if (entry & 2 != 0) slot.* |= @as(u8, 1) << @intCast(box.outputs[1]);
        }
    }
    return out;
}

const fn1_rounds = [4][4]Optimised{
    optimise(fn1_r1_boxes),
    optimise(fn1_r2_boxes),
    optimise(fn1_r3_boxes),
    optimise(fn1_r4_boxes),
};

const fn2_rounds = [4][4]Optimised{
    optimise(fn2_r1_boxes),
    optimise(fn2_r2_boxes),
    optimise(fn2_r3_boxes),
    optimise(fn2_r4_boxes),
};

const fn1_key_bits = [96]u8{
    33, 58, 49, 36, 0,  31,
    22, 30, 3,  16, 5,  53,
    10, 41, 23, 19, 27, 39,
    43, 6,  34, 12, 61, 21,
    48, 13, 32, 35, 6,  42,
    43, 14, 21, 41, 52, 25,
    18, 47, 46, 37, 57, 53,
    20, 8,  55, 54, 59, 60,
    27, 33, 35, 18, 8,  15,
    63, 1,  50, 44, 16, 46,
    5,  4,  45, 51, 38, 25,
    13, 11, 62, 29, 48, 2,
    59, 61, 62, 56, 51, 57,
    54, 9,  24, 63, 22, 7,
    26, 42, 45, 40, 23, 14,
    2,  31, 52, 28, 44, 17,
};

const fn2_key_bits = [96]u8{
    34, 9,  32, 24, 44, 54,
    38, 61, 47, 13, 28, 7,
    29, 58, 18, 1,  20, 60,
    15, 6,  11, 43, 39, 19,
    63, 23, 16, 62, 54, 40,
    31, 3,  56, 61, 17, 25,
    47, 38, 55, 57, 5,  4,
    15, 42, 22, 7,  2,  19,
    46, 37, 29, 39, 12, 30,
    49, 57, 31, 41, 26, 27,
    24, 36, 11, 63, 33, 16,
    56, 62, 48, 60, 59, 32,
    12, 30, 53, 48, 10, 0,
    50, 35, 3,  59, 14, 49,
    51, 45, 44, 2,  21, 33,
    55, 52, 23, 28, 8,  26,
};

const subkey_bits = [64]u8{
    5,  10, 14, 9, 4,  0,  15, 6,  1,  8,  3,  2,  12, 7, 13, 11,
    5,  12, 7,  2, 13, 11, 9,  14, 4,  1,  6,  10, 8,  0, 15, 3,
    4,  10, 2,  0, 6,  9,  12, 1,  11, 7,  15, 8,  13, 5, 14, 3,
    14, 11, 12, 7, 4,  5,  2,  10, 1,  15, 0,  9,  8,  6, 13, 3,
};

const fn1_r1_boxes = [4]Sbox{
    .{
        .table = .{ 0, 2, 2, 0, 1, 0, 1, 1, 3, 2, 0, 3, 0, 3, 1, 2, 1, 1, 1, 2, 1, 3, 2, 2, 2, 3, 3, 2, 1, 1, 1, 2, 2, 2, 0, 0, 3, 1, 3, 1, 1, 1, 3, 0, 0, 1, 0, 0, 1, 2, 2, 1, 2, 3, 2, 2, 2, 3, 1, 3, 2, 0, 1, 3 },
        .inputs = .{ 3, 4, 5, 6, -1, -1 },
        .outputs = .{ 3, 6 },
    },
    .{
        .table = .{ 3, 0, 2, 2, 2, 1, 1, 1, 1, 2, 1, 0, 0, 0, 2, 3, 2, 3, 1, 3, 0, 0, 0, 2, 1, 2, 2, 3, 0, 3, 3, 3, 0, 1, 3, 2, 3, 3, 3, 1, 1, 1, 1, 2, 0, 1, 2, 1, 3, 2, 3, 1, 1, 3, 2, 2, 2, 3, 1, 3, 2, 3, 0, 0 },
        .inputs = .{ 0, 1, 2, 4, 7, -1 },
        .outputs = .{ 2, 7 },
    },
    .{
        .table = .{ 3, 0, 3, 1, 1, 0, 2, 2, 3, 1, 2, 0, 3, 3, 2, 3, 0, 1, 0, 1, 2, 3, 0, 2, 0, 2, 0, 1, 0, 0, 1, 0, 2, 3, 1, 2, 1, 0, 2, 0, 2, 1, 0, 1, 0, 2, 1, 0, 3, 1, 2, 3, 1, 3, 1, 1, 1, 2, 0, 2, 2, 0, 0, 0 },
        .inputs = .{ 0, 1, 2, 3, 6, 7 },
        .outputs = .{ 0, 1 },
    },
    .{
        .table = .{ 3, 2, 0, 3, 0, 2, 2, 1, 1, 2, 3, 2, 1, 3, 2, 1, 2, 2, 1, 3, 3, 2, 1, 0, 1, 0, 1, 3, 0, 0, 0, 2, 2, 1, 0, 1, 0, 1, 0, 1, 3, 1, 1, 2, 2, 3, 2, 0, 3, 3, 2, 0, 2, 1, 3, 3, 0, 0, 3, 0, 1, 1, 3, 3 },
        .inputs = .{ 0, 1, 3, 5, 6, 7 },
        .outputs = .{ 4, 5 },
    },
};

const fn1_r2_boxes = [4]Sbox{
    .{
        .table = .{ 3, 3, 2, 0, 3, 0, 3, 1, 0, 3, 0, 1, 0, 2, 1, 3, 1, 3, 0, 3, 3, 1, 3, 3, 3, 2, 3, 2, 2, 3, 1, 2, 0, 2, 2, 1, 0, 1, 2, 0, 3, 3, 0, 1, 3, 2, 1, 2, 3, 0, 1, 3, 0, 1, 2, 2, 1, 2, 1, 2, 0, 1, 3, 0 },
        .inputs = .{ 0, 1, 2, 3, 6, -1 },
        .outputs = .{ 1, 6 },
    },
    .{
        .table = .{ 1, 2, 3, 2, 1, 3, 0, 1, 1, 0, 2, 0, 0, 2, 3, 2, 3, 3, 0, 1, 2, 2, 1, 0, 1, 0, 1, 2, 3, 2, 1, 3, 2, 2, 2, 0, 1, 0, 2, 3, 2, 1, 2, 1, 2, 1, 0, 3, 0, 1, 2, 3, 1, 2, 1, 3, 2, 0, 3, 2, 3, 0, 2, 0 },
        .inputs = .{ 2, 4, 5, 6, 7, -1 },
        .outputs = .{ 5, 7 },
    },
    .{
        .table = .{ 0, 1, 0, 2, 1, 1, 0, 1, 0, 2, 2, 2, 1, 3, 0, 0, 1, 1, 3, 1, 2, 2, 2, 3, 1, 0, 3, 3, 3, 2, 2, 2, 1, 1, 3, 0, 3, 1, 3, 0, 1, 3, 3, 2, 1, 1, 0, 0, 1, 2, 2, 2, 1, 1, 1, 2, 2, 0, 0, 3, 2, 3, 1, 3 },
        .inputs = .{ 1, 2, 3, 4, 5, 7 },
        .outputs = .{ 0, 3 },
    },
    .{
        .table = .{ 2, 1, 0, 3, 3, 3, 2, 0, 1, 2, 1, 1, 1, 0, 3, 1, 1, 3, 3, 0, 1, 2, 1, 0, 0, 0, 3, 0, 3, 0, 3, 0, 1, 3, 3, 3, 0, 3, 2, 0, 2, 1, 2, 2, 2, 1, 1, 3, 0, 1, 0, 1, 0, 1, 1, 1, 1, 3, 1, 0, 1, 2, 3, 3 },
        .inputs = .{ 0, 1, 3, 4, 6, 7 },
        .outputs = .{ 2, 4 },
    },
};

const fn1_r3_boxes = [4]Sbox{
    .{
        .table = .{ 0, 0, 0, 3, 3, 1, 1, 0, 2, 0, 2, 0, 0, 0, 3, 2, 0, 1, 2, 3, 2, 2, 1, 0, 3, 0, 0, 0, 0, 0, 2, 3, 3, 0, 0, 1, 1, 2, 3, 3, 0, 1, 3, 2, 0, 1, 3, 3, 2, 0, 0, 1, 0, 2, 0, 0, 0, 3, 1, 3, 3, 3, 3, 3 },
        .inputs = .{ 0, 1, 5, 6, 7, -1 },
        .outputs = .{ 0, 5 },
    },
    .{
        .table = .{ 2, 3, 2, 3, 0, 2, 3, 0, 2, 2, 3, 0, 3, 2, 0, 2, 1, 0, 2, 3, 1, 1, 1, 0, 0, 1, 0, 2, 1, 2, 2, 1, 3, 0, 2, 1, 2, 3, 3, 0, 3, 2, 3, 1, 0, 2, 1, 0, 1, 2, 2, 3, 0, 2, 1, 3, 1, 3, 0, 2, 1, 1, 1, 3 },
        .inputs = .{ 2, 3, 4, 6, 7, -1 },
        .outputs = .{ 6, 7 },
    },
    .{
        .table = .{ 3, 0, 2, 1, 1, 3, 1, 2, 2, 1, 2, 2, 2, 0, 0, 1, 2, 3, 1, 0, 2, 0, 0, 2, 3, 1, 2, 0, 0, 0, 3, 0, 2, 1, 1, 2, 0, 0, 1, 2, 3, 1, 1, 2, 0, 1, 3, 0, 3, 1, 1, 0, 0, 2, 3, 0, 0, 0, 0, 3, 2, 0, 0, 0 },
        .inputs = .{ 0, 2, 3, 4, 5, 6 },
        .outputs = .{ 1, 4 },
    },
    .{
        .table = .{ 0, 1, 0, 0, 2, 1, 3, 2, 3, 3, 2, 1, 0, 1, 1, 1, 1, 1, 0, 3, 3, 1, 1, 0, 0, 2, 2, 1, 0, 3, 3, 2, 1, 3, 3, 0, 3, 0, 2, 1, 1, 2, 3, 2, 2, 2, 1, 0, 0, 3, 3, 3, 2, 2, 3, 1, 0, 2, 3, 0, 3, 1, 1, 0 },
        .inputs = .{ 0, 1, 2, 3, 5, 7 },
        .outputs = .{ 2, 3 },
    },
};

const fn1_r4_boxes = [4]Sbox{
    .{
        .table = .{ 1, 1, 1, 1, 1, 0, 1, 3, 3, 2, 3, 0, 1, 2, 0, 2, 3, 3, 0, 1, 2, 1, 2, 3, 0, 3, 2, 3, 2, 0, 1, 2, 0, 1, 0, 3, 2, 1, 3, 2, 3, 1, 2, 3, 2, 0, 1, 2, 2, 0, 0, 0, 2, 1, 3, 0, 3, 1, 3, 0, 1, 3, 3, 0 },
        .inputs = .{ 1, 2, 3, 4, 5, 7 },
        .outputs = .{ 0, 4 },
    },
    .{
        .table = .{ 3, 0, 0, 0, 0, 1, 0, 2, 3, 3, 1, 3, 0, 3, 1, 2, 2, 2, 3, 1, 0, 0, 2, 0, 1, 0, 2, 2, 3, 3, 0, 0, 1, 1, 3, 0, 2, 3, 0, 3, 0, 3, 0, 2, 0, 2, 0, 1, 0, 3, 0, 1, 3, 1, 1, 0, 0, 1, 3, 3, 2, 2, 1, 0 },
        .inputs = .{ 0, 1, 2, 3, 5, 6 },
        .outputs = .{ 1, 3 },
    },
    .{
        .table = .{ 0, 1, 1, 2, 0, 1, 3, 1, 2, 0, 3, 2, 0, 0, 3, 0, 3, 0, 1, 2, 2, 3, 3, 2, 3, 2, 0, 1, 0, 0, 1, 0, 3, 0, 2, 3, 0, 2, 2, 2, 1, 1, 0, 2, 2, 0, 0, 1, 2, 1, 1, 1, 2, 3, 0, 3, 1, 2, 3, 3, 1, 1, 3, 0 },
        .inputs = .{ 0, 2, 4, 5, 6, 7 },
        .outputs = .{ 2, 6 },
    },
    .{
        .table = .{ 0, 1, 2, 2, 0, 1, 0, 3, 2, 2, 1, 1, 3, 2, 0, 2, 0, 1, 3, 3, 0, 2, 2, 3, 3, 2, 0, 0, 2, 1, 3, 3, 1, 1, 1, 3, 1, 2, 1, 1, 0, 3, 3, 2, 3, 2, 3, 0, 3, 1, 0, 0, 3, 0, 0, 0, 2, 2, 2, 1, 2, 3, 0, 0 },
        .inputs = .{ 0, 1, 3, 4, 6, 7 },
        .outputs = .{ 5, 7 },
    },
};

const fn2_r1_boxes = [4]Sbox{
    .{
        .table = .{ 2, 0, 2, 0, 3, 0, 0, 3, 1, 1, 0, 1, 3, 2, 0, 1, 2, 0, 1, 2, 0, 2, 0, 2, 2, 2, 3, 0, 2, 1, 3, 0, 0, 1, 0, 1, 2, 2, 3, 3, 0, 3, 0, 2, 3, 0, 1, 2, 1, 1, 0, 2, 0, 3, 1, 1, 2, 2, 1, 3, 1, 1, 3, 1 },
        .inputs = .{ 0, 3, 4, 5, 7, -1 },
        .outputs = .{ 6, 7 },
    },
    .{
        .table = .{ 1, 1, 0, 3, 0, 2, 0, 1, 3, 0, 2, 0, 1, 1, 0, 0, 1, 3, 2, 2, 0, 2, 2, 2, 2, 0, 1, 3, 3, 3, 1, 1, 1, 3, 1, 3, 2, 2, 2, 2, 2, 2, 0, 1, 0, 1, 1, 2, 3, 1, 1, 2, 0, 3, 3, 3, 2, 2, 3, 1, 1, 1, 3, 0 },
        .inputs = .{ 1, 2, 3, 4, 6, -1 },
        .outputs = .{ 3, 5 },
    },
    .{
        .table = .{ 1, 0, 2, 2, 3, 3, 3, 3, 1, 2, 2, 1, 0, 1, 2, 1, 1, 2, 3, 1, 2, 0, 0, 1, 2, 3, 1, 2, 0, 0, 0, 2, 2, 0, 1, 1, 0, 0, 2, 0, 0, 0, 2, 3, 2, 3, 0, 1, 3, 0, 0, 0, 2, 3, 2, 0, 1, 3, 2, 1, 3, 1, 1, 3 },
        .inputs = .{ 1, 2, 4, 5, 6, 7 },
        .outputs = .{ 1, 4 },
    },
    .{
        .table = .{ 1, 3, 3, 0, 3, 2, 3, 1, 3, 2, 1, 1, 3, 3, 2, 1, 2, 3, 0, 3, 1, 0, 0, 2, 3, 0, 0, 0, 3, 3, 0, 1, 2, 3, 0, 0, 0, 1, 2, 1, 3, 0, 0, 1, 0, 2, 2, 2, 3, 3, 1, 2, 1, 3, 0, 0, 0, 3, 0, 1, 3, 2, 2, 0 },
        .inputs = .{ 0, 2, 3, 5, 6, 7 },
        .outputs = .{ 0, 2 },
    },
};

const fn2_r2_boxes = [4]Sbox{
    .{
        .table = .{ 3, 1, 3, 0, 3, 0, 3, 1, 3, 0, 0, 1, 1, 3, 0, 3, 1, 1, 0, 1, 2, 3, 2, 3, 3, 1, 2, 2, 2, 0, 2, 3, 2, 2, 2, 1, 1, 3, 3, 0, 3, 1, 2, 1, 1, 1, 0, 2, 0, 3, 3, 0, 0, 2, 0, 0, 1, 1, 2, 1, 2, 1, 1, 0 },
        .inputs = .{ 0, 2, 4, 6, -1, -1 },
        .outputs = .{ 4, 6 },
    },
    .{
        .table = .{ 0, 3, 0, 3, 3, 2, 1, 2, 3, 1, 1, 1, 2, 0, 2, 3, 0, 3, 1, 2, 2, 1, 3, 3, 3, 2, 1, 2, 2, 0, 1, 0, 2, 3, 0, 1, 2, 0, 1, 1, 2, 0, 2, 1, 2, 0, 2, 3, 3, 1, 0, 2, 3, 3, 0, 3, 1, 1, 3, 0, 0, 1, 2, 0 },
        .inputs = .{ 1, 3, 4, 5, 6, 7 },
        .outputs = .{ 0, 3 },
    },
    .{
        .table = .{ 0, 0, 2, 1, 3, 2, 1, 0, 1, 2, 2, 2, 1, 1, 0, 3, 1, 2, 2, 3, 2, 1, 1, 0, 3, 0, 0, 1, 1, 2, 3, 1, 3, 3, 2, 2, 1, 0, 1, 1, 1, 2, 0, 1, 2, 3, 0, 3, 3, 0, 3, 2, 2, 0, 2, 2, 1, 2, 3, 2, 1, 0, 2, 1 },
        .inputs = .{ 0, 1, 3, 4, 5, 7 },
        .outputs = .{ 1, 7 },
    },
    .{
        .table = .{ 0, 2, 1, 2, 0, 2, 2, 0, 1, 3, 2, 0, 3, 2, 3, 0, 3, 3, 2, 3, 1, 2, 3, 1, 2, 2, 0, 0, 2, 2, 1, 2, 2, 3, 3, 3, 1, 1, 0, 0, 0, 3, 2, 0, 3, 2, 3, 1, 1, 1, 1, 0, 1, 0, 1, 3, 0, 0, 1, 2, 2, 3, 2, 0 },
        .inputs = .{ 1, 2, 3, 5, 6, 7 },
        .outputs = .{ 2, 5 },
    },
};

const fn2_r3_boxes = [4]Sbox{
    .{
        .table = .{ 2, 1, 2, 1, 2, 3, 1, 3, 2, 2, 1, 3, 3, 0, 0, 1, 0, 2, 0, 3, 3, 1, 0, 0, 1, 1, 0, 2, 3, 2, 1, 2, 1, 1, 2, 1, 1, 3, 2, 2, 0, 2, 2, 3, 3, 3, 2, 0, 0, 0, 0, 0, 3, 3, 3, 0, 1, 2, 1, 0, 2, 3, 3, 1 },
        .inputs = .{ 2, 3, 4, 6, -1, -1 },
        .outputs = .{ 3, 5 },
    },
    .{
        .table = .{ 3, 2, 3, 3, 1, 0, 3, 0, 2, 0, 1, 1, 1, 0, 3, 0, 3, 1, 3, 1, 0, 1, 2, 3, 2, 2, 3, 2, 0, 1, 1, 2, 3, 0, 0, 2, 1, 0, 0, 2, 2, 0, 1, 0, 0, 2, 0, 0, 1, 3, 1, 3, 2, 0, 3, 3, 1, 0, 2, 2, 2, 3, 0, 0 },
        .inputs = .{ 0, 1, 3, 5, 7, -1 },
        .outputs = .{ 0, 2 },
    },
    .{
        .table = .{ 2, 2, 1, 0, 2, 3, 3, 0, 0, 0, 1, 3, 1, 2, 3, 2, 2, 3, 1, 3, 0, 3, 0, 3, 3, 2, 2, 1, 0, 0, 0, 2, 1, 2, 2, 2, 0, 0, 1, 2, 0, 1, 3, 0, 2, 3, 2, 1, 3, 2, 2, 2, 3, 1, 3, 0, 2, 0, 2, 1, 0, 3, 3, 1 },
        .inputs = .{ 0, 1, 2, 3, 5, 7 },
        .outputs = .{ 1, 6 },
    },
    .{
        .table = .{ 1, 2, 3, 2, 0, 2, 1, 3, 3, 1, 0, 1, 1, 2, 2, 0, 0, 1, 1, 1, 2, 1, 1, 2, 0, 1, 3, 3, 1, 1, 1, 2, 3, 3, 1, 0, 2, 1, 1, 1, 2, 1, 0, 0, 2, 2, 3, 2, 3, 2, 2, 0, 2, 2, 3, 3, 0, 2, 3, 0, 2, 2, 1, 1 },
        .inputs = .{ 0, 2, 4, 5, 6, 7 },
        .outputs = .{ 4, 7 },
    },
};

const fn2_r4_boxes = [4]Sbox{
    .{
        .table = .{ 2, 0, 1, 1, 2, 1, 3, 3, 1, 1, 1, 2, 0, 1, 0, 2, 0, 1, 2, 0, 2, 3, 0, 2, 3, 3, 2, 2, 3, 2, 0, 1, 3, 0, 2, 0, 2, 3, 1, 3, 2, 0, 0, 1, 1, 2, 3, 1, 1, 1, 0, 1, 2, 0, 3, 3, 1, 1, 1, 3, 3, 1, 1, 0 },
        .inputs = .{ 0, 1, 3, 6, 7, -1 },
        .outputs = .{ 0, 3 },
    },
    .{
        .table = .{ 1, 2, 2, 1, 0, 3, 3, 1, 0, 2, 2, 2, 1, 0, 1, 0, 1, 1, 0, 1, 0, 2, 1, 0, 2, 1, 0, 2, 3, 2, 3, 3, 2, 2, 1, 2, 2, 3, 1, 3, 3, 3, 0, 1, 0, 1, 3, 0, 0, 0, 1, 2, 0, 3, 3, 2, 3, 2, 1, 3, 2, 1, 0, 2 },
        .inputs = .{ 0, 1, 2, 4, 5, 6 },
        .outputs = .{ 4, 7 },
    },
    .{
        .table = .{ 2, 3, 2, 1, 3, 2, 3, 0, 0, 2, 1, 1, 0, 0, 3, 2, 3, 1, 0, 1, 2, 2, 2, 1, 3, 2, 2, 1, 0, 2, 1, 2, 0, 3, 1, 0, 0, 3, 1, 1, 3, 3, 2, 0, 1, 0, 1, 3, 0, 0, 1, 2, 1, 2, 3, 2, 1, 0, 0, 3, 2, 1, 1, 3 },
        .inputs = .{ 0, 2, 3, 4, 5, 7 },
        .outputs = .{ 1, 2 },
    },
    .{
        .table = .{ 2, 0, 0, 3, 2, 2, 2, 1, 3, 3, 1, 1, 2, 0, 0, 3, 1, 0, 3, 2, 1, 0, 2, 0, 3, 2, 2, 3, 2, 0, 3, 0, 1, 3, 0, 2, 2, 1, 3, 3, 0, 1, 0, 3, 1, 1, 3, 2, 0, 3, 0, 2, 3, 2, 1, 3, 2, 3, 0, 0, 1, 3, 2, 1 },
        .inputs = .{ 2, 3, 4, 5, 6, 7 },
        .outputs = .{ 5, 6 },
    },
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a key ROM decodes to a master key and the range it covers" {
    // Twenty bytes counting up: no board's key, but the rotation that reads one
    // is the hardware's, and this is what it makes of these bytes.
    var rom: [key_bytes]u8 = undefined;
    for (&rom, 0..) |*byte, i| byte.* = @intCast(i);
    const key = readKey(&rom);
    try testing.expectEqual([2]u32{ 0x21222023, 0xc1c2c0c3 }, key.master);
    try testing.expectEqual(@as(u32, 0), key.lower);
    try testing.expectEqual(@as(u32, 0xff4000 / 2), key.upper);
    try testing.expect(!key.dead);

    // A board whose battery has gone reads as erased, and so does a set that
    // arrived without a key file at all: both are the same board to us.
    for ([_][]const u8{ &.{}, &(.{0xff} ** key_bytes) }) |erased| {
        const dead = readKey(erased);
        try testing.expect(dead.dead);
        try testing.expectEqual([2]u32{ 0xffffffff, 0xffffffff }, dead.master);
        try testing.expectEqual(@as(u32, 0xff0000 / 2), dead.lower);
    }
}

test "sixteen opcodes come out where MAME's decryptor puts them" {
    // No key ROM ships with this repo — a key is part of a set, and sets are
    // the user's — so the pin is not a real game's first sixteen opcodes. It is
    // sixteen NOPs under the key above, and the values are MAME's own
    // `cps2crypt.cpp` compiled on its own and run on the same input. Every
    // address decrypts under its own schedule, which is why sixteen identical
    // words come out sixteen different ones.
    var rom: [key_bytes]u8 = undefined;
    for (&rom, 0..) |*byte, i| byte.* = @intCast(i);

    var program: [32]u8 = undefined;
    for (0..16) |i| std.mem.writeInt(u16, program[i * 2 ..][0..2], 0x4e71, .big);
    var decoded: [32]u8 = undefined;
    decrypt(&program, &decoded, readKey(&rom));

    const want = [16]u16{
        0xecc2, 0xcc26, 0x639b, 0xbddd, 0x360f, 0x79de, 0xf4d0, 0xfc58,
        0x6054, 0xc5f2, 0x0eda, 0x0cb3, 0x3bb4, 0x739b, 0xcd4e, 0x6b8c,
    };
    for (want, 0..) |word, i|
        try testing.expectEqual(word, std.mem.readInt(u16, decoded[i * 2 ..][0..2], .big));
}

test "a dead board leaves the program it cannot decrypt in clear" {
    // The dead key covers ff0000-ffffff and nothing else, and no program ROM
    // reaches that far, so every word comes through untouched. That is the
    // board that boots to its own error screen rather than to the game.
    var program: [64]u8 = undefined;
    for (&program, 0..) |*byte, i| byte.* = @intCast(i);
    var decoded: [64]u8 = @splat(0);
    decrypt(&program, &decoded, readKey(&.{}));
    try testing.expectEqualSlices(u8, &program, &decoded);
}
