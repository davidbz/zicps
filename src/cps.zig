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
/// calls by method while the functions themselves stay free.
const file = @This();

/// What a read of nothing at all returns: the bus floats high.
pub const open_bus = 0xffff;

/// Which halves of the 16-bit data bus an access drives. A byte-wide device is
/// wired to one of them and leaves the other floating.
const high_lane = 0xff00;
const low_lane = 0x00ff;
const both_lanes = high_lane | low_lane;

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
/// The two command latches of a plain CPS-1 board (§7.5). A QSound board has
/// shared RAM instead and never touches these; this board has no shared RAM at
/// all, and a byte posted here is the whole of what the 68000 tells the Z80.
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
/// service and test there is no way into the settings menu.
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

pub const Inputs = struct {
    pad: [2]u16 = @splat(0),
    panel: u8 = 0,
};

// ----------------------------------------------------------------- eeprom

/// A QSound board has no DIP switches, so everything a DIP switch would have
/// said lives in a 93C46 serial EEPROM and is edited in the board's own service
/// menu. Sixty-four words, one wire in and one out.
pub const eeprom_words = 64;
pub const eeprom_bytes = eeprom_words * 2;
/// An erased cell is all ones, which is what an unprogrammed chip holds and
/// what a board with no `.nv` file beside it comes up with.
pub const eeprom_erased = 0xffff;

/// The three wires the 68000 drives, on the low byte of `0xf1c006`.
const eeprom_di = 0x10;
const eeprom_clk = 0x20;
const eeprom_cs = 0x40;

/// Start bit, two opcode bits, six address bits: what the chip listens for
/// before it does anything at all.
const eeprom_command_bits = 9;
const eeprom_data_bits = 16;
/// A read clocks out a dummy zero before the word, so its shift register is a
/// bit wider than the word it holds.
const eeprom_read_bits = eeprom_data_bits + 1;

const EepromOp = enum(u2) { special, write, read, erase };
/// `special` puts its own two bits at the top of the address field.
const EepromSpecial = enum(u2) { disable, write_all, erase_all, enable };

pub const Eeprom = struct {
    data: [eeprom_words]u16 = @splat(eeprom_erased),
    /// Set by any cell that changed, cleared by the frontend once the sidecar
    /// file has been rewritten. A game writes its settings a word at a time.
    dirty: bool = false,

    cs: bool = false,
    clk: bool = false,
    /// Erase and write are refused until an enable command arrives, which is
    /// what stops a glitching board from wiping its own settings.
    writable: bool = false,

    /// What has been clocked in: the command, then a write's data word.
    shift: u16 = 0,
    bits: u8 = 0,
    in_data: bool = false,
    /// The data word about to arrive goes to every cell, not to `addr`.
    all: bool = false,
    addr: u6 = 0,

    /// What is being clocked out, MSB first, and how much of it is left.
    out: u32 = 0,
    out_bits: u8 = 0,

    /// The one wire the 68000 reads back. High while idle: a real chip pulls it
    /// there when it is ready for the next command, and a driver polls for it.
    pub fn read(e: *const Eeprom) u1 {
        if (e.out_bits == 0) return 1;
        return @truncate(e.out >> @intCast(e.out_bits - 1));
    }

    pub fn write(e: *Eeprom, value: u8) void {
        const cs = value & eeprom_cs != 0;
        const clk = value & eeprom_clk != 0;
        // Dropping chip select abandons whatever was half said. The enable
        // latch is not part of that: it holds until a disable command.
        if (!cs) {
            e.* = .{ .data = e.data, .dirty = e.dirty, .writable = e.writable };
            return;
        }
        defer e.clk = clk;
        e.cs = true;
        if (!clk or e.clk) return;
        e.shiftIn(@intFromBool(value & eeprom_di != 0));
    }

    /// One rising clock edge.
    fn shiftIn(e: *Eeprom, di: u1) void {
        if (e.out_bits != 0) {
            e.out_bits -= 1;
            return;
        }
        // Leading zeros are not part of a command: the chip waits for the
        // start bit, so a driver may clock as many of them as it likes. A data
        // word has no start bit and every one of its zeros counts.
        if (!e.in_data and e.bits == 0 and di == 0) return;
        e.shift = e.shift << 1 | di;
        e.bits += 1;

        if (e.in_data) {
            if (e.bits < eeprom_data_bits) return;
            const word = e.shift;
            const all = e.all;
            e.idle();
            if (!all) return e.poke(e.addr, word);
            for (0..eeprom_words) |i| e.poke(@intCast(i), word);
            return;
        }
        if (e.bits < eeprom_command_bits) return;
        e.command();
    }

    fn command(e: *Eeprom) void {
        const addr: u6 = @truncate(e.shift);
        const op: EepromOp = @enumFromInt(@as(u2, @truncate(e.shift >> 6)));
        e.addr = addr;
        e.idle();
        switch (op) {
            .read => {
                e.out = e.data[addr];
                e.out_bits = eeprom_read_bits;
            },
            .write => {
                e.in_data = true;
            },
            .erase => e.poke(addr, eeprom_erased),
            .special => switch (@as(EepromSpecial, @enumFromInt(@as(u2, @truncate(addr >> 4))))) {
                .enable => e.writable = true,
                .disable => e.writable = false,
                .erase_all => for (0..eeprom_words) |i| e.poke(@intCast(i), eeprom_erased),
                // Write-all takes its word the way a write does; every cell
                // gets it rather than the one the address field named.
                .write_all => {
                    e.in_data = true;
                    e.all = true;
                },
            },
        }
    }

    fn poke(e: *Eeprom, addr: u6, value: u16) void {
        if (!e.writable) return;
        e.data[addr] = value;
        e.dirty = true;
    }

    fn idle(e: *Eeprom) void {
        e.shift = 0;
        e.bits = 0;
        e.in_data = false;
        e.all = false;
    }

    /// The `.nv` file beside the set, big-endian so it reads the way the board
    /// does. A short or missing file leaves the rest of the chip erased, which
    /// is what a board whose settings menu grew a page sees on real hardware.
    pub fn load(e: *Eeprom, bytes: []const u8) void {
        e.* = .{};
        for (0..@min(eeprom_words, bytes.len / 2)) |i| {
            e.data[i] = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .big);
        }
    }

    pub fn save(e: *const Eeprom, out: *[eeprom_bytes]u8) void {
        for (e.data, 0..) |word, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], word, .big);
    }
};

pub const Cps = struct {
    /// The battery's contents. Read-only once loaded.
    board: board.Board,
    /// The heap slices, the one exception to the no-allocation rule: reattached
    /// after a save state is loaded rather than copied into it.
    rom: romset.Set,

    v: video.Video = .{},
    ram: [ram_bytes]u8 = @splat(0),
    /// The sound board is a board: its own CPU, its own ROM, its own RAM. The
    /// two shared windows below live on it, because that is the chip they are.
    sound: soundboard.SoundBoard = .{},
    /// Where the resampled result piles up until `main.zig` drains it.
    mixer: audio.Mixer = .{},

    inputs: Inputs = .{},
    /// The settings a board with no DIP switches keeps instead.
    eeprom: Eeprom = .{},
    /// Coin counters and lockouts, latched. Nothing reads them back; they exist
    /// because a game writes them and the write must land somewhere.
    coin_control: u16 = 0,
    coin_control2: u16 = 0,

    /// The reference clock, never reset, and where in the
    /// picture we are.
    ref: u64 = 0,
    frame: u64 = 0,
    line: u32 = 0,
    /// Cycles the last line's final instruction ran past its budget, one per
    /// CPU: neither core stops on a cycle boundary, so what it overran is owed
    /// to the next line rather than forgiven.
    cpu_over: u64 = 0,
    sound_over: u64 = 0,
    /// Reference ticks owed to the Z80's periodic interrupt and to the sound
    /// chip's sample clock, carried the same way the CPUs carry cycles. Which
    /// clock `sample_debt` counts is the board's: the QSound chip's, or the
    /// OPM's.
    sound_irq_debt: u64 = 0,
    sample_debt: u64 = 0,
    /// A CPS-1 board's Z80 does not divide the reference evenly either, so its
    /// cycles are owed rather than budgeted, and the M6295 keeps a debt of its
    /// own because it is the one chip here on a crystal nothing else shares.
    sound_debt: u64 = 0,
    oki_debt: u64 = 0,
    /// The last sample the M6295 finished, held until it finishes another: it
    /// runs at a seventh of the OPM's rate and the mix happens at the OPM's.
    oki_out: i16 = 0,

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
        in0_lo...in0_hi => highByteWide(if (slot(addr) == in0_slot) in0(c) else dsw(c, slot(addr))),
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
        // One wire of the low byte is the EEPROM's data out; the rest of the
        // word is nothing at all.
        eeprom_lo...eeprom_hi => open_bus & ~@as(u16, 1) | c.eeprom.read(),
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

/// The DIP banks, which only a plain CPS-1 board carries.
fn dsw(c: *const Cps, which: u24) u8 {
    if (c.board.sound() != .cps1) return dsw_absent;
    return dsw_setting[which - 1];
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
        eeprom_lo...eeprom_hi => if (mask & low_lane != 0) c.eeprom.write(@truncate(value)),
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
fn eepromBit(c: *Cps, bit: u1) void {
    const di: u16 = if (bit == 1) eeprom_di else 0;
    write8(c, eeprom_lo + 1, @truncate(eeprom_cs | di));
    write8(c, eeprom_lo + 1, @truncate(eeprom_cs | eeprom_clk | di));
    write8(c, eeprom_lo + 1, @truncate(eeprom_cs | di));
}

fn eepromSend(c: *Cps, value: u32, bits: u5) void {
    var i = bits;
    while (i > 0) : (i -= 1) eepromBit(c, @truncate(value >> (i - 1)));
}

fn eepromSelect(c: *Cps, on: bool) void {
    write8(c, eeprom_lo + 1, if (on) eeprom_cs else 0);
}

/// A command is a start bit, two opcode bits and six address bits.
fn eepromCommand(c: *Cps, op: EepromOp, addr: u6) void {
    eepromSelect(c, true);
    eepromSend(c, 1 << (eeprom_command_bits - 1) | @as(u32, @intFromEnum(op)) << 6 | addr, eeprom_command_bits);
}

fn eepromRead(c: *Cps, addr: u6) !u16 {
    eepromCommand(c, .read, addr);
    // The chip answers with a dummy zero and then the word, MSB first.
    try testing.expectEqual(@as(u16, 0), read16(c, eeprom_lo) & 1);
    var word: u16 = 0;
    for (0..eeprom_data_bits) |_| {
        eepromBit(c, 0);
        word = word << 1 | @as(u16, @truncate(read16(c, eeprom_lo) & 1));
    }
    eepromSelect(c, false);
    return word;
}

test "the EEPROM answers the 93C46 protocol a service menu speaks" {
    var c = bare();
    // An erased chip, and a write refused until one is enabled.
    try testing.expectEqual(@as(u16, eeprom_erased), try eepromRead(&c, 3));
    eepromCommand(&c, .write, 3);
    eepromSend(&c, 0x1234, eeprom_data_bits);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, eeprom_erased), try eepromRead(&c, 3));
    try testing.expect(!c.eeprom.dirty);

    eepromCommand(&c, .special, @as(u6, @intFromEnum(EepromSpecial.enable)) << 4);
    eepromSelect(&c, false);
    eepromCommand(&c, .write, 3);
    eepromSend(&c, 0x1234, eeprom_data_bits);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, 0x1234), try eepromRead(&c, 3));
    try testing.expect(c.eeprom.dirty);
    // Its neighbours are untouched, and so is the rest of the chip.
    try testing.expectEqual(@as(u16, eeprom_erased), try eepromRead(&c, 4));

    eepromCommand(&c, .erase, 3);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, eeprom_erased), try eepromRead(&c, 3));

    // Disabling holds across chip select, which is what stops a glitch from
    // wiping the settings.
    eepromCommand(&c, .special, @as(u6, @intFromEnum(EepromSpecial.disable)) << 4);
    eepromSelect(&c, false);
    eepromCommand(&c, .write, 7);
    eepromSend(&c, 0xbeef, eeprom_data_bits);
    eepromSelect(&c, false);
    try testing.expectEqual(@as(u16, eeprom_erased), try eepromRead(&c, 7));

    // The idle wire reads high, and nothing but bit 0 is driven at all.
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, eeprom_lo));
}

test "the EEPROM round-trips through the file beside the set" {
    var e = Eeprom{};
    e.data[0] = 0x0102;
    e.data[eeprom_words - 1] = 0xfeed;
    var bytes: [eeprom_bytes]u8 = undefined;
    e.save(&bytes);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, bytes[0..2]);

    var back = Eeprom{};
    back.load(&bytes);
    try testing.expectEqualSlices(u16, &e.data, &back.data);

    // A short file fills the front and leaves the rest erased.
    back.load(bytes[0..4]);
    try testing.expectEqual(@as(u16, 0x0102), back.data[0]);
    try testing.expectEqual(@as(u16, eeprom_erased), back.data[eeprom_words - 1]);
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
