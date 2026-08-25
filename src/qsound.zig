//! QSound (DL-1425): the host side of the DSP, and the DSP (DESIGN.md §7.3).
//!
//! The Z80 talks to the chip through three write ports and one read port — two
//! bytes of data latched, then a register number that commits them — and the
//! DSP answers a ready flag it drops on every write and raises again when it
//! has finished a sample. On the other side of that register file are sixteen
//! looping PCM channels, a panning path built out of two mix curves and a
//! 95-tap FIR, and an echo; one stereo sample comes out every 2496 clocks of
//! the chip's own 60 MHz, which is the 24.038 kHz the scheduler paces it at.
//!
//! The model is high-level by design: the behaviour of the mask-programmed
//! DSP16A program, not a core running it, because the 8 KiB of program cannot
//! be redistributed and the audio path would skip on any machine without it.
//! Its coefficient tables can be, and are (`qsound_rom.zig`). §7.3 rules the
//! three ADPCM channels and the second filter mode out of scope: no known
//! board uses either.

const std = @import("std");
const audio = @import("audio");
const rom = @import("qsound_rom.zig");

/// The register number is a byte, so this is every register the chip has,
/// decoded or not.
pub const reg_count = 0x100;

/// The three write ports, as offsets from the base of the chip's window.
pub const port_data_hi = 0;
pub const port_data_lo = 1;
pub const port_reg = 2;

/// The bit a read of the chip answers with when it is ready for the next
/// command. A driver spins on it, and the chip drops it on every register
/// write until it has finished the sample it was in the middle of.
pub const ready = 0x80;

pub const Write = struct { reg: u8 = 0, value: u16 = 0 };

/// How many of the most recent register writes are kept. Enough to see a
/// channel set up (bank, start, pitch, loop, end, volume, pan) without being a
/// log file: this is a window on the driver, not a recording of it.
pub const log_len = 32;

pub const voices = 16;
pub const channels = 2;

/// A PCM channel. `addr` and `phase` together are one 16.12 fixed-point
/// position into the sample ROM that `rate` is added to every sample; the top
/// half doubles as the register a driver writes to start a sample.
pub const Voice = struct {
    bank: u16 = 0,
    addr: i16 = 0,
    phase: u16 = 0,
    rate: u16 = 0,
    loop_len: i16 = 0,
    end_addr: i16 = 0,
    volume: i16 = 0,
    echo: i16 = 0,
};

// ------------------------------------------------------------- the map

/// Seven of every eight registers below `reg_voice_pan` belong to one voice,
/// in the order a driver sets them. The eighth is not decoded.
pub const voice_regs = 8;
pub const reg_bank = 0;
pub const reg_addr = 1;
pub const reg_rate = 2;
pub const reg_phase = 3;
pub const reg_loop_len = 4;
pub const reg_end_addr = 5;
pub const reg_volume = 6;

/// The rest of the file: one pan and one echo send per voice, and the chip's
/// own registers. The two stereo halves of each of the last group sit two
/// apart, interleaved with the mode-2 registers between them.
pub const reg_voice_pan = 0x80;
pub const reg_echo_feedback = 0x93;
pub const reg_voice_echo = 0xba;
pub const reg_echo_end = 0xd9;
pub const reg_wet_filter = 0xda;
pub const reg_wet_delay = 0xde;
pub const reg_delay_update = 0xe2;
pub const reg_state = 0xe3;
pub const reg_wet_volume = 0xe4;
pub const reg_dry_volume = 0xe5;
pub const channel_stride = 2;

/// A voice reads the sample ROM only when its bank register says so; the low
/// bits address the ROM 64 KiB at a time. Without this bit the DSP would be
/// reading its own program space, and answers zero instead.
pub const bank_enable = 0x8000;
pub const bank_mask = 0x7fff;
pub const bank_shift = 16;

/// The position is 16.12, and the DSP clamps it to 28 bits rather than letting
/// a runaway rate wrap a channel to the other end of the ROM.
pub const phase_bits = 12;
pub const phase_max = 0x7ffffff;
pub const phase_min = -0x8000000;

/// The volume register is 2.14: 0x4000 is unity, and the chip keeps the top
/// bits of the product.
pub const volume_shift = 14;

/// A pan register is an absolute position, not an offset: 0x110 is hard left,
/// 0x130 hard right, and 0x120 the centre the chip powers up at. Everything
/// from 0x140 up selects the linear curve instead, which mutes the wet path.
pub const pan_base = 0x110;
pub const pan_centre = 0x120;
pub const pan_linear = 0x30;
pub const pan_entries = 98;
pub const pan_max = pan_entries - 1;
pub const pan_dry = 0;
pub const pan_wet = 1;

/// The echo's delay line is addressed from a fixed point in DSP memory, so the
/// register a driver writes is an end address and the length is the difference.
pub const echo_base = 0x554;
pub const echo_len = 1024;

/// The two output delay lines, which is where the pan filter's group delay is
/// undone. Both are the same fixed length; only the read position moves.
pub const delay_len = 51;
pub const dry_delay_left = 46;
pub const dry_delay_right = 48;
pub const delay_volume = 0x3fff;

/// Where the two default pan filters live in the mask ROM.
pub const filter_left = 0xdb2;
pub const filter_right = 0xe11;

/// The DSP's own round-to-nearest, applied to the 16.16 accumulator before the
/// top half is taken.
pub const dsp_round = 0x8000;

/// The program's entry points, as the addresses a driver writes to the state
/// register to reach them. The chip powers up at none of them, which is the
/// initialisation path.
pub const State = enum(u16) {
    init1 = 0x288,
    init2 = 0x61a,
    refresh1 = 0x039,
    refresh2 = 0x04f,
    normal1 = 0x314,
    normal2 = 0x6b2,
    _,
};

/// Initialisation takes three turns of the program and the normal path runs
/// six before it looks at the state register again, so the one counter means
/// two different things in the two states — as it does on the chip.
pub const init_turns = 2;
pub const normal_samples = 6;

/// Reset to the first sample a listener hears: three turns of initialisation,
/// one that reloads the pan filters, and the first mixed sample.
pub const boot_samples = init_turns + 3;

// ------------------------------------------------------------- the chip

/// The pan filter: 95 taps, and a delay line one shorter, because the newest
/// sample meets the last tap on its way in rather than a sample later.
const Fir = struct {
    taps: [rom.fir_taps]i16 = @splat(0),
    line: [rom.fir_taps]i16 = @splat(0),
    at: u32 = 0,
    tap_count: u32 = rom.fir_taps,
    table_pos: u16 = 0,
};

/// One output delay line and the attenuation on the way out of it.
const Delay = struct {
    line: [delay_len]i16 = @splat(0),
    delay: i16 = 0,
    volume: i16 = 0,
    write_at: i16 = 0,
    read_at: i16 = 0,
};

const Echo = struct {
    line: [echo_len]i16 = @splat(0),
    end_pos: u16 = 0,
    feedback: i16 = 0,
    length: i16 = 0,
    last: i16 = 0,
    at: i16 = 0,
};

pub const Qsound = struct {
    /// The two data bytes, waiting for the register write that commits them.
    latch: u16 = 0,
    /// Every register as written, decoded or not. The chip's own state below
    /// is what plays; this is what a debugger and the machine hash read, and
    /// it costs half a kilobyte to never have to ask twice.
    regs: [reg_count]u16 = @splat(0),
    ready_flag: u8 = 0,

    voice: [voices]Voice = @splat(.{}),
    pan: [voices]u16 = @splat(pan_centre),
    echo: Echo = .{},
    filter: [channels]Fir = @splat(.{}),
    wet: [channels]Delay = @splat(.{}),
    dry: [channels]Delay = @splat(.{}),
    out: [channels]i16 = @splat(0),

    state: State = @enumFromInt(0),
    next_state: State = @enumFromInt(0),
    counter: u32 = 0,
    delay_update: bool = false,

    /// The sample ROM. One of DESIGN.md §3.2's heap slices: reattached after a
    /// save state rather than copied into it. The mask is the chip's own — the
    /// address bus is as wide as the ROM is, so a sample that runs off the end
    /// wraps rather than reaching nothing.
    samples: []const u8 = &.{},
    sample_mask: u32 = 0,

    /// One bit per voice, for debugging: a muted voice still runs, so muting
    /// and unmuting it does not move where it is in its sample — it is just
    /// not heard, in the mix or in the echo.
    muted: u16 = 0,

    log: [log_len]Write = @splat(.{}),
    log_at: usize = 0,
    /// Every write since reset, not just the logged ones.
    writes: u64 = 0,

    /// The writes still in the log, oldest first.
    pub fn recent(q: *const Qsound, buf: *[log_len]Write) []const Write {
        const kept: usize = @intCast(@min(q.writes, log_len));
        for (0..kept) |i| buf[i] = q.log[(q.log_at + log_len - kept + i) % log_len];
        return buf[0..kept];
    }
};

/// Hands the chip its sample ROM. Separate from a reset because the ROM
/// outlives one: a save state restores the chip and reattaches the slice.
pub fn attach(q: *Qsound, samples: []const u8) void {
    q.samples = samples;
    // The address bus is as wide as the ROM needs, so a sample that runs off
    // the end comes back round the front of it. A set whose ROM is not a whole
    // power of two has the gap above it, and that reads as silence.
    const rounded: u32 = if (samples.len == 0) 0 else std.math.ceilPowerOfTwo(u32, @intCast(samples.len)) catch 0;
    q.sample_mask = rounded -| 1;
}

/// Back to power-up, with the sample ROM still attached: a reset is a pin on
/// the chip, not the board being taken apart.
pub fn reset(q: *Qsound) void {
    q.* = .{ .samples = q.samples, .sample_mask = q.sample_mask };
}

// ------------------------------------------------------------- the ports

pub fn write(q: *Qsound, port: u16, value: u8) void {
    switch (port) {
        port_data_hi => q.latch = (q.latch & 0x00ff) | @as(u16, value) << 8,
        port_data_lo => q.latch = (q.latch & 0xff00) | value,
        port_reg => commit(q, value),
        else => {},
    }
}

fn commit(q: *Qsound, reg: u8) void {
    q.regs[reg] = q.latch;
    q.log[q.log_at] = .{ .reg = reg, .value = q.latch };
    q.log_at = (q.log_at + 1) % log_len;
    q.writes += 1;

    store(q, reg, q.latch);
    // The DSP is in the middle of a sample and cannot look at the file until
    // it comes back round, so a driver that writes two registers back to back
    // is made to wait for the second.
    q.ready_flag = 0;
}

pub fn read(q: *const Qsound) u8 {
    return q.ready_flag;
}

/// Decodes one register write into the chip state it names. Registers the DSP
/// program does not read are not an error: the file is a byte wide and most of
/// it is nothing.
fn store(q: *Qsound, reg: u8, value: u16) void {
    if (reg < voices * voice_regs) {
        const v = reg / voice_regs;
        switch (reg % voice_regs) {
            // A bank register belongs to the *next* voice, which is how the
            // DSP program indexes it and not a mistake to tidy up.
            reg_bank => q.voice[(v + 1) % voices].bank = value,
            reg_addr => q.voice[v].addr = @bitCast(value),
            reg_rate => q.voice[v].rate = value,
            reg_phase => q.voice[v].phase = value,
            reg_loop_len => q.voice[v].loop_len = @bitCast(value),
            reg_end_addr => q.voice[v].end_addr = @bitCast(value),
            reg_volume => q.voice[v].volume = @bitCast(value),
            else => {},
        }
        return;
    }
    switch (reg) {
        reg_voice_pan...reg_voice_pan + voices - 1 => q.pan[reg - reg_voice_pan] = value,
        reg_voice_echo...reg_voice_echo + voices - 1 => q.voice[reg - reg_voice_echo].echo = @bitCast(value),
        reg_echo_feedback => q.echo.feedback = @bitCast(value),
        reg_echo_end => q.echo.end_pos = value,
        reg_wet_filter, reg_wet_filter + channel_stride => {
            q.filter[(reg - reg_wet_filter) / channel_stride].table_pos = value;
        },
        reg_wet_delay, reg_wet_delay + channel_stride => {
            q.wet[(reg - reg_wet_delay) / channel_stride].delay = @bitCast(value);
        },
        reg_wet_delay + 1, reg_wet_delay + 1 + channel_stride => {
            q.dry[(reg - reg_wet_delay - 1) / channel_stride].delay = @bitCast(value);
        },
        reg_wet_volume, reg_wet_volume + channel_stride => {
            q.wet[(reg - reg_wet_volume) / channel_stride].volume = @bitCast(value);
        },
        reg_dry_volume, reg_dry_volume + channel_stride => {
            q.dry[(reg - reg_dry_volume) / channel_stride].volume = @bitCast(value);
        },
        reg_delay_update => q.delay_update = value != 0,
        reg_state => q.next_state = @enumFromInt(value),
        else => {},
    }
}

// ------------------------------------------------------------- the DSP

/// One stereo sample at the chip's own rate, which is one turn of the DSP
/// program: initialising, reloading the pan filters, or mixing.
pub fn sample(q: *Qsound) audio.Frame {
    switch (q.state) {
        .refresh1, .refresh2 => refresh(q),
        .normal1, .normal2 => mix(q),
        // Both init entry points, and the nothing the chip powers up holding.
        else => start(q),
    }
    return .{ .l = q.out[0], .r = q.out[1] };
}

/// The initialisation the program runs before it will play anything: every
/// voice silenced and pointed at the sample ROM, the pans centred, the pan
/// filters and output delays given the mode-1 defaults. It costs three turns
/// of the program, and the refresh turn after it reloads the pan filters, so
/// the fifth sample is the first one a listener hears.
///
/// ponytail: mode 2 initialises differently and adds a second filter on the
/// dry path. DESIGN.md §7.3 rules it out of scope — no known board uses it —
/// so a driver that asks for it gets mode 1. The state register is decoded, so
/// this shows up as `next_state` reading `init2`, not as silence.
fn start(q: *Qsound) void {
    if (q.counter >= init_turns) {
        q.counter = 0;
        q.state = q.next_state;
        return;
    }
    if (q.counter == 1) {
        q.counter = init_turns;
        return;
    }

    q.voice = @splat(.{});
    q.filter = @splat(.{});
    q.wet = @splat(.{});
    q.dry = @splat(.{});
    q.echo = .{};
    q.pan = @splat(pan_centre);

    for (&q.voice) |*v| v.bank = bank_enable;
    q.dry[0].delay = dry_delay_left;
    q.dry[1].delay = dry_delay_right;
    for (&q.wet, &q.dry) |*w, *d| {
        w.volume = delay_volume;
        d.volume = delay_volume;
    }
    q.filter[0].table_pos = filter_left;
    q.filter[1].table_pos = filter_right;
    q.echo.end_pos = echo_base + normal_samples;

    q.next_state = .refresh1;
    q.delay_update = true;
    q.ready_flag = 0;
    q.counter = 1;
}

/// Copies the coefficients each pan filter has been pointed at. A register
/// pointing at nothing the ROM has leaves the filter with what it had, which
/// is what the program's own bounds check does.
fn refresh(q: *Qsound) void {
    for (&q.filter) |*f| {
        f.at = 0;
        f.tap_count = rom.fir_taps;
        const table = rom.table(f.table_pos) orelse continue;
        // ponytail: the last table in the ROM is exactly 95 coefficients from
        // its end, so a shorter one can only come of a register pointing into
        // the overlap run past that. Zero rather than read off the end.
        const taken = @min(table.len, rom.fir_taps);
        @memcpy(f.taps[0..taken], table[0..taken]);
        @memset(f.taps[taken..], 0);
    }
    q.state = .normal1;
    q.next_state = .normal1;
}

/// One mixed sample: every voice stepped, the echo fed and read, and the two
/// outputs built out of a dry component and a filtered wet one.
fn mix(q: *Qsound) void {
    q.ready_flag = ready;

    // The echo length is the difference between where the driver put its end
    // and where the line starts, taken as the sixteen bits the DSP keeps.
    const span: i16 = @truncate(@as(i32, q.echo.end_pos) - echo_base);
    q.echo.length = std.math.clamp(span, 0, echo_len);

    var heard: [voices]i16 = undefined;
    var echo_in: i32 = 0;
    for (&q.voice, &heard, 0..) |*v, *out, i| {
        const played = step(q, v);
        out.* = if (q.muted & @as(u16, 1) << @intCast(i) != 0) 0 else played;
        echo_in +%= (@as(i32, out.*) * v.echo) << 2;
    }
    const echoed = echoStep(&q.echo, echo_in);

    for (0..channels) |ch| {
        // The echo comes back on the unfiltered half of the left channel and
        // the filtered half of the right one, which is most of what makes the
        // effect wide.
        var wet: i32 = if (ch == 1) @as(i32, echoed) << 16 else 0;
        var dry: i32 = if (ch == 0) @as(i32, echoed) << 16 else 0;
        for (heard, q.pan) |out, pan| {
            const p = panIndex(pan);
            dry -%= (@as(i32, out) * pan_table[ch][pan_dry][p]) << 2;
            wet -%= (@as(i32, out) * pan_table[ch][pan_wet][p]) << 2;
        }

        wet = firStep(&q.filter[ch], @truncate(wet >> 16));
        const mixed = (delayStep(&q.wet[ch], wet) +% delayStep(&q.dry[ch], dry)) << 2;
        // Round to nearest and keep the top half. The program masks the low
        // sixteen bits off first, which an arithmetic shift already does.
        q.out[ch] = @truncate((mixed +% dsp_round) >> 16);

        if (q.delay_update) {
            delayReload(&q.wet[ch]);
            delayReload(&q.dry[ch]);
        }
    }
    q.delay_update = false;

    q.counter += 1;
    if (q.counter >= normal_samples) {
        q.counter = 0;
        q.state = q.next_state;
    }
}

/// One voice: the sample under its position, at its volume, and the position
/// moved on by its rate — back by the loop length when it reaches the end.
fn step(q: *Qsound, v: *Voice) i16 {
    const played: i16 = @truncate((@as(i32, v.volume) * pcm(q, v.bank, v.addr)) >> volume_shift);

    var at: i32 = @as(i32, v.rate) + ((@as(i32, v.addr) << phase_bits) | (v.phase >> 4));
    if (at >> phase_bits >= v.end_addr) at -= @as(i32, v.loop_len) << phase_bits;
    at = std.math.clamp(at, phase_min, phase_max);
    v.addr = @truncate(at >> phase_bits);
    v.phase = @truncate(@as(u32, @bitCast(at)) << 4);
    return played;
}

/// A byte of the sample ROM, as the sixteen bits the DSP reads it into: the
/// ROM is eight bits wide and the chip repeats the byte in both halves.
fn pcm(q: *const Qsound, bank: u16, addr: i16) i16 {
    if (bank & bank_enable == 0) return 0;
    const at = (@as(u32, bank & bank_mask) << bank_shift | @as(u16, @bitCast(addr))) & q.sample_mask;
    if (at >= q.samples.len) return 0;
    const byte: u16 = q.samples[at];
    return @bitCast(byte << 8 | byte);
}

/// The echo: a two-tap moving average off the delay line, fed back in at the
/// driver's chosen depth. What it returns is the averaged old sample, so the
/// echo a listener hears is one lap of the line behind the mix.
fn echoStep(e: *Echo, input: i32) i16 {
    const at: usize = @intCast(e.at);
    const stored: i32 = e.line[at];
    const averaged: i32 = (stored + e.last) >> 1;
    e.last = @truncate(stored);

    e.line[at] = @truncate((input +% ((averaged * e.feedback) << 2)) >> 16);
    e.at += 1;
    if (e.at >= e.length) e.at = 0;
    return @truncate(averaged);
}

/// The pan filter. The newest sample meets the last tap on its way past, so
/// the line holds one fewer sample than there are coefficients.
fn firStep(f: *Fir, input: i16) i32 {
    const wrap = f.tap_count - 1;
    var acc: i32 = 0;
    for (f.taps[0..wrap]) |tap| {
        acc -%= (@as(i32, tap) * f.line[f.at]) << 2;
        f.at += 1;
        if (f.at >= wrap) f.at = 0;
    }
    acc -%= (@as(i32, f.taps[wrap]) * input) << 2;

    f.line[f.at] = input;
    f.at += 1;
    if (f.at >= wrap) f.at = 0;
    return acc;
}

/// One step of an output delay line: the new sample in at the write position,
/// an older one out at the read position and through the attenuator.
fn delayStep(d: *Delay, input: i32) i32 {
    d.line[@intCast(d.write_at)] = @truncate(input >> 16);
    d.write_at = @rem(d.write_at + 1, delay_len);

    const out = @as(i32, d.line[@intCast(d.read_at)]) * d.volume;
    d.read_at = @rem(d.read_at + 1, delay_len);
    return out;
}

/// Puts the read position back where the delay register says, which is the
/// only way the length changes: the line itself never moves.
fn delayReload(d: *Delay) void {
    d.read_at = @intCast(@mod(@as(i32, d.write_at) - d.delay, delay_len));
}

fn panIndex(pan: u16) usize {
    const p = pan -% pan_base;
    return if (p > pan_max) pan_max else p;
}

/// The two mix curves as the chip holds them: one attenuation per channel per
/// pan position, the right channel reading its curve backwards. Above
/// `pan_linear` the dry path switches to the linear curve and the wet path
/// goes to zero, which is what mutes the filter and gives plain stereo.
const pan_table = blk: {
    var t: [channels][2][pan_entries]i16 = @splat(@splat(@splat(0)));
    for (0..rom.pan_steps + 1) |i| {
        const mirrored = rom.pan_steps - i;
        t[0][pan_dry][i] = rom.dry_mix[i];
        t[1][pan_dry][i] = rom.dry_mix[mirrored];
        t[0][pan_wet][i] = rom.wet_mix[i];
        t[1][pan_wet][i] = rom.wet_mix[mirrored];
        t[0][pan_dry][i + pan_linear] = rom.linear_mix[i];
        t[1][pan_dry][i + pan_linear] = rom.linear_mix[mirrored];
    }
    break :blk t;
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A chip taken past its four-sample initialisation, so a test can write
/// registers and hear the result rather than waiting for the program to boot.
fn started(q: *Qsound) void {
    for (0..boot_samples) |_| _ = sample(q);
}

fn setReg(q: *Qsound, reg: u8, value: u16) void {
    write(q, port_data_hi, @intCast(value >> 8));
    write(q, port_data_lo, @truncate(value));
    write(q, port_reg, reg);
}

test "two data bytes and a register number are one register write" {
    var q = Qsound{};
    write(&q, port_data_hi, 0x12);
    write(&q, port_data_lo, 0x34);
    // Nothing lands until the register write commits it.
    try testing.expectEqual(@as(u64, 0), q.writes);

    write(&q, port_reg, 0x0b);
    try testing.expectEqual(@as(u16, 0x1234), q.regs[0x0b]);
    try testing.expectEqual(@as(u64, 1), q.writes);

    // The latch keeps its halves, so a driver writing only the low byte of the
    // next value keeps the high one.
    write(&q, port_data_lo, 0x56);
    write(&q, port_reg, 0x0c);
    try testing.expectEqual(@as(u16, 0x1256), q.regs[0x0c]);
}

test "the log keeps the most recent writes, oldest first" {
    var q = Qsound{};
    for (0..log_len + 3) |i| {
        write(&q, port_data_lo, @intCast(i));
        write(&q, port_reg, @intCast(i));
    }

    var buf: [log_len]Write = undefined;
    const recent = q.recent(&buf);
    try testing.expectEqual(@as(usize, log_len), recent.len);
    try testing.expectEqual(@as(u8, 3), recent[0].reg);
    try testing.expectEqual(@as(u8, log_len + 2), recent[recent.len - 1].reg);

    // And a log that has not filled yet is short rather than padded.
    var fresh = Qsound{};
    write(&fresh, port_reg, 0x40);
    try testing.expectEqual(@as(usize, 1), fresh.recent(&buf).len);
}

test "the chip is busy until it has booted, and busy again after every write" {
    var q = Qsound{};
    // The chip mixes nothing while it initialises, and a driver's spin loop
    // spins for those samples.
    for (0..boot_samples - 1) |_| {
        try testing.expectEqual(@as(u8, 0), read(&q));
        _ = sample(&q);
    }
    _ = sample(&q);
    try testing.expectEqual(@as(u8, ready), read(&q));

    setReg(&q, reg_voice_pan, pan_centre);
    try testing.expectEqual(@as(u8, 0), read(&q));
    _ = sample(&q);
    try testing.expectEqual(@as(u8, ready), read(&q));
}

test "initialisation leaves the chip with the defaults the program writes" {
    var q = Qsound{};
    started(&q);

    for (q.voice) |v| try testing.expectEqual(@as(u16, bank_enable), v.bank);
    for (q.pan) |p| try testing.expectEqual(@as(u16, pan_centre), p);
    try testing.expectEqual(@as(i16, dry_delay_right), q.dry[1].delay);
    try testing.expectEqual(@as(i16, delay_volume), q.wet[0].volume);
    // The pan filters were pointed at the mask ROM and reloaded from it: the
    // left one's big centre tap is what says the coefficients really arrived.
    try testing.expectEqual(rom.filters[1][43], q.filter[0].taps[43]);
    try testing.expectEqual(rom.filters[2][45], q.filter[1].taps[45]);
    // Six samples of mixing and the program comes back round to itself.
    for (0..normal_samples) |_| _ = sample(&q);
    try testing.expectEqual(State.normal1, q.state);
}

test "a bank register belongs to the next voice, and the rest to its own" {
    var q = Qsound{};
    started(&q);

    setReg(&q, 0 * voice_regs + reg_bank, bank_enable | 3);
    try testing.expectEqual(@as(u16, bank_enable | 3), q.voice[1].bank);
    // The last voice's bank register wraps back to the first.
    setReg(&q, (voices - 1) * voice_regs + reg_bank, bank_enable | 9);
    try testing.expectEqual(@as(u16, bank_enable | 9), q.voice[0].bank);

    setReg(&q, 5 * voice_regs + reg_rate, 0x2000);
    try testing.expectEqual(@as(u16, 0x2000), q.voice[5].rate);
    setReg(&q, 5 * voice_regs + reg_volume, 0x4000);
    try testing.expectEqual(@as(i16, 0x4000), q.voice[5].volume);
    // The eighth register of every voice is not decoded, and says so by
    // leaving the voice alone rather than by landing somewhere else.
    const before = q.voice[5];
    setReg(&q, 5 * voice_regs + 7, 0xffff);
    try testing.expectEqual(before, q.voice[5]);
}

/// A ramp, so a sample read at the wrong address is a different number rather
/// than the same one.
fn rampRom() [0x10000]u8 {
    var r: [0x10000]u8 = undefined;
    for (&r, 0..) |*b, i| b.* = @truncate(i);
    return r;
}

/// Sets voice 0 playing `sample_rom` from `start` at unity volume and one
/// sample per output sample, hard left, with no echo send.
fn playVoice(q: *Qsound, start_at: u16, end_at: u16, loop: i16) void {
    setReg(q, 0 * voice_regs + reg_bank, bank_enable);
    // Voice 0's bank comes from voice 15's register.
    setReg(q, (voices - 1) * voice_regs + reg_bank, bank_enable);
    setReg(q, 0 * voice_regs + reg_addr, start_at);
    setReg(q, 0 * voice_regs + reg_phase, 0);
    setReg(q, 0 * voice_regs + reg_rate, 1 << phase_bits);
    setReg(q, 0 * voice_regs + reg_end_addr, end_at);
    setReg(q, 0 * voice_regs + reg_loop_len, @bitCast(loop));
    setReg(q, 0 * voice_regs + reg_volume, 1 << volume_shift);
}

test "a voice walks the sample ROM at its rate and loops back at its end" {
    var samples = rampRom();
    var q = Qsound{};
    attach(&q, &samples);
    started(&q);
    playVoice(&q, 0x100, 0x104, 4);

    // One ROM sample per output sample, so the position walks one at a time,
    // and the step that would reach the end address takes the loop length back
    // off instead: it plays 0x100 to 0x103 forever rather than running into
    // whatever follows.
    for ([_]i16{ 0x101, 0x102, 0x103, 0x100, 0x101 }) |want| {
        _ = sample(&q);
        try testing.expectEqual(want, q.voice[0].addr);
    }

    // Half the rate is half the speed, and the fractional half is carried.
    setReg(&q, 0 * voice_regs + reg_rate, 1 << (phase_bits - 1));
    const at = q.voice[0].addr;
    _ = sample(&q);
    try testing.expectEqual(at, q.voice[0].addr);
    _ = sample(&q);
    try testing.expectEqual(at + 1, q.voice[0].addr);
}

test "a voice with no bank enable reads silence rather than the DSP's own space" {
    var samples = rampRom();
    var q = Qsound{};
    attach(&q, &samples);
    started(&q);
    playVoice(&q, 0x100, 0x8000, 0);

    setReg(&q, (voices - 1) * voice_regs + reg_bank, 0);
    for (0..normal_samples) |_| _ = sample(&q);
    try testing.expectEqual(audio.Frame{ .l = 0, .r = 0 }, sample(&q));
}

/// The loudest either channel gets over `n` samples, once the pan filter and
/// the output delays have flushed whatever came before. Without the settle a
/// measurement taken after a register write is the tail of the last one.
fn peak(q: *Qsound, n: usize) [channels]u32 {
    var loudest: [channels]u32 = @splat(0);
    for (0..rom.fir_taps + delay_len) |_| _ = sample(q);
    for (0..n) |_| {
        const f = sample(q);
        for (&loudest, [channels]i16{ f.l, f.r }) |*p, v| p.* = @max(p.*, @abs(@as(i32, v)));
    }
    return loudest;
}

const silence = [channels]u32{ 0, 0 };

/// An echo send loud enough to hear and quiet enough that the chip's own
/// accumulator does not wrap, which it is entitled to and which would make an
/// amplitude test measure the wrap rather than the echo.
const echo_send = 0x0800;

/// A square wave, so a voice has something with energy in it to play.
fn squareRom() [0x10000]u8 {
    var r: [0x10000]u8 = undefined;
    for (&r, 0..) |*b, i| b.* = if (i / 8 % 2 == 0) 0x60 else 0xa0;
    return r;
}

test "a pan register moves a voice between the channels" {
    var samples = squareRom();
    var q = Qsound{};
    attach(&q, &samples);
    started(&q);
    playVoice(&q, 0, 0x7fff, 0);

    setReg(&q, reg_voice_pan, pan_base);
    const left = peak(&q, 400);
    setReg(&q, reg_voice_pan, pan_base + rom.pan_steps);
    const right = peak(&q, 400);

    // Hard left is not silence on the right, and is not meant to be: what the
    // far channel gets is the filtered component, which is the whole trick.
    // Panning moves the balance between them, so the balance is what is
    // measured: neither channel goes quiet, but which one leads changes.
    try testing.expect(@as(u64, left[0]) * right[1] > @as(u64, left[1]) * right[0]);

    // Centred, both channels get it, and neither is far ahead of the other.
    setReg(&q, reg_voice_pan, pan_centre);
    const centre = peak(&q, 400);
    try testing.expect(centre[0] > 0 and centre[1] > 0);
    try testing.expect(centre[0] < centre[1] * 4 and centre[1] < centre[0] * 4);

    // Above the linear window the wet path is muted, so a hard-left voice
    // really does leave the right channel alone.
    setReg(&q, reg_voice_pan, pan_base + pan_linear);
    const linear = peak(&q, 400);
    try testing.expect(linear[0] > 0);
    try testing.expect(linear[1] * 20 < linear[0]);
}

test "a muted voice is not heard, in the mix or in the echo, and keeps its place" {
    var samples = squareRom();
    var q = Qsound{};
    attach(&q, &samples);
    started(&q);
    playVoice(&q, 0, 0x7fff, 0);
    setReg(&q, reg_voice_echo, echo_send);
    try testing.expect(peak(&q, 400)[0] > 0);

    q.muted = 1;
    // Past the echo's tail and both delay lines, so what is left is not the
    // last of the mix on its way out.
    _ = peak(&q, 2000);
    try testing.expectEqual(silence, peak(&q, 400));

    // It kept running: unmuting it does not restart the sample.
    const at = q.voice[0].addr;
    q.muted = 0;
    _ = peak(&q, 400);
    try testing.expect(q.voice[0].addr != at);
    try testing.expect(peak(&q, 400)[0] > 0);
}

test "the echo sends a voice back around its delay line" {
    var samples = squareRom();
    var q = Qsound{};
    attach(&q, &samples);
    started(&q);
    playVoice(&q, 0, 0x7fff, 0);

    // A long line, so the echo lands well after the note rather than inside it.
    const line = 400;
    setReg(&q, reg_echo_end, echo_base + line);
    setReg(&q, reg_echo_feedback, 0x3000);
    setReg(&q, reg_voice_echo, echo_send);
    _ = peak(&q, line * 2);

    // Cut the voice, wait for the direct sound to clear the pan filter and the
    // output delay, and what is still coming out is the line emptying itself.
    setReg(&q, 0 * voice_regs + reg_volume, 0);
    _ = peak(&q, rom.fir_taps + delay_len * 2);
    try testing.expect(peak(&q, line)[0] > 0);

    // With the feedback off, the line runs dry inside one lap of it.
    setReg(&q, reg_echo_feedback, 0);
    _ = peak(&q, line * 2);
    try testing.expectEqual(silence, peak(&q, line));
}

test "a filter register the ROM has nothing at leaves the filter alone" {
    var q = Qsound{};
    started(&q);
    const before = q.filter[0].taps;

    setReg(&q, reg_wet_filter, 0);
    setReg(&q, reg_state, @intFromEnum(State.refresh1));
    for (0..normal_samples * 2) |_| _ = sample(&q);
    try testing.expectEqual(before, q.filter[0].taps);

    // And one it does have something at reloads from there.
    setReg(&q, reg_wet_filter, filter_right);
    setReg(&q, reg_state, @intFromEnum(State.refresh1));
    for (0..normal_samples * 2) |_| _ = sample(&q);
    try testing.expectEqual(rom.filters[2][45], q.filter[0].taps[45]);
}

test "the pan curves are the chip's, mirrored between the channels" {
    // Hard left is full attenuation on the right and none on the left, and the
    // curve the right channel reads is the left one backwards.
    try testing.expectEqual(pan_table[0][pan_dry][0], pan_table[1][pan_dry][rom.pan_steps]);
    try testing.expect(pan_table[0][pan_dry][rom.pan_steps] == 0);
    // Above the linear window the wet path is silent, which is what turns the
    // filter off and leaves plain stereo.
    try testing.expect(pan_table[0][pan_wet][pan_linear] == 0);
    try testing.expect(pan_table[0][pan_dry][pan_linear] != 0);
    // A pan register below the base, or far above it, is pinned to the end of
    // the table rather than reading off it.
    try testing.expectEqual(@as(usize, pan_max), panIndex(0));
    try testing.expectEqual(@as(usize, pan_max), panIndex(0xffff));
    try testing.expectEqual(@as(usize, 0), panIndex(pan_base));
}
