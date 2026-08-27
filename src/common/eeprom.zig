//! The 93C46 serial EEPROM: sixty-four words, one wire in and one out.
//!
//! A QSound board has no DIP switches — everything a DIP switch would have
//! said lives here and is edited in the board's own service menu. The chip is
//! the same one on CPS-2, wired to a different port, so what it knows is the
//! protocol and nothing about which register drove its three pins.

const std = @import("std");

pub const words = 64;
pub const bytes = words * 2;
/// An erased cell is all ones, which is what an unprogrammed chip holds and
/// what a board with no `.nv` file beside it comes up with.
pub const erased = 0xffff;

/// Start bit, two opcode bits, six address bits: what the chip listens for
/// before it does anything at all.
pub const command_bits = 9;
pub const data_bits = 16;
/// A read clocks out a dummy zero before the word, so its shift register is a
/// bit wider than the word it holds.
const read_bits = data_bits + 1;

pub const Op = enum(u2) { special, write, read, erase };
/// `special` puts its own two bits at the top of the address field.
pub const Special = enum(u2) { disable, write_all, erase_all, enable };

pub const Eeprom = struct {
    data: [words]u16 = @splat(erased),
    /// Set by any cell that changed, cleared by the frontend once the sidecar
    /// file has been rewritten. A game writes its settings a word at a time.
    dirty: bool = false,

    cs: bool = false,
    clk: bool = false,
    /// Erase and write are refused until an enable command arrives, which is
    /// what stops a glitching board from wiping its own settings.
    writable: bool = false,

    /// What has been clocked in: the command, then a write's data word.
    shift: u16 = 0,
    bits: u8 = 0,
    in_data: bool = false,
    /// The data word about to arrive goes to every cell, not to `addr`.
    all: bool = false,
    addr: u6 = 0,

    /// What is being clocked out, MSB first, and how much of it is left.
    out: u32 = 0,
    out_bits: u8 = 0,

    /// The one wire the 68000 reads back. High while idle: a real chip pulls it
    /// there when it is ready for the next command, and a driver polls for it.
    pub fn read(e: *const Eeprom) u1 {
        if (e.out_bits == 0) return 1;
        return @truncate(e.out >> @intCast(e.out_bits - 1));
    }

    /// The three pins, as the machine's own port register left them.
    pub fn write(e: *Eeprom, cs: bool, clk: bool, di: u1) void {
        // Dropping chip select abandons whatever was half said. The enable
        // latch is not part of that: it holds until a disable command.
        if (!cs) {
            e.* = .{ .data = e.data, .dirty = e.dirty, .writable = e.writable };
            return;
        }
        defer e.clk = clk;
        e.cs = true;
        if (!clk or e.clk) return;
        e.shiftIn(di);
    }

    /// One rising clock edge.
    fn shiftIn(e: *Eeprom, di: u1) void {
        if (e.out_bits != 0) {
            e.out_bits -= 1;
            return;
        }
        // Leading zeros are not part of a command: the chip waits for the
        // start bit, so a driver may clock as many of them as it likes. A data
        // word has no start bit and every one of its zeros counts.
        if (!e.in_data and e.bits == 0 and di == 0) return;
        e.shift = e.shift << 1 | di;
        e.bits += 1;

        if (e.in_data) {
            if (e.bits < data_bits) return;
            const word = e.shift;
            const all = e.all;
            e.idle();
            if (!all) return e.poke(e.addr, word);
            for (0..words) |i| e.poke(@intCast(i), word);
            return;
        }
        if (e.bits < command_bits) return;
        e.command();
    }

    fn command(e: *Eeprom) void {
        const addr: u6 = @truncate(e.shift);
        const op: Op = @enumFromInt(@as(u2, @truncate(e.shift >> 6)));
        e.addr = addr;
        e.idle();
        switch (op) {
            .read => {
                e.out = e.data[addr];
                e.out_bits = read_bits;
            },
            .write => {
                e.in_data = true;
            },
            .erase => e.poke(addr, erased),
            .special => switch (@as(Special, @enumFromInt(@as(u2, @truncate(addr >> 4))))) {
                .enable => e.writable = true,
                .disable => e.writable = false,
                .erase_all => for (0..words) |i| e.poke(@intCast(i), erased),
                // Write-all takes its word the way a write does; every cell
                // gets it rather than the one the address field named.
                .write_all => {
                    e.in_data = true;
                    e.all = true;
                },
            },
        }
    }

    fn poke(e: *Eeprom, addr: u6, value: u16) void {
        if (!e.writable) return;
        e.data[addr] = value;
        e.dirty = true;
    }

    fn idle(e: *Eeprom) void {
        e.shift = 0;
        e.bits = 0;
        e.in_data = false;
        e.all = false;
    }

    /// The `.nv` file beside the set, big-endian so it reads the way the board
    /// does. A short or missing file leaves the rest of the chip erased, which
    /// is what a board whose settings menu grew a page sees on real hardware.
    pub fn load(e: *Eeprom, from: []const u8) void {
        e.* = .{};
        for (0..@min(words, from.len / 2)) |i| {
            e.data[i] = std.mem.readInt(u16, from[i * 2 ..][0..2], .big);
        }
    }

    pub fn save(e: *const Eeprom, out: *[bytes]u8) void {
        for (e.data, 0..) |word, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], word, .big);
    }
};
