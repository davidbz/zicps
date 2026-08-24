//! The frame loop (DESIGN.md §3.3).
//!
//! A CPS-1.5 board has three independent oscillators and no master clock, so
//! time here is a 120 MHz reference tick: the smallest rate that divides all
//! four of the board's into integers. It is a modelling convenience, not a wire
//! on the board.
//!
//! A line is the step. The 68000 gets a line's worth of cycles, and because an
//! instruction is not split at the boundary, whatever it overran by is taken off
//! the next line. The reference counter is absolute and never reset: every
//! question a chip asks about its own state turns out to be a question about
//! when.

const std = @import("std");
const m68k = @import("m68k");
const cps = @import("cps");
const video = @import("video");

const Core = m68k.Core(cps.Cps);

/// Re-exported so nothing downstream needs the CPU package wired in just to
/// name the register file it hands us.
pub const Cpu = m68k.Cpu;

pub const reference_hz = 120_000_000;
pub const cpu_hz = 12_000_000;
pub const sound_hz = 8_000_000;
pub const pixel_hz = 8_000_000;

pub const ref_per_cpu = reference_hz / cpu_hz;
pub const ref_per_sound = reference_hz / sound_hz;
pub const ref_per_dot = reference_hz / pixel_hz;

pub const ref_per_line = ref_per_dot * video.dots_per_line;
pub const ref_per_frame = ref_per_line * video.lines_per_frame;

/// 7680 reference ticks a line divide by 10 exactly, so the 68000 carries no
/// remainder from line to line and needs no debt counter of its own. QSound's
/// 4992 does not divide evenly, and brings §3.3's debt machinery with it at M4.
pub const cpu_per_line = ref_per_line / ref_per_cpu;
pub const sound_per_line = ref_per_line / ref_per_sound;

comptime {
    std.debug.assert(ref_per_line % ref_per_cpu == 0);
    std.debug.assert(ref_per_line % ref_per_sound == 0);
}

/// The refresh rate the picture actually runs at, as a ratio, so nothing in the
/// emulator has to round it. 8 MHz over 134,144 dots is 59.6374 Hz — DESIGN.md
/// §3.3 said 59.6295, which is an arithmetic slip; MAME's own comment on the
/// same numbers says 59.63.
pub const refresh_num = pixel_hz;
pub const refresh_den = video.dots_per_line * video.lines_per_frame;

/// Runs one whole frame, line by line.
pub fn runFrame(c: *cps.Cps, cpu: *m68k.Cpu) void {
    c.line = 0;
    while (c.line < video.lines_per_frame) : (c.line += 1) {
        runLine(c, cpu);
        c.ref += ref_per_line;
    }
    c.frame +%= 1;
}

fn runLine(c: *cps.Cps, cpu: *m68k.Cpu) void {
    // A line whose predecessor overran by more than a whole line's budget owes
    // the difference forward rather than running backwards.
    const budget = cpu_per_line -| c.cpu_over;
    const ran = Core.run(cpu, c, budget);
    c.cpu_over = c.cpu_over + ran - cpu_per_line;
}

/// Fills the reset vector and puts the 68000 on it.
pub fn reset(c: *cps.Cps, cpu: *m68k.Cpu) void {
    cpu.* = .{};
    Core.reset(cpu, c);
}

/// Everything a frame can have changed, in one number: what `--frames N` prints
/// and what a replay is compared on (DESIGN.md §6.1). The framebuffer alone is
/// not enough at M0 — nothing draws yet, so a picture-only hash would be the
/// same on every run of every set and would prove nothing.
pub fn hash(c: *const cps.Cps, cpu: *const m68k.Cpu) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.sliceAsBytes(&c.v.fb));
    h.update(&c.ram);
    h.update(std.mem.sliceAsBytes(&c.v.gfxram));
    h.update(std.mem.sliceAsBytes(&c.v.palette));
    h.update(std.mem.sliceAsBytes(&c.v.a));
    h.update(std.mem.sliceAsBytes(&c.v.b));
    h.update(std.mem.asBytes(&cpu.d));
    h.update(std.mem.asBytes(&cpu.a));
    h.update(std.mem.asBytes(&cpu.pc));
    h.update(std.mem.asBytes(&cpu.cycles));
    return h.final();
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A program ROM that spins on itself, with a stack pointer and a reset vector
/// ahead of it. Enough to prove the 68000 starts where the board tells it to.
fn spinRom() [0x408]u8 {
    var rom: [0x408]u8 = @splat(0);
    std.mem.writeInt(u32, rom[0..4], 0x00ff0000, .big);
    std.mem.writeInt(u32, rom[4..8], 0x00000400, .big);
    // BRA.b -2: branch to itself, forever.
    std.mem.writeInt(u16, rom[0x400..0x402], 0x60fe, .big);
    return rom;
}

fn spinning(rom: []u8) cps.Cps {
    return .{
        .board = .{},
        .rom = .{ .program = rom, .gfx = &.{}, .audio = &.{}, .qsound = &.{} },
    };
}

test "the 68000 starts at its reset vector" {
    var rom = spinRom();
    var c = spinning(&rom);
    var cpu: m68k.Cpu = .{};
    reset(&c, &cpu);

    try testing.expectEqual(@as(u32, 0x00000400), cpu.pc);
    try testing.expectEqual(@as(u32, 0x00ff0000), cpu.a[7]);
}

test "a frame runs a frame's worth of cycles, and the remainder carries" {
    var rom = spinRom();
    var c = spinning(&rom);
    var cpu: m68k.Cpu = .{};
    reset(&c, &cpu);

    const start = cpu.cycles;
    runFrame(&c, &cpu);
    const ran = cpu.cycles - start;
    const want = cpu_per_line * video.lines_per_frame;

    // A frame may overrun by at most one instruction, never more, because the
    // overrun is taken back off the next line.
    try testing.expect(ran >= want);
    try testing.expect(ran - want < cpu_per_line);
    try testing.expectEqual(@as(u64, 1), c.frame);
    try testing.expectEqual(ref_per_frame, c.ref);

    // Ten more frames must not drift: the debt does its job.
    for (0..10) |_| runFrame(&c, &cpu);
    const total = cpu.cycles - start;
    try testing.expect(total >= want * 11);
    try testing.expect(total - want * 11 < cpu_per_line);
}

test "one line is the same slice of time for every part of the board" {
    try testing.expectEqual(@as(u64, 7680), ref_per_line);
    try testing.expectEqual(@as(u64, 768), cpu_per_line);
    try testing.expectEqual(@as(u64, 512), sound_per_line);
    // 59.6374 Hz, to four places, without floating point in the constant.
    try testing.expectEqual(@as(u64, 596374), refresh_num * 10_000 / refresh_den);
}
