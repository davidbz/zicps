//! The machine: the whole CP System II board as one struct, and the 68000's bus.
//!
//! The same shape as `cps1/machine.zig` and for the same reasons — a word bus
//! with byte-wide devices on one lane of it, every address decoded here and
//! nowhere else — over a different map. What is genuinely new is two things:
//! the opcode window, where the 68000 fetches out of a decrypted copy of the
//! program while every data read sees the ROM as it was dumped, and object RAM,
//! which is two banks the CPU switches between rather than a copy taken out of
//! graphics RAM.
//!
//! There are no DIP switches and no Kabuki: the settings are in the EEPROM and
//! the sound Z80 runs its ROM in clear.

const std = @import("std");
const board = @import("board");
const romset = @import("romset");
const bus = @import("bus");
/// The CPS-A/CPS-B pair the whole family shares.
const chip = @import("video");
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
const peek = bus.peek;
const lowMask = bus.lowMask;
const merge = bus.merge;
const pokeBytes = bus.pokeBytes;
const pokeByteWide = bus.pokeByteWide;

// The 68000's map, as first and last address of each window.
pub const program_lo = 0x000000;
pub const program_hi = 0x3fffff;
/// Where the CPU tells the object hardware which list to draw and at what
/// priority. Six words of latch, and nothing reads them but M12.
pub const output_lo = 0x400000;
pub const output_hi = 0x40000b;
pub const shared_lo = 0x618000;
pub const shared_hi = 0x619fff;
/// The memory on the adapter board, where a game that finds it keeps its high
/// scores, and the word above it whose purpose nobody has written down.
pub const extra_lo = 0x660000;
pub const extra_hi = 0x664001;
pub const objram0_lo = 0x700000;
pub const objram0_hi = 0x701fff;
/// The other bank, mirrored every 8 KiB up to the end of the region.
pub const objram1_lo = 0x708000;
pub const objram1_hi = 0x70ffff;
/// Both register files are decoded twice, and games use both addresses.
pub const cps_a_lo = 0x800100;
pub const cps_a_hi = 0x80013f;
pub const cps_b_lo = 0x800140;
pub const cps_b_hi = 0x80017f;
pub const cps_a2_lo = 0x804100;
pub const cps_a2_hi = 0x80413f;
pub const cps_b2_lo = 0x804140;
pub const cps_b2_hi = 0x80417f;
pub const in0_lo = 0x804000;
pub const in1_lo = 0x804010;
pub const in2_lo = 0x804020;
pub const volume_lo = 0x804030;
pub const eeprom_lo = 0x804040;
/// Only development boards have switches here; a production one floats.
pub const dsw_lo = 0x8040b0;
pub const dsw_hi = 0x8040b2;
pub const objram_bank_lo = 0x8040e0;
pub const gfxram_lo = 0x900000;
pub const gfxram_hi = 0x92ffff;
pub const ram_lo = 0xff0000;
pub const ram_hi = 0xffffff;
/// On a board whose battery has gone the object latch appears at the top of
/// work RAM as well, which is the hole the phoenix patches write through.
pub const dead_output_lo = 0xfffff0;
pub const dead_output_hi = 0xfffffb;

comptime {
    std.debug.assert(cps_a_hi - cps_a_lo + 1 == chip.a_regs_bytes);
    std.debug.assert(cps_b_hi - cps_b_lo + 1 == board.cps_b_bytes);
    std.debug.assert(output_hi - output_lo + 1 == output_words * 2);
}

pub const ram_bytes = 0x10000;
pub const extra_bytes = extra_hi - extra_lo + 1;
pub const objram_bytes = 0x2000;
pub const output_words = 6;
/// Each shared RAM window is one byte per 68000 *word* address, so it is half
/// as many bytes as it is addresses — and the same 4 KiB the Z80 sees.
pub const shared_bytes = soundboard.shared_bytes;

/// IN0 holds player 1 in its low byte and player 2 in its high byte, in the
/// order `controls.Button` already counts them.
const in0_player_bits = 8;
/// IN1 carries the buttons a six-button harness has no room for on IN0: the
/// top row, three for player 1 and two for player 2.
const in1_p1_shift = @intFromEnum(controls.Button.b4);
const in1_p1_bits = 3;
const in1_p2_shift = 4;
const in1_p2_bits = 2;
/// And player 2's sixth is on IN2, where a four-player cabinet has its third
/// coin slot instead.
const in2_p2_b6 = 0x4000;
const in2_eeprom_do = 0x0001;

/// Which bit of IN2 each panel input is on. The two coins are at the top of the
/// word, the two starts in the middle, and the two service switches at the
/// bottom — the test switch is the one a service menu is entered with.
const in2_bit = [controls.panel_count]u16{ 0x1000, 0x2000, 0x0004, 0x0100, 0x0200, 0x0002 };

/// The three wires the 68000 drives, on the high byte of `0x804040`.
const eeprom_di = 0x1000;
const eeprom_clk = 0x2000;
const eeprom_cs = 0x4000;

/// What the volume register answers. The board has a digital knob with forty
/// positions and this is the top one; bit 14 clear would say the adapter's
/// memory is there and bit 15 clear that a network adapter is, and neither is.
///
/// ponytail: a constant rather than a knob. The frontend already has a volume
/// control of its own, and a second one that only some games show in their test
/// menu is not worth the wire.
const volume_top = 0xe021;

pub const Machine = struct {
    /// The battery's contents. Read-only once loaded.
    board: board.Board,
    /// The heap slices, the one exception to the no-allocation rule: reattached
    /// after a save state is loaded rather than copied into it. `decrypted` is
    /// the second view of the program the opcode window reads.
    rom: romset.Set,

    v: chip.Video = .{},
    ram: [ram_bytes]u8 = @splat(0),
    /// The adapter board's memory. Present in the map whether the adapter is or
    /// not, because a game only uses it if the volume register says it is there.
    extra: [extra_bytes]u8 = @splat(0),
    /// Two banks of object RAM. `0x8040e0` says which of them the CPU is
    /// writing; a game fills the far one and then flips, because the chip is
    /// reading the near one.
    objram: [2][objram_bytes]u8 = @splat(@splat(0)),
    objram_bank: u1 = 0,
    /// Where the object hardware is told what to draw and how to rank it.
    output: [output_words]u16 = @splat(0),

    /// What the object hardware has: the bank it reads and the priority word
    /// that went with it, both as they stood at the last vblank. A sprite the
    /// 68000 writes now is on screen next frame, and a game that reranks its
    /// layers mid-frame does not tear.
    obj: [objram_bytes]u8 = @splat(0),
    pri_ctrl: u16 = 0,
    sound: soundboard.SoundBoard = .{},
    mixer: audio.Mixer = .{},

    inputs: controls.Inputs = .{},
    eeprom: eeprom.Eeprom = .{},
    /// Coin counters, lockouts and the sound CPU's reset line, latched.
    coin_control: u16 = 0,

    /// Whether the access the 68000 is making is an opcode fetch. Set by the
    /// core through the hook below before every bus cycle, and the only thing
    /// that decides which of the two views of the program a read sees.
    program_space: bool = false,
    /// Whether the key ROM read back as a board whose battery has gone. Nothing
    /// in the machine turns on it — a dead board runs on its own ciphertext,
    /// which is exactly what it does on a bench — but the card says so.
    suicided: bool = false,
    /// Whether the key that decrypted the program is the board file's
    /// transcription of what that battery held, the set having carried none.
    key_from_board: bool = false,

    /// Where in the picture the machine is, and what its chips are owed.
    t: clock.Timing = .{},

    // The 68000 core reaches its bus by method call. The functions stay free.
    pub const read8 = file.read8;
    pub const read16 = file.read16;
    pub const write8 = file.write8;
    pub const write16 = file.write16;
    pub const setProgram = file.setProgram;
};

/// The core announcing which address space the next access is in, which on this
/// board is the whole of the encryption: the same address answers with two
/// different words depending on what the 68000 wants it for.
pub fn setProgram(c: *Machine, program: bool) void {
    c.program_space = program;
}

// ------------------------------------------------------------------- reads

pub fn read16(c: *Machine, addr: u24) u16 {
    return switch (addr) {
        program_lo...program_hi => peek(programView(c), addr - program_lo),
        output_lo...output_hi => c.output[(addr - output_lo) / 2],
        shared_lo...shared_hi => byteWide(c.sound.shared[0][(addr - shared_lo) / 2]),
        extra_lo...extra_hi => peek(&c.extra, addr - extra_lo),
        // The bank the CPU is not writing at `0x700000`, which is the one the
        // chip is not drawing. Nothing writes objects through the low window.
        objram1_lo...objram1_hi => peek(&c.objram[c.objram_bank ^ 1], (addr - objram1_lo) & (objram_bytes - 1)),
        cps_b_lo...cps_b_hi => chip.readB(&c.v, &c.board, @truncate(addr - cps_b_lo)),
        cps_b2_lo...cps_b2_hi => chip.readB(&c.v, &c.board, @truncate(addr - cps_b2_lo)),
        in0_lo, in0_lo + 1 => in0(c),
        in1_lo, in1_lo + 1 => in1(c),
        in2_lo, in2_lo + 1 => in2(c),
        volume_lo, volume_lo + 1 => volume_top,
        dsw_lo...dsw_hi => open_bus,
        gfxram_lo...gfxram_hi => peek(&c.v.gfxram, addr - gfxram_lo),
        ram_lo...ram_hi => if (deadLatch(c, addr))
            c.output[(addr - dead_output_lo) / 2]
        else
            peek(&c.ram, addr - ram_lo),
        else => open_bus,
    };
}

/// A byte read takes whichever half of the word its address selects.
pub fn read8(c: *Machine, addr: u24) u8 {
    const word = read16(c, addr & ~@as(u24, 1));
    if (addr & 1 == 0) return @truncate(word >> 8);
    return @truncate(word);
}

/// Which of the two program ROMs a read is answered from: the one that was
/// dumped, or the one the key made of it.
fn programView(c: *const Machine) []const u8 {
    return if (c.program_space) c.rom.decrypted else c.rom.program;
}

/// A board whose key has died decodes almost nothing, and the object latch
/// moves to the top of work RAM — which is inside work RAM's window rather than
/// beside it, so it is a question about an address and not a case of its own.
fn deadLatch(c: *const Machine, addr: u24) bool {
    return c.suicided and addr >= dead_output_lo and addr <= dead_output_hi;
}

/// Controls are wired to ground, so a pressed button reads as a zero.
fn in0(c: *const Machine) u16 {
    const low: u16 = c.inputs.pad[0] & lowMask(in0_player_bits);
    const high: u16 = c.inputs.pad[1] & lowMask(in0_player_bits);
    return ~(low | high << 8);
}

/// The top row of a six-button panel. Button 4 is on IN0 as well, because which
/// of the two a cabinet's harness wires is the cabinet's business: a four-button
/// game reads it there and a six-button one here, and driving both is how one
/// pad serves either without a board file saying which.
fn in1(c: *const Machine) u16 {
    const low: u16 = (c.inputs.pad[0] >> in1_p1_shift) & lowMask(in1_p1_bits);
    const high: u16 = (c.inputs.pad[1] >> in1_p1_shift) & lowMask(in1_p2_bits);
    return ~(low | high << in1_p2_shift);
}

/// The panel, the EEPROM's answer, and the one button that did not fit
/// anywhere else.
fn in2(c: *const Machine) u16 {
    var bits: u16 = 0;
    for (in2_bit, 0..) |bit, i| {
        if (c.inputs.panel & (@as(u8, 1) << @intCast(i)) != 0) bits |= bit;
    }
    if (c.inputs.pad[1] & controls.Button.b6.mask() != 0) bits |= in2_p2_b6;
    // Every wire here is active low except the EEPROM's, which is a chip's
    // output and not a switch to ground.
    return ~bits & ~@as(u16, in2_eeprom_do) | c.eeprom.read();
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
        output_lo...output_hi => merge(&c.output[(addr - output_lo) / 2], value, mask),
        shared_lo...shared_hi => pokeByteWide(&c.sound.shared[0], (addr - shared_lo) / 2, value, mask),
        extra_lo...extra_hi => pokeBytes(&c.extra, addr - extra_lo, value, mask),
        // The low window writes the bank the CPU owns and the high one the bank
        // it does not, which is how a game fills the list it is not showing.
        objram0_lo...objram0_hi => pokeBytes(&c.objram[c.objram_bank], (addr - objram0_lo) & (objram_bytes - 1), value, mask),
        objram1_lo...objram1_hi => pokeBytes(&c.objram[c.objram_bank ^ 1], (addr - objram1_lo) & (objram_bytes - 1), value, mask),
        cps_a_lo...cps_a_hi => chip.writeA(&c.v, &c.board, @truncate(addr - cps_a_lo), value, mask),
        cps_b_lo...cps_b_hi => chip.writeB(&c.v, &c.board, @truncate(addr - cps_b_lo), value, mask),
        cps_a2_lo...cps_a2_hi => chip.writeA(&c.v, &c.board, @truncate(addr - cps_a2_lo), value, mask),
        cps_b2_lo...cps_b2_hi => chip.writeB(&c.v, &c.board, @truncate(addr - cps_b2_lo), value, mask),
        // The EEPROM's three wires are on the high lane and the coin counters
        // on the low one, so a byte write reaches one or the other.
        eeprom_lo, eeprom_lo + 1 => {
            if (mask & high_lane != 0) eepromPins(c, value);
            if (mask & low_lane != 0) merge(&c.coin_control, value, low_lane);
        },
        objram_bank_lo, objram_bank_lo + 1 => if (mask & low_lane != 0) {
            c.objram_bank = @truncate(value & 1);
        },
        gfxram_lo...gfxram_hi => pokeBytes(&c.v.gfxram, addr - gfxram_lo, value, mask),
        ram_lo...ram_hi => if (deadLatch(c, addr))
            merge(&c.output[(addr - dead_output_lo) / 2], value, mask)
        else
            pokeBytes(&c.ram, addr - ram_lo, value, mask),
        else => {},
    }
}

/// The port register the 68000 leaves the three wires on, as the chip sees
/// them: which bit is which is this board's wiring and not the 93C46's.
fn eepromPins(c: *Machine, value: u16) void {
    c.eeprom.write(value & eeprom_cs != 0, value & eeprom_clk != 0, @intFromBool(value & eeprom_di != 0));
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A machine with no ROMs, for exercising the parts of the map that are RAM.
fn bare() Machine {
    return .{ .board = .{ .system = .cps2, .cpu_hz = board.cps2_cpu_hz }, .rom = .empty };
}

test "work RAM, graphics RAM and the adapter's memory answer bytes and words" {
    var c = bare();
    write16(&c, ram_lo, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), read16(&c, ram_lo));
    try testing.expectEqual(@as(u8, 0x12), read8(&c, ram_lo));
    write8(&c, ram_lo + 1, 0xab);
    try testing.expectEqual(@as(u16, 0x12ab), read16(&c, ram_lo));

    write16(&c, gfxram_hi - 1, 0xbeef);
    try testing.expectEqual(@as(u16, 0xbeef), read16(&c, gfxram_hi - 1));
    try testing.expectEqual(@as(u16, open_bus), read16(&c, gfxram_hi + 1));

    write16(&c, extra_hi - 1, 0x5678);
    try testing.expectEqual(@as(u16, 0x5678), read16(&c, extra_hi - 1));
}

test "the opcode window is a second program ROM, and only the 68000 sees it" {
    var program = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var decrypted = [_]u8{ 0x4e, 0x71, 0x4e, 0x75 };
    var c = bare();
    c.rom.program = &program;
    c.rom.decrypted = &decrypted;

    try testing.expectEqual(@as(u16, 0x1122), read16(&c, 0));
    setProgram(&c, true);
    try testing.expectEqual(@as(u16, 0x4e71), read16(&c, 0));
    try testing.expectEqual(@as(u8, 0x75), read8(&c, 3));
    setProgram(&c, false);
    try testing.expectEqual(@as(u16, 0x3344), read16(&c, 2));

    // And the program is read-only either way.
    write16(&c, 0, 0xffff);
    try testing.expectEqual(@as(u16, 0x1122), read16(&c, 0));
}

test "object RAM is two banks, and the register says which one the CPU has" {
    var c = bare();
    write16(&c, objram0_lo, 0xaaaa);
    // The high window is the other bank, and the low one is what the CPU owns.
    try testing.expectEqual(@as(u16, 0), read16(&c, objram1_lo));
    write16(&c, objram1_lo, 0x5555);
    try testing.expectEqual(@as(u16, 0x5555), read16(&c, objram1_lo));

    write16(&c, objram_bank_lo, 1);
    try testing.expectEqual(@as(u1, 1), c.objram_bank);
    // Swapping the bank swaps both windows at once.
    try testing.expectEqual(@as(u16, 0xaaaa), read16(&c, objram1_lo));

    // The high window is mirrored every 8 KiB to the end of the region.
    try testing.expectEqual(@as(u16, 0xaaaa), read16(&c, objram1_lo + 0x6000));
    write16(&c, objram1_lo + 0x2000, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), read16(&c, objram1_lo));
}

test "controls are wired to ground, so a pressed button reads as a zero" {
    var c = bare();
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in0_lo));
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in1_lo));
    // The EEPROM's wire is the one bit here that is not a switch, and an idle
    // chip leaves it high like everything else.
    try testing.expectEqual(@as(u16, 0xffff), read16(&c, in2_lo));

    c.inputs.pad[0] = controls.Button.up.mask() | controls.Button.b1.mask() | controls.Button.b6.mask();
    c.inputs.pad[1] = controls.Button.left.mask() | controls.Button.b4.mask();
    // IN0 holds eight bits per player: the stick and the first four buttons.
    try testing.expectEqual(@as(u16, ~@as(u16, 0x0018 | 0x8200)), read16(&c, in0_lo));
    // The top row is on IN1, three bits for player 1 and two for player 2.
    try testing.expectEqual(@as(u16, ~@as(u16, 0x0004 | 0x0010)), read16(&c, in1_lo));
    // And player 2's sixth button is on IN2 with the panel.
    c.inputs.pad[1] |= controls.Button.b6.mask();
    c.inputs.panel = controls.Panel.coin1.mask() | controls.Panel.start2.mask();
    try testing.expectEqual(@as(u16, ~@as(u16, 0x1000 | 0x0200 | 0x4000)), read16(&c, in2_lo));
}

test "a dead board finds the object latch at the top of its work RAM" {
    var c = bare();
    write16(&c, dead_output_lo, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), read16(&c, dead_output_lo));
    try testing.expectEqual(@as(u16, 0), c.output[0]);

    c.suicided = true;
    write16(&c, dead_output_lo, 0x5678);
    try testing.expectEqual(@as(u16, 0x5678), c.output[0]);
    try testing.expectEqual(@as(u16, 0x5678), read16(&c, output_lo));
    // And the work RAM under it is untouched by either write.
    c.suicided = false;
    try testing.expectEqual(@as(u16, 0x1234), read16(&c, dead_output_lo));
}

test "the sound board is reached through shared RAM, one byte per word address" {
    var c = bare();
    write16(&c, shared_lo, 0x1234);
    write16(&c, shared_lo + 2, 0x5678);
    try testing.expectEqual(@as(u16, 0xff34), read16(&c, shared_lo));
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x78 }, c.sound.shared[0][0..2]);
    // The window is the whole of the Z80's 4 KiB and no more.
    try testing.expectEqual(@as(u16, open_bus), read16(&c, shared_hi + 1));
}

test "both copies of each register file are the same register file" {
    var c = bare();
    write16(&c, cps_a_lo + chip.scroll1_x, 0x0123);
    try testing.expectEqual(@as(u16, 0x0123), c.v.a[chip.scroll1_x / 2]);
    write16(&c, cps_a2_lo + chip.scroll1_x, 0x0456);
    try testing.expectEqual(@as(u16, 0x0456), c.v.a[chip.scroll1_x / 2]);

    write16(&c, cps_b_lo + 0x20, 0x0789);
    try testing.expectEqual(@as(u16, 0x0789), read16(&c, cps_b2_lo + 0x20));
    // The volume knob answers a board with no adapter and no network.
    try testing.expectEqual(@as(u16, volume_top), read16(&c, volume_lo));
}
