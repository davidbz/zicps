//! The ROM set: the chips on the two boards, as files.
//!
//! A set is a directory of chip images or a zip of the same. The board file
//! says which file goes where, because one chip is rarely a contiguous slice of
//! anything: a 16-bit program ROM holds its words the other way round, and a
//! graphics chip holds one byte of every eight, interleaved with its three or
//! seven neighbours so the video chip can fetch a whole row in one go.
//!
//! Graphics are de-interleaved once here, into one byte per pixel. It costs a
//! few megabytes and buys a renderer that never touches a bit shift.

const std = @import("std");
const board = @import("board");

const Diag = board.Diag;

pub const Error = error{ BadRomSet, OutOfMemory };

/// Ceilings on what a board file may ask us to allocate. A board file is text
/// from outside, so every size that reaches an allocator is checked against
/// what the hardware could physically hold.
pub const max_program = 4 << 20;
pub const max_gfx = 16 << 20;
pub const max_audio = 512 << 10;
pub const max_qsound = 8 << 20;
/// No chip on either board is bigger than this, so no file needs to be.
pub const max_file = 8 << 20;

/// Unpopulated ROM reads as an erased EPROM does.
pub const blank = 0xff;

pub const Set = struct {
    /// 68000 program, big-endian, ready to be read as words.
    program: []u8,
    /// One byte per pixel, four bits of colour in each.
    gfx: []u8,
    /// The sound board's Z80 ROM, still Kabuki-encrypted.
    audio: []u8,
    /// QSound sample ROM.
    qsound: []u8,

    pub fn deinit(s: *Set, gpa: std.mem.Allocator) void {
        gpa.free(s.program);
        gpa.free(s.gfx);
        gpa.free(s.audio);
        gpa.free(s.qsound);
        s.* = undefined;
    }
};

/// Loads the set at `path`, which is either a directory or a zip file, laid out
/// as `b` says. Every refusal names the file and what was wrong with it.
pub fn load(gpa: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, path: []const u8, b: *const board.Board, diag: *Diag) Error!Set {
    var src = try open(gpa, io, parent, path, diag);
    defer src.close();

    var sizes = std.EnumArray(board.Region, u64).initFill(0);
    for (b.romList()) |rom| {
        const at = sizes.getPtr(rom.region);
        at.* = @max(at.*, rom.mode.extent(rom.dest, rom.len));
    }
    try cap(&sizes.values, diag);

    // Graphics arrive interleaved and are expanded afterwards; the other three
    // regions are their final selves.
    const program = try alloc(gpa, sizes.get(.program));
    errdefer gpa.free(program);
    const audio = try alloc(gpa, sizes.get(.audio));
    errdefer gpa.free(audio);
    const qsound = try alloc(gpa, sizes.get(.qsound));
    errdefer gpa.free(qsound);

    const packed_gfx = try alloc(gpa, sizes.get(.gfx));
    defer gpa.free(packed_gfx);

    try fill(gpa, &src, b, std.EnumArray(board.Region, []u8).init(.{
        .program = program,
        .gfx = packed_gfx,
        .audio = audio,
        .qsound = qsound,
    }), diag);

    const gfx = try alloc(gpa, packed_gfx.len * pixels_per_byte);
    errdefer gpa.free(gfx);
    decode(packed_gfx, gfx);

    return .{ .program = program, .gfx = gfx, .audio = audio, .qsound = qsound };
}

/// Reads every chip the board file names into the region it belongs to. A file
/// too short for what the board file reads out of it, or one whose CRC says it
/// is not the chip the file was written for, stops the load here.
fn fill(gpa: std.mem.Allocator, src: *Source, b: *const board.Board, regions: std.EnumArray(board.Region, []u8), diag: *Diag) Error!void {
    for (b.romList()) |rom| {
        const bytes = try src.read(rom);
        defer gpa.free(bytes);

        const want = @as(u64, rom.src) + rom.len;
        if (bytes.len < want)
            return fail(diag, "{s} is 0x{x} bytes, but the board file reads 0x{x} from it", .{ rom.name, bytes.len, want });
        try verify(rom, bytes, diag);

        place(regions.get(rom.region), rom, bytes[rom.src..][0..rom.len]);
    }
}

/// A board file that names the dump it was written against is checked against
/// the dump that turned up. The CRC covers the whole file, as MAME's does, so a
/// chip loaded in two pieces is checked twice rather than by halves.
fn verify(rom: board.Rom, bytes: []const u8, diag: *Diag) Error!void {
    const want = rom.crc orelse return;
    const got = std.hash.Crc32.hash(bytes);
    if (got == want) return;
    return fail(diag, "{s} has crc {x:0>8}, and this board file was written for {x:0>8}: this is a different set", .{ rom.name, got, want });
}

fn cap(sizes: *[board.region_count]u64, diag: *Diag) Error!void {
    for (sizes, 0..) |size, i| {
        const region: board.Region = @enumFromInt(i);
        const max = limit(region);
        if (size <= max) continue;
        return fail(diag, "the board file fills 0x{x} bytes of {s} ROM; no board holds more than 0x{x}", .{ size, @tagName(region), max });
    }
}

fn limit(region: board.Region) u64 {
    return switch (region) {
        .program => max_program,
        .gfx => max_gfx,
        .audio => max_audio,
        .qsound => max_qsound,
    };
}

fn alloc(gpa: std.mem.Allocator, len: u64) Error![]u8 {
    const bytes = try gpa.alloc(u8, @intCast(len));
    @memset(bytes, blank);
    return bytes;
}

/// Copies one file into its region the way its chip sits on the board.
fn place(region: []u8, rom: board.Rom, bytes: []const u8) void {
    switch (rom.mode) {
        .byte => @memcpy(region[rom.dest..][0..bytes.len], bytes),
        // The file holds each word low byte first and the 68000 reads them the
        // other way round.
        .word => for (bytes, 0..) |byte, i| {
            region[rom.dest + (i ^ 1)] = byte;
        },
        // Half of a 16-bit pair, already in the order the 68000 reads: the chip
        // on the even addresses holds the high byte of every word.
        .byte16 => for (bytes, 0..) |byte, i| {
            region[rom.dest + i * 2] = byte;
        },
        .word64 => for (bytes, 0..) |byte, i| {
            region[rom.dest + (i / 2) * 8 + (i & 1)] = byte;
        },
        .byte64 => for (bytes, 0..) |byte, i| {
            region[rom.dest + i * 8] = byte;
        },
    }
}

// ------------------------------------------------------- graphics decoding

/// Every eight interleaved bytes are one row of sixteen pixels: four bit planes
/// for the left eight in the first four bytes, four for the right eight in the
/// next four. Every tile size the board draws — 8x8, 16x16, 32x32 — is built
/// out of that same row, so this is the only shape the decoder needs to know.
pub const bytes_per_row = 8;
pub const pixels_per_row = 16;
pub const pixels_per_byte = pixels_per_row / bytes_per_row;
/// Each half of the row is four bit planes over eight pixels.
const plane_count = bytes_per_row / 2;
const half_row_pixels = pixels_per_row / 2;

fn nibble(planes: *const [plane_count]u8, bit: u3) u8 {
    var pen: u8 = 0;
    for (planes, 0..) |plane, p| pen |= @as(u8, (plane >> bit) & 1) << @intCast(p);
    return pen;
}

/// Expands one row. Pixel 0 is the *high* bit of each plane byte.
pub fn decodeRow(src: *const [bytes_per_row]u8, dst: *[pixels_per_row]u8) void {
    for (0..half_row_pixels) |x| {
        const bit: u3 = @intCast(half_row_pixels - 1 - x);
        dst[x] = nibble(src[0..plane_count], bit);
        dst[half_row_pixels + x] = nibble(src[plane_count..][0..plane_count], bit);
    }
}

pub fn decode(src: []const u8, dst: []u8) void {
    std.debug.assert(dst.len == src.len * pixels_per_byte);
    var i: usize = 0;
    while (i + bytes_per_row <= src.len) : (i += bytes_per_row) {
        decodeRow(src[i..][0..bytes_per_row], dst[i * pixels_per_byte ..][0..pixels_per_row]);
    }
}

// ------------------------------------------------------------ the two forms

/// A set on disk: a directory of files, or a zip holding the same names.
const Source = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    diag: *Diag,
    dir: std.Io.Dir,
    zip: ?std.Io.File,

    fn close(s: *Source) void {
        if (s.zip) |f| f.close(s.io) else s.dir.close(s.io);
    }

    fn read(s: *Source, rom: board.Rom) Error![]u8 {
        if (s.zip != null) return s.readZip(rom);
        return s.dir.readFileAlloc(s.io, rom.name, s.gpa, .limited(max_file)) catch |err|
            fail(s.diag, "cannot read {s}: {t}", .{ rom.name, err });
    }

    /// ponytail: rescans the central directory once per file. A set is a dozen
    /// files loaded once, so the quadratic scan is cheaper than a name index.
    fn readZip(s: *Source, rom: board.Rom) Error![]u8 {
        var window: [4096]u8 = undefined;
        var fr = s.zip.?.reader(s.io, &window);
        var it = std.zip.Iterator.init(&fr) catch |err|
            return fail(s.diag, "cannot read the set as a zip: {t}", .{err});

        var found: [max_name]u8 = undefined;
        var same_chip: ?std.zip.Iterator.Entry = null;
        while (it.next() catch |err| return fail(s.diag, "the zip's directory is damaged: {t}", .{err})) |entry| {
            if (entry.filename_len > found.len) continue;
            const in_zip = found[0..entry.filename_len];
            try seek(&fr, entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader), s.diag);
            fr.interface.readSliceAll(in_zip) catch |err|
                return fail(s.diag, "the zip's directory is damaged: {t}", .{err});
            // A set zipped before MAME last renamed its dumps holds the right
            // chips under the wrong names. A zip records what each entry
            // hashes to, and a board file that names a CRC knows which chip it
            // wants, so the second is found by what it is rather than what it
            // is called. MAME does the same with the same numbers.
            if (rom.crc) |want| {
                if (same_chip == null and entry.crc32 == want) same_chip = entry;
            }
            if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(in_zip), rom.name)) continue;
            return s.extract(&fr, entry, rom.name);
        }
        if (same_chip) |entry| return s.extract(&fr, entry, rom.name);
        if (rom.crc) |want|
            return fail(s.diag, "the set has no {s}, and nothing in it has crc {x:0>8} either", .{ rom.name, want });
        return fail(s.diag, "{s} is not in the set", .{rom.name});
    }

    fn extract(s: *Source, fr: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, name: []const u8) Error![]u8 {
        switch (entry.compression_method) {
            .store, .deflate => {},
            else => return fail(s.diag, "{s} is compressed in a way this build cannot read", .{name}),
        }
        if (entry.uncompressed_size > max_file)
            return fail(s.diag, "{s} unpacks to 0x{x} bytes; no chip on the board is that big", .{ name, entry.uncompressed_size });

        try seek(fr, entry.file_offset, s.diag);
        const local = fr.interface.takeStruct(std.zip.LocalFileHeader, .little) catch |err|
            return fail(s.diag, "{s} has no header in the zip: {t}", .{ name, err });
        if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig))
            return fail(s.diag, "{s} has no header in the zip", .{name});
        try seek(fr, entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len, s.diag);

        const history = try s.gpa.alloc(u8, std.compress.flate.max_window_len);
        defer s.gpa.free(history);
        const out = try s.gpa.alloc(u8, @intCast(entry.uncompressed_size));
        errdefer s.gpa.free(out);

        const unpacked = switch (entry.compression_method) {
            .store => fr.interface.readSliceAll(out),
            .deflate => deflate: {
                var stream = std.compress.flate.Decompress.init(&fr.interface, .raw, history);
                break :deflate stream.reader.readSliceAll(out);
            },
            else => unreachable,
        };
        unpacked catch |err| return fail(s.diag, "{s} does not unpack: {t}", .{ name, err });
        if (std.hash.Crc32.hash(out) != entry.crc32)
            return fail(s.diag, "{s} unpacks to something the zip says is not what went in", .{name});
        return out;
    }
};

/// Zip names are stored with their directory, and a set is often zipped with
/// its own folder around it, so entries are matched on the last component.
const max_name = 256;

fn seek(fr: *std.Io.File.Reader, pos: u64, diag: *Diag) Error!void {
    fr.seekTo(pos) catch |err| return fail(diag, "the zip ends sooner than it says: {t}", .{err});
}

fn open(gpa: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, path: []const u8, diag: *Diag) Error!Source {
    var src = Source{ .gpa = gpa, .io = io, .diag = diag, .dir = undefined, .zip = null };

    const stat = parent.statFile(io, path, .{}) catch |err|
        return fail(diag, "cannot open the ROM set {s}: {t}", .{ path, err });
    if (stat.kind == .directory) {
        src.dir = parent.openDir(io, path, .{}) catch |err|
            return fail(diag, "cannot open the ROM set {s}: {t}", .{ path, err });
        return src;
    }

    src.zip = parent.openFile(io, path, .{}) catch |err|
        return fail(diag, "cannot open the ROM set {s}: {t}", .{ path, err });
    return src;
}

fn fail(diag: *Diag, comptime fmt: []const u8, args: anytype) Error {
    diag.set(fmt, args);
    return error.BadRomSet;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a row of graphics comes out of four planes, high bit last" {
    // Plane 0 sets pixel 0, plane 1 sets pixel 1, and so on down the row, so a
    // correct decode reads back as 1, 2, 4, 8 and then the right-hand eight.
    const src = [bytes_per_row]u8{ 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 };
    var dst: [pixels_per_row]u8 = undefined;
    decodeRow(&src, &dst);
    try testing.expectEqualSlices(u8, &.{
        1, 2, 4, 8, 0, 0, 0, 0,
        0, 0, 0, 0, 1, 2, 4, 8,
    }, &dst);

    // All four planes set is colour 15 everywhere; none set is colour 0.
    decodeRow(&@as([bytes_per_row]u8, @splat(0xff)), &dst);
    try testing.expectEqualSlices(u8, &@as([pixels_per_row]u8, @splat(15)), &dst);
    decodeRow(&@as([bytes_per_row]u8, @splat(0)), &dst);
    try testing.expectEqualSlices(u8, &@as([pixels_per_row]u8, @splat(0)), &dst);
}

test "every load mode puts a file where its chip sits" {
    const file = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var region: [32]u8 = @splat(0);

    place(&region, .{ .region = .program, .dest = 0, .len = 4, .mode = .word, .src = 0, .name = "" }, &file);
    try testing.expectEqualSlices(u8, &.{ 0x22, 0x11, 0x44, 0x33 }, region[0..4]);

    // The odd half of a 16-bit pair: every other byte, and no swap, because the
    // chip is already on the addresses it belongs to.
    @memset(&region, 0);
    place(&region, .{ .region = .program, .dest = 1, .len = 4, .mode = .byte16, .src = 0, .name = "" }, &file);
    try testing.expectEqualSlices(u8, &.{ 0, 0x11, 0, 0x22, 0, 0x33, 0, 0x44 }, region[0..8]);

    @memset(&region, 0);
    place(&region, .{ .region = .gfx, .dest = 2, .len = 4, .mode = .word64, .src = 0, .name = "" }, &file);
    try testing.expectEqualSlices(u8, &.{
        0, 0, 0x11, 0x22, 0, 0, 0, 0,
        0, 0, 0x33, 0x44, 0, 0, 0, 0,
    }, region[0..16]);

    @memset(&region, 0);
    place(&region, .{ .region = .gfx, .dest = 7, .len = 4, .mode = .byte64, .src = 0, .name = "" }, &file);
    try testing.expectEqual(@as(u8, 0x11), region[7]);
    try testing.expectEqual(@as(u8, 0x44), region[7 + 24]);
}

/// A two-chip set small enough to build in a test: two 16-bit program halves
/// and four graphics chips, written out and loaded back.
const tiny_board =
    \\version = 1
    \\layer_control = 0x12
    \\priority = 0x14 0x16 0x08 0x0a
    \\palette_control = 0x0c
    \\layer_enable = 0x02 0x04 0x08 0 0
    \\gfx_bank = sprites|scroll1 0 0xffff 0
    \\program = 0x000000 0x10 word   even.bin
    \\program = 0x000010 0x10 word   odd.bin
    \\gfx     = 0x000000 0x08 word64 g1.bin
    \\gfx     = 0x000002 0x08 word64 g2.bin
    \\gfx     = 0x000004 0x08 word64 g3.bin
    \\gfx     = 0x000006 0x08 word64 g4.bin
;

/// The tiny set's files, in the order `tinyChip` numbers them: two program
/// halves, then the four graphics chips.
const tiny_names = [_][]const u8{ "even.bin", "odd.bin", "g1.bin", "g2.bin", "g3.bin", "g4.bin" };
const tiny_program_chips = 2;

/// One chip's bytes, written into `buf` so that nothing here allocates. Every
/// byte says which chip it came from and how far into it, which is what makes a
/// misplaced load visible in the assertions.
fn tinyChip(chip: usize, buf: *[0x10]u8) []const u8 {
    if (chip < tiny_program_chips) {
        const base: u8 = if (chip == 0) 0xa0 else 0xb0;
        for (buf, 0..) |*byte, i| byte.* = base + @as(u8, @intCast(i));
        return buf;
    }
    const gfx_chip = chip - tiny_program_chips;
    for (buf[0..8], 0..) |*byte, i| byte.* = @intCast(gfx_chip * 0x10 + i);
    return buf[0..8];
}

fn writeTinySet(dir: std.Io.Dir) !void {
    var buf: [0x10]u8 = undefined;
    for (tiny_names, 0..) |name, chip| {
        try dir.writeFile(testing.io, .{ .sub_path = name, .data = tinyChip(chip, &buf) });
    }
}

test "a directory of chip images loads into four regions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTinySet(tmp.dir);

    var diag = board.Diag{};
    const b = try board.parse(tiny_board, &diag);
    var set = load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag) catch {
        std.debug.print("unexpected: {s}\n", .{diag.message()});
        return error.TestUnexpectedResult;
    };
    defer set.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0x20), set.program.len);
    // Words arrive swapped, so the first byte of the file is the second byte
    // the 68000 sees.
    try testing.expectEqual(@as(u8, 0xa1), set.program[0]);
    try testing.expectEqual(@as(u8, 0xa0), set.program[1]);
    try testing.expectEqual(@as(u8, 0xb1), set.program[0x10]);

    // Four chips, two bytes each per group of eight: 0x20 packed bytes, twice
    // as many pixels.
    try testing.expectEqual(@as(usize, 0x20 * pixels_per_byte), set.gfx.len);
    // The first eight region bytes are the four chips' first words interleaved,
    // 00 01 10 11 20 21 30 31, which decode to this row of sixteen pixels.
    try testing.expectEqualSlices(u8, &.{
        0, 0, 0,  12, 0, 0, 0, 10,
        0, 0, 15, 12, 0, 0, 0, 10,
    }, set.gfx[0..pixels_per_row]);

    // Unpopulated regions still exist, and read as erased ROM.
    try testing.expectEqual(@as(usize, 0), set.audio.len);
    try testing.expectEqual(@as(usize, 0), set.qsound.len);
}

test "a set that does not add up is refused by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTinySet(tmp.dir);
    // Half a chip: exactly the failure a bad download looks like.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "odd.bin", .data = &[_]u8{0} ** 8 });

    var diag = board.Diag{};
    const b = try board.parse(tiny_board, &diag);
    try testing.expectError(error.BadRomSet, load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "odd.bin") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "0x8 bytes") != null);

    try writeTinySet(tmp.dir);
    try tmp.dir.deleteFile(testing.io, "g3.bin");
    try testing.expectError(error.BadRomSet, load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "g3.bin") != null);
}

test "a set under the right name that is not the right dump is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTinySet(tmp.dir);

    var chip: [0x10]u8 = undefined;
    const dump = std.hash.Crc32.hash(tinyChip(0, &chip));
    var text: [tiny_board.len + 80]u8 = undefined;
    var diag = board.Diag{};

    // The same file loaded a second time, under the CRC of a dump that is not
    // the one on disk: this is what a shipped board file meeting the wrong set
    // looks like.
    const wrong = try std.fmt.bufPrint(&text, "{s}\nprogram = 0x20 0x10 word even.bin crc=0x{x:0>8}\n", .{ tiny_board, dump +% 1 });
    const off = try board.parse(wrong, &diag);
    try testing.expectError(error.BadRomSet, load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &off, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "even.bin") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "different set") != null);

    const right = try std.fmt.bufPrint(&text, "{s}\nprogram = 0x20 0x10 word even.bin crc=0x{x:0>8}\n", .{ tiny_board, dump });
    const b = try board.parse(right, &diag);
    var set = load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag) catch {
        std.debug.print("unexpected: {s}\n", .{diag.message()});
        return error.TestUnexpectedResult;
    };
    set.deinit(testing.allocator);
}

test "a board file asking for more than a board can hold is refused" {
    var sizes = [4]u64{ max_program + 1, 0, 0, 0 };
    var diag = board.Diag{};
    try testing.expectError(error.BadRomSet, cap(&sizes, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "program") != null);
}

/// Builds a stored (uncompressed) zip of the tiny set, so the zip path gets
/// exercised without a fixture file in the tree. Writes the three record types
/// as they sit in memory, which is correct on a little-endian host and is where
/// tests run.
fn tinyZip(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var offsets: [tiny_names.len]u32 = undefined;
    var buf: [0x10]u8 = undefined;

    for (tiny_names, &offsets, 0..) |name, *offset, chip| {
        const data = tinyChip(chip, &buf);
        offset.* = @intCast(out.items.len);
        const local = std.zip.LocalFileHeader{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 10,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = std.hash.Crc32.hash(data),
            .compressed_size = @intCast(data.len),
            .uncompressed_size = @intCast(data.len),
            .filename_len = @intCast(name.len),
            .extra_len = 0,
        };
        try out.appendSlice(gpa, std.mem.asBytes(&local));
        try out.appendSlice(gpa, name);
        try out.appendSlice(gpa, data);
    }

    const cd_start: u32 = @intCast(out.items.len);
    for (tiny_names, offsets, 0..) |name, offset, chip| {
        const data = tinyChip(chip, &buf);
        const len: u32 = @intCast(data.len);
        const header = std.zip.CentralDirectoryFileHeader{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 10,
            .version_needed_to_extract = 10,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = std.hash.Crc32.hash(data),
            .compressed_size = len,
            .uncompressed_size = len,
            .filename_len = @intCast(name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = offset,
        };
        try out.appendSlice(gpa, std.mem.asBytes(&header));
        try out.appendSlice(gpa, name);
    }

    const end = std.zip.EndRecord{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = tiny_names.len,
        .record_count_total = tiny_names.len,
        .central_directory_size = @intCast(out.items.len - cd_start),
        .central_directory_offset = cd_start,
        .comment_len = 0,
    };
    try out.appendSlice(gpa, std.mem.asBytes(&end));
    return out.toOwnedSlice(gpa);
}

test "a zipped set loads the same as a loose one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTinySet(tmp.dir);

    const zipped = try tinyZip(testing.allocator);
    defer testing.allocator.free(zipped);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "set.zip", .data = zipped });

    var diag = board.Diag{};
    const b = try board.parse(tiny_board, &diag);

    var loose = try load(testing.allocator, testing.io, tmp.parent_dir, &tmp.sub_path, &b, &diag);
    defer loose.deinit(testing.allocator);

    var path_buf: [64]u8 = undefined;
    const zip_path = try std.fmt.bufPrint(&path_buf, "{s}/set.zip", .{tmp.sub_path});
    var zipped_set = load(testing.allocator, testing.io, tmp.parent_dir, zip_path, &b, &diag) catch {
        std.debug.print("unexpected: {s}\n", .{diag.message()});
        return error.TestUnexpectedResult;
    };
    defer zipped_set.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, loose.program, zipped_set.program);
    try testing.expectEqualSlices(u8, loose.gfx, zipped_set.gfx);
}
