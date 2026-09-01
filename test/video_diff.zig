//! The video state differential: a real game's graphics RAM and CPS-A/B
//! register file, taken out of MAME at a chosen frame and rendered by this
//! renderer.
//!
//! `tools/mame_video_dump.lua` writes the dump; this reads it back, pokes it
//! into a `Video`, renders a whole frame and writes the picture out as a PPM
//! beside MAME's own snapshot of the same frame. What that answers is the one
//! question the acceptance ROM cannot: when a set draws badly, is the renderer
//! wrong or is the bus? With MAME's state in it, only the renderer is left.
//!
//! A dump is derived from a ROM nobody may redistribute, so it lives in
//! gitignored `testdata/` and gates nothing. Run by hand:
//!
//!     zig build video-diff -- roms/dino.zip testdata/video/dino-0600.vdump
//!
//! The set is still needed: the graphics ROMs are what a tilemap is made of,
//! and they are not in the dump.

const std = @import("std");
const board = @import("board");
const boards = @import("boards");
const cps1 = @import("cps1");
const video = @import("video");
const cps1_video = @import("cps1_video");

const usage = "usage: video_diff <set> <dump> [out.ppm]";

/// What a dump is. The magic is checked rather than trusted, because the file
/// is 192 KiB of graphics RAM and everything past a wrong header would render
/// as convincing-looking rubbish.
const magic = "zicps-vd";
const dump_version = 1;
const header_bytes = magic.len + 4 + 4;
const dump_bytes = header_bytes + video.a_regs_bytes + board.cps_b_bytes + video.gfxram_bytes;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.skip();
    const set = args.next() orelse fatal("{s}", .{usage});
    const dump_path = args.next() orelse fatal("{s}", .{usage});
    const out = args.next() orelse try std.fmt.allocPrint(arena, "{s}.ppm", .{dump_path});

    const cwd = std.Io.Dir.cwd();
    // One past the size a dump is, because `.limited` refuses a stream that
    // reaches its limit and every good dump is exactly `dump_bytes` long. A
    // longer file still comes back short of what `read` wants and is refused
    // there, with a message that says what it is rather than how it was read.
    const bytes = cwd.readFileAlloc(io, dump_path, arena, .limited(dump_bytes + 1)) catch |err|
        fatal("cannot read {s} ({t})\n{s}", .{ dump_path, err, usage });

    var diag = board.Diag{};
    var machine = boards.loadSet(arena, io, set, null, &diag) catch
        fatal("{s}: {s}", .{ set, diag.message() });
    defer machine.deinit(arena);

    // The whole machine, for one field of it: `Video` is a third of a megabyte
    // and the stack is not where it goes.
    const c = try arena.create(cps1.Machine);
    c.* = .{ .board = machine.b, .rom = machine.rom };

    const frame = read(bytes, &c.v) catch |err|
        fatal("{s} is not a dump this build reads ({t})", .{ dump_path, err });

    render(c, frame);
    describe(arena, c, frame, machine.from());

    var ppm: std.ArrayList(u8) = .empty;
    try writePpm(arena, &ppm, &c.v.fb);
    try cwd.writeFile(io, .{ .sub_path = out, .data = ppm.items });
    std.debug.print("wrote {s} ({d}x{d})\n", .{ out, video.width, video.height });
}

/// Pokes a dump into a `Video`, and answers with the frame MAME was on: the
/// star layers are drawn from it, so a dump that did not carry it would move
/// the stars and nothing else.
fn read(bytes: []const u8, v: *video.Video) !u32 {
    if (bytes.len != dump_bytes) return error.WrongSize;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.NotADump;
    var at: usize = magic.len;
    if (word(bytes, at) != dump_version) return error.WrongVersion;
    at += 4;
    const frame = word(bytes, at);
    at += 4;

    for (&v.a) |*reg| {
        reg.* = std.mem.readInt(u16, bytes[at..][0..2], .little);
        at += 2;
    }
    for (&v.b) |*reg| {
        reg.* = std.mem.readInt(u16, bytes[at..][0..2], .little);
        at += 2;
    }
    @memcpy(&v.gfxram, bytes[at..][0..video.gfxram_bytes]);
    return frame;
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// One frame, the way the scheduler draws one but with no CPU under it: the
/// two things the chip does for itself at the edges of a frame, and then every
/// line.
///
/// Both of those are where this differs from the board. The palette is copied
/// when the base register is written, and the object list is latched at
/// vblank — so what is rendered here is MAME's graphics RAM as it stood at the
/// end of a frame, where the board would have drawn the object list it took a
/// frame earlier. A sprite that moved between the two frames is one frame
/// ahead in this picture, and nothing else is.
fn render(c: *cps1.Machine, frame: u32) void {
    c.t.frame = frame;
    video.copyPalette(&c.v, &c.board);
    cps1_video.latchObjects(&c.v);
    for (0..video.lines_per_frame) |line| {
        cps1_video.renderLine(&c.v, &c.board, c.rom.gfx, @intCast(line), c.t.frame);
    }
}

/// What the registers say, next to the picture that came out of them: a
/// picture that is wrong in a way a person can see is usually wrong in a way
/// one of these lines already said.
fn describe(gpa: std.mem.Allocator, c: *const cps1.Machine, frame: u32, source: []const u8) void {
    const v = &c.v;
    std.debug.print("frame {d}, board file {s}\n", .{ frame, source });
    std.debug.print("  layer control {x:0>4}   palette control {x:0>4}\n", .{
        if (c.board.layer_control) |o| v.b[o / 2] else 0,
        if (c.board.palette_control) |o| v.b[o / 2] else 0,
    });
    const scrolls = [_]struct { []const u8, u8, u8 }{
        .{ "scroll1", video.scroll1_x, video.scroll1_y },
        .{ "scroll2", video.scroll2_x, video.scroll2_y },
        .{ "scroll3", video.scroll3_x, video.scroll3_y },
    };
    for (scrolls) |s| {
        std.debug.print("  {s} base {x:0>4} at {d},{d}\n", .{
            s[0],
            v.a[baseReg(s[0])],
            @as(i16, @bitCast(v.a[s[1] / 2])),
            @as(i16, @bitCast(v.a[s[2] / 2])),
        });
    }
    std.debug.print("  objects at {x:0>4}   video control {x:0>4}   {d} colours drawn\n", .{
        v.a[video.obj_base / 2],
        v.a[video.video_control / 2],
        colors(gpa, v),
    });
}

fn baseReg(layer: []const u8) usize {
    return switch (layer[layer.len - 1]) {
        '1' => video.scroll1_base / 2,
        '2' => video.scroll2_base / 2,
        else => video.scroll3_base / 2,
    };
}

/// How many different colours ended up on screen. One is a blank picture, and
/// a handful is a board that drew its RAM test and stopped — either way it
/// says the picture before anyone opens it.
fn colors(gpa: std.mem.Allocator, v: *const video.Video) usize {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    for (v.fb) |pixel| {
        seen.put(gpa, pixel, {}) catch return 0;
    }
    return seen.count();
}

/// Binary PPM, because it is six lines to write and every image viewer and
/// `compare` on this planet reads it. The framebuffer is RGBA with red in the
/// low byte, which is the order PPM wants anyway.
fn writePpm(gpa: std.mem.Allocator, out: *std.ArrayList(u8), fb: []const u32) !void {
    try out.print(gpa, "P6\n{d} {d}\n255\n", .{ video.width, video.height });
    for (fb) |pixel| {
        try out.appendSlice(gpa, &[_]u8{ @truncate(pixel), @truncate(pixel >> 8), @truncate(pixel >> 16) });
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A dump with something recognisable in every field, built the way the Lua
/// script builds one.
fn fixture(into: []u8) void {
    @memset(into, 0);
    @memcpy(into[0..magic.len], magic);
    std.mem.writeInt(u32, into[magic.len..][0..4], dump_version, .little);
    std.mem.writeInt(u32, into[magic.len + 4 ..][0..4], 600, .little);
    var at: usize = header_bytes;
    std.mem.writeInt(u16, into[at + video.scroll1_x ..][0..2], 0x1234, .little);
    at += video.a_regs_bytes;
    std.mem.writeInt(u16, into[at..][0..2], 0xbeef, .little);
    at += board.cps_b_bytes;
    into[at] = 0xa5;
    into[at + video.gfxram_bytes - 1] = 0x5a;
}

test "a dump reads back into the chip it was taken from" {
    const bytes = try testing.allocator.alloc(u8, dump_bytes);
    defer testing.allocator.free(bytes);
    fixture(bytes);

    const v = try testing.allocator.create(video.Video);
    defer testing.allocator.destroy(v);
    v.* = .{};

    try testing.expectEqual(@as(u32, 600), try read(bytes, v));
    try testing.expectEqual(@as(u16, 0x1234), v.a[video.scroll1_x / 2]);
    try testing.expectEqual(@as(u16, 0xbeef), v.b[0]);
    try testing.expectEqual(@as(u8, 0xa5), v.gfxram[0]);
    try testing.expectEqual(@as(u8, 0x5a), v.gfxram[video.gfxram_bytes - 1]);
}

test "a dump from somewhere else is refused rather than rendered" {
    const bytes = try testing.allocator.alloc(u8, dump_bytes);
    defer testing.allocator.free(bytes);
    const v = try testing.allocator.create(video.Video);
    defer testing.allocator.destroy(v);
    v.* = .{};

    fixture(bytes);
    bytes[1] = 'x';
    try testing.expectError(error.NotADump, read(bytes, v));

    fixture(bytes);
    std.mem.writeInt(u32, bytes[magic.len..][0..4], dump_version + 1, .little);
    try testing.expectError(error.WrongVersion, read(bytes, v));

    fixture(bytes);
    try testing.expectError(error.WrongSize, read(bytes[0 .. dump_bytes - 1], v));
}

test "the picture goes out as a PPM the size of the screen" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const fb = try testing.allocator.alloc(u32, video.width * video.height);
    defer testing.allocator.free(fb);
    @memset(fb, 0xff11_2233); // opaque, blue 0x11, green 0x22, red 0x33

    try writePpm(testing.allocator, &out, fb);
    const head = "P6\n384 224\n255\n";
    try testing.expectEqualStrings(head, out.items[0..head.len]);
    try testing.expectEqual(head.len + fb.len * 3, out.items.len);
    try testing.expectEqualSlices(u8, &.{ 0x33, 0x22, 0x11 }, out.items[head.len..][0..3]);
}
