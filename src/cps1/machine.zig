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
const bus = @import("bus");
/// The CPS-A/CPS-B pair the whole family shares, and this board's half of it.
const chip = @import("video");
const video = @import("cps1_video");
const audio = @import("audio");
const soundboard = @import("soundboard");
const controls = @import("controls");
const eeprom = @import("eeprom");
const clock = @import("clock");

/// This file, so that `Machine` can hand the 68000 core the bus entry points it
/// calls by method while the functions themselves stay free.
const file = @This();

/// The data bus itself is the same on both boards and lives in `common/`; what
/// is this file's is the map that puts a device at an address.
pub const open_bus = bus.open_bus;
const high_lane = bus.high_lane;
const low_lane = bus.low_lane;
const both_lanes = bus.both_lanes;
const byteWide = bus.byteWide;
const highByteWide = bus.highByteWide;
const peek = bus.peek;
const peekByte = bus.peekByte;
const lowMask = bus.lowMask;
const merge = bus.merge;
const pokeBytes = bus.pokeBytes;
const pokeByteWide = bus.pokeByteWide;

// The 68000's map, as first and last address of each window.
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
/// The two command latches of a plain CPS-1 board. A QSound board has shared
/// RAM instead and never touches these; this board has no shared RAM at all,
/// and a byte posted here is the whole of what the 68000 tells the Z80.
pub const latch0_lo = 0x800180;
pub const latch0_hi = 0x800187;
pub const latch1_lo = 0x800188;
pub const latch1_hi = 0x80018f;
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
    std.debug.assert(cps_a_hi - cps_a_lo + 1 == chip.a_regs_bytes);
    std.debug.assert(cps_b_hi - cps_b_lo + 1 == board.cps_b_bytes);
}

pub const ram_bytes = 0x10000;
/// Each shared RAM window is one byte per 68000 *word* address, so it is half
/// as many bytes as it is addresses — and the same 4 KiB the Z80 sees.
pub const shared_bytes = soundboard.shared_bytes;

/// The bits IN0 puts each panel input on. Not a straight run: the two start
/// buttons skip a bit, and the test switch sits above them.
const in0_bit = [controls.panel_count]u8{ 0x01, 0x02, 0x04, 0x10, 0x20, 0x40 };
/// IN1 carries player 1 in its low byte and player 2 in its high byte, seven
/// bits each; buttons 4 to 6 come from IN2 instead.
const in1_player_bits = 7;
const in2_button_shift = @intFromEnum(controls.Button.b4);

/// The IN0 window holds four byte-wide registers a word apart: the system
/// inputs, then the three DIP banks.
const dsw_slots = 4;
const in0_slot = 0;
/// A QSound board has no DIP switches at all — its settings live in the
/// service menu — and the pins float high.
const dsw_absent = 0xff;

/// Where the three banks are left, since nothing here can turn them. All
/// switches off, except the one in bank C that decides whether the attract
/// mode is heard: `demo_sounds` is the odd switch that reads zero when it is
/// on, and off it would leave every game in the library silent until a coin.
const demo_sounds = 0x20;
const dsw_setting = [dsw_slots - 1]u8{ 0xff, 0xff, 0xff & ~@as(u8, demo_sounds) };

/// The three wires the 68000 drives, on the low byte of `0xf1c006`.
const eeprom_di = 0x10;
const eeprom_clk = 0x20;
const eeprom_cs = 0x40;

/// The port register the 68000 leaves the three wires on, as the chip sees
/// them: which bit is which is this board's wiring and not the 93C46's.
fn eepromPins(c: *Machine, value: u8) void {
    c.eeprom.write(value & eeprom_cs != 0, value & eeprom_clk != 0, @intFromBool(value & eeprom_di != 0));
}

pub const Machine = struct {
    /// The battery's contents. Read-only once loaded.
    board: board.Board,
    /// The heap slices, the one exception to the no-allocation rule: reattached
    /// after a save state is loaded rather than copied into it.
    rom: romset.Set,

    v: chip.Video = .{},
    ram: [ram_bytes]u8 = @splat(0),
    /// The sound board is a board: its own CPU, its own ROM, its own RAM. The
    /// two shared windows below live on it, because that is the chip they are.
    sound: soundboard.SoundBoard = .{},
    /// Where the resampled result piles up until `main.zig` drains it.
    mixer: audio.Mixer = .{},

    inputs: controls.Inputs = .{},
    /// The settings a board with no DIP switches keeps instead.
    eeprom: eeprom.Eeprom = .{},
    /// Coin counters and lockouts, latched. Nothing reads them back; they exist
    /// because a game writes them and the write must land somewhere.
    coin_control: u16 = 0,
    coin_control2: u16 = 0,

    /// Where in the picture the machine is, and what its chips are owed.
    t: clock.Timing = .{},

    // The 68000 core reaches its bus by method call. The functions stay free.
    pub const read8 = file.read8;
    pub const read16 = file.read16;
    pub const write8 = file.write8;
    pub const write16 = file.write16;
};

// ------------------------------------------------------------------- reads

pub fn read16(c: *Machine, addr: u24) u16 {
    return switch (addr) {
        program_lo...program_hi => peek(c.rom.program, addr - program_lo),
        in1_lo...in1_hi => in1(c),
        in0_lo...in0_hi => highByteWide(if (slot(addr) == in0_slot) in0(c) else dsw(c, slot(addr))),
        cps_a_lo...cps_a_hi => chip.readA(&c.v, @truncate(addr - cps_a_lo)),
        cps_b_lo...cps_b_hi => cboard(c, @truncate(addr - cps_b_lo)),
        gfxram_lo...gfxram_hi => peek(&c.v.gfxram, addr - gfxram_lo),
        // The sample ROM seen a byte at a time through the sound board: a
        // protection read on the boards that use it, harmless on those that
        // do not.
        audio_peek_lo...audio_peek_hi => byteWide(peekByte(c.rom.qsound, (addr - audio_peek_lo) / 2)),
        shared0_lo...shared0_hi => byteWide(c.sound.shared[0][(addr - shared0_lo) / 2]),
        shared1_lo...shared1_hi => byteWide(c.sound.shared[1][(addr - shared1_lo) / 2]),
        in2_lo...in2_hi => in2(c),
        in3_lo...in3_hi => open_bus,
        // One wire of the low byte is the EEPROM's data out; the rest of the
        // word is nothing at all.
        eeprom_lo...eeprom_hi => open_bus & ~@as(u16, 1) | c.eeprom.read(),
        ram_lo...ram_hi => peek(&c.ram, addr - ram_lo),
        else => open_bus,
    };
}

/// A byte read takes whichever half of the word its address selects, which is
/// the only way the CPU can see one byte of a 16-bit bus.
pub fn read8(c: *Machine, addr: u24) u8 {
    const word = read16(c, addr & ~@as(u24, 1));
    if (addr & 1 == 0) return @truncate(word >> 8);
    return @truncate(word);
}

/// Which of the IN0 window's four registers an address picks.
fn slot(addr: u24) u24 {
    return (addr >> 1) & (dsw_slots - 1);
}

/// Controls are wired to ground, so a pressed button reads as a zero.
fn in1(c: *const Machine) u16 {
    const low: u16 = c.inputs.pad[0] & lowMask(in1_player_bits);
    const high: u16 = c.inputs.pad[1] & lowMask(in1_player_bits);
    return ~(low | high << 8);
}

/// The CPS-B window, where a plain CPS-1 board's C-board also decodes its
/// extra controls: a register the board file names, inside the register file
/// and not in the input window at all. A CPS-1.5 board has them on their own
/// address instead. Without this a six-button game finds nothing where its
/// kicks are and only ever punches.
///
/// ponytail: the same register is player 3 on a three-player cabinet, and this
/// hands those games player 1's buttons 4 to 6 rather than the nothing they
/// used to read. Split it when a third player is worth having.
fn cboard(c: *Machine, offset: u8) u16 {
    if (c.board.in2_offset) |off| {
        if (off == offset) return in2(c);
    }
    return chip.readB(&c.v, &c.board, offset);
}

fn in2(c: *const Machine) u16 {
    const low: u16 = (c.inputs.pad[0] >> in2_button_shift) & lowMask(controls.button_count - in2_button_shift);
    const high: u16 = (c.inputs.pad[1] >> in2_button_shift) & lowMask(controls.button_count - in2_button_shift);
    return ~(low | high << 4);
}

/// The DIP banks, which only a plain CPS-1 board carries.
fn dsw(c: *const Machine, which: u24) u8 {
    if (c.board.sound() != .cps1) return dsw_absent;
    return dsw_setting[which - 1];
}
fn in0(c: *const Machine) u8 {
    var bits: u8 = 0;
    for (in0_bit, 0..) |bit, i| {
        if (c.inputs.panel & (@as(u8, 1) << @intCast(i)) != 0) bits |= bit;
    }
    return ~bits;
}

// ------------------------------------------------------------------ writes

pub fn write16(c: *Machine, addr: u24, value: u16) void {
    poke(c, addr, value, both_lanes);
}

/// The CPU drives the same byte onto both lanes; the address picks which of
/// them the strobe lands on.
pub fn write8(c: *Machine, addr: u24, value: u8) void {
    const word = @as(u16, value) << 8 | value;
    poke(c, addr & ~@as(u24, 1), word, if (addr & 1 == 0) high_lane else low_lane);
}

/// `mask` is which halves of the data bus the CPU is driving.
fn poke(c: *Machine, addr: u24, value: u16, mask: u16) void {
    switch (addr) {
        coinctrl_lo...coinctrl_hi => merge(&c.coin_control, value, mask),
        cps_a_lo...cps_a_hi => chip.writeA(&c.v, &c.board, @truncate(addr - cps_a_lo), value, mask),
        cps_b_lo...cps_b_hi => chip.writeB(&c.v, &c.board, @truncate(addr - cps_b_lo), value, mask),
        // The first latch takes whichever lane the CPU drove — a driver posts
        // it with a byte write as often as a word one. The second is wired to
        // the low lane only.
        latch0_lo...latch0_hi => soundboard.post(&c.sound, 0, if (mask & low_lane != 0)
            @truncate(value)
        else
            @truncate(value >> 8)),
        latch1_lo...latch1_hi => if (mask & low_lane != 0) soundboard.post(&c.sound, 1, @truncate(value)),
        gfxram_lo...gfxram_hi => pokeBytes(&c.v.gfxram, addr - gfxram_lo, value, mask),
        // Byte-wide, and only the low lane is wired, so an even-address byte
        // write reaches nothing at all.
        shared0_lo...shared0_hi => pokeByteWide(&c.sound.shared[0], (addr - shared0_lo) / 2, value, mask),
        shared1_lo...shared1_hi => pokeByteWide(&c.sound.shared[1], (addr - shared1_lo) / 2, value, mask),
        coinctrl2_lo...coinctrl2_hi => merge(&c.coin_control2, value, mask),
        // Byte-wide like the shared RAM beside it: the three EEPROM wires are
        // on the low lane, so an even-address byte write reaches none of them.
        eeprom_lo...eeprom_hi => if (mask & low_lane != 0) eepromPins(c, @truncate(value)),
        ram_lo...ram_hi => pokeBytes(&c.ram, addr - ram_lo, value, mask),
        else => {},
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A machine with no ROMs, for exercising the parts of the map that are RAM.
fn bare() Machine {
    return .{ .board = .{}, .rom = .{ .program = &.{}, .gfx = &.{}, .audio = &.{}, .qsound = &.{}, .oki = &.{} } };
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

    c.inputs.pad[0] = controls.Button.up.mask() | controls.Button.b1.mask() | controls.Button.b6.mask();
    c.inputs.pad[1] = controls.Button.left.mask();
    // IN1 holds seven bits per player: the stick and the first three buttons.
    try testing.expectEqual(@as(u16, ~@as(u16, 0x0018 | 0x0200)), read16(&c, in1_lo));
    // Button 6 is on IN2 instead, four bits up for player 2.
    try testing.expectEqual(@as(u16, ~@as(u16, 0x04)), read16(&c, in2_lo));

    // A plain CPS-1 board reads the same bits from the CPS-B register its
    // board file names, and from no other register in that window.
    c.board.in2_offset = 0x36;
    try testing.expectEqual(@as(u16, ~@as(u16, 0x04)), read16(&c, cps_b_lo + 0x36));
    try testing.expectEqual(@as(u8, 0xfb), read8(&c, cps_b_lo + 0x37));
    // Every other register in that window is still the register file.
    write16(&c, cps_b_lo + 0x34, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), read16(&c, cps_b_lo + 0x34));
    c.board.in2_offset = null;

    c.inputs.panel = controls.Panel.coin1.mask() | controls.Panel.start2.mask();
    try testing.expectEqual(@as(u16, 0xde), read8(&c, in0_lo));
    // The system inputs are byte-wide, and the DSW banks a QSound board has
    // none of read as all-ones.
    try testing.expectEqual(@as(u16, 0xdeff), read16(&c, in0_lo));
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in0_lo + 2));
}

test "a plain CPS-1 board has DIP switches, and the demo sounds one is on" {
    var c = bare();
    c.board.roms[0] = .{ .region = .oki, .dest = 0, .len = 0, .mode = .byte, .src = 0, .name = "" };
    c.board.rom_count = 1;
    // Banks A and B as they leave the factory, and bank C with the one switch
    // that decides whether an uncoined machine is heard.
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in0_lo + 2));
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in0_lo + 4));
    try testing.expectEqual(@as(u16, 0xdfff), read16(&c, in0_lo + 6));
}
/// Clocks one bit into the EEPROM the way a driver does: set the wire, raise
/// the clock, drop it. Chip select stays asserted throughout.
fn eepromBit(c: *Machine, bit: u1) void {
    const di: u16 = if (bit == 1) eeprom_di else 0;
    write8(c, eeprom_lo + 1, @truncate(eeprom_cs | di));
    write8(c, eeprom_lo + 1, @truncate(eeprom_cs | eeprom_clk | di));
    write8(c, eeprom_lo + 1, @truncate(eeprom_cs | di));
}

fn eepromSend(c: *Machine, value: u32, bits: u5) void {
    var i = bits;
    while (i > 0) : (i -= 1) eepromBit(c, @truncate(value >> (i - 1)));
}

fn eepromSelect(c: *Machine, on: bool) void {
    write8(c, eeprom_lo + 1, if (on) eeprom_cs else 0);
}

/// A command is a start bit, two opcode bits and six address bits.
fn eepromCommand(c: *Machine, op: eeprom.Op, addr: u6) void {
    eepromSelect(c, true);
    eepromSend(c, 1 << (eeprom.command_bits - 1) | @as(u32, @intFromEnum(op)) << 6 | addr, eeprom.command_bits);
}

fn eepromRead(c: *Machine, addr: u6) !u16 {
    eepromCommand(c, .read, addr);
    // The chip answers with a dummy zero and then the word, MSB first.
    try testing.expectEqual(@as(u16, 0), read16(c, eeprom_lo) & 1);
    var word: u16 = 0;
    for (0..eeprom.data_bits) |_| {
        eepromBit(c, 0);
        word = word << 1 | @as(u16, @truncate(read16(c, eeprom_lo) & 1));
    }
    eepromSelect(c, false);
    return word;
}

test "the EEPROM answers the 93C46 protocol a service menu speaks" {
    var c = bare();
    // An erased chip, and a write refused until one is enabled.
    try testing.expectEqual(@as(u16, eeprom.erased), try eepromRead(&c, 3));
    eepromCommand(&c, .write, 3);
    eepromSend(&c, 0x1234, eeprom.data_bits);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, eeprom.erased), try eepromRead(&c, 3));
    try testing.expect(!c.eeprom.dirty);

    eepromCommand(&c, .special, @as(u6, @intFromEnum(eeprom.Special.enable)) << 4);
    eepromSelect(&c, false);
    eepromCommand(&c, .write, 3);
    eepromSend(&c, 0x1234, eeprom.data_bits);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, 0x1234), try eepromRead(&c, 3));
    try testing.expect(c.eeprom.dirty);
    // Its neighbours are untouched, and so is the rest of the chip.
    try testing.expectEqual(@as(u16, eeprom.erased), try eepromRead(&c, 4));

    eepromCommand(&c, .erase, 3);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, eeprom.erased), try eepromRead(&c, 3));

    // Disabling holds across chip select, which is what stops a glitch from
    // wiping the settings.
    eepromCommand(&c, .special, @as(u6, @intFromEnum(eeprom.Special.disable)) << 4);
    eepromSelect(&c, false);
    eepromCommand(&c, .write, 7);
    eepromSend(&c, 0xbeef, eeprom.data_bits);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, eeprom.erased), try eepromRead(&c, 7));

    // The idle wire reads high, and nothing but bit 0 is driven at all.
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, eeprom_lo));
}

test "the EEPROM round-trips through the file beside the set" {
    var e = eeprom.Eeprom{};
    e.data[0] = 0x0102;
    e.data[eeprom.words - 1] = 0xfeed;
    var bytes: [eeprom.bytes]u8 = undefined;
    e.save(&bytes);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, bytes[0..2]);

    var back = eeprom.Eeprom{};
    back.load(&bytes);
    try testing.expectEqualSlices(u16, &e.data, &back.data);

    // A short file fills the front and leaves the rest erased.
    back.load(bytes[0..4]);
    try testing.expectEqual(@as(u16, 0x0102), back.data[0]);
    try testing.expectEqual(@as(u16, eeprom.erased), back.data[eeprom.words - 1]);
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
