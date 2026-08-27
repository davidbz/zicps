//! The clocks, and the sound board's share of a line.
//!
//! A CP System board has three independent oscillators and no master clock, so
//! time here is a 120 MHz reference tick: the smallest rate that divides all
//! four of the board's into integers. It is a modelling convenience, not a wire
//! on the board.
//!
//! A line is the step. Each CPU gets a line's worth of cycles, and because an
//! instruction is not split at the boundary, whatever it overran by is taken off
//! the next line. The reference counter is absolute and never reset: every
//! question a chip asks about its own state turns out to be a question about
//! when.
//!
//! Which order the parts of a line go in is the machine's, and lives with it.
//! The sound board is not: both generations hang the same Z80 off the same
//! shared RAM, so what it owes per line is here and is asked for by both.

const std = @import("std");
const video = @import("video");
const audio = @import("audio");
const oki = @import("oki");
const qsound = @import("qsound");
const soundboard = @import("soundboard");
const ym2151 = @import("ym2151");

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
/// its own. QSound's 4992 does not divide evenly, and brings the debt
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

/// The plain CPS-1 sound board's crystal, which the Z80 and the YM2151 share.
/// It divides into the reference with a remainder, so both of them run off debt
/// counters rather than a per-line budget.
pub const cps1_sound_hz = 3_579_545;
/// The OPM makes one stereo sample every 64 of those clocks: 55.93 kHz.
pub const opm_divider = ym2151.clock_divider;
pub const ref_per_opm = reference_hz * opm_divider;
pub const opm_rate = audio.Rate{ .out = audio.sample_rate * opm_divider, .in = cps1_sound_hz };

/// The M6295's clock on a CPS-1 board is the 16 MHz video crystal over 16, and
/// pin 7 picks which of two divisors it makes a sample on. Both are whole
/// numbers of reference ticks, so this chip needs no fraction — only a counter.
pub const oki_hz = 1_000_000;
pub const ref_per_oki_high = reference_hz / oki_hz * oki.divider_high;
pub const ref_per_oki_low = reference_hz / oki_hz * oki.divider_low;

/// What the board's mixer makes of the two, as MAME weights them, as hundredths.
pub const fm_gain = 35;
pub const adpcm_gain = 30;
const gain_denominator = 100;

/// The sound board's Z80 takes a periodic interrupt off a divider on its own
/// clock: 8 MHz over 32000 is 250 Hz, which is what a driver counts its
/// envelope ticks on. Nothing on the board makes it line-synchronous, so it
/// gets the same debt treatment as the sample clock.
pub const sound_irq_divider = 32_000;
pub const sound_irq_hz = sound_hz / sound_irq_divider;
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

/// Where in the picture the machine is, and what its chips are owed. Every
/// counter here is in reference ticks unless it says otherwise, and none of
/// them is reset with the board: the absolute count is the point.
pub const Timing = struct {
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
    /// Wider than a sample, because the chip sums four voices without a limiter.
    oki_out: i32 = 0,
};

/// The sound board's share of the same line: the Z80's cycles, the interrupts
/// its divider raised while they ran, and the samples the chip finished.
///
/// The 68000 has already had its line by the time this runs. The two CPUs only
/// meet in shared RAM, and a byte posted there is read a line later at worst,
/// which is well inside what a sound driver polls at.
pub fn runSound(t: *Timing, s: *soundboard.SoundBoard, mixer: *audio.Mixer) void {
    // A set with no sound ROM has no sound board — the in-repo test ROM is one
    // — and a Z80 fetching 0xff out of empty space would spend
    // the run taking RST 38 and pushing return addresses into RAM.
    if (s.rom.len == 0) return;
    switch (s.kind) {
        .cps1 => runCps1(t, s, mixer),
        else => runQsound(t, s, mixer),
    }
}

/// The sound Z80's `owed` cycles, less whatever the last line overran by, with
/// this line's overrun carried forward the same way the 68000's is. Both boards
/// run their Z80 this way; only what they owe it differs.
pub fn runZ80(t: *Timing, s: *soundboard.SoundBoard, owed: u64) void {
    const budget = owed -| t.sound_over;
    const start = s.cpu.cycles;
    while (s.cpu.cycles -% start < budget) {
        soundboard.interrupt(s);
        soundboard.step(s);
    }
    t.sound_over = t.sound_over + (s.cpu.cycles -% start) - owed;
}

/// The QSound board: a Z80 on a clock that divides the line evenly, an
/// interrupt off a divider, and one chip.
fn runQsound(t: *Timing, s: *soundboard.SoundBoard, mixer: *audio.Mixer) void {
    t.sound_irq_debt += ref_per_line;
    while (t.sound_irq_debt >= ref_per_sound_irq) : (t.sound_irq_debt -= ref_per_sound_irq) {
        s.int_pending = true;
    }

    runZ80(t, s, sound_per_line);

    // ponytail: the chip is sampled after the Z80 has had the whole line
    // rather than in step with it, so a register written mid-line takes effect
    // from the line's first sample. At 24 kHz that is 16 samples of slack on a
    // note's start; slice it finer only if a game turns out to hear it.
    t.sample_debt += ref_per_line;
    while (t.sample_debt >= ref_per_sample) : (t.sample_debt -= ref_per_sample) {
        const f = qsound.sample(&s.q);
        mixer.pushNative(f.l, f.r, qsound_rate);
    }
}

/// The plain CPS-1 board: a Z80 and an OPM sharing one crystal that divides the
/// line into a fraction, an M6295 on a crystal of its own, and no interrupt
/// divider at all — the OPM's timer is the interrupt.
fn runCps1(t: *Timing, s: *soundboard.SoundBoard, mixer: *audio.Mixer) void {
    t.sound_debt += ref_per_line * cps1_sound_hz;
    const owed = t.sound_debt / reference_hz;
    t.sound_debt -= owed * reference_hz;

    runZ80(t, s, owed);

    // ponytail: the M6295 is stepped a whole line at a time, which at 7.6 kHz
    // is one sample or none — so a phrase starts up to a line late. Fold it
    // into the OPM loop below if a game ever turns out to hear the 63 µs.
    const per_oki: u64 = if (s.m6295.pin7) ref_per_oki_high else ref_per_oki_low;
    t.oki_debt += ref_per_line;
    while (t.oki_debt >= per_oki) : (t.oki_debt -= per_oki) t.oki_out = oki.sample(&s.m6295);

    // Both chips go out as one stream at the OPM's rate, which is what the
    // board's own mixer does with them: the slower chip is held between its
    // samples rather than resampled.
    t.sample_debt += ref_per_line * cps1_sound_hz;
    while (t.sample_debt >= ref_per_opm) : (t.sample_debt -= ref_per_opm) {
        const f = ym2151.sample(&s.ym);
        mixer.pushNative(mix(f.l, t.oki_out), mix(f.r, t.oki_out), opm_rate);
    }
}

/// The one place the two chips' headroom is spent: the M6295 hands over more
/// than a sample can hold, and it is the weights that bring it back into one.
fn mix(fm: i16, adpcm: i32) i16 {
    const v = @divTrunc(@as(i32, fm) * fm_gain + adpcm * adpcm_gain, gain_denominator);
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "the sound Z80 is owed exactly what it is given, line after line" {
    var t = Timing{};
    var s = soundboard.SoundBoard{};

    // JR -2, spinning on itself, so nothing but the budget decides how far it
    // gets in a line.
    const jr_cycles = 12;
    const z80 = [_]u8{ 0x18, 0xfe };
    soundboard.load(&s, .qsound, &z80, &.{}, null);
    soundboard.reset(&s);

    // A whole line's worth, then a budget shorter than one instruction takes
    // to run: the second is what the debt is for, and what a CPS-1 board's
    // fractional line can hand over.
    const lines = 100;
    for ([_]u64{ sound_per_line, jr_cycles / 2 }) |owed| {
        t.sound_over = 0;
        const start = s.cpu.cycles;
        for (0..lines) |_| runZ80(&t, &s, owed);

        // Every cycle over budget is a cycle owed, exactly, and no line puts
        // more than one instruction on the tab.
        const ran = s.cpu.cycles -% start;
        try testing.expectEqual(ran, owed * lines + t.sound_over);
        try testing.expect(t.sound_over < jr_cycles);
    }
}

test "one line is the same slice of time for every part of the board" {
    try testing.expectEqual(@as(u64, 7680), ref_per_line);
    try testing.expectEqual(@as(u64, 768), cpu_per_line);
    try testing.expectEqual(@as(u64, 512), sound_per_line);
    // 59.6374 Hz, to four places, without floating point in a constant.
    try testing.expectEqual(@as(u64, 596374), refresh_num * 10_000 / refresh_den);
}
