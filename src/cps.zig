//! The machine: the whole board as one struct, and the 68000's bus.
//!
//! Every address the CPU can put on the bus is decoded here and nowhere else.
//! The board is a 16-bit machine with byte-wide devices hung off the low half
//! of its data bus, so the primary operation is the word: a byte access is a
//! word access with one lane driven, which is what `mask` carries and why a
//! byte read of a byte-wide device still sees 0xff in the other half.

const std = @import("std");
const board = @import("board");
const romset = @import("romset");
const video = @import("video");
const audio = @import("audio");
const soundboard = @import("soundboard");

/// This file, so that `Cps` can hand the 68000 core the bus entry points it
/// calls by method while the functions themselves stay free (DESIGN.md §3.2).
const file = @This();

/// What a read of nothing at all returns: the bus floats high.
pub const open_bus = 0xffff;

/// Which halves of the 16-bit data bus an access drives. A byte-wide device is
/// wired to one of them and leaves the other floating.
const high_lane = 0xff00;
const low_lane = 0x00ff;
const both_lanes = high_lane | low_lane;

// The 68000's map (DESIGN.md §7.1), as first and last address of each window.
pub const program_lo = 0x000000;
pub const program_hi = 0x1fffff;
pub const in1_lo = 0x800000;
pub const in1_hi = 0x800007;
pub const in0_lo = 0x800018;
pub const in0_hi = 0x80001f;
pub const coinctrl_lo = 0x800030;
pub const coinctrl_hi = 0x800037;
pub const cps_a_lo = 0x800100;
pub const cps_a_hi = 0x80013f;
pub const cps_b_lo = 0x800140;
pub const cps_b_hi = 0x80017f;
pub const gfxram_lo = 0x900000;
pub const gfxram_hi = 0x92ffff;
pub const audio_peek_lo = 0xf00000;
pub const audio_peek_hi = 0xf0ffff;
pub const shared0_lo = 0xf18000;
pub const shared0_hi = 0xf19fff;
pub const in2_lo = 0xf1c000;
pub const in2_hi = 0xf1c001;
pub const in3_lo = 0xf1c002;
pub const in3_hi = 0xf1c003;
pub const coinctrl2_lo = 0xf1c004;
pub const coinctrl2_hi = 0xf1c005;
pub const eeprom_lo = 0xf1c006;
pub const eeprom_hi = 0xf1c007;
pub const shared1_lo = 0xf1e000;
pub const shared1_hi = 0xf1ffff;
pub const ram_lo = 0xff0000;
pub const ram_hi = 0xffffff;

comptime {
    // A register file wider than its window holds registers no bus cycle can
    // reach, and a board file naming one would be accepted and then ignored.
    std.debug.assert(cps_a_hi - cps_a_lo + 1 == video.a_regs_bytes);
    std.debug.assert(cps_b_hi - cps_b_lo + 1 == board.cps_b_bytes);
}

pub const ram_bytes = 0x10000;
/// Each shared RAM window is one byte per 68000 *word* address, so it is half
/// as many bytes as it is addresses — and the same 4 KiB the Z80 sees.
pub const shared_bytes = soundboard.shared_bytes;

/// One player's controls, active high. Bit order is the board's own: the four
/// directions in the order the wiring reads them, then six buttons.
pub const Button = enum(u4) {
    right,
    left,
    down,
    up,
    b1,
    b2,
    b3,
    b4,
    b5,
    b6,

    pub fn mask(b: Button) u16 {
        return @as(u16, 1) << @intFromEnum(b);
    }
};
pub const button_count = @typeInfo(Button).@"enum".fields.len;

/// The panel inputs a board with no DIP switches cannot do without: without
/// service and test there is no way into the settings menu (DESIGN.md §5.1).
pub const Panel = enum(u3) {
    coin1,
    coin2,
    service,
    start1,
    start2,
    test_switch,

    pub fn mask(p: Panel) u8 {
        return @as(u8, 1) << @intFromEnum(p);
    }
};
pub const panel_count = @typeInfo(Panel).@"enum".fields.len;

/// The bits IN0 puts each panel input on. Not a straight run: the two start
/// buttons skip a bit, and the test switch sits above them.
const in0_bit = [panel_count]u8{ 0x01, 0x02, 0x04, 0x10, 0x20, 0x40 };
/// IN1 carries player 1 in its low byte and player 2 in its high byte, seven
/// bits each; buttons 4 to 6 come from IN2 instead.
const in1_player_bits = 7;
const in2_button_shift = @intFromEnum(Button.b4);

/// The IN0 window holds four byte-wide registers a word apart: the system
/// inputs, then the three DIP banks. A QSound board carries none of the banks.
const dsw_slots = 4;
const in0_slot = 0;
const dsw_absent = 0xff;

pub const Inputs = struct {
    pad: [2]u16 = @splat(0),
    panel: u8 = 0,
};

pub const Cps = struct {
    /// The battery's contents. Read-only once loaded.
    board: board.Board,
    /// The heap slices of DESIGN.md §3.2's one exception: reattached after a
    /// save state is loaded rather than copied into it.
    rom: romset.Set,

    v: video.Video = .{},
    ram: [ram_bytes]u8 = @splat(0),
    /// The sound board is a board: its own CPU, its own ROM, its own RAM. The
    /// two shared windows below live on it, because that is the chip they are.
    sound: soundboard.SoundBoard = .{},
    /// Where the resampled result piles up until `main.zig` drains it.
    mixer: audio.Mixer = .{},

    inputs: Inputs = .{},
    /// Coin counters and lockouts, latched. Nothing reads them back; they exist
    /// because a game writes them and the write must land somewhere.
    coin_control: u16 = 0,
    coin_control2: u16 = 0,

    /// The reference clock of DESIGN.md §3.3, never reset, and where in the
    /// picture we are.
    ref: u64 = 0,
    frame: u64 = 0,
    line: u32 = 0,
    /// Cycles the last line's final instruction ran past its budget, one per
    /// CPU: neither core stops on a cycle boundary, so what it overran is owed
    /// to the next line rather than forgiven.
    cpu_over: u64 = 0,
    sound_over: u64 = 0,
    /// Reference ticks owed to the Z80's periodic interrupt and to the QSound
    /// chip's sample clock, carried the same way the CPUs carry cycles.
    sound_irq_debt: u64 = 0,
    sample_debt: u64 = 0,

    // The 68000 core reaches its bus by method call. The functions stay free.
    pub const read8 = file.read8;
    pub const read16 = file.read16;
    pub const write8 = file.write8;
    pub const write16 = file.write16;
};

// ------------------------------------------------------------------- reads

pub fn read16(c: *Cps, addr: u24) u16 {
    return switch (addr) {
        program_lo...program_hi => peek(c.rom.program, addr - program_lo),
        in1_lo...in1_hi => in1(c),
        in0_lo...in0_hi => highByteWide(if (slot(addr) == in0_slot) in0(c) else dsw_absent),
        cps_a_lo...cps_a_hi => video.readA(&c.v, @truncate(addr - cps_a_lo)),
        cps_b_lo...cps_b_hi => video.readB(&c.v, &c.board, @truncate(addr - cps_b_lo)),
        gfxram_lo...gfxram_hi => peek(&c.v.gfxram, addr - gfxram_lo),
        // The sample ROM seen a byte at a time through the sound board: a
        // protection read on the boards that use it, harmless on those that
        // do not.
        audio_peek_lo...audio_peek_hi => byteWide(peekByte(c.rom.qsound, (addr - audio_peek_lo) / 2)),
        shared0_lo...shared0_hi => byteWide(c.sound.shared[0][(addr - shared0_lo) / 2]),
        shared1_lo...shared1_hi => byteWide(c.sound.shared[1][(addr - shared1_lo) / 2]),
        in2_lo...in2_hi => in2(c),
        in3_lo...in3_hi => open_bus,
        eeprom_lo...eeprom_hi => open_bus,
        ram_lo...ram_hi => peek(&c.ram, addr - ram_lo),
        else => open_bus,
    };
}

/// A byte read takes whichever half of the word its address selects, which is
/// the only way the CPU can see one byte of a 16-bit bus.
pub fn read8(c: *Cps, addr: u24) u8 {
    const word = read16(c, addr & ~@as(u24, 1));
    if (addr & 1 == 0) return @truncate(word >> 8);
    return @truncate(word);
}

/// A device wired to the low half of the data bus leaves the high half floating.
fn byteWide(value: u8) u16 {
    return high_lane | @as(u16, value);
}

/// The system inputs and the DIP banks are wired to the high half instead.
fn highByteWide(value: u8) u16 {
    return @as(u16, value) << 8 | low_lane;
}

/// Which of the IN0 window's four registers an address picks.
fn slot(addr: u24) u24 {
    return (addr >> 1) & (dsw_slots - 1);
}

fn peek(bytes: []const u8, offset: u32) u16 {
    if (offset + 1 >= bytes.len) return open_bus;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn peekByte(bytes: []const u8, offset: u32) u8 {
    if (offset >= bytes.len) return romset.blank;
    return bytes[offset];
}

/// Controls are wired to ground, so a pressed button reads as a zero.
fn in1(c: *const Cps) u16 {
    const low: u16 = c.inputs.pad[0] & lowMask(in1_player_bits);
    const high: u16 = c.inputs.pad[1] & lowMask(in1_player_bits);
    return ~(low | high << 8);
}

fn in2(c: *const Cps) u16 {
    const low: u16 = (c.inputs.pad[0] >> in2_button_shift) & lowMask(button_count - in2_button_shift);
    const high: u16 = (c.inputs.pad[1] >> in2_button_shift) & lowMask(button_count - in2_button_shift);
    return ~(low | high << 4);
}

fn in0(c: *const Cps) u8 {
    var bits: u8 = 0;
    for (in0_bit, 0..) |bit, i| {
        if (c.inputs.panel & (@as(u8, 1) << @intCast(i)) != 0) bits |= bit;
    }
    return ~bits;
}

fn lowMask(bits: u4) u16 {
    return (@as(u16, 1) << bits) - 1;
}

// ------------------------------------------------------------------ writes

pub fn write16(c: *Cps, addr: u24, value: u16) void {
    poke(c, addr, value, both_lanes);
}

/// The CPU drives the same byte onto both lanes; the address picks which of
/// them the strobe lands on.
pub fn write8(c: *Cps, addr: u24, value: u8) void {
    const word = @as(u16, value) << 8 | value;
    poke(c, addr & ~@as(u24, 1), word, if (addr & 1 == 0) high_lane else low_lane);
}

/// `mask` is which halves of the data bus the CPU is driving.
fn poke(c: *Cps, addr: u24, value: u16, mask: u16) void {
    switch (addr) {
        coinctrl_lo...coinctrl_hi => merge(&c.coin_control, value, mask),
        cps_a_lo...cps_a_hi => video.writeA(&c.v, &c.board, @truncate(addr - cps_a_lo), value, mask),
        cps_b_lo...cps_b_hi => video.writeB(&c.v, &c.board, @truncate(addr - cps_b_lo), value, mask),
        gfxram_lo...gfxram_hi => pokeBytes(&c.v.gfxram, addr - gfxram_lo, value, mask),
        // Byte-wide, and only the low lane is wired, so an even-address byte
        // write reaches nothing at all.
        shared0_lo...shared0_hi => pokeByteWide(&c.sound.shared[0], (addr - shared0_lo) / 2, value, mask),
        shared1_lo...shared1_hi => pokeByteWide(&c.sound.shared[1], (addr - shared1_lo) / 2, value, mask),
        coinctrl2_lo...coinctrl2_hi => merge(&c.coin_control2, value, mask),
        ram_lo...ram_hi => pokeBytes(&c.ram, addr - ram_lo, value, mask),
        else => {},
    }
}

fn merge(reg: *u16, value: u16, mask: u16) void {
    reg.* = (reg.* & ~mask) | (value & mask);
}

fn pokeBytes(bytes: []u8, offset: u32, value: u16, mask: u16) void {
    if (offset + 1 >= bytes.len) return;
    if (mask & high_lane != 0) bytes[offset] = @truncate(value >> 8);
    if (mask & low_lane != 0) bytes[offset + 1] = @truncate(value);
}

fn pokeByteWide(bytes: []u8, offset: u32, value: u16, mask: u16) void {
    if (offset >= bytes.len or mask & low_lane == 0) return;
    bytes[offset] = @truncate(value);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A machine with no ROMs, for exercising the parts of the map that are RAM.
fn bare() Cps {
    return .{ .board = .{}, .rom = .{ .program = &.{}, .gfx = &.{}, .audio = &.{}, .qsound = &.{} } };
}

test "work RAM and graphics RAM answer bytes and words alike" {
    var c = bare();
    write16(&c, ram_lo, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), read16(&c, ram_lo));
    try testing.expectEqual(@as(u8, 0x12), read8(&c, ram_lo));
    try testing.expectEqual(@as(u8, 0x34), read8(&c, ram_lo + 1));

    write8(&c, ram_lo + 1, 0xab);
    try testing.expectEqual(@as(u16, 0x12ab), read16(&c, ram_lo));

    write16(&c, gfxram_hi - 1, 0xbeef);
    try testing.expectEqual(@as(u16, 0xbeef), read16(&c, gfxram_hi - 1));
    // One past the last word of RAM is nothing at all.
    try testing.expectEqual(@as(u16, open_bus), read16(&c, gfxram_hi + 1));
}

test "shared RAM is one byte per word address, on the low half of the bus" {
    var c = bare();
    write16(&c, shared0_lo, 0x1234);
    write16(&c, shared0_lo + 2, 0x5678);
    try testing.expectEqual(@as(u16, 0xff34), read16(&c, shared0_lo));
    try testing.expectEqual(@as(u8, 0x78), read8(&c, shared0_lo + 3));
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x78 }, c.sound.shared[0][0..2]);

    // The high half is not wired, so writing it changes nothing.
    write8(&c, shared0_lo, 0xaa);
    try testing.expectEqual(@as(u8, 0x34), c.sound.shared[0][0]);

    // The two windows cover the Z80's 4 KiB each, and do not overlap.
    write16(&c, shared1_lo, 0x0099);
    try testing.expectEqual(@as(u8, 0x34), c.sound.shared[0][0]);
    try testing.expectEqual(@as(u8, 0x99), c.sound.shared[1][0]);
}

test "controls are wired to ground, so a pressed button reads as a zero" {
    var c = bare();
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in1_lo));
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in2_lo));
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in0_lo));

    c.inputs.pad[0] = Button.up.mask() | Button.b1.mask() | Button.b6.mask();
    c.inputs.pad[1] = Button.left.mask();
    // IN1 holds seven bits per player: the stick and the first three buttons.
    try testing.expectEqual(@as(u16, ~@as(u16, 0x0018 | 0x0200)), read16(&c, in1_lo));
    // Button 6 is on IN2 instead, four bits up for player 2.
    try testing.expectEqual(@as(u16, ~@as(u16, 0x04)), read16(&c, in2_lo));

    c.inputs.panel = Panel.coin1.mask() | Panel.start2.mask();
    try testing.expectEqual(@as(u16, 0xde), read8(&c, in0_lo));
    // The system inputs are byte-wide, and the DSW banks a QSound board has
    // none of read as all-ones.
    try testing.expectEqual(@as(u16, 0xdeff), read16(&c, in0_lo));
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in0_lo + 2));
}

test "program ROM is read-only and stops where the chips do" {
    var program = [_]u8{ 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x04, 0x00 };
    var c = bare();
    c.rom.program = &program;

    try testing.expectEqual(@as(u16, 0x0008), read16(&c, 2));
    write16(&c, 2, 0xffff);
    try testing.expectEqual(@as(u16, 0x0008), read16(&c, 2));
    try testing.expectEqual(@as(u16, open_bus), read16(&c, program.len));
}
