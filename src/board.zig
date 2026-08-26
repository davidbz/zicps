//! The board file: what the battery on a CPS-1.5 board holds.
//!
//! The CPS-B-21's register mapping, its graphics bank table and the Kabuki key
//! are not in the ROMs — they are in RAM held up by a battery, which is why a
//! board with a dead one keeps every chip and forgets how to be itself. This
//! file is that RAM, as `key = value` text the user supplies beside their set.
//!
//! Unlike `config.zig`, nothing here is forgiving. Settings can fall back to a
//! default; a board cannot. A wrong CPS-B offset looks like a video bug rather
//! than a bad file, so every problem stops the load with a message naming the
//! key and the line it was on, and a missing key is named too.

const std = @import("std");

pub const version = 1;

/// A CPS-B register offset in bytes from $800140, or null on a board whose PAL
/// does not decode that register at all.
pub const Reg = ?u8;

/// How wide the CPS-B window is, and so how far a register offset can reach.
/// The 68000 decodes `0x800140-0x80017f` and no further, so an offset above
/// this names a register no bus cycle can reach. `cps.zig` asserts the two
/// agree.
pub const cps_b_bytes = 0x40;

/// The six things the video chip draws. The order is the bit order of a gfx
/// range's type mask.
pub const Layer = enum(u3) { sprites, scroll1, scroll2, scroll3, stars };

/// What the layer-enable masks are in, which is not `Layer`: the object list
/// has no enable bit of its own and each starfield has one.
pub const Enable = enum(u3) { scroll1, scroll2, scroll3, stars1, stars2 };
pub const enable_count = @typeInfo(Enable).@"enum".fields.len;

/// Every member of an enum, comma-separated, for the error messages that offer
/// the reader the whole list. Built from the enum, so a member added later
/// cannot go unnamed.
fn nameList(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".fields, 0..) |field, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ field.name;
        }
        return out;
    }
}

/// Which chips a tile code range lives on, and the same four bank sizes the
/// B-board's PAL switches between.
pub const gfx_banks = 4;
pub const max_gfx_ranges = 16;
pub const max_roms = 64;

/// The four halves of a Kabuki key. Two nibble permutations,
/// an address key and a XOR; `kabuki.zig` turns them into the two views of the
/// sound ROM.
pub const Kabuki = struct {
    swap1: u32,
    swap2: u32,
    addr: u16,
    xor: u8,
};

/// Which chip on the board a file's bytes belong to.
pub const Region = enum { program, gfx, audio, qsound, oki };
pub const region_count = @typeInfo(Region).@"enum".fields.len;
/// The two sound boards: a Z80 behind a Kabuki with the DL-1425 beside it, or a
/// plain Z80 with a YM2151 and an OKI M6295. `none` is a set with no sound ROM
/// at all, which only the in-repo test ROM is.
pub const Sound = enum { none, qsound, cps1 };

/// A tile's attribute word picks one of four priority masks, so the PAL decodes
/// four registers to hold them.
pub const priority_groups = 4;

/// How a file's bytes land in their region: one chip of a set is rarely a
/// contiguous slice of the address space the CPU sees.
pub const Mode = enum {
    /// A byte-wide chip, copied straight: the sound ROM and the samples.
    byte,
    /// A 16-bit program ROM. The file holds each word low byte first and the
    /// 68000 reads big-endian, so every pair is swapped on the way in.
    word,
    /// Half of a 16-bit pair: one byte of every two, in the file's own order.
    /// The even addresses of a 68000 region are its high bytes, so a chip that
    /// starts on one needs no swap.
    byte16,
    /// One of four graphics chips: two bytes of every eight.
    word64,
    /// One of eight graphics chips: one byte of every eight.
    byte64,

    /// One past the last byte of the region this load touches. An interleaved
    /// chip stops at its own last byte, not at the end of its neighbours'
    /// group, so this is not `dest + len * stride`.
    pub fn extent(m: Mode, dest: u32, len: u32) u64 {
        const d: u64 = dest;
        return switch (m) {
            .byte, .word => d + len,
            .byte16 => d + (len - 1) * 2 + 1,
            .word64 => d + (len / 2 - 1) * 8 + 2,
            .byte64 => d + (len - 1) * 8 + 1,
        };
    }
};

/// One file of the set, and where it goes. Reads as one MAME `ROM_LOAD` line
/// does, because that is what a user transcribing a set has in front of them.
pub const Rom = struct {
    region: Region,
    dest: u32,
    len: u32,
    mode: Mode,
    /// Offset within the file to start at, for a chip that lands in two pieces
    /// (MAME's `ROM_CONTINUE`).
    src: u32,
    /// The CRC32 of the whole file, when the board file names one: a board that
    /// came with this build knows which dump it was written against, and a set
    /// under the right name that is not that dump is refused rather than drawn.
    crc: ?u32 = null,
    /// Points into the board file text, which the caller keeps for the load.
    name: []const u8,
};

/// A tile code range and the bank it selects, straight off the B-board's PAL.
pub const GfxRange = struct {
    /// Bit per `Layer`.
    types: u8,
    start: u32,
    end: u32,
    bank: u2,
};

pub const Board = struct {
    // CPS-B-21 register offsets. These are the ones the battery holds.
    layer_control: Reg = null,
    priority: [priority_groups]Reg = @splat(null),
    palette_control: Reg = null,
    /// The self-test register some boards answer with a fixed value, and the
    /// value they answer with. A game that checks it will not boot without it.
    id_offset: Reg = null,
    id_value: u16 = 0,
    /// 16x16 multiply with a 32-bit result, used as a protection check: two
    /// factors written, two halves of the product read back.
    mult_factor1: Reg = null,
    mult_factor2: Reg = null,
    mult_result_lo: Reg = null,
    mult_result_hi: Reg = null,
    /// Extra controls and outputs a C-board maps into the CPS-B window.
    in2_offset: Reg = null,
    in3_offset: Reg = null,
    out2_offset: Reg = null,
    /// Which bit of the layer control register enables each layer, in `Enable`
    /// order. Ideally one bit each; on many boards it is not known which bit is
    /// which, which is why these are masks and not indices.
    layer_enable: [enable_count]u16 = @splat(0),
    /// The two raster counters, for a board whose PAL decodes them and whose
    /// B-board carries level 4 through to the 68000. Most do not, and a board
    /// file that says nothing gets no raster interrupt.
    raster_line: [2]Reg = @splat(null),

    bank_sizes: [gfx_banks]u32 = @splat(0),
    ranges: [max_gfx_ranges]GfxRange = undefined,
    range_count: u8 = 0,

    kabuki: ?Kabuki = null,

    roms: [max_roms]Rom = undefined,
    rom_count: u8 = 0,

    pub fn gfxRanges(b: *const Board) []const GfxRange {
        return b.ranges[0..b.range_count];
    }

    /// Which of the two sound boards this set came with. Nothing in a board file
    /// says so directly, and nothing needs to: no CPS-1 set has both a QSound
    /// sample ROM and an OKI one, so the samples name the board.
    pub fn sound(b: *const Board) Sound {
        var found = Sound.none;
        for (b.romList()) |r| switch (r.region) {
            .qsound => return .qsound,
            .audio, .oki => found = .cps1,
            else => {},
        };
        return found;
    }

    pub fn romList(b: *const Board) []const Rom {
        return b.roms[0..b.rom_count];
    }
};

/// Why a board file was refused, in words a user can act on. Held in a fixed
/// buffer so nothing here allocates.
pub const Diag = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }

    /// Truncates rather than fails: a message that does not fit is still worth
    /// more than no message.
    pub fn set(d: *Diag, comptime fmt: []const u8, args: anytype) void {
        var w = std.Io.Writer.fixed(&d.buf);
        w.print(fmt, args) catch {};
        d.len = w.buffered().len;
    }

    fn say(d: *Diag, comptime fmt: []const u8, args: anytype) error{BadBoardFile} {
        d.set(fmt, args);
        return error.BadBoardFile;
    }
};

pub const Error = error{BadBoardFile};

/// Every key a board file carries that is not a ROM line. The `Region` names
/// are keys too, and are matched after these.
const Key = enum {
    version,
    layer_control,
    priority,
    palette_control,
    id,
    multiply,
    in2,
    in3,
    out2,
    layer_enable,
    raster_line,
    bank_sizes,
    gfx_bank,
    kabuki,
};

/// The board being built and where in the file it is being built from. It is
/// what a line of the file is applied to, and what the two "did the file say
/// this at all" flags hang off.
const Parser = struct {
    b: Board = .{},
    diag: *Diag,
    line_no: u32 = 0,
    seen_version: bool = false,
    // A board whose PAL decodes no priority mask at all writes the line out as
    // four `none`s, and a board file that forgot the line has not. The values
    // cannot tell those apart, so the line is remembered rather than read back.
    seen_priority: bool = false,
};

/// Parses a board file. Every failure carries a line number and the key that
/// was wrong, or the list of keys that never appeared.
pub fn parse(text: []const u8, diag: *Diag) Error!Board {
    var p = Parser{ .diag = diag };

    var lines = std.mem.splitAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        p.line_no += 1;
        const line = trim(stripComment(raw));
        if (line.len == 0) continue;
        try parseLine(&p, line);
    }

    if (!p.seen_version) return diag.say("no `version` line: this does not look like a board file", .{});
    try require(&p.b, p.seen_priority, diag);
    return p.b;
}

/// One `key = value` line, whichever of the three kinds of key it names.
fn parseLine(p: *Parser, line: []const u8) Error!void {
    const diag = p.diag;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse
        return diag.say("line {d}: expected `key = value`, got `{s}`", .{ p.line_no, line });
    const key = trim(line[0..eq]);
    var vals = std.mem.tokenizeAny(u8, line[eq + 1 ..], " \t,");

    const what = std.meta.stringToEnum(Key, key);
    if (!p.seen_version and what != .version)
        return diag.say("line {d}: expected `version = {d}` first; this does not look like a board file", .{ p.line_no, version });

    if (what) |k| {
        try applyKey(p, k, key, &vals);
    } else if (std.meta.stringToEnum(Region, key)) |region| {
        try addRom(&p.b, region, &vals, p.line_no, diag);
    } else {
        return diag.say("line {d}: unknown key `{s}`", .{ p.line_no, key });
    }

    if (vals.next()) |extra|
        return diag.say("line {d}: `{s}` has more values than it takes, starting at `{s}`", .{ p.line_no, key, extra });
}

/// What each key means, and how many values it takes.
fn applyKey(p: *Parser, k: Key, key: []const u8, vals: *Tokens) Error!void {
    const b = &p.b;
    const line_no = p.line_no;
    const diag = p.diag;
    switch (k) {
        .version => {
            const v = try int(u32, vals, key, line_no, diag);
            if (v != version) return diag.say("line {d}: board file version {d}, this build reads {d}", .{ line_no, v, version });
            p.seen_version = true;
        },
        .layer_control => b.layer_control = try reg(vals, key, line_no, diag),
        .priority => {
            for (&b.priority) |*x| x.* = try reg(vals, key, line_no, diag);
            p.seen_priority = true;
        },
        .palette_control => b.palette_control = try reg(vals, key, line_no, diag),
        .id => {
            b.id_offset = try reg(vals, key, line_no, diag);
            b.id_value = try int(u16, vals, key, line_no, diag);
        },
        .multiply => {
            b.mult_factor1 = try reg(vals, key, line_no, diag);
            b.mult_factor2 = try reg(vals, key, line_no, diag);
            b.mult_result_lo = try reg(vals, key, line_no, diag);
            b.mult_result_hi = try reg(vals, key, line_no, diag);
        },
        .in2 => b.in2_offset = try reg(vals, key, line_no, diag),
        .in3 => b.in3_offset = try reg(vals, key, line_no, diag),
        .out2 => b.out2_offset = try reg(vals, key, line_no, diag),
        .layer_enable => for (&b.layer_enable) |*m| {
            m.* = try int(u16, vals, key, line_no, diag);
        },
        .raster_line => for (&b.raster_line) |*r| {
            r.* = try reg(vals, key, line_no, diag);
        },
        .bank_sizes => for (&b.bank_sizes) |*s| {
            s.* = try int(u32, vals, key, line_no, diag);
        },
        .gfx_bank => try addRange(b, vals, line_no, diag),
        .kabuki => b.kabuki = .{
            .swap1 = try int(u32, vals, key, line_no, diag),
            .swap2 = try int(u32, vals, key, line_no, diag),
            .addr = try int(u16, vals, key, line_no, diag),
            .xor = try int(u8, vals, key, line_no, diag),
        },
    }
}

/// The keys without which the machine cannot be built at all. Named together
/// rather than one per run, so a hand-written file is finished in one pass.
fn require(b: *const Board, seen_priority: bool, diag: *Diag) Error!void {
    const needed = [_]struct { []const u8, bool }{
        .{ "layer_control", b.layer_control != null },
        // Present, not populated: a board whose PAL decodes none of the four
        // priority masks draws every tile flat, and there are real ones.
        .{ "priority", seen_priority },
        .{ "palette_control", b.palette_control != null },
        // Not one mask each — a board with no starfields really does have two
        // zeroes — but all five zero means nothing would ever be drawn.
        .{ "layer_enable", !std.mem.allEqual(u16, &b.layer_enable, 0) },
        .{ "gfx_bank", b.range_count != 0 },
        .{ "program", b.rom_count != 0 },
    };

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for (needed) |key| {
        if (key[1]) continue;
        w.print("{s}{s}", .{ if (w.buffered().len == 0) "" else ", ", key[0] }) catch break;
    }
    if (w.buffered().len == 0) return needsKabuki(b, diag);
    return diag.say("board file is missing: {s}", .{w.buffered()});
}

/// Only the QSound board's Z80 is behind a Kabuki custom, so only that board's
/// sound ROM decrypts to noise without a key. A CPS-1 board's Z80 is plain, and
/// a set with no sound ROM at all — the in-repo test ROM — needs no key either.
fn needsKabuki(b: *const Board, diag: *Diag) Error!void {
    if (b.kabuki != null or b.sound() != .qsound) return;
    for (b.romList()) |r| {
        if (r.region == .audio)
            return diag.say("board file has a QSound sound ROM ({s}) but no `kabuki` key to decrypt it with", .{r.name});
    }
}

fn addRange(b: *Board, vals: *Tokens, line_no: u32, diag: *Diag) Error!void {
    if (b.range_count == max_gfx_ranges)
        return diag.say("line {d}: more than {d} `gfx_bank` ranges", .{ line_no, max_gfx_ranges });

    const types_text = vals.next() orelse
        return diag.say("line {d}: `gfx_bank` needs <layers> <start> <end> <bank>", .{line_no});
    var types: u8 = 0;
    var names = std.mem.tokenizeScalar(u8, types_text, '|');
    while (names.next()) |name| {
        const layer = std.meta.stringToEnum(Layer, name) orelse
            return diag.say("line {d}: `{s}` is not a layer (" ++ nameList(Layer) ++ ")", .{ line_no, name });
        types |= @as(u8, 1) << @intFromEnum(layer);
    }

    const range = GfxRange{
        .types = types,
        .start = try int(u32, vals, "gfx_bank", line_no, diag),
        .end = try int(u32, vals, "gfx_bank", line_no, diag),
        .bank = try int(u2, vals, "gfx_bank", line_no, diag),
    };
    if (range.end < range.start)
        return diag.say("line {d}: `gfx_bank` range ends (0x{x}) before it starts (0x{x})", .{ line_no, range.end, range.start });

    b.ranges[b.range_count] = range;
    b.range_count += 1;
}

fn addRom(b: *Board, region: Region, vals: *Tokens, line_no: u32, diag: *Diag) Error!void {
    if (b.rom_count == max_roms)
        return diag.say("line {d}: more than {d} ROM files", .{ line_no, max_roms });

    const key = @tagName(region);
    const dest = try int(u32, vals, key, line_no, diag);
    const len = try int(u32, vals, key, line_no, diag);
    const mode_text = vals.next() orelse
        return diag.say("line {d}: `{s}` needs <dest> <length> <mode> <file> [<offset in file>]", .{ line_no, key });
    const mode = std.meta.stringToEnum(Mode, mode_text) orelse
        return diag.say("line {d}: `{s}` is not a load mode (" ++ nameList(Mode) ++ ")", .{ line_no, mode_text });
    const name = vals.next() orelse
        return diag.say("line {d}: `{s}` names no file", .{ line_no, key });

    if (len == 0) return diag.say("line {d}: `{s}` loads {s} with nothing", .{ line_no, key, name });
    if (mode == .word and len % 2 != 0)
        return diag.say("line {d}: {s} is loaded as 16-bit words but its length (0x{x}) is odd", .{ line_no, name, len });
    if (mode == .word64 and len % 2 != 0)
        return diag.say("line {d}: {s} is loaded two bytes at a time but its length (0x{x}) is odd", .{ line_no, name, len });

    var rom = Rom{
        .region = region,
        .dest = dest,
        .len = len,
        .mode = mode,
        .src = 0,
        .name = name,
    };
    // What follows the file name is a file offset, a CRC, both, or neither, and
    // a board file written by hand has neither.
    var saw_src = false;
    while (vals.next()) |extra| {
        if (std.mem.startsWith(u8, extra, crc_prefix)) {
            rom.crc = try num(u32, extra[crc_prefix.len..], key, line_no, diag);
            continue;
        }
        if (saw_src)
            return diag.say("line {d}: `{s}` has more values than it takes, starting at `{s}`", .{ line_no, key, extra });
        rom.src = try num(u32, extra, key, line_no, diag);
        saw_src = true;
    }

    b.roms[b.rom_count] = rom;
    b.rom_count += 1;
}

const crc_prefix = "crc=";

const Tokens = std.mem.TokenIterator(u8, .any);

fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..hash];
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

/// `none` is how a board file says a register its PAL does not decode, which is
/// not the same as leaving the line out.
fn reg(vals: *Tokens, key: []const u8, line_no: u32, diag: *Diag) Error!Reg {
    const text = vals.next() orelse
        return diag.say("line {d}: `{s}` needs a register offset", .{ line_no, key });
    if (std.mem.eql(u8, text, "none")) return null;
    const v = std.fmt.parseInt(u8, text, 0) catch
        return diag.say("line {d}: `{s}` wants a register offset or `none`, got `{s}`", .{ line_no, key, text });
    if (v % 2 != 0)
        return diag.say("line {d}: `{s}` offset 0x{x} is odd, and CPS-B registers are words", .{ line_no, key, v });
    if (v >= cps_b_bytes)
        return diag.say("line {d}: `{s}` offset 0x{x} is past the end of the CPS-B window (0x{x})", .{ line_no, key, v, cps_b_bytes });
    return v;
}

fn int(comptime T: type, vals: *Tokens, key: []const u8, line_no: u32, diag: *Diag) Error!T {
    const text = vals.next() orelse
        return diag.say("line {d}: `{s}` needs another value", .{ line_no, key });
    return num(T, text, key, line_no, diag);
}

fn num(comptime T: type, text: []const u8, key: []const u8, line_no: u32, diag: *Diag) Error!T {
    return std.fmt.parseInt(T, text, 0) catch
        return diag.say("line {d}: `{s}` cannot read `{s}` as a number that fits {s}", .{ line_no, key, text, @typeName(T) });
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// One real board, transcribed from published research: a QSound B-board's
/// register mapping, its mapper's bank table, a Kabuki key and that set's own
/// load lines. Committed here as a *test fixture* for the parser, not as a
/// database: no code reads it and no game name reaches the emulator.
const example =
    \\version = 1
    \\
    \\layer_control   = 0x12
    \\priority        = 0x14 0x16 0x08 0x0a
    \\palette_control = 0x0c
    \\layer_enable    = 0x04 0x02 0x20 0x00 0x00
    \\id              = 0x0e 0x0c00
    \\multiply        = none none none none
    \\in2             = 0x2c
    \\
    \\bank_sizes = 0x8000 0x8000 0 0
    \\gfx_bank = sprites|scroll1|scroll2|scroll3 0x00000 0x07fff 0
    \\gfx_bank = sprites|scroll1|scroll2|scroll3 0x08000 0x0ffff 1
    \\
    \\kabuki = 0x76543210 0x24601357 0x4343 0x43
    \\
    \\program = 0x000000 0x80000 word   cde_23a.8f crc=0x8f4e585e
    \\program = 0x080000 0x80000 word   cde_22a.7f
    \\gfx     = 0x000000 0x80000 word64 cd-1m.3a
    \\gfx     = 0x000002 0x80000 word64 cd-3m.5a
    \\audio   = 0x00000  0x08000 byte   cd_q.5k
    \\audio   = 0x10000  0x18000 byte   cd_q.5k 0x8000
    \\qsound  = 0x000000 0x80000 byte   cd-q1.1k
;

test "a whole board file parses into the battery's contents" {
    var diag = Diag{};
    const b = parse(example, &diag) catch {
        std.debug.print("unexpected: {s}\n", .{diag.message()});
        return error.TestUnexpectedResult;
    };

    try testing.expectEqual(@as(Reg, 0x12), b.layer_control);
    try testing.expectEqual([4]Reg{ 0x14, 0x16, 0x08, 0x0a }, b.priority);
    try testing.expectEqual(@as(Reg, 0x0c), b.palette_control);
    try testing.expectEqual(@as(u16, 0x0c00), b.id_value);
    // `none` is a decoded answer, not a missing one.
    try testing.expectEqual(@as(Reg, null), b.mult_factor1);
    try testing.expectEqual(@as(Reg, 0x2c), b.in2_offset);
    // The masks are in `Enable` order, so the third is scroll3's and not — as
    // `Layer` would have it — scroll2's.
    try testing.expectEqual(@as(u16, 0x20), b.layer_enable[@intFromEnum(Enable.scroll3)]);
    try testing.expectEqual(@as(u16, 0x02), b.layer_enable[@intFromEnum(Enable.scroll2)]);
    // Nothing said `raster_line`, so this board has no raster interrupt.
    try testing.expectEqual([2]Reg{ null, null }, b.raster_line);

    try testing.expectEqual(@as(u8, 2), b.range_count);
    const all_four = (1 << @intFromEnum(Layer.sprites)) | (1 << @intFromEnum(Layer.scroll1)) |
        (1 << @intFromEnum(Layer.scroll2)) | (1 << @intFromEnum(Layer.scroll3));
    try testing.expectEqual(GfxRange{ .types = all_four, .start = 0x8000, .end = 0xffff, .bank = 1 }, b.ranges[1]);

    try testing.expectEqual(@as(u32, 0x24601357), b.kabuki.?.swap2);
    try testing.expectEqual(@as(u8, 0x43), b.kabuki.?.xor);

    try testing.expectEqual(@as(u8, 7), b.rom_count);
    try testing.expectEqualDeep(Rom{
        .region = .program,
        .dest = 0x80000,
        .len = 0x80000,
        .mode = .word,
        .src = 0,
        .name = "cde_22a.7f",
    }, b.roms[1]);
    // The second half of a chip that lands in two pieces keeps its file offset.
    try testing.expectEqual(@as(u32, 0x8000), b.roms[5].src);
    try testing.expectEqual(Mode.word64, b.roms[2].mode);
    // A CRC is the dump this board was written against; a line without one is
    // taken on trust, which is what a hand-written file gets.
    try testing.expectEqual(@as(?u32, 0x8f4e585e), b.roms[0].crc);
    try testing.expectEqual(@as(?u32, null), b.roms[1].crc);
}

test "a file offset and a CRC follow the file name in either order" {
    var diag = Diag{};
    const b = try parse(example ++
        "\naudio = 0x10000 0x18000 byte q.5k crc=0x605fdb0b 0x8000" ++
        "\nqsound = 0x0 0x80000 byte s.1k 0x40 crc=0x11223344\n", &diag);
    const with_crc_first = b.roms[b.rom_count - 2];
    try testing.expectEqual(@as(u32, 0x8000), with_crc_first.src);
    try testing.expectEqual(@as(?u32, 0x605fdb0b), with_crc_first.crc);
    const with_offset_first = b.roms[b.rom_count - 1];
    try testing.expectEqual(@as(u32, 0x40), with_offset_first.src);
    try testing.expectEqual(@as(?u32, 0x11223344), with_offset_first.crc);
}

test "an interleaved chip reaches its own last byte and no further" {
    // One byte of every two, so a 4-byte chip at 0 covers 0, 2, 4 and 6.
    try testing.expectEqual(@as(u64, 7), Mode.byte16.extent(0, 4));
    try testing.expectEqual(@as(u64, 8), Mode.byte16.extent(1, 4));
}

fn expectRefused(text: []const u8, wanted: []const u8) !void {
    var diag = Diag{};
    try testing.expectError(error.BadBoardFile, parse(text, &diag));
    if (std.mem.indexOf(u8, diag.message(), wanted) == null) {
        std.debug.print("message `{s}` does not mention `{s}`\n", .{ diag.message(), wanted });
        return error.TestUnexpectedResult;
    }
}

test "a board file that is wrong says what is wrong with it" {
    try expectRefused("scale = 3\n", "version");
    try expectRefused("version = 99\n", "version 99");
    try expectRefused(example ++ "\nnonsense = 3\n", "unknown key `nonsense`");
    try expectRefused(example ++ "\nlayer_control = 0x13\n", "is odd");
    // The window the 68000 decodes is 0x40 bytes. An offset above it parses as
    // a number but names a register no bus cycle can ever reach, which would
    // show up as a video bug rather than as the bad file it is.
    try expectRefused(example ++ "\nlayer_control = 0x40\n", "past the end of the CPS-B window");
    try expectRefused(example ++ "\nlayer_control = fish\n", "`fish`");
    try expectRefused(example ++ "\npriority = 0x14 0x16\n", "needs a register offset");
    try expectRefused(example ++ "\nlayer_control = 0x12 0x14\n", "more values than it takes");
    try expectRefused(example ++ "\ngfx_bank = scroll9 0 1 0\n", "not a layer");
    try expectRefused(example ++ "\ngfx_bank = sprites 0x100 0x080 0\n", "ends (0x80) before it starts");
    try expectRefused(example ++ "\nprogram = 0x0 0x1000 nibble x.bin\n", "not a load mode");
    try expectRefused(example ++ "\nprogram = 0x0 0x1001 word x.bin\n", "length (0x1001) is odd");
    try expectRefused(example ++ "\nprogram = 0x0 0x0 byte x.bin\n", "with nothing");
    try expectRefused(example ++ "\nprogram = 0x0 0x100 word x.bin crc=zz\n", "`zz`");
    try expectRefused(example ++ "\nprogram = 0x0 0x100 word x.bin 0x10 0x20\n", "more values than it takes");
}

// An error that offers the reader a list has to offer the whole list: a mode
// or a layer added later and left out of the message reads as one the board
// file may not ask for.
test "an error that lists what is allowed lists all of it" {
    try expectNames(Mode, example ++ "\nprogram = 0x0 0x1000 nibble x.bin\n");
    try expectNames(Layer, example ++ "\ngfx_bank = scroll9 0 1 0\n");
}

fn expectNames(comptime E: type, text: []const u8) !void {
    var diag = Diag{};
    try testing.expectError(error.BadBoardFile, parse(text, &diag));
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (std.mem.indexOf(u8, diag.message(), field.name) == null) {
            std.debug.print("`{s}` is allowed but `{s}` does not say so\n", .{ field.name, diag.message() });
            return error.NameNotListed;
        }
    }
}
test "a board file missing what the machine needs names all of it at once" {
    var diag = Diag{};
    try testing.expectError(error.BadBoardFile, parse("version = 1\n", &diag));
    const msg = diag.message();
    for ([_][]const u8{ "layer_control", "priority", "palette_control", "gfx_bank", "program" }) |key| {
        if (std.mem.indexOf(u8, msg, key) == null) {
            std.debug.print("`{s}` missing from `{s}`\n", .{ key, msg });
            return error.TestUnexpectedResult;
        }
    }
}

test "a sound ROM with no key to decrypt it is refused by name" {
    const common = "version = 1\nlayer_control = 0\npriority = 0 2 4 6\npalette_control = 8\nlayer_enable = 2 4 8 0 0\n" ++
        "gfx_bank = sprites 0 0xffff 0\nprogram = 0 0x100 word p.bin\naudio = 0 0x8000 byte q.5k\n";
    // The samples say which board this is: with a QSound one the Z80 is behind
    // a Kabuki and the key is missing, with an OKI one there is nothing to
    // decrypt and the same sound ROM is fine as it stands.
    try expectRefused(common ++ "qsound = 0 0x8000 byte q.1m\n", "q.5k");
    var diag = Diag{};
    const b = try parse(common ++ "oki = 0 0x8000 byte o.1m\n", &diag);
    try testing.expectEqual(Sound.cps1, b.sound());
}

test "comments, blank lines and stray whitespace are not content" {
    var diag = Diag{};
    const b = try parse(
        \\  # the battery
        \\version = 1   # trailing comment
        \\
        \\  layer_control = 0x12
        \\priority = 0x14 0x16 0x08 0x0a
        \\palette_control = 0x0c
        \\layer_enable = 0x02 0x04 0x08 0 0
        \\gfx_bank = sprites 0 0xffff 0
        \\program = 0 0x100 word p.bin
    , &diag);
    try testing.expectEqual(@as(Reg, 0x12), b.layer_control);
    try testing.expectEqual(@as(u8, 1), b.rom_count);
}
