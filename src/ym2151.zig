//! The YM2151 (OPM): eight channels of four operators, and the two timers.
//!
//! Four operators, eight ways of wiring them: one of them modulates the
//! phase of the next, the last one out is heard, and which is which is the
//! channel's algorithm. Each operator has its own envelope, its own detune and
//! multiple, and its own share of the chip's one LFO, which bends both pitch
//! and volume. The fourth operator of the eighth channel can be a noise source
//! instead of a sine. Two timers run beside all of it and drive the sound Z80's
//! interrupt, which is the only reason a CPS-1 driver ever reads this chip.
//!
//! One stereo sample comes out every 64 clocks of the chip's 3.579545 MHz,
//! which is the 55.93 kHz the scheduler paces it at.
//!
//! `ponytail:` this is a model of the chip a sample at a time, not of the die a
//! gate at a time. It keys and hears all 32 operators on the same sample
//! boundary where the die sweeps them across one, its phase-increment table is
//! computed as an equal-tempered octave rather than read out of the chip's own
//! approximation of one, its LFO waveforms are the published shapes, its noise
//! is a shift register of the right length and not the right polynomial, and
//! its output is clamped rather than passed through the DAC's floating-point
//! compression. Everything else has been diffed against the die and fixed:
//! `test/opm_ref_test.zig` measures what is left against Nuked-OPM, and the
//! ceiling to lift, if a game ever needs it, is that file's `allowed`.

const std = @import("std");
const audio = @import("audio");

pub const channels = 8;
pub const ops_per_channel = 4;
pub const operators = channels * ops_per_channel;

/// The chip divides its clock by this to make one stereo sample.
pub const clock_divider = 64;

/// The two ports the Z80 sees: an address latch and the data behind it.
pub const port_address = 0;
pub const port_data = 1;

/// Status bits, as a driver reads them back.
pub const status_flag_a = 0x01;
pub const status_flag_b = 0x02;

// ------------------------------------------------------------- the map

/// Registers below 0x20 are the chip's own; from 0x20 up they are eight of a
/// kind, one per channel, and from 0x40 up they are thirty-two, one per
/// operator, addressed as `group << 3 | channel`.
pub const reg_test = 0x01;
pub const reg_key = 0x08;
pub const reg_noise = 0x0f;
pub const reg_clka1 = 0x10;
pub const reg_clka2 = 0x11;
pub const reg_clkb = 0x12;
pub const reg_control = 0x14;
pub const reg_lfrq = 0x18;
pub const reg_pmd_amd = 0x19;
pub const reg_ct_wave = 0x1b;
pub const reg_channel = 0x20;
pub const reg_operator = 0x40;

/// `reg_control`, bit by bit.
pub const load_a = 0x01;
pub const load_b = 0x02;
pub const irq_en_a = 0x04;
pub const irq_en_b = 0x08;
pub const reset_a = 0x10;
pub const reset_b = 0x20;
pub const csm_on = 0x40;

/// The key-on register names its channel in the low three bits and the
/// operators to key in the four above, in the order the registers are laid
/// out: M1, M2, C1, C2.
pub const key_shift = 3;

/// Which of the four register groups holds each position of an algorithm. The
/// registers run M1, M2, C1, C2 and the algorithms run M1, C1, M2, C2, so the
/// middle two are swapped — the one place this chip is not laid out the way it
/// is drawn.
const alg_order = [ops_per_channel]u8{ 0, 2, 1, 3 };

/// Where a channel's nth operator in algorithm order lives in the register file.
fn slotOf(ch: usize, n: usize) usize {
    return alg_order[n] * channels + ch;
}

// ------------------------------------------------------------- the algorithms

/// What an operator's phase can be modulated by: the first operator's output
/// this sample, the second's from the sample before (`Channel.delayed`), and
/// the third's this sample. Nothing else is to hand when it is needed.
const mod_first = 1;
const mod_prev = 2;
const mod_third = 4;

/// A modulator contributes half its output to the phase it bends.
const mod_shift = 1;

/// The eight algorithms as the manual draws them: for operators two, three and
/// four, what modulates each, and then which of the four are heard.
const Algorithm = struct { mod: [ops_per_channel - 1]u3, heard: u4 };
const algorithm = [8]Algorithm{
    .{ .mod = .{ mod_first, mod_prev, mod_third }, .heard = 0b1000 },
    .{ .mod = .{ 0, mod_first | mod_prev, mod_third }, .heard = 0b1000 },
    .{ .mod = .{ 0, mod_prev, mod_first | mod_third }, .heard = 0b1000 },
    .{ .mod = .{ mod_first, 0, mod_prev | mod_third }, .heard = 0b1000 },
    .{ .mod = .{ mod_first, 0, mod_third }, .heard = 0b1010 },
    .{ .mod = .{ mod_first, mod_first, mod_first }, .heard = 0b1110 },
    .{ .mod = .{ 0, 0, 0 }, .heard = 0b1110 },
    .{ .mod = .{ 0, 0, 0 }, .heard = 0b1111 },
};

// ------------------------------------------------------------- the tables

/// The sine, as attenuation rather than amplitude, so that an operator's
/// envelope is an addition and not a multiply: 256 points of a quarter period,
/// in 1/256 of a halving. The chip mirrors and negates it for the other three
/// quarters, and so does `operatorOut`.
const log_sin = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*x, i| {
        const s = @sin((@as(f64, @floatFromInt(i)) + 0.5) * std.math.pi / 512.0);
        x.* = @intFromFloat(@round(-@log2(s) * 256.0));
    }
    break :blk t;
};

/// The other half of that: attenuation back to amplitude, one halving's worth
/// in 256 steps, with the whole halvings done by a shift.
const exp_table = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*x, i| {
        x.* = @intFromFloat(@round(@exp2(@as(f64, @floatFromInt(255 - i)) / 256.0) * 1024.0));
    }
    break :blk t;
};

/// Attenuation is twelve bits, which is 16 halvings — past that an operator is
/// silent. The low eight index `exp_table`, the high four are whole halvings,
/// and the table's own ten bits are shifted up to the fourteen an operator puts
/// out.
const att_max = 4095;
const exp_fraction_bits = 8;
const exp_fraction_mask = (1 << exp_fraction_bits) - 1;
const exp_gain_shift = 2;

/// A phase is twenty bits, of which the top ten name one of the sine's four
/// quarters and where in it: the two highest say which quarter.
const phase_bits = 20;
const phase_mask = (1 << phase_bits) - 1;
const sine_bits = 10;
const sine_mask = (1 << sine_bits) - 1;
const quarter_mask = (1 << (sine_bits - 2)) - 1;
const sine_mirror = quarter_mask + 1;
const sine_negate = sine_mirror << 1;

/// How far the first operator's last two outputs come down before the
/// channel's feedback depth is taken off that.
const feedback_shift = 10;

/// An envelope level is ten bits, 0 loud and 1023 silent, in steps of 3/32 dB.
pub const level_max = 1023;
/// Four attenuation counts to one envelope count, and eight to one of TL's.
const level_shift = 2;
const tl_shift = 3;

/// The chip carries pitch as thirteen bits: three of octave, four of note code
/// and six of the fraction between one code and the next. Sixteen codes to the
/// octave but only twelve notes — the fourth of every four is not a note, and
/// everything below steps over it rather than landing on it.
const note_step = 64;
const octave_step = note_step * 16;
const notes_per_octave = 12;
const kcode_max = octave_step * 8 - 1;
/// The steps of the fraction the increment table is actually cut at: four to a
/// note code, so 48 real ones to the octave, with the last four bits of the
/// fraction interpolated between them.
const fnum_entries = 64;
const fnum_shift = 4;
const freq_base = 1299;

fn noteCode(kcode: u32) u32 {
    return kcode >> 6;
}

fn isNote(code: u32) bool {
    return code & 3 != 3;
}

/// One octave of phase increments, equally tempered from the chip's own lowest
/// note. Everything above octave 0 is this shifted. The codes that are not
/// notes hold no frequency at all, which is what the die reads there.
const fnum_base = blk: {
    @setEvalBranchQuota(4000);
    var t: [fnum_entries]u16 = @splat(0);
    var n = 0;
    for (&t, 0..) |*x, i| {
        if (!isNote(i / 4)) continue;
        x.* = @intFromFloat(@round(freq_base *
            @exp2(@as(f64, @floatFromInt(n)) / (notes_per_octave * 4))));
        n += 1;
    }
    break :blk t;
};

/// What the chip interpolates the last four bits of the fraction along: below
/// the top of the octave it is the distance to the next entry, and over the
/// last eleven the chip's own approximation flattens out into these, which is
/// why they are written rather than computed.
const fnum_flat = 49;
const fnum_slope = blk: {
    var t: [fnum_entries]u8 = @splat(16);
    var last = 0;
    for (0..fnum_entries) |i| {
        if (fnum_base[i] == 0) continue;
        if (last < fnum_flat) t[last] = fnum_base[i] - fnum_base[last];
        last = i;
    }
    for (fnum_flat..60) |i| t[i] = if (i < 54) 31 else 30;
    break :blk t;
};

/// DT2, as a whole number of note codes and a fraction on top of it. The two
/// larger settings are the manual's 781 and 950 cents; both carry.
const dt2_notes = [4]u32{ 0, 8, 9, 12 };
const dt2_fraction = [4]u32{ 0, 0, 52, 32 };

/// DT1's four sizes, before the shift that scales them by octave.
const dt1_table = [8]u8{ 16, 17, 19, 20, 22, 24, 27, 29 };

/// How much further the fast rates move, by the low two bits of the rate: 0, 1,
/// 2 or 3 of every four counts step twice instead of once.
const eg_step = [4][4]u8{
    .{ 0, 0, 0, 0 },
    .{ 1, 0, 0, 0 },
    .{ 1, 0, 1, 0 },
    .{ 1, 1, 1, 0 },
};

/// An envelope moves once every three samples.
const eg_divider = 3;

/// PMS as a depth in the chip's own pitch units, measured off the die rather
/// than off the manual's rounded cents: the LFO's full travel bends the pitch
/// by 4, 8, 16, 32 and 64 of them, and then by five and eleven of that last
/// one — 4.7 cents at the bottom and 826 at the top.
const pms_depth = [8]u16{ 0, 16, 32, 64, 128, 256, 1280, 2816 };
const pms_shift = 9;

// ------------------------------------------------------------- the state

pub const Eg = enum { attack, decay, sustain, release };

pub const Operator = struct {
    dt1: u3 = 0,
    mul: u4 = 0,
    tl: u7 = 0,
    ks: u2 = 0,
    ar: u5 = 0,
    ame: bool = false,
    d1r: u5 = 0,
    dt2: u2 = 0,
    d2r: u5 = 0,
    d1l: u4 = 0,
    rr: u4 = 0,

    /// Twenty bits, of which the top ten index the sine.
    phase: u32 = 0,
    level: i32 = level_max,
    state: Eg = .release,
    key: bool = false,
    /// The last two outputs, which only M1 uses: feedback is the sum of both.
    history: [2]i32 = @splat(0),
};

pub const Channel = struct {
    kc: u7 = 0,
    kf: u6 = 0,
    alg: u3 = 0,
    fb: u3 = 0,
    left: bool = true,
    right: bool = true,
    pms: u3 = 0,
    ams: u2 = 0,
    /// What the second operator of the algorithm put out last sample. The chip
    /// works its four operators in register order — M1, M2, C1, C2 — which is
    /// not the order the algorithms run in, so wherever an algorithm feeds C1
    /// into M2 the chip has already been past M2 this sample and reaches for
    /// the sample before instead. It is one 55 kHz sample of delay in the
    /// middle of a chain, and it is audible: it is the difference between this
    /// core and the reference on half the algorithms.
    delayed: i32 = 0,
};

pub const Ym2151 = struct {
    ch: [channels]Channel = @splat(.{}),
    op: [operators]Operator = @splat(.{}),

    /// The address latched by a write to port 0, waiting for its data.
    addr: u8 = 0,

    /// The LFO: a counter that steps a phase, a waveform read off that phase,
    /// and the two depths the phase is scaled by before it is applied.
    lfo_counter: u32 = 0,
    lfo_timer: u32 = 0,
    lfo_phase: u8 = 0,
    lfo_step: u32 = 0,
    lfo_period: u32 = 1 << 18,
    lfo_wave: u2 = 0,
    amd: u7 = 0,
    pmd: u7 = 0,
    am: i32 = 0,
    pm: i32 = 0,

    /// The noise source on C2 of channel 8, and the counter that clocks it.
    noise_on: bool = false,
    noise_freq: u5 = 0,
    noise_acc: u32 = 0,
    noise_lfsr: u16 = 0xffff,

    env_counter: u32 = 0,
    env_divider: u32 = 0,

    period_a: u16 = 0,
    period_b: u8 = 0,
    count_a: u32 = 0,
    count_b: u32 = 0,
    control: u8 = 0,
    flag_a: bool = false,
    flag_b: bool = false,
};

// ------------------------------------------------------------- the bus

pub fn reset(y: *Ym2151) void {
    y.* = .{};
}

/// The interrupt line, which on a CPS-1 board is the Z80's only one.
pub fn irq(y: *const Ym2151) bool {
    return (y.flag_a and y.control & irq_en_a != 0) or (y.flag_b and y.control & irq_en_b != 0);
}

/// A read answers the two timer flags. The busy bit is never set: this model
/// commits a write at once, so there is no window for a driver to see it in.
pub fn read(y: *const Ym2151) u8 {
    var v: u8 = 0;
    if (y.flag_a) v |= status_flag_a;
    if (y.flag_b) v |= status_flag_b;
    return v;
}

pub fn write(y: *Ym2151, port: u16, value: u8) void {
    if (port & 1 == 0) {
        y.addr = value;
        return;
    }
    writeReg(y, y.addr, value);
}

fn writeReg(y: *Ym2151, addr: u8, value: u8) void {
    if (addr >= reg_operator) return writeOperator(y, addr, value);
    if (addr >= reg_channel) return writeChannel(y, addr, value);
    switch (addr) {
        reg_test => if (value & 0x02 != 0) {
            y.lfo_phase = 0;
            y.lfo_counter = 0;
        },
        reg_key => keyOn(y, value),
        reg_noise => {
            y.noise_on = value & 0x80 != 0;
            y.noise_freq = @truncate(value);
        },
        reg_clka1 => y.period_a = (y.period_a & 0x03) | (@as(u16, value) << 2),
        reg_clka2 => y.period_a = (y.period_a & 0x3fc) | (value & 0x03),
        reg_clkb => y.period_b = value,
        reg_control => writeControl(y, value),
        reg_lfrq => {
            // The high nibble halves the counter's period each step; the low
            // nibble is how far it moves when it does.
            y.lfo_period = @as(u32, 1) << @intCast(18 - (value >> 4));
            y.lfo_step = 0x10 + (value & 0x0f);
        },
        reg_pmd_amd => {
            if (value & 0x80 != 0) y.pmd = @truncate(value) else y.amd = @truncate(value);
        },
        reg_ct_wave => y.lfo_wave = @truncate(value),
        else => {},
    }
}

fn writeControl(y: *Ym2151, value: u8) void {
    if (value & reset_a != 0) y.flag_a = false;
    if (value & reset_b != 0) y.flag_b = false;
    // A timer starts counting on the edge that loads it, and keeps its count
    // while the load bit stays up.
    if (value & load_a != 0 and y.control & load_a == 0) y.count_a = periodA(y);
    if (value & load_b != 0 and y.control & load_b == 0) y.count_b = periodB(y);
    y.control = value;
}

fn writeChannel(y: *Ym2151, addr: u8, value: u8) void {
    const c = &y.ch[addr & 7];
    switch (addr & 0x18) {
        0x00 => {
            c.right = value & 0x80 != 0;
            c.left = value & 0x40 != 0;
            c.fb = @truncate(value >> 3);
            c.alg = @truncate(value);
        },
        0x08 => c.kc = @truncate(value),
        0x10 => c.kf = @truncate(value >> 2),
        else => {
            c.pms = @truncate(value >> 4);
            c.ams = @truncate(value);
        },
    }
}

fn writeOperator(y: *Ym2151, addr: u8, value: u8) void {
    const op = &y.op[addr & 0x1f];
    switch (addr & 0xe0) {
        0x40 => {
            op.dt1 = @truncate(value >> 4);
            op.mul = @truncate(value);
        },
        0x60 => op.tl = @truncate(value),
        0x80 => {
            op.ks = @truncate(value >> 6);
            op.ar = @truncate(value);
        },
        0xa0 => {
            op.ame = value & 0x80 != 0;
            op.d1r = @truncate(value);
        },
        0xc0 => {
            op.dt2 = @truncate(value >> 6);
            op.d2r = @truncate(value);
        },
        else => {
            op.d1l = @truncate(value >> 4);
            op.rr = @truncate(value);
        },
    }
}

fn keyOn(y: *Ym2151, value: u8) void {
    const ch: usize = value & 7;
    for (0..ops_per_channel) |group| {
        // The four bits are in the order the algorithms run, not the order the
        // registers are laid out in, so the middle two are swapped here too.
        const on = value & (@as(u8, 1) << @intCast(key_shift + group)) != 0;
        keySlot(y, alg_order[group] * channels + ch, on);
    }
}

fn keySlot(y: *Ym2151, slot: usize, on: bool) void {
    const op = &y.op[slot];
    if (op.key == on) return;
    op.key = on;
    if (!on) {
        op.state = .release;
        return;
    }
    op.state = .attack;
    op.phase = 0;
    // The fastest attack has no ramp at all: the level is there on the key.
    if (rateOf(op.ar, ksrOf(y, slot)) >= 62) op.level = 0;
}

// ------------------------------------------------------------- the pitch

/// Where the channel sits in the chip's thirteen bits, with the LFO's bend and
/// this operator's DT2 already in it. Both of those can push the pitch onto a
/// code that is not a note, and the chip steps over it rather than sounding it.
///
/// ponytail: the bend is the manual's depth curve scaled into these units, not
/// the bit-mangling the die does to get there, and the sign of a downward bend
/// is taken before the sum rather than after it. Both are only reachable
/// through PMD, and both are named in the diff's tolerance.
fn pitchOf(y: *const Ym2151, ch: usize, op: *const Operator) u32 {
    const c = &y.ch[ch];
    const bend = if (c.pms == 0) 0 else (y.pm * pms_depth[c.pms]) >> pms_shift;
    const sum = std.math.clamp(
        @as(i32, c.kc) * note_step + c.kf + bend,
        0,
        kcode_max,
    );
    var code = noteCode(@intCast(sum));
    var fraction = @as(u32, @intCast(sum)) & (note_step - 1);
    if (!isNote(code)) code += 1;

    code += dt2_notes[op.dt2];
    if (!isNote(code)) code += 1;
    fraction += dt2_fraction[op.dt2];
    if (fraction >= note_step) {
        fraction -= note_step;
        code += 1;
        if (!isNote(code)) code += 1;
    }
    // Off the top the chip stops at the last code it can still name.
    if (code > kcode_max / note_step) return 126 * note_step + note_step - 1;
    return code * note_step + fraction;
}

/// The five-bit key code the envelope's rate scaling and DT1 are both cut
/// from: three bits of octave and two of where in it.
fn keyCode(pitch: u32) u32 {
    return pitch >> 8;
}

fn ksrOf(y: *const Ym2151, slot: usize) u32 {
    const op = &y.op[slot];
    return keyCode(pitchOf(y, slot & 7, op)) >> (3 - @as(u5, op.ks));
}

/// The increment for one step of the fraction, interpolated between the two
/// entries the chip has room for either side of it. The last eleven entries of
/// the octave take a coarser path through the same shifts.
fn fnumOf(pitch: u32) u32 {
    const i = (pitch >> fnum_shift) & (fnum_entries - 1);
    const bits = pitch & (@as(u32, 1 << fnum_shift) - 1);
    const slope: u32 = fnum_slope[i];
    var sum: u32 = 0;
    if (i < fnum_flat) {
        for (0..fnum_shift) |b| {
            if (bits & (@as(u32, 1) << @intCast(b)) != 0) sum += slope >> @intCast(3 - b);
        }
    } else {
        const s = slope | 1;
        if (bits & 1 != 0) sum += (s >> 3) + 2;
        if (bits & 2 != 0) sum += 8;
        if (bits & 4 != 0) sum += s >> 1;
        if (bits & 8 != 0) sum += s + 1;
        if (bits & 12 == 12 and slope & 1 == 0) sum += 4;
    }
    return fnum_base[i] + (sum >> 1);
}

/// The phase increment: an octave-shifted table lookup, detuned, then scaled
/// by the operator's multiple. A multiple of zero is a half, not a nothing.
fn incrementOf(y: *const Ym2151, ch: usize, op: *const Operator) u32 {
    const pitch = pitchOf(y, ch, op);
    const block = pitch / octave_step;
    var inc: u32 = (fnumOf(pitch) << @intCast(block)) >> 2;

    const fine = op.dt1 & 3;
    if (fine != 0) {
        const code = @min(keyCode(pitch), 0x1c);
        const sum = code / 4 + 9 + @intFromBool(fine >= 2);
        const detune = @as(u32, dt1_table[(sum & 1) * 4 + (code & 3)]) >> @intCast(9 - sum / 2);
        inc = if (op.dt1 & 4 != 0) inc -% detune else inc +% detune;
        inc &= 0x1ffff;
    }
    inc = if (op.mul != 0) inc * op.mul else inc >> 1;
    return inc & 0xfffff;
}

// ------------------------------------------------------------- the envelope

/// The rate an envelope stage runs at: twice the register, plus the key code's
/// share of it, and never past the top of the table.
fn rateOf(reg: u32, ksr: u32) u32 {
    if (reg == 0) return 0;
    return @min(63, reg * 2 + ksr);
}

fn stageRate(op: *const Operator, ksr: u32) u32 {
    return switch (op.state) {
        .attack => rateOf(op.ar, ksr),
        .decay => rateOf(op.d1r, ksr),
        .sustain => rateOf(op.d2r, ksr),
        // Release is four to a step rather than two, and never stands still.
        .release => rateOf(@as(u32, op.rr) * 2 + 1, ksr),
    };
}

/// How far the envelope moves this count at this rate. Below rate 48 it moves
/// on some counts and not others; above it, it moves more than once.
///
/// The top four bits of the rate pick how often it moves: once every 2^n
/// counts. The bottom two add a step of their own on a period twice and four
/// times as long, which is where the three-in-four and one-in-four patterns
/// come from — they are two more counters, not a pattern held in a table.
fn envelopeStep(rate: u32, counter: u32) u32 {
    if (rate == 0) return 0;
    const hi = rate >> 2;
    const lo = rate & 3;
    if (hi >= 12) {
        // Past rate 48 the counter has stopped being the limit: every count
        // moves, and the rate says how far — up to eight, and no further.
        return @min(@as(u32, 1 + eg_step[lo][egPhase(counter)]) << @intCast(hi - 12), 8);
    }
    if (counts(counter, 12 - hi)) return 1;
    if (lo & 2 != 0 and counts(counter, 13 - hi)) return 1;
    if (lo & 1 != 0 and counts(counter, 14 - hi)) return 1;
    return 0;
}

/// Whether the counter's lowest set bit is where a step of this size wants it.
/// The chip looks for it halfway through the period rather than at the wrap.
fn counts(counter: u32, bits: u32) bool {
    const period = @as(u32, 1) << @intCast(bits);
    return counter & (period - 1) == (period / 2 + 1) & (period - 1);
}

/// Which of the four counts the fast rates are looking at. The chip reads its
/// counter through a latch that is a count behind on the even ones, so the four
/// go 1, 0, 3, 2 rather than 0, 1, 2, 3.
fn egPhase(counter: u32) u32 {
    return if (counter & 1 != 0) counter & 3 else (counter +% 2) & 3;
}

/// Where the first decay hands over to the second. D1L of 15 is the bottom of
/// the range, not fifteen sixteenths of it.
fn sustainLevel(d1l: u4) i32 {
    const sl: i32 = if (d1l == 15) 31 else d1l;
    return sl << 5;
}

fn clockEnvelope(y: *Ym2151, slot: usize) void {
    const ksr = ksrOf(y, slot);
    const op = &y.op[slot];
    const step: i32 = @intCast(envelopeStep(stageRate(op, ksr), y.env_counter));
    if (step == 0) return;
    switch (op.state) {
        .attack => {
            // The attack is the one stage that is not linear in attenuation:
            // it closes a fraction of what is left every step.
            op.level += (~op.level * step) >> 4;
            if (op.level <= 0) {
                op.level = 0;
                op.state = .decay;
            }
        },
        .decay => {
            op.level += step;
            if (op.level >= sustainLevel(op.d1l)) op.state = .sustain;
        },
        .sustain, .release => {
            op.level += step;
            if (op.level > level_max) op.level = level_max;
        },
    }
}

// ------------------------------------------------------------- the LFO

fn clockLfo(y: *Ym2151) void {
    y.lfo_timer += 1;
    if (y.lfo_timer >= y.lfo_period) {
        y.lfo_timer = 0;
        y.lfo_counter += y.lfo_step;
        y.lfo_phase = @truncate(y.lfo_counter >> 4);
    }
    const p: i32 = y.lfo_phase;
    var a: i32 = undefined;
    var f: i32 = undefined;
    switch (y.lfo_wave) {
        // A falling ramp for volume, a rising one for pitch.
        0 => {
            a = p ^ 0xff;
            f = if (p < 0x80) p else p - 0xff;
        },
        // A square, which is the only wave that reaches full depth at once.
        1 => {
            a = if (p < 0x80) 255 else 0;
            f = if (p < 0x80) 128 else -128;
        },
        // A triangle, at twice the resolution of the phase.
        2 => {
            a = if (p < 0x80) p * 2 else (0xff - p) * 2;
            f = switch (p >> 6) {
                0 => p * 2,
                1 => 0xff - p * 2,
                2 => -((p - 0x80) * 2),
                else => p * 2 - 0x1ff,
            };
        },
        // Noise, which the chip draws from the same shift register the eighth
        // channel's noise operator does.
        3 => {
            a = @as(i32, y.noise_lfsr & 0xff);
            f = a - 0x80;
        },
    }
    y.am = @divTrunc(a * y.amd, 128);
    y.pm = @divTrunc(f * y.pmd, 128);
}

fn clockNoise(y: *Ym2151) void {
    // Rates 30 and 31 are the same, and the register counts down from there.
    const period: u32 = 32 - @as(u32, @min(y.noise_freq, 30));
    y.noise_acc += 2;
    while (y.noise_acc >= period) {
        y.noise_acc -= period;
        const bit = (y.noise_lfsr ^ (y.noise_lfsr >> 3)) & 1;
        y.noise_lfsr = (y.noise_lfsr >> 1) | (bit << 15);
    }
}

// ------------------------------------------------------------- the operators

/// The attenuation an operator is heard through: its envelope, its total
/// level, and whatever share of the LFO's volume bend it is enabled for.
fn attenuationOf(y: *const Ym2151, ch: usize, op: *const Operator) i32 {
    var att = op.level + (@as(i32, op.tl) << tl_shift);
    const ams = y.ch[ch].ams;
    if (op.ame and ams != 0) att += y.am << @intCast(ams - 1);
    return @min(att, level_max);
}

/// Attenuation back to amplitude: the low bits are one halving read out of the
/// table, the high bits are the whole halvings, done as a shift.
fn amplitude(att: u32) i32 {
    const total = @min(att_max, att);
    const fraction: u32 = exp_table[total & exp_fraction_mask];
    return @intCast((fraction << exp_gain_shift) >> @intCast(total >> exp_fraction_bits));
}

/// One operator's output: a sine of its own phase, bent by whatever is
/// modulating it, at whatever the envelope leaves of it. Fourteen bits signed.
fn operatorOut(y: *Ym2151, ch: usize, slot: usize, mod: i32) i32 {
    const op = &y.op[slot];
    const att = attenuationOf(y, ch, op);
    const phase = @as(i32, @intCast(op.phase >> (phase_bits - sine_bits))) +% mod;
    op.phase = (op.phase +% incrementOf(y, ch, op)) & phase_mask;

    // The table is a quarter period; the chip mirrors it for the second
    // quarter and negates both for the half below.
    const index: u32 = @as(u32, @bitCast(phase)) & sine_mask;
    const point = if (index & sine_mirror != 0) (index & quarter_mask) ^ quarter_mask else index & quarter_mask;
    const mag = amplitude(@as(u32, log_sin[point]) + (@as(u32, @intCast(att)) << level_shift));
    return if (index & sine_negate != 0) -mag else mag;
}

/// The noise operator: the same envelope, but the shift register's sign
/// instead of a sine. Only C2 of the eighth channel can be one.
fn noiseOut(y: *Ym2151, slot: usize) i32 {
    const op = &y.op[slot];
    const att = attenuationOf(y, channels - 1, op);
    const mag = amplitude(@as(u32, @intCast(att)) << level_shift);
    return if (y.noise_lfsr & 1 != 0) mag else -mag;
}

/// One channel, one sample. Every operator is clocked whether it is heard or
/// not — a muted operator still moves its phase on, and is in tune when the
/// algorithm changes under it.
fn channelOut(y: *Ym2151, ch: usize) i32 {
    const c = y.ch[ch];
    const alg = algorithm[c.alg];
    const prev = c.delayed;

    var out: [ops_per_channel]i32 = @splat(0);
    out[0] = feedbackOut(y, ch, c.fb);
    for (alg.mod, 1..) |mod, i| {
        var phase: i32 = 0;
        if (mod & mod_first != 0) phase += out[0];
        if (mod & mod_prev != 0) phase += prev;
        if (mod & mod_third != 0) phase += out[2];
        out[i] = operatorOut(y, ch, slotOf(ch, i), phase >> mod_shift);
    }
    y.ch[ch].delayed = out[1];

    if (ch == channels - 1 and y.noise_on) out[3] = noiseOut(y, slotOf(ch, 3));

    var sum: i32 = 0;
    for (out, 0..) |o, i| {
        if (alg.heard & (@as(u4, 1) << @intCast(i)) != 0) sum += o;
    }
    return sum;
}

/// The first operator, the only one that can modulate itself: the feedback is
/// the sum of its last two outputs, which is why it keeps a history at all.
fn feedbackOut(y: *Ym2151, ch: usize, fb: u3) i32 {
    const op = &y.op[slotOf(ch, 0)];
    const mod: i32 = if (fb == 0) 0 else (op.history[0] + op.history[1]) >> @intCast(feedback_shift - @as(u5, fb));
    const out = operatorOut(y, ch, slotOf(ch, 0), mod);
    op.history[1] = op.history[0];
    op.history[0] = out;
    return out;
}

// ------------------------------------------------------------- the timers

fn periodA(y: *const Ym2151) u32 {
    return 1024 - @as(u32, y.period_a);
}

/// Timer B counts sixteen samples to the tick that timer A counts one of.
fn periodB(y: *const Ym2151) u32 {
    return (256 - @as(u32, y.period_b)) * 16;
}

fn clockTimers(y: *Ym2151) void {
    if (y.control & load_a != 0) {
        y.count_a -|= 1;
        if (y.count_a == 0) {
            y.count_a = periodA(y);
            if (y.control & irq_en_a != 0) y.flag_a = true;
            // CSM keys every operator of every channel off one timer, which is
            // how a driver plays speech through the FM side.
            if (y.control & csm_on != 0) {
                for (0..channels) |ch| keyOn(y, @intCast(ch | 0x78));
            }
        }
    }
    if (y.control & load_b != 0) {
        y.count_b -|= 1;
        if (y.count_b == 0) {
            y.count_b = periodB(y);
            if (y.control & irq_en_b != 0) y.flag_b = true;
        }
    }
}

// ------------------------------------------------------------- the sample

pub fn sample(y: *Ym2151) audio.Frame {
    clockLfo(y);
    clockNoise(y);
    clockTimers(y);

    y.env_divider += 1;
    if (y.env_divider >= eg_divider) {
        y.env_divider = 0;
        y.env_counter +%= 1;
        for (0..operators) |slot| clockEnvelope(y, slot);
    }

    var l: i32 = 0;
    var r: i32 = 0;
    for (0..channels) |ch| {
        const out = channelOut(y, ch);
        if (y.ch[ch].left) l += out;
        if (y.ch[ch].right) r += out;
    }
    return .{ .l = clip(l), .r = clip(r) };
}

fn clip(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

// ------------------------------------------------------------- tests

const testing = std.testing;

fn set(y: *Ym2151, addr: u8, value: u8) void {
    write(y, port_address, addr);
    write(y, port_data, value);
}

test "the tables are the chip's" {
    // Both are computed rather than transcribed, so this is the check that the
    // formula still lands on the ROM: the ends of each, from the die shots.
    try testing.expectEqual(@as(u16, 0x859), log_sin[0]);
    try testing.expectEqual(@as(u16, 0x6c3), log_sin[1]);
    try testing.expectEqual(@as(u16, 0x000), log_sin[255]);
    try testing.expectEqual(@as(u16, 0x7fa), exp_table[0]);
    try testing.expectEqual(@as(u16, 0x400), exp_table[255]);
    // The pitch ROM the same way: the first note, the code that is not one,
    // the octave's last step, and the slopes that run between them.
    try testing.expectEqual(@as(u16, freq_base), fnum_base[0]);
    try testing.expectEqual(@as(u16, 0), fnum_base[12]);
    try testing.expectEqual(@as(u16, 1545), fnum_base[16]);
    try testing.expectEqual(@as(u16, 2561), fnum_base[59]);
    try testing.expectEqual(@as(u8, 19), fnum_slope[0]);
    try testing.expectEqual(@as(u8, 22), fnum_slope[11]);
    try testing.expectEqual(@as(u8, 31), fnum_slope[48]);
}

test "a keyed operator rises and a released one falls" {
    var y = Ym2151{};
    set(&y, reg_channel + 0, 0xc7); // both speakers, no feedback, algorithm 7
    set(&y, reg_channel + 0x08, 0x4a); // a middle key code
    for (0..ops_per_channel) |g| {
        const slot: u8 = @intCast(g * channels);
        set(&y, reg_operator + slot, 0x01); // multiple 1
        set(&y, 0x60 + slot, 0x00); // full volume
        set(&y, 0x80 + slot, 0x1f); // fastest attack
        set(&y, 0xa0 + slot, 0x00); // no decay
        set(&y, 0xe0 + slot, 0x0f); // fastest release
    }

    try testing.expectEqual(@as(i32, level_max), y.op[0].level);
    set(&y, reg_key, 0x78); // every operator of channel 0
    for (0..64) |_| _ = sample(&y);
    try testing.expectEqual(@as(i32, 0), y.op[0].level);

    var loud: u32 = 0;
    for (0..256) |_| loud = @max(loud, @abs(sample(&y).l));
    try testing.expect(loud > 4096);

    set(&y, reg_key, 0x00);
    for (0..512) |_| _ = sample(&y);
    try testing.expectEqual(@as(i32, level_max), y.op[0].level);
    try testing.expectEqual(@as(i16, 0), sample(&y).l);
}

test "an octave up is twice the phase increment" {
    var y = Ym2151{};
    set(&y, reg_operator, 0x01);
    set(&y, reg_channel + 0x08, 0x0a);
    const low = incrementOf(&y, 0, &y.op[0]);
    set(&y, reg_channel + 0x08, 0x1a);
    // Within a step: the octave is a shift applied before the increment is cut
    // down to its 20 bits, so the low bit of the smaller one is lost.
    try testing.expect(incrementOf(&y, 0, &y.op[0]) - low * 2 <= 1);
    // And a multiple of zero is a half, which is the chip's one asymmetry.
    set(&y, reg_operator, 0x00);
    try testing.expectEqual(low, incrementOf(&y, 0, &y.op[0]));
}

test "the timers count down and raise the interrupt" {
    var y = Ym2151{};
    set(&y, reg_clka1, 0xff);
    set(&y, reg_clka2, 0x03); // the shortest period timer A has: one sample
    set(&y, reg_control, load_a | irq_en_a);
    try testing.expect(!irq(&y));
    _ = sample(&y);
    try testing.expect(y.flag_a);
    try testing.expect(irq(&y));

    // The flag is only cleared by asking, and the interrupt goes with it.
    set(&y, reg_control, load_a | irq_en_a | reset_a);
    try testing.expect(!irq(&y));

    set(&y, reg_clkb, 0xff); // sixteen samples
    set(&y, reg_control, load_b | irq_en_b);
    for (0..15) |_| _ = sample(&y);
    try testing.expect(!y.flag_b);
    _ = sample(&y);
    try testing.expect(y.flag_b);
}

test "the pan bits pick which side a channel is heard on" {
    var y = Ym2151{};
    set(&y, reg_channel + 0, 0x87); // right only
    set(&y, reg_channel + 0x08, 0x4a);
    set(&y, reg_operator, 0x01);
    set(&y, 0x80, 0x1f);
    set(&y, 0xa0, 0x00);
    set(&y, reg_key, 0x08);
    var right: u32 = 0;
    for (0..256) |_| {
        const f = sample(&y);
        try testing.expectEqual(@as(i16, 0), f.l);
        right = @max(right, @abs(f.r));
    }
    try testing.expect(right > 0);
}
