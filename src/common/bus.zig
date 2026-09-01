//! The 68000's data bus, as both boards see it.
//!
//! Nothing here knows which generation it is on: a lane is a lane, and a device
//! wired to one of them answers the same way on a CPS-1 board as on a CPS-2
//! one. The maps that say *which* device is at which address are each board's
//! own, in `cps1/machine.zig` and `cps2/machine.zig`.

const std = @import("std");
const romset = @import("romset");

/// What a read of nothing at all returns: the bus floats high.
pub const open_bus = 0xffff;

/// Which halves of the 16-bit data bus an access drives. A byte-wide device is
/// wired to one of them and leaves the other floating.
pub const high_lane = 0xff00;
pub const low_lane = 0x00ff;
pub const both_lanes = high_lane | low_lane;

/// A device wired to the low half of the data bus leaves the high half floating.
pub fn byteWide(value: u8) u16 {
    return high_lane | @as(u16, value);
}

/// The system inputs and the DIP banks are wired to the high half instead.
pub fn highByteWide(value: u8) u16 {
    return @as(u16, value) << 8 | low_lane;
}

/// A word out of a region, or the open bus past its end.
pub fn peek(bytes: []const u8, offset: u32) u16 {
    if (offset + 1 >= bytes.len) return open_bus;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

/// A byte out of a region. Past its end is unpopulated ROM rather than open
/// bus: these are the byte-wide chips, and a socket with nothing in it reads
/// as an erased EPROM.
pub fn peekByte(bytes: []const u8, offset: u32) u8 {
    if (offset >= bytes.len) return romset.blank;
    return bytes[offset];
}

/// The low `bits` bits set: which wires of a register are populated.
pub fn lowMask(bits: u4) u16 {
    return (@as(u16, 1) << bits) - 1;
}

/// A register takes only the lanes the CPU drove; the rest of it stands.
pub fn merge(reg: *u16, value: u16, mask: u16) void {
    reg.* = (reg.* & ~mask) | (value & mask);
}

pub fn pokeBytes(bytes: []u8, offset: u32, value: u16, mask: u16) void {
    if (offset + 1 >= bytes.len) return;
    if (mask & high_lane != 0) bytes[offset] = @truncate(value >> 8);
    if (mask & low_lane != 0) bytes[offset + 1] = @truncate(value);
}

/// A byte-wide device on the low lane: an access that drives only the high one
/// reaches nothing at all.
pub fn pokeByteWide(bytes: []u8, offset: u32, value: u16, mask: u16) void {
    if (offset >= bytes.len or mask & low_lane == 0) return;
    bytes[offset] = @truncate(value);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a read past the end of a region is the open bus, and of a byte-wide one blank ROM" {
    const rom = [_]u8{ 0x12, 0x34 };
    try testing.expectEqual(@as(u16, 0x1234), peek(&rom, 0));
    try testing.expectEqual(@as(u16, open_bus), peek(&rom, 1));
    try testing.expectEqual(@as(u8, 0x34), peekByte(&rom, 1));
    try testing.expectEqual(@as(u8, romset.blank), peekByte(&rom, 2));
}

test "a write reaches only the lanes it drives" {
    var reg: u16 = 0x1234;
    merge(&reg, 0xabcd, low_lane);
    try testing.expectEqual(@as(u16, 0x12cd), reg);
    merge(&reg, 0xabcd, high_lane);
    try testing.expectEqual(@as(u16, 0xabcd), reg);

    var ram = [_]u8{ 0, 0, 0 };
    pokeBytes(&ram, 0, 0xabcd, high_lane);
    try testing.expectEqual([_]u8{ 0xab, 0, 0 }, ram);
    pokeBytes(&ram, 0, 0xabcd, low_lane);
    try testing.expectEqual([_]u8{ 0xab, 0xcd, 0 }, ram);
    // Off the end, and the far side of a byte-wide device: neither is written.
    pokeBytes(&ram, 2, 0xabcd, both_lanes);
    pokeByteWide(&ram, 2, 0xabcd, high_lane);
    try testing.expectEqual([_]u8{ 0xab, 0xcd, 0 }, ram);
    pokeByteWide(&ram, 2, 0xabcd, low_lane);
    try testing.expectEqual([_]u8{ 0xab, 0xcd, 0xcd }, ram);
}

test "a byte-wide device leaves the lane it is not on floating" {
    try testing.expectEqual(@as(u16, 0xff5a), byteWide(0x5a));
    try testing.expectEqual(@as(u16, 0x5aff), highByteWide(0x5a));
    try testing.expectEqual(@as(u16, 0x003f), lowMask(6));
}
