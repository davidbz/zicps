//! QSound (DL-1425), as much of it as M3 needs: the host side of the DSP.
//!
//! The Z80 talks to the chip through three write ports and one read port — two
//! bytes of data latched, then a register number that commits them — and the
//! DSP answers nothing but "ready". M3 stops there: this logs what the sound
//! driver asks for and produces silence, which is what makes the driver
//! debuggable before there is a synthesiser to blame. The sixteen channels,
//! the pan FIR and the echo are M4's, and they read the same register file.

const std = @import("std");
const audio = @import("audio");

/// The register number is a byte, so this is every register the chip has,
/// decoded or not.
pub const reg_count = 0x100;

/// The three write ports, as offsets from the base of the chip's window.
pub const port_data_hi = 0;
pub const port_data_lo = 1;
pub const port_reg = 2;

/// What a read of the chip returns. The real DSP answers a status byte whose
/// top bit is "ready for the next command", and the driver spins on it; it is
/// always ready here because the writes land instantly.
pub const ready = 0x80;

pub const Write = struct { reg: u8 = 0, value: u16 = 0 };

/// How many of the most recent register writes are kept. Enough to see a
/// channel set up (bank, start, pitch, loop, end, volume, pan) without being a
/// log file: this is a window on the driver, not a recording of it.
pub const log_len = 32;

pub const Qsound = struct {
    /// The two data bytes, waiting for the register write that commits them.
    latch: u16 = 0,
    regs: [reg_count]u16 = @splat(0),

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
}

pub fn read(q: *const Qsound) u8 {
    _ = q;
    return ready;
}

/// One stereo sample at the chip's own rate. Silence until M4 puts the sixteen
/// channels behind it; the rate, the debt that produces it and everything
/// downstream of it are real already.
pub fn sample(q: *const Qsound) audio.Frame {
    _ = q;
    return .{ .l = 0, .r = 0 };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

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
