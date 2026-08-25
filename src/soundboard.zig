//! The sound board: the Z80's bus, its banking, and the two boards' one shared
//! window.
//!
//! This is a board of its own. It has its own crystal, its own ROM and the two
//! kilobytes of RAM the 68000 can see into; the 68000 does not drive the sound
//! chip at all, it posts a byte into that RAM and the driver here does the
//! rest. So the Z80's bus is this struct rather than the machine: the shared
//! RAM lives on the sound board, which is where the chips are, and `cps.zig`
//! reaches into it through the window the main board has on it.
//!
//! The fixed half of the ROM arrives encrypted and is decoded once at load
//! into two buffers, one for opcode fetches and one for data reads
//! (`kabuki.zig`). The banked half is not encrypted at all.

const std = @import("std");
const board = @import("board");
const kabuki = @import("kabuki");
const qsound = @import("qsound");
const z80 = @import("z80");

const file = @This();

pub const Core = z80.Core(SoundBoard);

/// The Z80's map. The fixed ROM and the bank window are the two halves of the
/// audio region; everything above them is RAM and chips.
pub const fixed_lo = 0x0000;
pub const fixed_hi = 0x7fff;
pub const bank_lo = 0x8000;
pub const bank_hi = 0xbfff;
pub const shared0_lo = 0xc000;
pub const shared0_hi = 0xcfff;
pub const qsound_lo = 0xd000;
pub const qsound_hi = 0xd002;
pub const banksw = 0xd003;
pub const qsound_status = 0xd007;
pub const shared1_lo = 0xf000;
pub const shared1_hi = 0xffff;

pub const fixed_bytes = fixed_hi - fixed_lo + 1;
pub const bank_bytes = bank_hi - bank_lo + 1;
pub const shared_bytes = shared0_hi - shared0_lo + 1;
/// Two separate RAMs, each of which both CPUs reach at an address of its own.
pub const shared_windows = 2;

/// Where the banked half of the audio region starts. The fixed half is a whole
/// 64 KiB slot wide even though only half of it is ROM, which is why a board
/// file's second `audio` line lands here and not at 0x8000.
pub const bank_base = 0x10000;

/// Unpopulated address space, and unpopulated ROM: both read as an erased
/// EPROM on a bus with nothing driving it.
pub const blank = 0xff;

pub const SoundBoard = struct {
    cpu: z80.Cpu = .{},
    q: qsound.Qsound = .{},

    /// The fixed ROM as the CPU sees it, once each way. Decoding at load costs
    /// 64 KiB of machine state and buys a bus read that is one index.
    op: [fixed_bytes]u8 = @splat(blank),
    data: [fixed_bytes]u8 = @splat(blank),
    /// The whole audio region, for the bank window. One of the
    /// heap slices: reattached after a save state rather than copied into it.
    rom: []const u8 = &.{},

    /// The Z80's RAM, and the 68000's window on it.
    shared: [shared_windows][shared_bytes]u8 = @splat(@splat(0)),

    bank: u4 = 0,
    /// The periodic interrupt, held until the CPU takes it.
    int_pending: bool = false,

    /// ponytail: which of the two ROM views a read gets is decided by the
    /// address matching where the next instruction byte is due, because the
    /// pinned z80 has no `z80Fetch` hook. The custom watches the
    /// M1 pin, and M1 is low only for an opcode byte and the prefixes ahead of
    /// it: an instruction's immediate bytes are ordinary reads and decrypt the
    /// other way. So the cursor carries `m1` alongside it. It is wrong only for
    /// a data read that lands exactly on the next unfetched byte, inside the
    /// encrypted half of the ROM. The hook settles it for good at the z80 tag
    /// bump, and all three of these fields go with it.
    fetch: u16 = 0,
    m1: bool = true,
    /// Whether the prefix run so far was `dd`/`fd`, which is the one case where
    /// a `cb` after it is *not* followed by another opcode fetch: `dd cb d op`
    /// reads its displacement and its opcode with M1 high.
    indexed: bool = false,

    pub const z80Read8 = file.z80Read8;
    pub const z80Write8 = file.z80Write8;
    pub const z80In = file.z80In;
    pub const z80Out = file.z80Out;
};

/// Decodes the fixed ROM into its two views and holds on to the region for the
/// bank window, and hands the chip the sample ROM it plays out of. A board with
/// no Kabuki key — the set this project builds for itself — reads the same
/// bytes both ways.
pub fn load(s: *SoundBoard, rom: []const u8, samples: []const u8, key: ?board.Kabuki) void {
    s.rom = rom;
    qsound.attach(&s.q, samples);
    const fixed = rom[0..@min(rom.len, fixed_bytes)];
    @memset(&s.op, blank);
    @memset(&s.data, blank);
    if (key) |k| {
        kabuki.decode(k, fixed, s.op[0..fixed.len], s.data[0..fixed.len]);
    } else {
        @memcpy(s.op[0..fixed.len], fixed);
        @memcpy(s.data[0..fixed.len], fixed);
    }
}

/// One instruction, with the fetch cursor put back on the program counter so
/// the bus can tell an instruction's own bytes from the data it reads.
pub fn step(s: *SoundBoard) void {
    s.fetch = s.cpu.pc;
    s.m1 = true;
    s.indexed = false;
    Core.step(&s.cpu, s);
}

/// Offers the pending interrupt at an instruction boundary. Level-triggered:
/// a driver running with interrupts off keeps it until it lets it in.
pub fn interrupt(s: *SoundBoard) void {
    if (s.int_pending and Core.interrupt(&s.cpu, s, .{ .int = true })) s.int_pending = false;
}

pub fn reset(s: *SoundBoard) void {
    s.cpu = .{};
    Core.reset(&s.cpu);
    s.bank = 0;
    s.int_pending = false;
    qsound.reset(&s.q);
}

// --------------------------------------------------------------------- bus

pub fn z80Read8(s: *SoundBoard, addr: u16) u8 {
    const fetching = addr == s.fetch;
    const as_op = fetching and s.m1;
    if (fetching) s.fetch +%= 1;

    const byte = switch (addr) {
        fixed_lo...fixed_hi => if (as_op) s.op[addr] else s.data[addr],
        bank_lo...bank_hi => peek(s.rom, bankOffset(s.bank) + (addr - bank_lo)),
        shared0_lo...shared0_hi => s.shared[0][addr - shared0_lo],
        shared1_lo...shared1_hi => s.shared[1][addr - shared1_lo],
        qsound_status => qsound.read(&s.q),
        else => blank,
    };
    if (as_op) nextIsOpcode(s, byte);
    return byte;
}

/// Whether the byte after this opcode byte is another one. Only a prefix is
/// followed by a second M1 cycle, and `cb` behind an index prefix is not: what
/// follows there is a displacement and then an opcode the CPU reads without
/// pulling M1 low, which is the whole reason this is not `isPrefix`.
fn nextIsOpcode(s: *SoundBoard, byte: u8) void {
    switch (byte) {
        0xdd, 0xfd => {
            s.m1 = true;
            s.indexed = true;
        },
        0xcb => {
            s.m1 = !s.indexed;
            s.indexed = false;
        },
        0xed => {
            s.m1 = true;
            s.indexed = false;
        },
        else => {
            s.m1 = false;
            s.indexed = false;
        },
    }
}

pub fn z80Write8(s: *SoundBoard, addr: u16, value: u8) void {
    switch (addr) {
        shared0_lo...shared0_hi => s.shared[0][addr - shared0_lo] = value,
        shared1_lo...shared1_hi => s.shared[1][addr - shared1_lo] = value,
        qsound_lo...qsound_hi => qsound.write(&s.q, addr - qsound_lo, value),
        banksw => s.bank = @truncate(value),
        else => {},
    }
}

/// The sound board has nothing on its I/O ports. The Z80's `in`/`out` reach
/// no chip at all, which is not the same as reaching one that answers zero.
pub fn z80In(s: *SoundBoard, port: u16) u8 {
    _ = s;
    _ = port;
    return blank;
}

pub fn z80Out(s: *SoundBoard, port: u16, value: u8) void {
    _ = s;
    _ = port;
    _ = value;
}

fn bankOffset(bank: u4) u32 {
    return bank_base + @as(u32, bank) * bank_bytes;
}

fn peek(rom: []const u8, offset: u32) u8 {
    if (offset >= rom.len) return blank;
    return rom[offset];
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A sound board with a ROM of its own, unencrypted: every byte says where it
/// came from, so a read landing in the wrong bank is visible.
fn withRom(rom: []const u8) SoundBoard {
    var s = SoundBoard{};
    load(&s, rom, &.{}, null);
    return s;
}

test "the fixed ROM, the bank window and the two RAMs are where the Z80 finds them" {
    var rom: [bank_base + 4 * bank_bytes]u8 = @splat(0);
    rom[0] = 0xc9;
    rom[fixed_hi] = 0x5a;
    for (0..4) |b| rom[bank_base + b * bank_bytes] = @intCast(0xb0 + b);

    var s = withRom(&rom);
    try testing.expectEqual(@as(u8, 0xc9), z80Read8(&s, 0));
    try testing.expectEqual(@as(u8, 0x5a), z80Read8(&s, fixed_hi));
    try testing.expectEqual(@as(u8, 0xb0), z80Read8(&s, bank_lo));

    z80Write8(&s, banksw, 3);
    try testing.expectEqual(@as(u8, 3), s.bank);
    try testing.expectEqual(@as(u8, 0xb3), z80Read8(&s, bank_lo));

    // A bank the ROM is too short for reads as unpopulated rather than as
    // whatever is at the front of it.
    z80Write8(&s, banksw, 15);
    try testing.expectEqual(@as(u8, blank), z80Read8(&s, bank_lo));

    // ROM does not take a write, and the two RAMs do.
    z80Write8(&s, 0, 0x00);
    try testing.expectEqual(@as(u8, 0xc9), z80Read8(&s, 0));
    z80Write8(&s, shared0_lo, 0x11);
    z80Write8(&s, shared1_hi, 0x22);
    try testing.expectEqual(@as(u8, 0x11), s.shared[0][0]);
    try testing.expectEqual(@as(u8, 0x22), s.shared[1][shared_bytes - 1]);
    try testing.expectEqual(@as(u8, blank), z80Read8(&s, 0xe000));
}

test "the fixed ROM answers one byte to a fetch and another to a data read" {
    const key = board.Kabuki{ .swap1 = 0x76543210, .swap2 = 0x24601357, .addr = 0x4343, .xor = 0x43 };
    const at = 0x1234;

    var rom: [fixed_bytes]u8 = @splat(blank);
    rom[at] = kabuki.encodeByte(key, at, .op, 0xaa);

    var s = SoundBoard{};
    load(&s, &rom, &.{}, key);

    // The cursor is where the next instruction byte is due, so this read is a
    // fetch and gets the opcode view.
    s.fetch = at;
    try testing.expectEqual(@as(u8, 0xaa), z80Read8(&s, at));
    // The cursor moved on with it: the same address again is a data read, and
    // the same ROM byte decodes to something else.
    try testing.expect(z80Read8(&s, at) != 0xaa);
    try testing.expectEqual(@as(u16, at + 1), s.fetch);
}

test "the QSound ports latch, and the chip answers ready once it has run" {
    var s = SoundBoard{};
    z80Write8(&s, qsound_lo + qsound.port_data_hi, 0x01);
    z80Write8(&s, qsound_lo + qsound.port_data_lo, 0x02);
    z80Write8(&s, qsound_lo + qsound.port_reg, 0x33);
    try testing.expectEqual(@as(u16, 0x0102), s.q.regs[0x33]);

    // A write leaves the chip busy, which is what the driver spins on; it
    // answers ready again once it has finished a sample.
    try testing.expectEqual(@as(u8, 0), z80Read8(&s, qsound_status));
    for (0..8) |_| _ = qsound.sample(&s.q);
    try testing.expectEqual(@as(u8, qsound.ready), z80Read8(&s, qsound_status));
}
