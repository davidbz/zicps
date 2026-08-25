//! The differential check for the QSound core (DESIGN.md §9 M4).
//!
//! Verification here is by diff, not by ear, exactly as zigesis validated its
//! FM core against Nuked-OPN2: the same register log is driven into this core
//! and into ctr's `qsound-hle`, one sample at a time, and the two outputs are
//! compared sample by sample. A deviation is either a bug or a deliberate
//! divergence with a reason — DESIGN.md §9 M4 carries the table this prints.
//!
//! The reference is fetched by `tools/fetch_qsound_reference.sh` into
//! gitignored `testdata/`. `build.zig` wires this file in only when it is
//! there, so a fresh checkout is green without it.

const std = @import("std");
const qsound = @import("qsound");

const c = @cImport({
    @cInclude("qsound.h");
});

/// The DSP's own clock. `qsound_start` only divides it down to report a sample
/// rate the harness does not use; the scheduler paces the chip, not this.
const dsp_clock = 60_000_000;

/// A sample ROM small enough to hold in the binary and whole-power-of-two, so
/// that this core's address mask and the reference's unmasked index agree on
/// every address a case reaches.
const rom_bytes = 0x10000;
var sample_rom: [rom_bytes]u8 = undefined;

/// Something with energy at every scale: a slow ramp under a fast square, so
/// a pitch change moves the output and so does a filter change.
fn fillRom() void {
    for (&sample_rom, 0..) |*b, i| {
        const ramp: u8 = @truncate(i >> 6);
        b.* = if (i / 12 % 2 == 0) ramp else ramp ^ 0xc0;
    }
}

// ------------------------------------------------------------- the log

/// One entry in a register log: an optional write, then that many samples
/// pulled out of both chips. Writes land at the same sample in both, so the
/// two output streams line up exactly and the diff needs no alignment.
const Step = struct {
    reg: ?u8 = null,
    value: u16 = 0,
    run: u32 = 1,
};

const Case = struct {
    name: []const u8,
    steps: []const Step,
};

fn vreg(voice: u8, reg: u8) u8 {
    return voice * qsound.voice_regs + reg;
}

/// A voice's bank register sits in the *previous* voice's block — the DSP
/// program reads it one slot early — so voice 0's bank is written at voice 15.
fn bankReg(voice: u8) u8 {
    return vreg((voice + qsound.voices - 1) % qsound.voices, qsound.reg_bank);
}

/// Sets a voice playing at unity volume and one ROM sample per output sample.
fn play(comptime voice: u8, comptime start_at: u16, comptime end_at: u16, comptime loop: u16) [8]Step {
    return .{
        .{ .reg = bankReg(voice), .value = qsound.bank_enable, .run = 0 },
        .{ .reg = vreg(voice, qsound.reg_addr), .value = start_at, .run = 0 },
        .{ .reg = vreg(voice, qsound.reg_phase), .value = 0, .run = 0 },
        .{ .reg = vreg(voice, qsound.reg_rate), .value = 1 << qsound.phase_bits, .run = 0 },
        .{ .reg = vreg(voice, qsound.reg_end_addr), .value = end_at, .run = 0 },
        .{ .reg = vreg(voice, qsound.reg_loop_len), .value = loop, .run = 0 },
        .{ .reg = vreg(voice, qsound.reg_volume), .value = 1 << qsound.volume_shift, .run = 0 },
        .{ .reg = qsound.reg_voice_pan + voice, .value = qsound.pan_centre, .run = 0 },
    };
}

/// The samples the chip spends initialising, before any of this means
/// anything. Both models spend them the same way, which is itself checked.
const boot = Step{ .run = qsound.boot_samples };

const playback = play(0, 0x0100, 0x7f00, 0) ++ [_]Step{
    .{ .run = 400 },
    // A second voice on top of the first, so the mix is a sum of two channels
    // and not one channel with the rest of the file idle.
} ++ play(1, 0x2000, 0x7f00, 0) ++ [_]Step{
    .{ .reg = vreg(1, qsound.reg_volume), .value = 1 << (qsound.volume_shift - 2) },
    .{ .run = 400 },
    // And silencing one of them again leaves the other where it was.
    .{ .reg = vreg(0, qsound.reg_volume), .value = 0 },
    .{ .run = 200 },
};

const looping = play(0, 0x0100, 0x0140, 0x40) ++ [_]Step{
    .{ .run = 600 },
    // A loop shorter than the pan filter, so every tap of it is a loop point.
    .{ .reg = vreg(0, qsound.reg_end_addr), .value = 0x0108 },
    .{ .reg = vreg(0, qsound.reg_loop_len), .value = 8 },
    .{ .run = 600 },
    // A one-shot: no loop length, so the position runs on past the end.
    .{ .reg = vreg(0, qsound.reg_loop_len), .value = 0 },
    .{ .run = 200 },
};

const pitch = play(0, 0x0100, 0x7f00, 0) ++ [_]Step{
    .{ .run = 200 },
    // Half speed, so the fractional phase carries between samples.
    .{ .reg = vreg(0, qsound.reg_rate), .value = 1 << (qsound.phase_bits - 1) },
    .{ .run = 200 },
    // A rate that divides into nothing, which is what a real driver's pitch
    // bend looks like.
    .{ .reg = vreg(0, qsound.reg_rate), .value = 0x0123 },
    .{ .run = 200 },
    // Faster than the sample rate, and fast enough to clamp the position.
    .{ .reg = vreg(0, qsound.reg_rate), .value = 0x1800 },
    .{ .run = 200 },
    .{ .reg = vreg(0, qsound.reg_rate), .value = 0xffff },
    .{ .run = 200 },
    // Stopped: the rate is zero and the voice holds one sample.
    .{ .reg = vreg(0, qsound.reg_rate), .value = 0 },
    .{ .run = 100 },
};

/// The whole pan register range, a step at a time: the two mix curves, the
/// dead band above them, the linear window, and the clamp past the end of it.
const panning = blk: {
    var steps: [8 + 1 + 0x48 * 2]Step = undefined;
    steps[0..8].* = play(0, 0x0100, 0x7f00, 0);
    steps[8] = .{ .run = 100 };
    for (0..0x48) |i| {
        steps[9 + i * 2] = .{ .reg = qsound.reg_voice_pan, .value = qsound.pan_base + i, .run = 0 };
        steps[10 + i * 2] = .{ .run = 20 };
    }
    break :blk steps;
};

const echoing = play(0, 0x0100, 0x7f00, 0) ++ [_]Step{
    .{ .reg = qsound.reg_echo_end, .value = qsound.echo_base + 0x200 },
    .{ .reg = qsound.reg_echo_feedback, .value = 0x2000 },
    .{ .reg = qsound.reg_voice_echo, .value = 0x0800 },
    .{ .run = 1200 },
    // A longer line than the chip has, which the DSP program clamps.
    .{ .reg = qsound.reg_echo_end, .value = qsound.echo_base + 0x800 },
    .{ .run = 600 },
    // And the send off again, so the line drains through the feedback path
    // with nothing new going into it.
    .{ .reg = qsound.reg_voice_echo, .value = 0 },
    .{ .run = 600 },
};

const cases = [_]Case{
    .{ .name = "channel playback", .steps = &(.{boot} ++ playback) },
    .{ .name = "looping", .steps = &(.{boot} ++ looping) },
    .{ .name = "pitch", .steps = &(.{boot} ++ pitch) },
    .{ .name = "panning", .steps = &(.{boot} ++ panning) },
    .{ .name = "echo", .steps = &(.{boot} ++ echoing) },
};

// ------------------------------------------------------------- the diff

const Deviation = struct {
    samples: u32 = 0,
    differing: u32 = 0,
    worst: u32 = 0,
};

/// How far apart the two are allowed to get. Every case is exact, so this is a
/// tripwire rather than a tolerance: a deliberate divergence would need its own
/// entry here with the reason beside it.
const allowed = 0;

fn compare(case: Case) Deviation {
    var mine = qsound.Qsound{};
    qsound.attach(&mine, &sample_rom);

    var theirs: c.struct_qsound_chip = undefined;
    _ = c.qsound_start(&theirs, dsp_clock);
    theirs.rom_data = &sample_rom;
    theirs.rom_mask = rom_bytes - 1;
    c.qsound_reset(&theirs);

    var d = Deviation{};
    for (case.steps) |step| {
        if (step.reg) |reg| {
            const hi: u8 = @truncate(step.value >> 8);
            const lo: u8 = @truncate(step.value);
            qsound.write(&mine, qsound.port_data_hi, hi);
            qsound.write(&mine, qsound.port_data_lo, lo);
            qsound.write(&mine, qsound.port_reg, reg);
            _ = c.qsound_w(&theirs, qsound.port_data_hi, hi);
            _ = c.qsound_w(&theirs, qsound.port_data_lo, lo);
            _ = c.qsound_w(&theirs, qsound.port_reg, reg);
        }
        for (0..step.run) |_| {
            const frame = qsound.sample(&mine);
            var l: i16 = 0;
            var r: i16 = 0;
            var outs = [_][*c]i16{ &l, &r };
            _ = c.qsound_stream_update(&theirs, &outs, 1);

            const gap = @max(apart(frame.l, l), apart(frame.r, r));
            d.samples += 1;
            if (gap != 0) d.differing += 1;
            d.worst = @max(d.worst, gap);
        }
        // The busy flag is part of the interface a driver spins on, so it is
        // diffed too rather than only the audio.
        if (qsound.read(&mine) != c.qsound_r(&theirs)) d.differing += 1;
    }
    return d;
}

fn apart(a: i16, b: i16) u32 {
    return @abs(@as(i32, a) - @as(i32, b));
}

test "the QSound core matches qsound-hle sample for sample" {
    fillRom();

    var results: [cases.len]Deviation = undefined;
    var worst: u32 = 0;
    for (cases, &results) |case, *result| {
        result.* = compare(case);
        worst = @max(worst, result.worst);
    }
    if (worst <= allowed) return;

    // Only a deviation is worth saying out loud; the exact run is the one
    // DESIGN.md §9 M4 publishes, and it says nothing every time it holds.
    std.debug.print("\n  {s:<18}{s:>9}{s:>11}{s:>8}\n", .{ "case", "samples", "differing", "worst" });
    for (cases, results) |case, d| {
        std.debug.print("  {s:<18}{d:>9}{d:>11}{d:>8}\n", .{ case.name, d.samples, d.differing, d.worst });
    }
    return error.DeviatesFromReference;
}
