//! CPS-1's frame loop: what happens in a line, and in what order.
//!
//! The clocks themselves and the sound board's share of a line are the same on
//! every generation and live in `common/clock.zig`. What is this board's is the
//! order: the 68000 gets the line, then the sound board, then the line is drawn
//! with whatever the CPU left in the registers, and only then are the two
//! interrupt pins set for the line after.

const std = @import("std");
const m68k = @import("m68k");
const cps1 = @import("cps1");
/// The CPS-A/CPS-B pair the whole family shares, and this board's half of it.
const chip = @import("video");
const video = @import("cps1_video");
const clock = @import("clock");
const soundboard = @import("soundboard");

const Core = m68k.Core(cps1.Machine);

/// Re-exported so nothing downstream needs the CPU package wired in just to
/// name the register file it hands us.
pub const Cpu = m68k.Cpu;

/// Vblank on the line after the last visible one, the raster counters at
/// whatever line they were programmed for, and — when the two land together —
/// both pins at once, which the 68000 reads as level 6.
pub const vint_level = 2;
pub const rint_level = 4;
pub const vblank_line = chip.first_visible_line + chip.height;

/// Runs one whole frame, line by line.
pub fn runFrame(c: *cps1.Machine, cpu: *m68k.Cpu) void {
    c.t.line = 0;
    while (c.t.line < chip.lines_per_frame) : (c.t.line += 1) {
        runLine(c, cpu);
        c.t.ref += clock.ref_per_line;
    }
    c.t.frame +%= 1;
}

fn runLine(c: *cps1.Machine, cpu: *m68k.Cpu) void {
    // A line whose predecessor overran by more than a whole line's budget owes
    // the difference forward rather than running backwards.
    const budget = clock.cpu_per_line -| c.t.cpu_over;
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
    c.t.cpu_over = c.t.cpu_over + ran - clock.cpu_per_line;

    clock.runSound(&c.t, &c.sound, &c.mixer);

    // Line, then interrupts: what the CPU wrote during a line is on screen for
    // that line, and an interrupt raised at the end of one is taken from the
    // start of the next.
    video.renderLine(&c.v, &c.board, c.rom.gfx, c.t.line, c.t.frame);

    // The object list is double-buffered, and vblank is when the chip takes its
    // copy: sprites written during a frame are drawn in the next one.
    if (c.t.line == vblank_line) video.latchObjects(&c.v);

    // ponytail: an interrupt is dropped after one line if the CPU never took
    // it, where the real board holds it until the acknowledge cycle. A game
    // that masks the level across all 768 cycles of the line misses that
    // frame. Add an acknowledge callback to z68k if one ever turns out to.
    var level: u3 = 0;
    if (chip.rasterDue(&c.v, &c.board, c.t.line)) level |= rint_level;
    if (c.t.line == vblank_line) level |= vint_level;
    Core.setIpl(cpu, level);
}

/// Fills the reset vector and puts the 68000 on it, and hands the sound board
/// its ROM: the Kabuki key is the board's, so this is the first moment both
/// halves of the machine are in one place.
pub fn reset(c: *cps1.Machine, cpu: *m68k.Cpu) void {
    cpu.* = .{};
    Core.reset(cpu, c);

    soundboard.reset(&c.sound);
    const kind = c.board.sound();
    const samples = if (kind == .cps1) c.rom.oki else c.rom.qsound;
    soundboard.load(&c.sound, kind, c.rom.audio, samples, c.board.kabuki);
}

/// Everything a frame can have changed, in one number: what `--frames N` prints
/// and what a replay is compared on. More than the picture, so
/// that a divergence which has not reached the screen yet is still caught.
pub fn hash(c: *const cps1.Machine, cpu: *const m68k.Cpu) u64 {
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
    // And the chip's own state, not only what was written at it: a voice that
    // has walked to the wrong place in the sample ROM is a divergence the
    // register file cannot see.
    h.update(std.mem.sliceAsBytes(&c.sound.q.voice));
    h.update(std.mem.sliceAsBytes(&c.sound.q.pan));
    h.update(std.mem.asBytes(&c.sound.q.out));
    // And the other board's two chips, for the same reason: the OPM's
    // envelopes and the M6295's position in a phrase are both state a driver
    // can walk off the end of without anything on screen moving.
    h.update(std.mem.sliceAsBytes(&c.sound.ym.op));
    h.update(std.mem.sliceAsBytes(&c.sound.ym.ch));
    h.update(std.mem.sliceAsBytes(&c.sound.m6295.voice));
    h.update(std.mem.asBytes(&c.sound.latch));
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

fn spinning(rom: []u8) cps1.Machine {
    return .{
        .board = .{},
        .rom = .{ .program = rom, .gfx = &.{}, .audio = &.{}, .qsound = &.{}, .oki = &.{} },
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
    const want = clock.cpu_per_line * chip.lines_per_frame;

    // A frame may overrun by at most one instruction, never more, because the
    // overrun is taken back off the next line.
    try testing.expect(ran >= want);
    try testing.expect(ran - want < clock.cpu_per_line);
    try testing.expectEqual(@as(u64, 1), c.t.frame);
    try testing.expectEqual(clock.ref_per_frame, c.t.ref);

    // Ten more frames must not drift: the debt does its job.
    for (0..10) |_| runFrame(&c, &cpu);
    const total = cpu.cycles - start;
    try testing.expect(total >= want * 11);
    try testing.expect(total - want * 11 < clock.cpu_per_line);
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
    std.mem.writeInt(u32, wide[0..4], cps1.ram_lo + 0x1000, .big);
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
