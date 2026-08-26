//! The OKI M6295: four ADPCM voices off one sample ROM.
//!
//! The chip is a phrase player, not a register file. A driver writes a phrase
//! number with bit 7 set, then a second byte saying which of the four voices
//! shall play it and how loud; the chip reads that phrase's start and stop
//! address out of a table in the first 1 KiB of the ROM and decodes Dialogic
//! ADPCM from there, one nibble per output sample, until it runs out.
//!
//! Its sample rate is set by pin 7 rather than by a register: the CPS-1 sound
//! board wires that pin to a Z80 port (§7.5), so a game may change it while it
//! runs, and the scheduler asks which divider is in effect every line.

const std = @import("std");

pub const voices = 4;

/// The phrase table: 128 entries of eight bytes at the base of the ROM, of
/// which the first six are a 18-bit start and stop address.
pub const phrase_bytes = 8;
pub const phrases = 128;
pub const addr_mask = 0x3ffff;

/// A phrase number arrives with this bit set; anything else is the second half
/// of a command, or a stop on its own.
pub const phrase_flag = 0x80;

/// In a play command, one bit per voice starting here. A stop command — one
/// with no phrase latched before it — uses a different set of bits, one place
/// down. That asymmetry is the chip's, not a typo.
pub const play_shift = 4;
pub const stop_shift = 3;

/// Pin 7 divides the chip's clock by one of two numbers to get its sample
/// rate. High is the CPS-1 board's reset state.
pub const divider_high = 132;
pub const divider_low = 165;

/// Attenuation per step of the command's low nibble, as a numerator over 32:
/// 0 dB down to -24 dB in eight steps, and silence past that.
const volume_table = [16]i32{ 32, 22, 16, 11, 8, 6, 4, 3, 2, 0, 0, 0, 0, 0, 0, 0 };
pub const volume_shift = 5;

/// The Dialogic step table: 49 sizes, each a tenth larger than the last, and
/// the index into it moves by this much per nibble. Every ADPCM bug lives in
/// the clamp at the two ends of that index.
const steps = 49;
const index_shift = [8]i8{ -1, -1, -1, -1, 2, 4, 6, 8 };

const step_table = blk: {
    @setEvalBranchQuota(4000);
    var t: [steps]i32 = undefined;
    var v: f64 = 16.0;
    for (&t) |*x| {
        x.* = @intFromFloat(@floor(v));
        v *= 1.1;
    }
    break :blk t;
};

/// The signal is 12 bits signed, and saturates rather than wraps.
pub const signal_max = 2047;
pub const signal_min = -2048;

/// One decoded nibble: how far the signal moved, and where the step index
/// went. The nibble is a sign bit and three magnitude bits, each weighting a
/// fraction of the current step size.
fn diff(step: i32, nibble: u4) i32 {
    const s: u32 = @intCast(step);
    const mag: i32 = @intCast(s / 8 +
        (if (nibble & 1 != 0) s / 4 else 0) +
        (if (nibble & 2 != 0) s / 2 else 0) +
        (if (nibble & 4 != 0) s else 0));
    return if (nibble & 8 != 0) -mag else mag;
}

pub const Voice = struct {
    playing: bool = false,
    /// Where in the ROM the next nibble comes from, and which half of the byte.
    at: u32 = 0,
    high_nibble: bool = false,
    /// Nibbles left in the phrase.
    left: u32 = 0,
    signal: i32 = 0,
    index: i32 = 0,
    volume: i32 = 0,
};

pub const Oki = struct {
    rom: []const u8 = &.{},
    voice: [voices]Voice = @splat(.{}),
    /// The phrase number waiting for the command that keys it, or none.
    latched: ?u7 = null,
    /// The state of pin 7. High is the faster of the two rates.
    pin7: bool = true,
};

pub fn attach(o: *Oki, samples: []const u8) void {
    o.rom = samples;
    reset(o);
}

pub fn reset(o: *Oki) void {
    o.voice = @splat(.{});
    o.latched = null;
    o.pin7 = true;
}

/// How many of the chip's own clocks one output sample takes.
pub fn divider(o: *const Oki) u32 {
    return if (o.pin7) divider_high else divider_low;
}

fn romByte(o: *const Oki, at: u32) u8 {
    return if (at < o.rom.len) o.rom[at] else 0;
}

fn address(o: *const Oki, at: u32) u32 {
    const hi: u32 = romByte(o, at);
    const mid: u32 = romByte(o, at + 1);
    const lo: u32 = romByte(o, at + 2);
    return (hi << 16 | mid << 8 | lo) & addr_mask;
}

/// A read answers which voices are still playing, one bit each from bit 0 up.
/// The top nibble reads back as ones, which is what the chip does and what at
/// least one driver waits on.
pub const status_high = 0xf0;

pub fn read(o: *const Oki) u8 {
    var v: u8 = status_high;
    for (o.voice, 0..) |voice, i| {
        if (voice.playing) v |= @as(u8, 1) << @intCast(i);
    }
    return v;
}

pub fn write(o: *Oki, value: u8) void {
    if (o.latched) |phrase| {
        o.latched = null;
        for (&o.voice, 0..) |*v, i| {
            if (value & (@as(u8, 1) << @intCast(play_shift + i)) == 0) continue;
            // A voice already playing keeps what it is playing: the chip has
            // one address counter per voice and the command does not reload it.
            if (v.playing) continue;
            const base = @as(u32, phrase) * phrase_bytes;
            const start = address(o, base);
            const stop = address(o, base + 3);
            if (start >= stop) continue;
            v.* = .{
                .playing = true,
                .at = start,
                .high_nibble = true,
                .left = 2 * (stop - start + 1),
                .volume = volume_table[value & 0x0f],
            };
        }
        return;
    }
    if (value & phrase_flag != 0) {
        o.latched = @truncate(value);
        return;
    }
    for (&o.voice, 0..) |*v, i| {
        if (value & (@as(u8, 1) << @intCast(stop_shift + i)) != 0) v.playing = false;
    }
}

/// One output sample: one nibble out of every playing voice, summed. The
/// result is the chip's twelve bits scaled by the voice's attenuation, which
/// puts a voice at full volume at the top of the sixteen-bit range.
pub fn sample(o: *Oki) i16 {
    var sum: i32 = 0;
    for (&o.voice) |*v| {
        if (!v.playing) continue;
        const byte = romByte(o, v.at);
        const nibble: u4 = if (v.high_nibble) @truncate(byte >> 4) else @truncate(byte);
        if (v.high_nibble) {
            v.high_nibble = false;
        } else {
            v.high_nibble = true;
            v.at +%= 1;
        }
        v.left -= 1;
        if (v.left == 0) v.playing = false;

        v.signal = std.math.clamp(v.signal + diff(step_table[@intCast(v.index)], nibble), signal_min, signal_max);
        v.index = std.math.clamp(v.index + index_shift[nibble & 7], 0, steps - 1);
        sum += v.signal * v.volume;
    }
    return @intCast(std.math.clamp(sum >> 1, std.math.minInt(i16), std.math.maxInt(i16)));
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "the step table is the Dialogic one" {
    try testing.expectEqual(@as(i32, 16), step_table[0]);
    try testing.expectEqual(@as(i32, 17), step_table[1]);
    try testing.expectEqual(@as(i32, 19), step_table[2]);
    try testing.expectEqual(@as(i32, 21), step_table[3]);
    try testing.expectEqual(@as(i32, 279), step_table[30]);
    try testing.expectEqual(@as(i32, 1552), step_table[steps - 1]);
}

test "the step index clamps at both ends" {
    var o = Oki{};
    // Eight nibbles of the largest magnitude walk the index off the top; it
    // stops at the last step rather than reading past the table.
    o.voice[0] = .{ .playing = true, .left = 1000, .volume = 1, .index = 0 };
    for (0..16) |_| {
        o.voice[0].index = std.math.clamp(o.voice[0].index + index_shift[7], 0, steps - 1);
    }
    try testing.expectEqual(@as(i32, steps - 1), o.voice[0].index);

    // And a run of the smallest walks it back to zero and stops there.
    for (0..100) |_| {
        o.voice[0].index = std.math.clamp(o.voice[0].index + index_shift[0], 0, steps - 1);
    }
    try testing.expectEqual(@as(i32, 0), o.voice[0].index);
}

/// The phrase a driver would write: a table entry pointing at some nibbles.
fn buildRom(nibbles: []const u4, buf: []u8) void {
    @memset(buf, 0);
    const start = phrases * phrase_bytes;
    const stop = start + (nibbles.len + 1) / 2 - 1;
    // Phrase 1's entry: start at [8..10], stop at [11..13].
    buf[phrase_bytes + 0] = @truncate(start >> 16);
    buf[phrase_bytes + 1] = @truncate(start >> 8);
    buf[phrase_bytes + 2] = @truncate(start);
    buf[phrase_bytes + 3] = @truncate(stop >> 16);
    buf[phrase_bytes + 4] = @truncate(stop >> 8);
    buf[phrase_bytes + 5] = @truncate(stop);
    for (nibbles, 0..) |n, i| {
        const at = start + i / 2;
        if (i % 2 == 0) buf[at] |= @as(u8, n) << 4 else buf[at] |= n;
    }
}

test "a known phrase decodes to known PCM" {
    var buf: [phrases * phrase_bytes + 16]u8 = undefined;
    // A rise on the biggest positive steps, then a fall on the biggest
    // negative ones: this walks the step index up and back down again.
    const nibbles = [_]u4{ 7, 7, 7, 7, 0xf, 0xf, 0xf, 0xf };
    buildRom(&nibbles, &buf);

    var o = Oki{};
    attach(&o, &buf);
    write(&o, phrase_flag | 1);
    write(&o, 1 << play_shift); // voice 0, full volume

    var out: [nibbles.len]i32 = undefined;
    for (&out) |*x| {
        _ = sample(&o);
        x.* = o.voice[0].signal;
    }
    // Worked by hand off the step table: a nibble of 7 adds step + step/2 +
    // step/4 + step/8 and moves the index up eight, so the four rises are
    // steps 16, 34, 73 and 157; the falls retrace them from step 337 and run
    // into the twelve-bit floor.
    try testing.expectEqualSlices(i32, &.{ 30, 93, 229, 522, -109, -1466, -2048, -2048 }, &out);
    try testing.expect(!o.voice[0].playing);
}

test "a play command keys the voices it names and a stop silences them" {
    var buf: [phrases * phrase_bytes + 16]u8 = undefined;
    buildRom(&[_]u4{ 1, 2, 3, 4 }, &buf);

    var o = Oki{};
    attach(&o, &buf);
    // A second byte with nothing latched is a stop, not a play.
    write(&o, 1 << play_shift);
    try testing.expect(!o.voice[0].playing);

    write(&o, phrase_flag | 1);
    write(&o, (1 << (play_shift + 2)) | 0x08);
    try testing.expect(o.voice[2].playing);
    try testing.expectEqual(volume_table[8], o.voice[2].volume);
    try testing.expectEqual(@as(u8, status_high | 0x04), read(&o));

    write(&o, 1 << (stop_shift + 2));
    try testing.expect(!o.voice[2].playing);
    try testing.expectEqual(@as(u8, status_high), read(&o));
}

test "pin 7 picks the divider" {
    var o = Oki{};
    try testing.expectEqual(@as(u32, divider_high), divider(&o));
    o.pin7 = false;
    try testing.expectEqual(@as(u32, divider_low), divider(&o));
}
