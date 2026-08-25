//! The constant tables the DL-1425 carries in its mask ROM: the two panning
//! mix curves, the linear one, and the FIR coefficient sets the pan filter is
//! pointed at.
//!
//! Running the mask ROM is out of scope — an LLE needs 8 KiB of program that
//! cannot be committed or fetched, and the whole audio path would skip on any
//! machine without it. These are the other half of that ROM: not program, but
//! about two kilobytes of coefficients that are as much a fact of the chip as
//! its sample rate is. Without them there is no pan/FIR path to write, so they
//! are committed, and the emulator runs on a fresh checkout.
//!
//! Values transcribed from the published disassembly of the DL-1425 program
//! ROM, by way of ctr (Ian Karlsson) and ValleyBell's qsound-hle, which is
//! BSD-3-licensed:
//!
//!     Copyright (c) 2018, ValleyBell, Ian Karlsson. All rights reserved.
//!     Redistributed under the BSD 3-Clause License; see
//!     https://github.com/ValleyBell/qsound-hle for its full text.
//!
//! That is a redistribution of data, not of the emulator: the model in
//! `qsound.zig` is written from the behaviour, and qsound-hle stays the
//! differential reference the model is checked
//! against, fetched at test time and never linked into zicps.

/// A pan register selects one of 33 positions in a mix curve — hard left to
/// hard right — and each curve is a table of that many attenuations.
pub const pan_steps = 32;

/// The filter the wet path runs through: 95 taps, and five sets of them in the
/// ROM. A game picks one by writing its ROM address to the filter register.
pub const fir_taps = 95;
pub const filter_count = 5;

/// Where the five sets start, and how a table address turns into one of them.
pub const filter_base = 0xd53;

/// Above the five there is a run of mostly-zero coefficients the ROM overlaps
/// three ways: 95 zeroes to silence a channel from `overlap_base`, 45 taps of
/// the mode-2 filter from 0xf73, and a single unity tap from 0xfa0. A table
/// address anywhere in it is a window on the same run rather than an entry in
/// an array, which is why this is bytes-from-a-base and not an index.
pub const overlap_base = 0xf2e;
pub const overlap_len = 209;

/// The coefficient run a filter register points at, or null when it points at
/// nothing the ROM has — which leaves the filter holding whatever it had.
pub fn table(offset: u16) ?[]const i16 {
    if (offset >= overlap_base and offset < overlap_base + overlap_len) {
        return overlap[offset - overlap_base ..];
    }
    if (offset < filter_base) return null;
    const index = (offset - filter_base) / fir_taps;
    if (index >= filter_count) return null;
    return &filters[index];
}

pub const dry_mix = [pan_steps + 1]i16{
    -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384,
    -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384,
    -16384, -14746, -13107, -11633, -10486, -9175,  -8520,  -7209,
    -6226,  -5226,  -4588,  -3768,  -3277,  -2703,  -2130,  -1802,
    0,
};

pub const wet_mix = [pan_steps + 1]i16{
    0,      -1638,  -1966,  -2458,  -2949,  -3441,  -4096,  -4669,
    -4915,  -5120,  -5489,  -6144,  -7537,  -8831,  -9339,  -9830,
    -10240, -10322, -10486, -10568, -10650, -11796, -12288, -12288,
    -12534, -12648, -12780, -12829, -12943, -13107, -13418, -14090,
    -16384,
};

pub const linear_mix = [pan_steps + 1]i16{
    -16379, -16338, -16257, -16135, -15973, -15772, -15531, -15251,
    -14934, -14580, -14189, -13763, -13303, -12810, -12284, -11729,
    -11729, -11144, -10531, -9893,  -9229,  -8543,  -7836,  -7109,
    -6364,  -5604,  -4829,  -4043,  -3246,  -2442,  -1631,  -817,
    0,
};

pub const filters = [filter_count][fir_taps]i16{
    .{
        0,    0,    0,    6,   44,   -24,  -53,  -10,  59,    -40,
        -27,  1,    39,   -27, 56,   127,  174,  36,   -13,   49,
        212,  142,  143,  -73, -20,  66,   -108, -117, -399,  -265,
        -392, -569, -473, -71, 95,   -319, -218, -230, 331,   638,
        449,  477,  -180, 532, 1107, 750,  9899, 3828, -2418, 1071,
        -176, 191,  -431, 64,  117,  -150, -274, -97,  -238,  165,
        166,  250,  -19,  4,   37,   204,  186,  -6,   140,   -77,
        -1,   1,    18,   -10, -151, -149, -103, -9,   55,    23,
        -102, -97,  -11,  13,  -48,  -27,  5,    18,   -61,   -30,
        64,   72,   0,    0,   0,
    },
    .{
        0,    0,    0,    85,   24,   -76,  -123, -86,  -29,  -14,
        -20,  -7,   6,    -28,  -87,  -89,  -5,   100,  154,  160,
        150,  118,  41,   -48,  -78,  -23,  59,   83,   -2,   -176,
        -333, -344, -203, -66,  -39,  2,    224,  495,  495,  280,
        432,  1340, 2483, 5377, 1905, 658,  0,    97,   347,  285,
        35,   -95,  -78,  -82,  -151, -192, -171, -149, -147, -113,
        -22,  71,   118,  129,  127,  110,  71,   31,   20,   36,
        46,   23,   -27,  -63,  -53,  -21,  -19,  -60,  -92,  -69,
        -12,  25,   29,   30,   40,   41,   29,   30,   46,   39,
        -15,  -74,  0,    0,    0,
    },
    .{
        0,    0,    0,    23,   42,   47,   29,   10,  2,    -14,
        -54,  -92,  -93,  -70,  -64,  -77,  -57,  18,  94,   113,
        87,   69,   67,   50,   25,   29,   58,   62,  24,   -39,
        -131, -256, -325, -234, -45,  58,   78,   223, 485,  496,
        127,  6,    857,  2283, 2683, 4928, 1328, 132, 79,   314,
        189,  -80,  -90,  35,   -21,  -186, -195, -99, -136, -258,
        -189, 82,   257,  185,  53,   41,   84,   68,  38,   63,
        77,   14,   -60,  -71,  -71,  -120, -151, -84, 14,   29,
        -8,   7,    66,   69,   12,   -3,   54,   92,  52,   -6,
        -15,  -2,   0,    0,    0,
    },
    .{
        0,   0,   0,   2,   -28, -37,  -17,  0,    -9,  -22,
        -3,  35,  52,  39,  20,  7,    -6,   2,    55,  121,
        129, 67,  8,   1,   9,   -6,   -16,  16,   66,  96,
        118, 130, 75,  -47, -92, 43,   223,  239,  151, 219,
        440, 475, 226, 206, 940, 2100, 2663, 4980, 865, 49,
        -33, 186, 231, 103, 42,  114,  191,  184,  116, 29,
        -47, -72, -21, 60,  96,  68,   31,   32,   63,  87,
        76,  39,  7,   14,  55,  85,   67,   18,   -12, -3,
        21,  34,  29,  6,   -27, -49,  -37,  -2,   16,  0,
        -21, -16, 0,   0,   0,
    },
    .{
        0,    0,    0,   48,   7,    -22,  -29,  -10,  24,   54,
        59,   29,   -36, -117, -185, -213, -185, -99,  13,   90,
        83,   24,   -5,  23,   53,   47,   38,   56,   67,   57,
        75,   107,  16,  -242, -440, -355, -120, -33,  -47,  152,
        501,  472,  -57, -292, 544,  1937, 2277, 6145, 1240, 153,
        47,   200,  152, 36,   64,   134,  74,   -82,  -208, -266,
        -268, -188, -42, 65,   74,   56,   89,   133,  114,  44,
        -3,   -1,   17,  29,   29,   -2,   -76,  -156, -187, -151,
        -85,  -31,  -5,  7,    20,   32,   24,   -5,   -20,  6,
        48,   62,   0,   0,    0,
    },
};

pub const overlap = [overlap_len]i16{
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    -371, -196, -268, -512, -303,
    -315, -184,   -76,  276, -256, 298,  196,  990,  236,  1114,
    -126, 4377,   6549, 791, 0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    -16384, 0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,    0,
    0,    0,      0,    0,   0,    0,    0,    0,    0,
};
