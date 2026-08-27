//! Save states: a small header and a straight copy of the machine's bytes.
//!
//! Because every chip is a plain fixed-size struct owned by value, a
//! state is `@memcpy` in both directions and there is no per-field serializer
//! to forget a field in — which is the usual way save states rot. What it costs
//! instead is that the file only means anything to the build that wrote it, so
//! the header carries a hash of every field's name, offset and width, computed
//! at comptime from the types themselves. Move a field, add one, widen one, and
//! yesterday's state is refused rather than loaded as garbage.
//!
//! The heap slices are the one thing not in the file: the ROMs belong to the
//! set this process loaded, not to the state, and they are put back over the
//! copy rather than saved with it.

const std = @import("std");
const cps = @import("cps");
const scheduler = @import("scheduler");

pub const Cpu = scheduler.Cpu;

/// First line of the file, so a state that is not one is refused by its first
/// twelve bytes rather than by its layout hash.
const magic = "zicps-state\n";
/// Bumped when the header itself changes shape. The machine moving underneath
/// it is what `layout_hash` is for, and does not need this.
const version: u32 = 1;

const version_at = magic.len;
const layout_at = version_at + @sizeOf(u32);
const body_at = layout_at + @sizeOf(u64);
const machine_bytes = @sizeOf(cps.Cps);
const cpu_bytes = @sizeOf(Cpu);

/// A state file, exactly. Every one is the same size: the machine is a fixed
/// struct and so is the file it goes in.
pub const bytes = body_at + machine_bytes + cpu_bytes;

/// What to read a state file with. One over the size and not the size itself,
/// because `readFileAlloc` refuses a stream that *reaches* its limit — and
/// every state reaches `bytes` on the nose, so the obvious cap rejects every
/// file this module writes.
pub const limit: std.Io.Limit = .limited(bytes + 1);

pub const Error = error{
    NotASaveState,
    WrongVersion,
    FromAnotherBuild,
    Truncated,
};

/// Every field's name, offset and width, all the way down, as one comptime
/// string. Pointers are named and not followed: what they point at is
/// reattached rather than saved, and following one would recurse forever
/// through a self-referential type.
fn layout(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(4_000_000);
        var s: []const u8 = @typeName(T) ++ std.fmt.comptimePrint(":{d}", .{@bitSizeOf(T)});
        switch (@typeInfo(T)) {
            .@"struct" => |info| for (info.fields) |f| {
                s = s ++ "{" ++ f.name ++
                    std.fmt.comptimePrint("@{d}", .{@bitOffsetOf(T, f.name)}) ++
                    layout(f.type) ++ "}";
            },
            .@"union" => |info| for (info.fields) |f| {
                s = s ++ "{" ++ f.name ++ layout(f.type) ++ "}";
            },
            .array => |a| s = s ++ layout(a.child),
            .optional => |o| s = s ++ layout(o.child),
            else => {},
        }
        return s;
    }
}

/// FNV-1a over that string. Not Wyhash: this runs at comptime over tens of
/// kilobytes, and a byte at a time with no bit tricks is the version that is
/// cheap to prove terminates inside an eval quota.
pub const layout_hash: u64 = blk: {
    @setEvalBranchQuota(4_000_000);
    var h: u64 = 0xcbf29ce484222325;
    for (layout(cps.Cps) ++ layout(Cpu)) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    break :blk h;
};

pub fn save(c: *const cps.Cps, cpu: *const Cpu, out: *[bytes]u8) void {
    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u32, out[version_at..][0..4], version, .little);
    std.mem.writeInt(u64, out[layout_at..][0..8], layout_hash, .little);
    @memcpy(out[body_at..][0..machine_bytes], std.mem.asBytes(c));
    @memcpy(out[body_at + machine_bytes ..][0..cpu_bytes], std.mem.asBytes(cpu));
}

/// Puts the machine back. The ROMs are the ones already in `c`: a state is only
/// ever loaded into the set it was taken from, and the file holds no pointer
/// worth trusting even when it does.
pub fn load(c: *cps.Cps, cpu: *Cpu, in: []const u8) Error!void {
    if (in.len < body_at or !std.mem.eql(u8, in[0..magic.len], magic)) return error.NotASaveState;
    if (std.mem.readInt(u32, in[version_at..][0..4], .little) != version) return error.WrongVersion;
    if (std.mem.readInt(u64, in[layout_at..][0..8], .little) != layout_hash) return error.FromAnotherBuild;
    if (in.len < bytes) return error.Truncated;

    const rom = c.rom;
    const b = c.board;
    const audio_rom = c.sound.rom;
    const samples = c.sound.q.samples;
    const adpcm = c.sound.m6295.rom;
    // The volume knob is the frontend's, not the machine's: a state taken
    // before the user turned it down must not turn it back up.
    const volume = c.mixer.volume_pct;

    @memcpy(std.mem.asBytes(c), in[body_at..][0..machine_bytes]);
    @memcpy(std.mem.asBytes(cpu), in[body_at + machine_bytes ..][0..cpu_bytes]);

    c.rom = rom;
    c.board = b;
    c.sound.rom = audio_rom;
    c.sound.q.samples = samples;
    c.sound.m6295.rom = adpcm;
    c.mixer.volume_pct = volume;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn bare() cps.Cps {
    return .{ .board = .{}, .rom = .{ .program = &.{}, .gfx = &.{}, .audio = &.{}, .qsound = &.{}, .oki = &.{} } };
}

test "a state round-trips the machine and leaves the ROMs where they were" {
    const buf = try testing.allocator.create([bytes]u8);
    defer testing.allocator.destroy(buf);

    var program = [_]u8{ 1, 2, 3, 4 };
    var c = bare();
    c.rom.program = &program;
    c.ram[0x1234] = 0xab;
    c.v.palette[7] = 0x0f0f;
    c.sound.shared[1][3] = 0x5a;
    c.frame = 99;
    var cpu: Cpu = .{};
    cpu.d[3] = 0xdeadbeef;
    save(&c, &cpu, buf);

    // Somewhere else entirely, with the same ROMs in it.
    var back = bare();
    back.rom.program = &program;
    back.ram[0x1234] = 0x00;
    var back_cpu: Cpu = .{};
    try load(&back, &back_cpu, buf);

    try testing.expectEqual(@as(u8, 0xab), back.ram[0x1234]);
    try testing.expectEqual(@as(u16, 0x0f0f), back.v.palette[7]);
    try testing.expectEqual(@as(u8, 0x5a), back.sound.shared[1][3]);
    try testing.expectEqual(@as(u64, 99), back.frame);
    try testing.expectEqual(@as(u32, 0xdeadbeef), back_cpu.d[3]);
    // The slice is this process's, not a number out of the file.
    try testing.expectEqual(@as([*]const u8, &program), back.rom.program.ptr);
}

test "a state that is not one, is from another build, or is short is refused" {
    const buf = try testing.allocator.create([bytes]u8);
    defer testing.allocator.destroy(buf);
    var c = bare();
    var cpu: Cpu = .{};
    save(&c, &cpu, buf);
    try load(&c, &cpu, buf);

    try testing.expectError(error.NotASaveState, load(&c, &cpu, "not a state at all"));
    try testing.expectError(error.Truncated, load(&c, &cpu, buf[0 .. bytes - 1]));

    var wrong = buf.*;
    wrong[layout_at] ^= 1;
    try testing.expectError(error.FromAnotherBuild, load(&c, &cpu, &wrong));
    wrong = buf.*;
    wrong[version_at] +%= 1;
    try testing.expectError(error.WrongVersion, load(&c, &cpu, &wrong));
}

test "the layout hash follows the machine's shape rather than its contents" {
    // Two types that differ only in a field's width hash differently, which is
    // the whole point: the bytes would still fit and mean something else.
    const a = comptime layout(struct { x: u16, y: [4]u8 });
    const wider = comptime layout(struct { x: u32, y: [4]u8 });
    try testing.expect(!std.mem.eql(u8, a, wider));
    // And a rename is a change too, because a field that moved names is a
    // field whose bytes now mean something else.
    const renamed = comptime layout(struct { x: u16, z: [4]u8 });
    try testing.expect(!std.mem.eql(u8, a, renamed));

    // And it goes all the way down rather than stopping at the machine's own
    // fields, which is what makes a chip's internals part of the reckoning.
    const machine = comptime layout(cps.Cps);
    try testing.expect(std.mem.indexOf(u8, machine, "gfxram") != null);
    try testing.expect(std.mem.indexOf(u8, machine, "sample_mask") != null);
}
