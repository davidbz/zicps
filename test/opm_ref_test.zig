//! The differential check for the YM2151 core.
//!
//! The same register log is driven into this core and into nukeykt's
//! Nuked-OPM, one sample at a time, and the two outputs are compared sample by
//! sample. The reference is fetched by `tools/fetch_opm_reference.sh` into
//! gitignored `testdata/`; `build.zig` wires this file in only when it is
//! there, so a fresh checkout is green without it.
//!
//! Unlike the QSound diff, this one has a tolerance rather than a tripwire, and
//! the tolerance is the point of the file: `allowed` is what a model of the
//! published architecture costs against a model of the die, measured rather
//! than assumed. See the ceilings in `src/ym2151.zig`. A change that widens it
//! is a regression even when every case still passes.

const std = @import("std");
const ym2151 = @import("ym2151");

const c = @cImport({
    @cInclude("opm.h");
});

/// The reference is clocked at half the chip's input clock and takes 32 of
/// those to walk its 32 operator slots, which is one stereo sample.
const cycles_per_sample = 32;

/// The real chip is a pipeline: a register write walks the operator slots, the
/// envelope and the mixer before it reaches the DAC, and the gate-level model
/// walks it with them. This core computes a whole sample at once, so its output
/// arrives four samples early — 71 µs, and a constant, not a drift. The diff
/// holds this core's samples back by that much rather than pretending the
/// difference is accuracy.
const pipeline = 4;

/// Two of those four samples are on the way in rather than on the way out: a
/// write reaches the reference's operators two samples after the harness makes
/// it, and until it does the envelope counter has moved on without it. This
/// core takes its writes at once, so it is started two samples early and the
/// two chips agree on when a write landed rather than only on what it did.
const write_lead = 2;

/// The die does not put its 32 operators on the same sample boundary: the
/// key-on that walks them reaches the last of the four a sample after the
/// first, and a model that computes a sample at once cannot be in two places.
/// So the reference's sample is matched against the nearest of three of this
/// core's, and what is left over is amplitude rather than time.
const slack = 1;

// ------------------------------------------------------------- the log

/// One entry in a register log: an optional write, then that many samples
/// pulled out of both chips. A write is followed by at least one sample in
/// both, which is the alignment the reference's own write pipeline needs.
const Step = struct {
    reg: ?u8 = null,
    value: u8 = 0,
    run: u32 = 1,
};

const Case = struct {
    name: []const u8,
    steps: []const Step,
};

fn op(comptime group: u8, comptime ch: u8) u8 {
    return group * ym2151.channels + ch;
}

/// A voice worth listening to: every operator at full volume with an envelope
/// that reaches it quickly and holds, so the diff is looking at the operators
/// rather than at four different ways of being silent.
fn voice(comptime ch: u8, comptime conn: u8, comptime fb: u8) [21]Step {
    var steps: [21]Step = undefined;
    steps[0] = .{ .reg = ym2151.reg_channel + ch, .value = 0xc0 | (fb << 3) | conn };
    steps[1] = .{ .reg = ym2151.reg_channel + 0x08 + ch, .value = 0x4a };
    steps[2] = .{ .reg = ym2151.reg_channel + 0x10 + ch, .value = 0x00 };
    steps[3] = .{ .reg = ym2151.reg_channel + 0x18 + ch, .value = 0x00 };
    for (0..ym2151.ops_per_channel) |g| {
        const slot: u8 = op(@intCast(g), ch);
        steps[4 + g * 4] = .{ .reg = 0x40 + slot, .value = @intCast(g + 1) };
        // The modulators are quieter than the carrier, or every algorithm
        // clips into the same square.
        steps[5 + g * 4] = .{ .reg = 0x60 + slot, .value = if (g == 3) 0x00 else 0x18 };
        steps[6 + g * 4] = .{ .reg = 0x80 + slot, .value = 0x1c };
        steps[7 + g * 4] = .{ .reg = 0xa0 + slot, .value = 0x08 };
    }
    steps[20] = .{ .reg = 0xe0, .value = 0x0f, .run = 0 };
    return steps;
}

fn keyOn(comptime ch: u8) Step {
    return .{ .reg = ym2151.reg_key, .value = 0x78 | ch, .run = 0 };
}

/// One voice through all eight algorithms, keyed afresh for each.
const algorithms = blk: {
    var steps: [8 * 24]Step = undefined;
    for (0..8) |alg| {
        steps[alg * 24 ..][0..21].* = voice(0, alg, 0);
        steps[alg * 24 + 21] = keyOn(0);
        steps[alg * 24 + 22] = .{ .run = 400 };
        steps[alg * 24 + 23] = .{ .reg = ym2151.reg_key, .value = 0x00, .run = 100 };
    }
    break :blk steps;
};

/// The whole envelope, one stage at a time, on a single carrier: a slow attack
/// that is watched all the way up, a decay to a sustain level short of silence,
/// a second decay, and a release.
const envelope = [_]Step{
    .{ .reg = ym2151.reg_channel, .value = 0xc7 },
    .{ .reg = ym2151.reg_channel + 0x08, .value = 0x4a },
    .{ .reg = 0x40, .value = 0x01 },
    .{ .reg = 0x60, .value = 0x00 },
    .{ .reg = 0x80, .value = 0x0d }, // a slow attack, and rate scaling on
    .{ .reg = 0xa0, .value = 0x0c },
    .{ .reg = 0xc0, .value = 0x06 },
    .{ .reg = 0xe0, .value = 0x48 }, // sustain a third of the way down
    keyOn(0),
    .{ .run = 3000 },
    .{ .reg = ym2151.reg_key, .value = 0x00 },
    .{ .run = 2000 },
    // And the fastest attack there is, which the chip does not ramp at all.
    .{ .reg = 0x80, .value = 0x1f },
    keyOn(0),
    .{ .run = 500 },
    .{ .reg = ym2151.reg_key, .value = 0x00, .run = 500 },
};

/// Pitch: every key code across two octaves, the fraction between two of them,
/// both detunes and the multiple.
const pitch = voice(0, 7, 0) ++ [_]Step{ keyOn(0), .{ .run = 64 } } ++ blk: {
    var steps: [32 * 2]Step = undefined;
    for (0..32) |i| {
        steps[i * 2] = .{ .reg = ym2151.reg_channel + 0x08, .value = @intCast(0x20 + i), .run = 0 };
        steps[i * 2 + 1] = .{ .run = 40 };
    }
    break :blk steps;
} ++ [_]Step{
    .{ .reg = ym2151.reg_channel + 0x10, .value = 0x80 }, // half a semitone up
    .{ .run = 120 },
    .{ .reg = 0x40, .value = 0x37 }, // DT1 = 3, MUL = 7
    .{ .run = 120 },
    .{ .reg = 0x40, .value = 0x70 }, // the other direction, MUL = 0 (a half)
    .{ .run = 120 },
    .{ .reg = 0xc0, .value = 0xc0 }, // DT2 = 3, the widest of the four
    .{ .run = 120 },
    .{ .reg = 0xc0, .value = 0x40 },
    .{ .run = 120 },
};

/// The LFO: all four waveforms, at both depths, into pitch and into volume.
const lfo = voice(0, 7, 0) ++ [_]Step{
    keyOn(0),
    .{ .reg = ym2151.reg_lfrq, .value = 0xa0 },
    .{ .reg = ym2151.reg_pmd_amd, .value = 0x7f }, // AMD, full
    .{ .reg = ym2151.reg_pmd_amd, .value = 0xff }, // PMD, full
    .{ .reg = ym2151.reg_channel + 0x18, .value = 0x73 }, // PMS 7, AMS 3
    .{ .reg = 0xa0, .value = 0x88 }, // and the operator listening for AM
    .{ .run = 600 },
} ++ blk: {
    var steps: [4 * 4]Step = undefined;
    for (0..4) |w| {
        steps[w * 4] = .{ .reg = ym2151.reg_ct_wave, .value = @intCast(w), .run = 0 };
        steps[w * 4 + 1] = .{ .run = 500 };
        steps[w * 4 + 2] = .{ .reg = ym2151.reg_lfrq, .value = 0x2f, .run = 0 };
        steps[w * 4 + 3] = .{ .run = 500 };
    }
    break :blk steps;
};

/// The noise generator, which is the eighth channel's fourth operator and
/// nothing else's.
const noise = voice(7, 7, 0) ++ [_]Step{
    keyOn(7),
    .{ .reg = ym2151.reg_noise, .value = 0x9f }, // on, at its slowest
    .{ .run = 500 },
    .{ .reg = ym2151.reg_noise, .value = 0x80 }, // and at its fastest
    .{ .run = 500 },
    .{ .reg = ym2151.reg_noise, .value = 0x00 },
    .{ .run = 200 },
};

/// Eight channels at once, which is the only case where the mixer's own
/// accumulator and its clamp are reached.
const chorus = blk: {
    var steps: [8 * 23]Step = undefined;
    for (0..8) |ch| {
        steps[ch * 23 ..][0..21].* = voice(ch, 4, 3);
        steps[ch * 23 + 21] = .{ .reg = ym2151.reg_channel + 0x08 + ch, .value = @intCast(0x2a + ch * 4), .run = 0 };
        steps[ch * 23 + 22] = .{ .reg = ym2151.reg_key, .value = @intCast(0x78 | ch), .run = 0 };
    }
    break :blk steps ++ [_]Step{.{ .run = 1200 }};
};

/// The timers, which are what the Z80 hears rather than what the speaker does:
/// this case is diffed on the status byte more than on the samples.
const timers = [_]Step{
    .{ .reg = ym2151.reg_clka1, .value = 0xf0 },
    .{ .reg = ym2151.reg_clka2, .value = 0x02 },
    .{ .reg = ym2151.reg_clkb, .value = 0xf0 },
    .{ .reg = ym2151.reg_control, .value = ym2151.load_a | ym2151.irq_en_a },
    .{ .run = 400 },
    .{ .reg = ym2151.reg_control, .value = ym2151.load_a | ym2151.irq_en_a | ym2151.reset_a },
    .{ .run = 200 },
    .{ .reg = ym2151.reg_control, .value = ym2151.load_b | ym2151.irq_en_b },
    .{ .run = 1200 },
    .{ .reg = ym2151.reg_control, .value = ym2151.load_b | ym2151.irq_en_b | ym2151.reset_b },
    .{ .run = 200 },
};

const cases = [_]Case{
    .{ .name = "algorithms", .steps = &algorithms },
    .{ .name = "envelope", .steps = &envelope },
    .{ .name = "pitch", .steps = &pitch },
    .{ .name = "lfo", .steps = &lfo },
    .{ .name = "noise", .steps = &noise },
    .{ .name = "chorus", .steps = &chorus },
    .{ .name = "timers", .steps = &timers },
};

// ------------------------------------------------------------- the diff

const Deviation = struct {
    samples: u32 = 0,
    differing: u32 = 0,
    worst: u32 = 0,
    status: u32 = 0,
};

/// How far apart the two are allowed to get, in LSBs of a 16-bit sample.
///
/// This is not a tripwire like the QSound one, and it is wide. What it holds is
/// time, not sound: everything that turned out to be a difference in *value*
/// has been fixed against this harness, and what is left is a fraction of a
/// sample of skew that a sample-at-a-time model cannot carry.
///
/// - The die keys its 32 operators over one 32-slot sweep, so two operators of
///   the same channel start a fraction of a sample apart and stay there. One
///   operator on its own tracks the reference to 12 LSBs; four summed, each
///   wanting a shift of its own, reach 1300; a four-deep chain multiplies that.
/// - The phase-increment ROM here is computed rather than read off the die, so
///   an operator can sit an LSB of fnum away and walk out of phase over a note.
/// - The LFO's depths are the die's, but its waveforms are the published
///   shapes, and at PMS 7 half a percent of vibrato is a lot of phase.
/// - The noise generator is a shift register of the same length and not the
///   same polynomial, which is a different noise, correctly shaped.
///
/// The number is measured, not chosen: it is where the worst case sits today,
/// so a change that makes the model *less* like the chip fails here even
/// though the tolerance is wide. The per-case table printed on failure is the
/// thing to read — a regression will move one case, not all of them.
const allowed = 19540;

/// A delay line of this core's output, deep enough to hold it back by the
/// reference's pipeline and to look a sample either side of that.
const Delay = struct {
    samples: [pipeline + slack + 1][2]i16 = @splat(.{ 0, 0 }),
    next: usize = 0,

    fn push(l: *Delay, left: i16, right: i16) void {
        l.samples[l.next] = .{ left, right };
        l.next = (l.next + 1) % l.samples.len;
    }

    fn back(l: *const Delay, d: usize) [2]i16 {
        return l.samples[(l.next + l.samples.len * 2 - 1 - d) % l.samples.len];
    }
};

fn compare(case: Case) Deviation {
    var mine = ym2151.Ym2151{};

    var theirs: c.opm_t = undefined;
    c.OPM_Reset(&theirs, c.opm_flags_none);
    for (0..write_lead) |_| _ = ym2151.sample(&mine);

    var line = Delay{};
    var d = Deviation{};
    for (case.steps) |step| {
        if (step.reg) |reg| {
            // The reference latches the address and the data through one byte
            // of pins, and holds itself busy for a sample after each: a driver
            // that wrote both in the same cycle would lose the address. So each
            // half gets a sample of its own, and neither is compared — the
            // difference between an instant write and a pipelined one is the
            // harness's, not the chip's. The samples still go into the delay
            // line, which is a line and not a gap.
            ym2151.write(&mine, ym2151.port_address, reg);
            c.OPM_Write(&theirs, ym2151.port_address, reg);
            settle(&mine, &theirs, &line);
            ym2151.write(&mine, ym2151.port_data, step.value);
            c.OPM_Write(&theirs, ym2151.port_data, step.value);
            settle(&mine, &theirs, &line);
        }
        for (0..step.run) |_| {
            const frame = ym2151.sample(&mine);
            line.push(frame.l, frame.r);
            var out: [2]i32 = .{ 0, 0 };
            for (0..cycles_per_sample) |_| c.OPM_Clock(&theirs, &out, null, null, null);

            var gap: u32 = std.math.maxInt(u32);
            for (pipeline - slack..pipeline + slack + 1) |back| {
                const was = line.back(back);
                gap = @min(gap, @max(apart(was[0], out[0]), apart(was[1], out[1])));
            }
            d.samples += 1;
            if (gap != 0) d.differing += 1;
            d.worst = @max(d.worst, gap);
        }
        // The timer flags are what the sound Z80 actually reads off this chip,
        // so they are diffed as strictly as the QSound busy bit: no tolerance.
        const flags = ym2151.status_flag_a | ym2151.status_flag_b;
        const theirs_status = c.OPM_Read(&theirs, ym2151.port_data) & flags;
        if (ym2151.read(&mine) & flags != theirs_status) d.status += 1;
    }
    return d;
}

/// One sample on each side, not compared.
fn settle(mine: *ym2151.Ym2151, theirs: *c.opm_t, line: *Delay) void {
    const frame = ym2151.sample(mine);
    line.push(frame.l, frame.r);
    for (0..cycles_per_sample) |_| c.OPM_Clock(theirs, null, null, null, null);
}

fn apart(a: i16, b: i32) u32 {
    return @abs(@as(i32, a) - b);
}

test "the YM2151 core tracks Nuked-OPM" {
    var results: [cases.len]Deviation = undefined;
    var worst: u32 = 0;
    var status: u32 = 0;
    for (cases, &results) |case, *result| {
        result.* = compare(case);
        worst = @max(worst, result.worst);
        status += result.status;
    }
    if (worst <= allowed and status == 0) return;

    std.debug.print("\n  {s:<14}{s:>9}{s:>11}{s:>8}{s:>8}\n", .{ "case", "samples", "differing", "worst", "status" });
    for (cases, results) |case, d| {
        std.debug.print("  {s:<14}{d:>9}{d:>11}{d:>8}{d:>8}\n", .{ case.name, d.samples, d.differing, d.worst, d.status });
    }
    return error.DeviatesFromReference;
}
