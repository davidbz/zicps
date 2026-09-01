//! CPS-2's frame loop: what happens in a line, and in what order.
//!
//! The clocks and the sound board's share of a line are the same on every
//! generation and live in `common/clock.zig` — `runSound`'s QSound arm is the
//! same call CPS-1 makes, because it is the same sound board. What is this
//! board's is the order, and one thing CPS-1 does not do at all: the program is
//! decrypted here, once, at power-on, because this is the first moment the key
//! and the ROM it opens are in the same place.
//!
//! The line is drawn where CPS-1 draws it, out of `cps2/video.zig`, and the
//! object list is latched at the same vblank edge. What differs is only what is
//! latched: a bank of the board's own RAM, and the ranking that went with it.

const std = @import("std");
const m68k = @import("m68k");
const board = @import("board");
const cps2 = @import("cps2");
const crypt = @import("cps2_crypt");
const video = @import("cps2_video");
/// The CPS-A/CPS-B pair the whole family shares.
const chip = @import("video");
const clock = @import("clock");
const soundboard = @import("soundboard");

const Core = m68k.Core(cps2.Machine);

/// Re-exported so nothing downstream needs the CPU package wired in just to
/// name the register file it hands us.
pub const Cpu = m68k.Cpu;

pub const vint_level = clock.vint_level;
pub const rint_level = clock.rint_level;
pub const vblank_line = clock.vblank_line;

/// Runs one whole frame, line by line.
pub fn runFrame(c: *cps2.Machine, cpu: *m68k.Cpu) void {
    c.t.line = 0;
    while (c.t.line < chip.lines_per_frame) : (c.t.line += 1) {
        runLine(c, cpu);
        c.t.ref += clock.ref_per_line;
    }
    c.t.frame +%= 1;
}

fn runLine(c: *cps2.Machine, cpu: *m68k.Cpu) void {
    clock.runCpu(cps2.Machine, c, cpu, c.board.cpu_hz);
    clock.runSound(&c.t, &c.sound, &c.mixer);

    // Line, then interrupts: what the CPU wrote during a line is on screen for
    // that line, and an interrupt raised at the end of one is taken from the
    // start of the next.
    video.renderLine(c, c.t.line);

    // The object list is double-buffered in RAM of its own here rather than in
    // graphics RAM, but vblank is still when the chip takes its copy: sprites
    // written during a frame are drawn in the next one.
    if (c.t.line == vblank_line) video.latchObjects(c);

    // The raster counters are the same two down-counters CPS-B has always had,
    // and vblank is on the line after the last visible one. An interrupt raised
    // at the end of a line is taken from the start of the next.
    var level: u3 = 0;
    if (chip.rasterDue(&c.v, &c.board, c.t.line)) level |= rint_level;
    if (c.t.line == vblank_line) level |= vint_level;
    Core.setIpl(cpu, level);
}

/// Power-on: the program is decrypted, the 68000 is put on its reset vector and
/// the sound board is handed its ROM, which on this generation is in clear.
pub fn reset(c: *cps2.Machine, cpu: *m68k.Cpu) void {
    decrypt(c);

    cpu.* = .{};
    Core.reset(cpu, c);

    soundboard.reset(&c.sound);
    soundboard.load(&c.sound, .qsound, c.rom.audio, c.rom.qsound, null);
}

/// Fills the opcode view of the program. A set loaded with no room for one —
/// every test in this repo, and any CPS-1 set — is left reading its opcodes out
/// of the program itself, which is a board with no cipher rather than a broken
/// one.
///
/// ponytail: this is 65,536 key schedules and a pass over 4 MiB, which is under
/// a tenth of a second in a release build and two thirds of one in a debug
/// build, taken again on every reset. Cache it on the set if a reset ever feels
/// slow enough to notice.
fn decrypt(c: *cps2.Machine) void {
    var key = crypt.readKey(c.rom.key);
    // A set that arrives without the twenty bytes its battery held runs its own
    // ciphertext, unless the board file wrote that key down. The set's own key
    // always wins: a real battery beats a transcription.
    c.key_from_board = key.dead and c.board.crypt != null;
    if (c.key_from_board) key = .{
        .master = c.board.crypt.?.master,
        // The board file holds byte addresses, the way MAME writes them.
        .lower = c.board.crypt.?.lower / 2,
        .upper = c.board.crypt.?.upper / 2,
        .dead = false,
    };
    c.suicided = key.dead;
    if (c.rom.decrypted.ptr == c.rom.program.ptr) return;
    crypt.decrypt(c.rom.program, c.rom.decrypted, key);
}

/// Everything a frame can have changed, in one number: what `--frames N` prints
/// and what a replay is compared on.
pub fn hash(c: *const cps2.Machine, cpu: *const m68k.Cpu) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.sliceAsBytes(&c.v.fb));
    h.update(&c.ram);
    h.update(&c.extra);
    h.update(std.mem.sliceAsBytes(&c.objram));
    h.update(std.mem.sliceAsBytes(&c.output));
    h.update(std.mem.sliceAsBytes(&c.v.gfxram));
    h.update(std.mem.sliceAsBytes(&c.v.palette));
    h.update(std.mem.sliceAsBytes(&c.v.a));
    h.update(std.mem.sliceAsBytes(&c.v.b));
    h.update(std.mem.asBytes(&cpu.d));
    h.update(std.mem.asBytes(&cpu.a));
    h.update(std.mem.asBytes(&cpu.pc));
    h.update(std.mem.asBytes(&cpu.cycles));
    // The sound board is state the picture cannot show, which is the whole
    // reason the hash is more than the framebuffer.
    h.update(std.mem.sliceAsBytes(&c.sound.shared));
    h.update(std.mem.sliceAsBytes(&c.sound.q.regs));
    h.update(std.mem.sliceAsBytes(&c.sound.q.voice));
    h.update(std.mem.sliceAsBytes(&c.sound.q.pan));
    h.update(std.mem.asBytes(&c.sound.q.out));
    h.update(std.mem.asBytes(&c.sound.cpu.pc));
    h.update(std.mem.asBytes(&c.sound.cpu.cycles));
    return h.final();
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A program that spins on itself, with a stack pointer and a reset vector
/// ahead of it. The 68000 fetches all three out of the opcode window, so this
/// is also what proves the two views are the same when nothing decrypts.
fn spinRom() [0x408]u8 {
    var rom: [0x408]u8 = @splat(0);
    std.mem.writeInt(u32, rom[0..4], 0x00ff0000, .big);
    std.mem.writeInt(u32, rom[4..8], 0x00000400, .big);
    // BRA.b -2: branch to itself, forever.
    std.mem.writeInt(u16, rom[0x400..0x402], 0x60fe, .big);
    return rom;
}

fn spinning(rom: []u8) cps2.Machine {
    var c = cps2.Machine{
        .board = .{ .system = .cps2, .cpu_hz = board.cps2_cpu_hz },
        .rom = .empty,
    };
    c.rom.program = rom;
    c.rom.decrypted = rom;
    return c;
}

test "the 68000 starts at its reset vector, out of the opcode window" {
    var rom = spinRom();
    var c = spinning(&rom);
    var cpu: m68k.Cpu = .{};
    reset(&c, &cpu);

    try testing.expectEqual(@as(u32, 0x00000400), cpu.pc);
    try testing.expectEqual(@as(u32, 0x00ff0000), cpu.a[7]);
    // No key ROM at all reads as a board whose battery has gone.
    try testing.expect(c.suicided);
}

test "a set with no key of its own runs on the key the board file holds" {
    var rom = spinRom();
    var dec: [0x408]u8 = @splat(0);
    var c = spinning(&rom);
    c.rom.decrypted = &dec;
    // What avsp's battery held, as the board file writes it down.
    c.board.crypt = .{ .master = .{ 0x15208f79, 0x4ade6cb3 }, .lower = 0, .upper = 0x100000 };
    var cpu: m68k.Cpu = .{};
    reset(&c, &cpu);

    try testing.expect(!c.suicided);
    try testing.expect(c.key_from_board);
    // The opcode at 0x400 is inside the range that key covers, so the view
    // the 68000 fetches from is no longer the program itself.
    try testing.expect(!std.mem.eql(u8, rom[0x400..0x402], dec[0x400..0x402]));
}

test "a frame runs a 16 MHz frame's worth of cycles, and the remainder carries" {
    var rom = spinRom();
    var c = spinning(&rom);
    var cpu: m68k.Cpu = .{};
    reset(&c, &cpu);

    const start = cpu.cycles;
    runFrame(&c, &cpu);
    const ran = cpu.cycles - start;
    const per_line = clock.cpuPerLine(c.board.cpu_hz);
    const want = per_line * chip.lines_per_frame;

    try testing.expect(ran >= want);
    try testing.expect(ran - want < per_line);
    try testing.expectEqual(@as(u64, 1), c.t.frame);
    try testing.expectEqual(clock.ref_per_frame, c.t.ref);

    // Ten more frames must not drift: the debt does its job.
    for (0..10) |_| runFrame(&c, &cpu);
    const total = cpu.cycles - start;
    try testing.expect(total >= want * 11);
    try testing.expect(total - want * 11 < per_line);
}

/// The same spin, but with the interrupt mask down and a level 2 handler that
/// counts the vblanks in the first word of RAM.
fn vblankRom() [0x508]u8 {
    const rom = spinRom();
    var wide: [0x508]u8 = @splat(0);
    @memcpy(wide[0..rom.len], &rom);

    const handler = 0x500;
    std.mem.writeInt(u32, wide[0..4], cps2.ram_lo + 0x1000, .big);
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

test "the opcode window is what the 68000 runs, and the ROM is what it reads" {
    var rom = spinRom();
    var opcodes = spinRom();
    var c = spinning(&rom);
    c.rom.decrypted = &opcodes;
    var cpu: m68k.Cpu = .{};
    reset(&c, &cpu);

    // A second view where the spin is a NOP into an infinite loop one word
    // along: same ROM, different program, which is what a key makes. Planted
    // after the reset, because the reset is what fills that view.
    std.mem.writeInt(u16, opcodes[0x400..0x402], 0x4e71, .big);
    std.mem.writeInt(u16, opcodes[0x402..0x404], 0x60fe, .big);

    runFrame(&c, &cpu);
    // It ran the NOP and settled in the loop after it, which is only in the
    // decrypted view; the plain ROM would have kept it at 0x400.
    try testing.expectEqual(@as(u32, 0x402), cpu.pc);
}
