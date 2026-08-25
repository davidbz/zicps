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
const audio = @import("audio");
const qsound = @import("qsound");
const soundboard = @import("soundboard");

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

/// 7680 reference ticks a line divide by 10 and by 15 exactly, so neither CPU
/// carries a remainder from line to line and neither needs a debt counter of
/// its own. QSound's 4992 does not divide evenly, and brings §3.3's debt
/// machinery with it.
pub const cpu_per_line = ref_per_line / ref_per_cpu;
pub const sound_per_line = ref_per_line / ref_per_sound;

comptime {
    std.debug.assert(ref_per_line % ref_per_cpu == 0);
    std.debug.assert(ref_per_line % ref_per_sound == 0);
}

/// The QSound chip's own crystal and the divider it runs its sample clock at:
/// one stereo frame every 4992 reference ticks, 24.038 kHz.
pub const qsound_hz = 60_000_000;
pub const qsound_divider = 2496;
pub const ref_per_sample = reference_hz / qsound_hz * qsound_divider;

/// That rate as the exact fraction the mixer resamples on, rather than a
/// rounded 24_038: the chip's rate is not a whole number of hertz, and the
/// fraction is what stops 48 kHz output from drifting against it.
pub const qsound_rate = audio.Rate{ .out = audio.sample_rate * qsound_divider, .in = qsound_hz };

/// The sound board's Z80 takes a periodic interrupt off a divider on its own
/// clock: 8 MHz over 32000 is 250 Hz, which is what a driver counts its
/// envelope ticks on. Nothing on the board makes it line-synchronous, so it
/// gets the same debt treatment as the sample clock.
pub const sound_irq_hz = sound_hz / 32_000;
pub const ref_per_sound_irq = reference_hz / sound_irq_hz;

/// The refresh rate the picture actually runs at, as a ratio, so nothing in the
/// emulator has to round it: 8 MHz over 134,144 dots is 59.6374 Hz.
pub const refresh_num = pixel_hz;
pub const refresh_den = video.dots_per_line * video.lines_per_frame;

/// Vblank on the line after the last visible one, the raster counters at
/// whatever line they were programmed for, and — when the two land together —
/// both pins at once, which the 68000 reads as level 6.
pub const vint_level = 2;
pub const rint_level = 4;
pub const vblank_line = video.first_visible_line + video.height;

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
    const start = cpu.cycles;

    // The interrupt is a level held on a pin, and the board drops it when the
    // 68000 acknowledges. z68k has no acknowledge hook, so a line with one
    // still on the pin is stepped rather than run, and the pin is dropped the
    // instant the vector is entered — otherwise a handler that returns inside
    // the same line takes the same vblank over and over.
    while (cpu.pending_ipl != 0 and cpu.cycles -% start < budget) {
        const takeable = cpu.pending_ipl > cpu.sr.ipl;
        Core.step(cpu, c);
        if (takeable) Core.setIpl(cpu, 0);
    }
    const stepped = cpu.cycles -% start;
    if (stepped < budget) _ = Core.run(cpu, c, budget - stepped);

    const ran = cpu.cycles -% start;
    c.cpu_over = c.cpu_over + ran - cpu_per_line;

    runSound(c);

    // Line, then interrupts: what the CPU wrote during a line is on screen for
    // that line, and an interrupt raised at the end of one is taken from the
    // start of the next.
    video.renderLine(&c.v, &c.board, c.rom.gfx, c.line, c.frame);

    // The object list is double-buffered, and vblank is when the chip takes its
    // copy: sprites written during a frame are drawn in the next one.
    if (c.line == vblank_line) video.latchObjects(&c.v);

    // ponytail: an interrupt is dropped after one line if the CPU never took
    // it, where the real board holds it until the acknowledge cycle. A game
    // that masks the level across all 768 cycles of the line misses that
    // frame. Add an acknowledge callback to z68k if one ever turns out to.
    var level: u3 = 0;
    if (video.rasterDue(&c.v, &c.board, c.line)) level |= rint_level;
    if (c.line == vblank_line) level |= vint_level;
    Core.setIpl(cpu, level);
}

/// The sound board's share of the same line: the Z80's cycles, the interrupts
/// its divider raised while they ran, and the samples the chip finished.
///
/// The 68000 has already had its line by the time this runs. The two CPUs only
/// meet in shared RAM, and a byte posted there is read a line later at worst,
/// which is well inside what a sound driver polls at.
fn runSound(c: *cps.Cps) void {
    const s = &c.sound;

    // A set with no sound ROM has no sound board — the in-repo test ROM is one
    // (DESIGN.md §8.1) — and a Z80 fetching 0xff out of empty space would spend
    // the run taking RST 38 and pushing return addresses into RAM.
    if (s.rom.len == 0) return;

    c.sound_irq_debt += ref_per_line;
    while (c.sound_irq_debt >= ref_per_sound_irq) : (c.sound_irq_debt -= ref_per_sound_irq) {
        s.int_pending = true;
    }

    const budget = sound_per_line -| c.sound_over;
    const start = s.cpu.cycles;
    while (s.cpu.cycles -% start < budget) {
        soundboard.interrupt(s);
        soundboard.step(s);
    }
    c.sound_over = c.sound_over + (s.cpu.cycles -% start) - sound_per_line;

    // ponytail: the chip is sampled after the Z80 has had the whole line
    // rather than in step with it, so a register written mid-line takes effect
    // from the line's first sample. At 24 kHz that is 16 samples of slack on a
    // note's start; slice it finer only if a game turns out to hear it.
    c.sample_debt += ref_per_line;
    while (c.sample_debt >= ref_per_sample) : (c.sample_debt -= ref_per_sample) {
        const f = qsound.sample(&s.q);
        c.mixer.pushNative(f.l, f.r, qsound_rate);
    }
}

/// Fills the reset vector and puts the 68000 on it, and hands the sound board
/// its ROM: the Kabuki key is the board's, so this is the first moment both
/// halves of the machine are in one place.
pub fn reset(c: *cps.Cps, cpu: *m68k.Cpu) void {
    cpu.* = .{};
    Core.reset(cpu, c);

    soundboard.reset(&c.sound);
    soundboard.load(&c.sound, c.rom.audio, c.board.kabuki);
}

/// Everything a frame can have changed, in one number: what `--frames N` prints
/// and what a replay is compared on (DESIGN.md §6.1). More than the picture, so
/// that a divergence which has not reached the screen yet is still caught.
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
    // The sound board is state the picture cannot show, which is the whole
    // reason the hash is more than the framebuffer: a driver that has gone off
    // the rails diverges here frames before anything else notices.
    h.update(std.mem.sliceAsBytes(&c.sound.shared));
    h.update(std.mem.sliceAsBytes(&c.sound.q.regs));
    h.update(std.mem.asBytes(&c.sound.cpu.pc));
    h.update(std.mem.asBytes(&c.sound.cpu.cycles));
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

/// The same spin, but with the interrupt mask down and a level 2 handler that
/// counts the vblanks in the first word of RAM.
///
///     0x400: move.w #$2000, sr   ; supervisor, mask 0
///     0x404: bra.b  -2
///     0x500: addq.w #1, ($ff0000).l
///            rte
fn vblankRom() [0x508]u8 {
    const rom = spinRom();
    var wide: [0x508]u8 = @splat(0);
    @memcpy(wide[0..rom.len], &rom);

    // Unlike the spin, this one takes exceptions, so its stack has to be in
    // RAM rather than at the very bottom of it.
    const handler = 0x500;
    std.mem.writeInt(u32, wide[0..4], cps.ram_lo + 0x1000, .big);
    std.mem.writeInt(u32, wide[m68k.Exception.autovector(vint_level).vectorAddr()..][0..4], handler, .big);
    for ([_]u16{ 0x46fc, 0x2000, 0x60fe }, 0..) |word, i| {
        std.mem.writeInt(u16, wide[0x400 + i * 2 ..][0..2], word, .big);
    }
    for ([_]u16{ 0x5279, 0x00ff, 0x0000, 0x4e73 }, 0..) |word, i| {
        std.mem.writeInt(u16, wide[handler + i * 2 ..][0..2], word, .big);
    }
    return wide;
}

test "vblank comes once a frame, at level 2" {
    var rom = vblankRom();
    var c = spinning(&rom);
    var cpu: m68k.Cpu = .{};
    reset(&c, &cpu);

    const frames = 5;
    for (0..frames) |_| runFrame(&c, &cpu);
    try testing.expectEqual(@as(u16, frames), std.mem.readInt(u16, c.ram[0..2], .big));

    // And it is level 2 the handler was reached by: masking level 2 out stops
    // the count, where a level 4 or 6 interrupt would still get through.
    cpu.sr.ipl = vint_level;
    for (0..frames) |_| runFrame(&c, &cpu);
    try testing.expectEqual(@as(u16, frames), std.mem.readInt(u16, c.ram[0..2], .big));
}

test "one line is the same slice of time for every part of the board" {
    try testing.expectEqual(@as(u64, 7680), ref_per_line);
    try testing.expectEqual(@as(u64, 768), cpu_per_line);
    try testing.expectEqual(@as(u64, 512), sound_per_line);
    // 59.6374 Hz, to four places, without floating point in the constant.
    try testing.expectEqual(@as(u64, 596374), refresh_num * 10_000 / refresh_den);
}
