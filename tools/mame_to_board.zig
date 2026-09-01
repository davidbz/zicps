//! MAME's Capcom tables, turned into the board files under `boards/`.
//!
//! The battery on a B-board holds numbers that are on no chip and in no dump,
//! so everyone who emulates this hardware is reading the same transcription:
//! MAME's `cps1_config_table`, keyed by the romset name the zip is already
//! called. This reads that table, the PAL-derived bank mappers beside it and
//! the ROM map of every `ROM_START` in both drivers, and writes one board file
//! per set. A CPS-1 set has a row of its own in that table; every CPS-2 set is
//! on the row called `cps2`, because every CPS-2 board is the same board.
//!
//! It is run by hand — `zig build boards -- <mame source dir>` — and its
//! output is committed. Nothing here runs during an ordinary build.
//!
//! Everything it writes goes back through `board.parse` before it is written,
//! so a set it cannot express exactly is named in the summary and skipped
//! rather than guessed at.

const std = @import("std");
const board = @import("board");
const romset = @import("romset");

const usage = "usage: mame_to_board <mame source directory> [output directory]";

/// The sets someone here has a dump of and has actually booted. Every other
/// board file says in its header that it has not been: the data is MAME's,
/// transcribed faithfully, but faithful to a table is not the same as right.
const booted = [_][]const u8{ "captcomm", "cawing", "dino", "ffight", "mercs", "punisher", "sf2" };

/// MAME's drivers are large and this reads whole ones. Well past `cps1.cpp`,
/// the biggest of the six at a megabyte.
const max_source_bytes = 64 << 20;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.skip();
    const src = args.next() orelse fatal("{s}", .{usage});
    const out = args.next() orelse "boards";

    const cwd = std.Io.Dir.cwd();
    var src_dir = cwd.openDir(io, src, .{}) catch |err|
        fatal("cannot read {s} ({t})\n{s}", .{ src, err, usage });
    defer src_dir.close(io);
    const sources = try Sources.read(arena, io, src_dir);

    var m = Mame{ .arena = arena };
    try m.readTables(sources.video);
    try m.readGames(sources.kabuki, sources.cps1);
    try m.readCrypts(sources.keys, sources.keyed);

    var out_dir = cwd.openDir(io, out, .{ .iterate = true }) catch |err|
        fatal("cannot write to {s} ({t})", .{ out, err });
    defer out_dir.close(io);

    const run = try generate(&m, io, out_dir, sources);
    try sweep(io, out_dir, run.written.items);
    try index(arena, io, out_dir, run.written.items, try handWritten(arena, io, out_dir));
    run.report(out);
}

/// The MAME files this reads, each with its comments already taken out.
const Sources = struct {
    /// What the battery held: the config table and the PAL-derived mappers.
    video: []const u8,
    /// Which files a CPS-1 set is made of, and which key its sound board wants.
    cps1: []const u8,
    kabuki: []const u8,
    /// Only the files: the row its 324 sets share is in `cps1_v.cpp`.
    cps2: []const u8,
    /// The two from the older MAME, which is the one thing 0.289 cannot say: it
    /// stopped writing the CPS-2 keys down when they moved into the ROM sets,
    /// and a suicided board's set arrives without them.
    keys: []const u8,
    keyed: []const u8,

    fn read(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Sources {
        return .{
            .video = try slurp(arena, io, dir, "cps1_v.cpp"),
            .cps1 = try slurp(arena, io, dir, "cps1.cpp"),
            .kabuki = try slurp(arena, io, dir, "kabuki.cpp"),
            .cps2 = try slurp(arena, io, dir, "cps2.cpp"),
            .keys = try slurp(arena, io, dir, "cps2_keys.h"),
            .keyed = try slurp(arena, io, dir, "cps2_keyed.cpp"),
        };
    }
};

/// What a run turned out to be: the board files it wrote, the sets it turned
/// away and why, and the CPS-2 sets whose key nothing holds.
const Run = struct {
    written: std.ArrayList([]const u8) = .empty,
    skipped: std.ArrayList([]const u8) = .empty,
    keyless: std.ArrayList([]const u8) = .empty,

    fn report(r: Run, out: []const u8) void {
        std.debug.print("wrote {d} board files to {s}/\n", .{ r.written.items.len, out });
        if (r.keyless.items.len != 0) {
            std.debug.print("{d} CPS-2 sets carry no key, so a dump without one stays suicided:\n ", .{r.keyless.items.len});
            for (r.keyless.items) |name| std.debug.print(" {s}", .{name});
            std.debug.print("\n", .{});
        }
        if (r.skipped.items.len == 0) return;
        std.debug.print("skipped {d} sets:\n", .{r.skipped.items.len});
        for (r.skipped.items) |line| std.debug.print("  {s}\n", .{line});
    }
};

/// Two drivers, one library. A CPS-1 set has a row of its own in the config
/// table; every CPS-2 set shares the one row named `cps2`, which is what makes
/// its half of a board file the same eight lines every time.
fn generate(m: *Mame, io: std.Io, out_dir: std.Io.Dir, sources: Sources) !Run {
    var run = Run{};
    for ([_]struct { board.System, []const u8 }{
        .{ .cps1, sources.cps1 },
        .{ .cps2, sources.cps2 },
    }) |driver| {
        var sets = RomStarts.init(driver[1]);
        while (sets.next()) |set| try writeBoard(m, io, out_dir, &run, set, driver[0]);
    }
    return run;
}

/// One set's board file, written or accounted for. A set this build cannot
/// express is named in the summary rather than guessed at.
fn writeBoard(m: *Mame, io: std.Io, out_dir: std.Io.Dir, run: *Run, set: RomStarts.Block, system: board.System) !void {
    const arena = m.arena;
    const text = m.build(set.name, set.body, system) catch |err| switch (err) {
        error.Unsupported => return run.skipped.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ set.name, m.why })),
        else => return err,
    };
    const file = try std.fmt.allocPrint(arena, "{s}.board", .{set.name});
    try out_dir.writeFile(io, .{ .sub_path = file, .data = text });
    try run.written.append(arena, set.name);
    // A set the older MAME never had a row for, or had one under another name.
    // Its file is fine; it just cannot carry a key.
    if (system == .cps2 and m.crypts.get(set.name) == null)
        try run.keyless.append(arena, set.name);
}

/// Takes out board files this run did not write. A set MAME has dropped or
/// renamed leaves one behind otherwise, and an inert file that nothing embeds
/// is worse than no file: it reads like a board that ships and is not one.
fn sweep(io: std.Io, dir: std.Io.Dir, written: []const []const u8) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".board")) continue;
        const name = entry.name[0 .. entry.name.len - ".board".len];
        for (written) |kept| {
            if (std.mem.eql(u8, kept, name)) break;
        } else {
            std.debug.print("removing {s}, which MAME no longer has\n", .{entry.name});
            try dir.deleteFile(io, entry.name);
        }
    }
}

/// The boards in `hand/`, which this tool neither writes nor sweeps. MAME's
/// tables are what it reads, so a board no table covers is typed out by a
/// person; they still belong in the one list, so they are named here. Nothing
/// is under there today: both generations are in the tables.
/// Sorted, because a directory hands them over in whatever order it likes and
/// this file is committed and diffed.
fn handWritten(arena: std.mem.Allocator, io: std.Io, out_dir: std.Io.Dir) ![]const []const u8 {
    var dir = out_dir.openDir(io, "hand", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".board")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ".board".len]));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

/// The list `src/boards.zig` reads: every board file beside it, embedded, so
/// that a build of zicps carries them and a changed board file rebuilds it.
fn index(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    written: []const []const u8,
    hand: []const []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll(
        \\//! Every board file in this directory, embedded. Written by
        \\//! tools/mame_to_board.zig along with the files themselves, and read by
        \\//! src/boards.zig, which is where anything that is not a table lives.
        \\
        \\pub const files = [_]struct { name: []const u8, text: []const u8 }{
        \\
    );
    for (written) |name| {
        try w.print("    .{{ .name = \"{s}\", .text = @embedFile(\"{s}.board\") }},\n", .{ name, name });
    }
    if (hand.len != 0) try w.writeAll("\n    // Under hand/, typed out rather than read off a table.\n");
    for (hand) |name| {
        try w.print("    .{{ .name = \"{s}\", .text = @embedFile(\"hand/{s}.board\") }},\n", .{ name, name });
    }
    try w.writeAll("};\n");
    try dir.writeFile(io, .{ .sub_path = "list.zig", .data = try aw.toOwnedSlice() });
}

fn slurp(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]const u8 {
    const raw = dir.readFileAlloc(io, name, arena, .limited(64 << 20)) catch |err|
        fatal("cannot read {s} ({t})\n{s}", .{ name, err, usage });
    // MAME documents these tables in comments, and one of them ends a line
    // mid-macro. Everything below reads the code, so the prose goes first.
    return stripComments(arena, raw);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

// ------------------------------------------------------------------ C++ text

/// Every `ROM_START(name) ... ROM_END` block of a driver. Both generations'
/// ROM maps are read this way, and so is the older MAME the CPS-2 keys come
/// out of.
const RomStarts = struct {
    it: std.mem.SplitIterator(u8, .sequence),

    const Block = struct {
        name: []const u8,
        /// Everything up to `ROM_END`, which is the set's own ROM map.
        body: []const u8,
    };

    fn init(src: []const u8) RomStarts {
        var it = std.mem.splitSequence(u8, src, "ROM_START(");
        _ = it.next(); // everything before the first set
        return .{ .it = it };
    }

    fn next(r: *RomStarts) ?Block {
        while (r.it.next()) |rest| {
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse continue;
            const end = std.mem.indexOf(u8, rest, "ROM_END") orelse continue;
            return .{ .name = trim(rest[0..close]), .body = rest[0..end] };
        }
        return null;
    }
};

/// C++ with its comments taken out, string literals left alone: a file name in
/// a `ROM_LOAD` line is a string, and one of them could hold a slash.
fn stripComments(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, text.len);
    var i: usize = 0;
    var quoted = false;
    while (i < text.len) {
        const c = text[i];
        if (quoted) {
            if (c == '\\' and i + 1 < text.len) {
                try out.appendSlice(arena, text[i..][0..2]);
                i += 2;
                continue;
            }
            if (c == '"') quoted = false;
        } else if (c == '"') {
            quoted = true;
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            i = @min(i + 2, text.len);
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

/// The text between the parentheses that follow `at`, balanced: the `CRC(...)`
/// inside a ROM line does not end the line early.
fn parens(text: []const u8, at: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, text, at, '(') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return text[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// The text between `{` and its matching `}`, starting at or after `at`.
fn braces(text: []const u8, at: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, text, at, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// A comma-separated list, split where C++ means it to be: not inside a
/// string, a nested call or a braced initialiser.
fn fields(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var quoted = false;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (quoted) {
            if (c == '"') quoted = false;
            continue;
        }
        switch (c) {
            '"' => quoted = true,
            '(', '{', '[' => depth += 1,
            ')', '}', ']' => depth -|= 1,
            ',' => if (depth == 0) {
                try out.append(arena, trim(text[start..i]));
                start = i + 1;
            },
            else => {},
        }
    }
    const tail = trim(text[start..]);
    if (tail.len != 0) try out.append(arena, tail);
    return out.items;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

/// A quoted C string, unquoted. Nothing in these tables escapes anything.
fn unquote(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, "\"");
}

fn number(text: []const u8) !i64 {
    return std.fmt.parseInt(i64, text, 0);
}

/// A quoted bare-hex string, which is how the key tables write a number.
fn hex(text: []const u8) !u32 {
    return std.fmt.parseInt(u32, unquote(text), 16);
}

/// The identifier that begins `text`, which for a ROM line is its macro.
fn word(text: []const u8) []const u8 {
    for (text, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return text[0..i];
    }
    return text;
}

// -------------------------------------------------------------- MAME's tables

/// One `CPS_B_*` or `HACK_B_*` define, expanded: twenty numbers, -1 for a
/// register this board's PAL does not decode.
const Cpsb = struct {
    id_offset: i64,
    id_value: i64,
    multiply: [4]i64,
    /// MAME records three registers nobody has worked out. Its own handler
    /// never reads them, so neither does the board file.
    unknown: [3]i64,
    layer_control: i64,
    priority: [4]i64,
    palette_control: i64,
    layer_enable: [5]i64,

    /// How many numbers a `CPS_B_*` define spells out, which is every
    /// register of the chip whether the board decodes it or not.
    const register_count = 20;

    fn parse(text: []const u8) !Cpsb {
        var n: [register_count]i64 = undefined;
        var count: usize = 0;
        var toks = std.mem.tokenizeAny(u8, text, " \t,{}");
        while (toks.next()) |tok| : (count += 1) {
            if (count == n.len) return error.BadTable;
            n[count] = try number(tok);
        }
        if (count != n.len) return error.BadTable;
        return .{
            .id_offset = n[0],
            .id_value = n[1],
            .multiply = n[2..6].*,
            .unknown = n[6..9].*,
            .layer_control = n[9],
            .priority = n[10..14].*,
            .palette_control = n[14],
            .layer_enable = n[15..20].*,
        };
    }
};

/// A B-board's bank sizes and the tile code ranges its PAL maps into them.
const Mapper = struct {
    sizes: [board.gfx_banks]u32,
    ranges: []const board.GfxRange,
};

/// One row of `cps1_config_table`.
const Config = struct {
    cpsb: Cpsb,
    mapper: Mapper,
    /// C-board I/O mapped into the CPS-B window; 0 on a board without it.
    in2: i64 = 0,
    in3: i64 = 0,
    out2: i64 = 0,
    /// MAME's catch-all for bootlegs that need the hardware bent around them.
    kludge: i64 = 0,
};

const Mame = struct {
    arena: std.mem.Allocator,
    configs: std.StringHashMapUnmanaged(Config) = .empty,
    keys: std.StringHashMapUnmanaged(board.Kabuki) = .empty,
    /// Each CPS-2 set's decryption key, for the sets whose dumps arrive
    /// without the twenty bytes the battery used to hold.
    crypts: std.StringHashMapUnmanaged(board.Crypt) = .empty,
    /// Each set's 68000 crystal, which is not in the config table at all: it is
    /// the machine config the `GAME` row names.
    clocks: std.StringHashMapUnmanaged(u32) = .empty,
    /// Why the set being built cannot be expressed, filled in on the way out.
    why: []const u8 = "",

    fn readTables(m: *Mame, text: []const u8) !void {
        // `__not_applicable__` stands for seven registers that are not there,
        // and the defines below read as twenty numbers once it is spelled out.
        const src = try std.mem.replaceOwned(u8, m.arena, text, "__not_applicable__", "-1,-1,-1,-1,-1,-1,-1");

        var defines: Defines = .{};
        try m.readRanges(src, &defines.ranges);
        try m.readDefines(src, &defines);
        try m.readConfigTable(src, defines);
    }

    /// What the `#define`s above the config table hold: a register file per
    /// B-board, a bank mapper per PAL, and the `gfx_range` tables the mappers
    /// point into by name.
    const Defines = struct {
        cpsbs: std.StringHashMapUnmanaged(Cpsb) = .empty,
        mappers: std.StringHashMapUnmanaged(Mapper) = .empty,
        ranges: std.StringHashMapUnmanaged([]const board.GfxRange) = .empty,
    };

    fn readDefines(m: *Mame, src: []const u8, d: *Defines) !void {
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw| {
            const line = trim(raw);
            if (!std.mem.startsWith(u8, line, "#define ")) continue;
            const rest = std.mem.trimStart(u8, line["#define ".len..], " \t");
            const name = word(rest);
            const body = trim(rest[name.len..]);
            if (std.mem.startsWith(u8, name, "CPS_B_") or std.mem.startsWith(u8, name, "HACK_B_")) {
                try d.cpsbs.put(m.arena, name, try Cpsb.parse(body));
                continue;
            }
            if (!std.mem.startsWith(u8, name, "mapper_")) continue;
            // `{ 0x8000, 0x8000, 0, 0 }, mapper_LWCHR_table`
            const close = std.mem.indexOfScalar(u8, body, '}') orelse return error.BadTable;
            var sizes: [board.gfx_banks]u32 = @splat(0);
            var toks = std.mem.tokenizeAny(u8, body[0..close], " \t,{");
            for (&sizes) |*size| size.* = @intCast(try number(toks.next() orelse return error.BadTable));
            const table = trim(std.mem.trim(u8, body[close + 1 ..], " \t,"));
            try d.mappers.put(m.arena, name, .{
                .sizes = sizes,
                .ranges = d.ranges.get(table) orelse return error.BadTable,
            });
        }
    }

    /// `cps1_config_table`: one row per set, naming the two `#define`s that
    /// were its B-board, and the handful of extra columns a set that needs
    /// them carries.
    fn readConfigTable(m: *Mame, src: []const u8, d: Defines) !void {
        const at = std.mem.indexOf(u8, src, "cps1_config_table[]") orelse return error.BadTable;
        const table = braces(src, at) orelse return error.BadTable;
        var rows = std.mem.splitScalar(u8, table, '{');
        _ = rows.next();
        while (rows.next()) |raw| {
            const row = try fields(m.arena, raw[0 .. std.mem.indexOfScalar(u8, raw, '}') orelse continue]);
            if (row.len < 3) break; // `{nullptr}`, the end of the table
            var config = Config{
                .cpsb = d.cpsbs.get(row[1]) orelse return error.BadTable,
                .mapper = d.mappers.get(row[2]) orelse return error.BadTable,
            };
            // The last four columns are left off a row that has none of them.
            const into = [_]*i64{ &config.in2, &config.in3, &config.out2, &config.kludge };
            for (row[3..], 0..) |value, i| {
                if (i == into.len) return error.BadTable;
                into[i].* = try number(value);
            }
            try m.configs.put(m.arena, unquote(row[0]), config);
        }
    }

    /// The `gfx_range` tables: which tile codes each B-board's PAL maps into
    /// which bank, for which layers.
    fn readRanges(m: *Mame, src: []const u8, into: *std.StringHashMapUnmanaged([]const board.GfxRange)) !void {
        const decl = "struct gfx_range ";
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src, at, decl)) |found| {
            const name = word(src[found + decl.len ..]);
            at = found + decl.len + name.len;
            if (!std.mem.endsWith(u8, name, "_table")) continue;

            var ranges: std.ArrayList(board.GfxRange) = .empty;
            var rows = std.mem.splitScalar(u8, braces(src, at) orelse return error.BadTable, '{');
            _ = rows.next();
            while (rows.next()) |raw| {
                const row = try fields(m.arena, raw[0 .. std.mem.indexOfScalar(u8, raw, '}') orelse continue]);
                if (row.len < 4) break; // `{ 0 }`, the end of the table
                var types: u8 = 0;
                var names = std.mem.tokenizeAny(u8, row[0], " |");
                while (names.next()) |gfxtype| {
                    const layer = std.meta.stringToEnum(board.Layer, lower(m.arena, gfxtype["GFXTYPE_".len..]) catch return error.BadTable) orelse
                        return error.BadTable;
                    types |= @as(u8, 1) << @intFromEnum(layer);
                }
                try ranges.append(m.arena, .{
                    .types = types,
                    .start = @intCast(try number(row[1])),
                    .end = @intCast(try number(row[2])),
                    .bank = @intCast(try number(row[3])),
                });
            }
            try into.put(m.arena, name, ranges.items);
        }
    }

    const Kabukis = std.StringHashMapUnmanaged(board.Kabuki);
    const returns_void = "void ";
    /// A ROM pointer, its length, and the four numbers that are the key.
    const decode_args = 6;
    /// Year, set name, and parent, which every row has before it differs.
    const game_row_fields = 3;

    /// The two per-set things the `GAME` list carries: the Kabuki key, and the
    /// 68000's crystal.
    ///
    /// A key belongs to a decode function, a decode function to an init
    /// function, and an init function to a row. A crystal belongs to a machine
    /// config, and configs derive from one another — only two lines in the whole
    /// driver name a clock — so the chain is walked rather than the names
    /// matched.
    fn readGames(m: *Mame, kabuki_src: []const u8, driver_src: []const u8) !void {
        const by_decode = try readDecodes(m.arena, kabuki_src);
        const by_init = try readInits(m.arena, driver_src, by_decode);
        const by_config = try readConfigs(m.arena, driver_src);
        try m.readRows(driver_src, by_init, by_config);
    }

    /// `void cps1_decode(u8 *rom, int swap1, int swap2, int addr, int xor)` —
    /// one Kabuki key per function, spelled out in its arguments.
    fn readDecodes(arena: std.mem.Allocator, kabuki_src: []const u8) !Kabukis {
        var by_decode: Kabukis = .empty;
        var lines = std.mem.splitScalar(u8, kabuki_src, '\n');
        while (lines.next()) |raw| {
            const line = trim(raw);
            const at = std.mem.indexOf(u8, line, "cps1_decode(") orelse continue;
            if (!std.mem.startsWith(u8, line, returns_void)) continue;
            const args = try fields(arena, parens(line, at) orelse continue);
            if (args.len != decode_args) return error.BadTable;
            try by_decode.put(arena, word(line[returns_void.len..]), .{
                .swap1 = @intCast(try number(args[2])),
                .swap2 = @intCast(try number(args[3])),
                .addr = @intCast(try number(args[4])),
                .xor = @intCast(try number(args[5])),
            });
        }
        return by_decode;
    }

    /// The same keys under the names a `GAME` row can name: each `kabuki_setup`
    /// call is inside an init function, and hands it the decode function.
    fn readInits(arena: std.mem.Allocator, driver_src: []const u8, by_decode: Kabukis) !Kabukis {
        var by_init: Kabukis = .empty;
        const setup = "kabuki_setup(";
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, driver_src, at, setup)) |found| {
            at = found + setup.len;
            const decode = word(driver_src[at..]);
            const key = by_decode.get(decode) orelse continue; // the setup function itself
            const init = "::init_";
            const named = std.mem.lastIndexOf(u8, driver_src[0..found], init) orelse return error.BadTable;
            try by_init.put(arena, word(driver_src[named + 2 ..]), key);
        }
        return by_init;
    }

    /// `GAME( 1993, dino, 0, qsound, dino, cps_state, init_dino, ROT0, ...)`,
    /// and `GAMEL` and `CONS` beside it — the CPS Changer sets are consoles as
    /// far as MAME is concerned, and they have the same sound board. Neither the
    /// machine config nor the init function is in the same column in all three,
    /// so both are found by name rather than counted to.
    fn readRows(
        m: *Mame,
        driver_src: []const u8,
        by_init: Kabukis,
        by_config: std.StringHashMapUnmanaged(u32),
    ) !void {
        for ([_][]const u8{ "\nGAME", "\nCONS" }) |macro| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, driver_src, at, macro)) |found| {
                at = found + 1;
                const row = try fields(m.arena, parens(driver_src, at) orelse continue);
                if (row.len < game_row_fields) continue;
                const name = row[1];
                for (row) |field| {
                    if (by_init.get(field)) |key| try m.keys.put(m.arena, name, key);
                    if (by_config.get(field)) |hz| try m.clocks.put(m.arena, name, hz);
                }
            }
        }
    }

    const CryptMacros = std.StringHashMapUnmanaged(board.Crypt);
    const define = "#define ";
    const crypt_params = "CRYPT_PARAMS";
    /// Two master key words and the address range they cover.
    const crypt_args = 4;
    /// The key a suicided board writes over itself, which is no key at all.
    const erased_key_lower = 0xff0000;

    /// What a CPS-2 battery held, out of the last MAME that still wrote it
    /// down. The header defines one macro per key and the driver names one
    /// macro per `ROM_START`, so a set's key is the macro its block mentions.
    fn readCrypts(m: *Mame, keys_src: []const u8, keyed_src: []const u8) !void {
        const by_macro = try readCryptMacros(m.arena, keys_src);
        var sets = RomStarts.init(keyed_src);
        while (sets.next()) |set| {
            const c = cryptOf(set.body, by_macro) orelse continue;
            try m.crypts.put(m.arena, set.name, c);
        }
    }

    /// `#define avsp_key CRYPT_PARAMS("15208f79","4ade6cb3","00000","0fffff")`,
    /// one line per set that still had its key written down.
    fn readCryptMacros(arena: std.mem.Allocator, keys_src: []const u8) !CryptMacros {
        var by_macro: CryptMacros = .empty;
        var lines = std.mem.splitScalar(u8, keys_src, '\n');
        while (lines.next()) |raw| {
            const line = trim(raw);
            if (!std.mem.startsWith(u8, line, define)) continue;
            const macro = word(line[define.len..]);
            if (std.mem.eql(u8, macro, crypt_params)) continue; // the macro itself
            const at = std.mem.indexOf(u8, line, crypt_params) orelse continue;
            const args = try fields(arena, parens(line, at) orelse continue);
            if (args.len != crypt_args) return error.BadTable;
            // Bare hex, quoted, the way a `ROM_PARAMETER` carries it.
            const c = board.Crypt{
                .master = .{ try hex(args[0]), try hex(args[1]) },
                .lower = try hex(args[2]),
                .upper = try hex(args[3]),
            };
            // A dead board's key is the erasure itself: FF over the top bank,
            // which is what a set with no key already does here.
            if (c.lower == erased_key_lower) continue;
            try by_macro.put(arena, macro, c);
        }
        return by_macro;
    }

    /// The key a set's ROM map names, which is the first identifier in it that
    /// is one of the macros.
    fn cryptOf(block: []const u8, by_macro: CryptMacros) ?board.Crypt {
        var at: usize = 0;
        while (at < block.len) {
            const id = word(block[at..]);
            if (id.len == 0) {
                at += 1;
                continue;
            }
            at += id.len;
            if (by_macro.get(id)) |c| return c;
        }
        return null;
    }

    // ------------------------------------------------------------ a board file

    /// One set's board file, or `error.Unsupported` with `why` set. Whatever
    /// comes back has already been through `board.parse`.
    fn build(m: *Mame, name: []const u8, block: []const u8, system: board.System) ![]const u8 {
        const config = switch (system) {
            .cps1 => m.configs.get(name) orelse
                return m.give("no row in MAME's cps1_config_table", .{}),
            // The one row all 324 of them are on, and the reason a CPS-2 board
            // file says nothing about itself that its neighbour does not.
            .cps2 => m.configs.get("cps2") orelse
                return m.give("no `cps2` row in MAME's cps1_config_table", .{}),
        };
        // The kludges are sprite layouts and RAM in the wrong place, bent
        // around bootlegs one at a time. A board file cannot say any of it.
        if (config.kludge != 0)
            return m.give("MAME needs bootleg kludge 0x{x} for this set", .{config.kludge});
        const cpu_hz: ?u32 = switch (system) {
            .cps1 => m.clocks.get(name) orelse
                return m.give("no GAME row names a machine config, so nothing says which 68000 this board has", .{}),
            // Every CPS-2 board is a 16 MHz one, which is what `system = cps2`
            // already means: a line saying it again is a line to keep in step.
            .cps2 => null,
        };

        var aw: std.Io.Writer.Allocating = .init(m.arena);
        const w = &aw.writer;
        try head(w, name, system, cpu_hz);
        try m.map(w, block, system);
        try registers(w, config, system);
        if (m.keys.get(name)) |key|
            try w.print("\nkabuki = 0x{x:0>8} 0x{x:0>8} 0x{x:0>4} 0x{x:0>2}\n", .{ key.swap1, key.swap2, key.addr, key.xor });
        // What the battery held, for a set whose dump has lost it. The set's
        // own `.key` still wins wherever there is one.
        if (m.crypts.get(name)) |c| if (system == .cps2)
            try w.print("\ncrypt = 0x{x:0>8} 0x{x:0>8} 0x{x:0>6} 0x{x:0>6}\n", .{ c.master[0], c.master[1], c.lower, c.upper });

        const text = try aw.toOwnedSlice();
        var diag = board.Diag{};
        const b = board.parse(text, &diag) catch
            return m.give("the board file this makes is not one this build reads: {s}", .{diag.message()});
        // A CPS-2 board without the twenty bytes its battery holds is not one:
        // `gigaman2` is in this driver because of what it copies, not what it
        // is, and it has an MCU and an OKI where the key and QSound should be.
        if (system == .cps2) {
            for (b.romList()) |rom| {
                if (rom.region == .key) break;
            } else return m.give("MAME gives this set no key ROM, so whatever it is wired as, it is not a CPS-2 board", .{});
        }
        try m.fits(&b);
        return text;
    }

    fn head(w: *std.Io.Writer, name: []const u8, system: board.System, cpu_hz: ?u32) !void {
        try w.print(
            \\# Board file for MAME's `{s}`, written by tools/mame_to_board.zig.
            \\#
            \\
        , .{name});
        const provenance: []const u8 = switch (system) {
            .cps1 =>
            \\# The register mapping, the bank table and the Kabuki key are what a
            \\# working board keeps in the RAM its battery holds up,
            \\# transcribed from MAME's CPS-1 driver (BSD-3-Clause, Nicola Salmoria
            \\# and the MAME team): src/mame/capcom/cps1.cpp and cps1_v.cpp.
            \\
            ,
            // Two files for the same reason MAME needs two: the ROM map is the
            // set's own, and the register mapping is the generation's.
            .cps2 =>
            \\# Transcribed from MAME's CPS-2 driver (BSD-3-Clause, Paul Leaman and
            \\# the MAME team): src/mame/capcom/cps2.cpp for the ROM map, and
            \\# cps1_v.cpp for the one row every CPS-2 board shares.
            \\# A CPS-2 board has no battery-backed configuration to hold: it is the
            \\# CPS-B-21 at its default strapping, and what its battery holds is the
            \\# decryption key: `key` below names the twenty bytes the set should
            \\# carry, and `crypt` is what that battery held, from the last MAME to
            \\# write the keys down (0.176, BSD-3-Clause, David Haywood).
            \\
            ,
        };
        try w.writeAll(provenance);
        for (booted) |set| {
            if (std.mem.eql(u8, set, name)) break;
        } else try w.writeAll(
            \\#
            \\# Untested: nobody here has this set to boot, so this file is only as
            \\# right as the table it came from.
            \\
        );
        try w.print("version = {d}\n", .{board.version});
        // `cps1` is the default, so only the other one is worth a line.
        if (system != .cps1) try w.print("system = {s}\n", .{@tagName(system)});
        // Soldered, not battery-backed, and the one number here that comes out
        // of the machine config rather than the tables.
        if (cpu_hz) |hz| try w.print("cpu_clock = {d}\n", .{hz});
    }

    /// The ROM map, region by region, in the order the chips are listed on the
    /// board rather than the order MAME happens to load them.
    fn map(m: *Mame, w: *std.Io.Writer, block: []const u8, system: board.System) !void {
        const l = try m.readLoads(block, system);
        try m.writeLoads(w, l.loads.items, l.beyond);
    }

    /// Every `ROM_LOAD` of a driver's block, as this build's lines.
    fn readLoads(m: *Mame, block: []const u8, system: board.System) !Loads {
        var l = Loads{ .arena = m.arena };
        var region: ?board.Region = null;
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |raw| {
            const line = trim(raw);
            const macro = word(line);
            if (!std.mem.startsWith(u8, macro, "ROM_")) continue;
            if (std.mem.startsWith(u8, macro, "ROM_REGION")) {
                region = regionOf(unquote((try fields(m.arena, parens(line, 0) orelse continue))[1]));
                continue;
            }
            // A PLD region, or the star field, or a patch: whatever it does
            // in there is not ours to express.
            const into = region orelse continue;
            const args = try fields(m.arena, parens(line, 0) orelse continue);
            try m.readLoad(&l, macro, args, into, system);
        }
        return l;
    }

    /// One ROM line of a region, which is a chip, a piece of one, or a macro
    /// that puts nothing on the board at all.
    fn readLoad(m: *Mame, l: *Loads, macro: []const u8, args: []const []const u8, into: board.Region, system: board.System) !void {
        if (std.mem.eql(u8, macro, "ROM_CONTINUE")) {
            // Nothing to continue means the chip this belongs to was one of
            // the lines above that could not be written down.
            const prev = l.last() orelse return l.cannot(into, "a ROM_CONTINUE with no chip before it", .{});
            return l.loads.append(m.arena, try continued(prev, into, args));
        }

        // The rest of a chip that is not loaded at all: a board file says where
        // each piece comes from, so a piece nobody reads is a line nobody
        // writes.
        if (std.mem.eql(u8, macro, "ROM_IGNORE")) return;

        if (std.mem.eql(u8, macro, "ROM_FILL")) {
            // The bottom of a CPS-2 graphics region a set leaves unpopulated.
            // It is not a chip and there is nothing to name: the loader already
            // reads an unpopulated CPS-2 graphics byte as the zero MAME writes
            // here. A fill of anything else, or anywhere else, is one this
            // build cannot express.
            if (system == .cps2 and into == .gfx and try number(args[2]) == 0) return;
            return l.cannot(into, "a ROM_FILL of {s} this build cannot express", .{args[2]});
        }

        const mode = modeOf(macro) orelse
            return l.cannot(into, "{s} is a load this build has no mode for", .{macro});
        if (args.len < load_args) return m.give("{s} with no dump behind it", .{macro});

        // A board file line is words with spaces between them, and MAME has a
        // handful of dumps whose file name has a space in it.
        const name = unquote(args[0]);
        if (std.mem.indexOfAny(u8, name, " \t") != null) {
            return l.cannot(into, "the file name `{s}` has a space in it, which a board file line cannot hold", .{name});
        }

        try l.loads.append(m.arena, .{
            .region = into,
            .dest = @intCast(try number(args[1])),
            .len = @intCast(try number(args[2])),
            .mode = mode,
            .name = name,
            .src = 0,
            .crc = crcOf(args[3]),
        });
    }
    /// The rest of a chip, landing somewhere else in the region: the same file
    /// in the same mode, carrying on from where the line before it stopped.
    fn continued(prev: Load, into: board.Region, args: []const []const u8) !Load {
        return .{
            .region = into,
            .dest = @intCast(try number(args[0])),
            .len = @intCast(try number(args[1])),
            .mode = prev.mode,
            .name = prev.name,
            .src = prev.src + prev.len,
            .crc = prev.crc,
        };
    }

    /// The board file's load lines, a region at a time. A region this build
    /// could not express is what turns the whole set away.
    fn writeLoads(m: *Mame, w: *std.Io.Writer, loads: []const Load, beyond: [board.region_count]?[]const u8) !void {
        for (std.enums.values(board.Region)) |into| {
            if (beyond[@intFromEnum(into)]) |reason|
                return m.give("{s} ({s} ROM)", .{ reason, @tagName(into) });
            var first = true;
            for (loads) |load| {
                if (load.region != into) continue;
                if (first) try w.writeByte('\n');
                first = false;
                try w.print("{s} = 0x{x:0>6} 0x{x:0>6} {s: <6} {s}", .{
                    @tagName(into), load.dest, load.len, load.mode, load.name,
                });
                if (load.src != 0) try w.print(" 0x{x}", .{load.src});
                if (load.crc) |crc| try w.print(" crc=0x{x:0>8}", .{crc});
                try w.writeByte('\n');
            }
        }
    }

    /// What the loader would have to allocate, against what a real board could
    /// hold. A set too big for those ceilings would be refused at load time,
    /// so it is refused here instead, where there is somewhere to say why.
    fn fits(m: *Mame, b: *const board.Board) !void {
        var sizes: [board.region_count]u64 = @splat(0);
        for (b.romList()) |rom| {
            const i = @intFromEnum(rom.region);
            sizes[i] = @max(sizes[i], rom.mode.extent(rom.dest, rom.len));
        }
        for (sizes, 0..) |size, i| {
            const region: board.Region = @enumFromInt(i);
            const max: u64 = switch (region) {
                .program => romset.max_program,
                .gfx => romset.max_gfx,
                .audio => romset.max_audio,
                .qsound => romset.max_qsound,
                .oki => romset.max_oki,
                .key => romset.max_key,
            };
            if (size > max)
                return m.give("0x{x} bytes of {s} ROM, and no board holds more than 0x{x}", .{ size, @tagName(region), max });
        }
    }

    fn give(m: *Mame, comptime fmt: []const u8, args: anytype) error{ Unsupported, OutOfMemory } {
        m.why = try std.fmt.allocPrint(m.arena, fmt, args);
        return error.Unsupported;
    }
};

// --------------------------------------------------------- the machine configs

/// Every `cps_state::` machine config in the driver, resolved to the 68000
/// crystal it ends up putting on the board.
/// No driver derives a machine config further than this, so a config that
/// somehow derives from itself answers with no clock rather than hanging.
const max_config_depth = 8;

fn readConfigs(arena: std.mem.Allocator, driver_src: []const u8) !std.StringHashMapUnmanaged(u32) {
    // A config either names a clock or inherits one from the config it opens
    // by calling.
    const Derived = struct { hz: ?u32 = null, from: ?[]const u8 = null };
    var bodies: std.StringHashMapUnmanaged(Derived) = .empty;

    const decl = "void cps_state::";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, driver_src, at, decl)) |found| {
        const name = word(driver_src[found + decl.len ..]);
        at = found + decl.len + name.len;
        if (!std.mem.startsWith(u8, driver_src[at..], "(machine_config")) continue;
        const body = braces(driver_src, at) orelse continue;
        try bodies.put(arena, name, if (mainClock(body)) |hz|
            .{ .hz = hz }
        else
            .{ .from = derivedFrom(body) });
    }

    var out: std.StringHashMapUnmanaged(u32) = .empty;
    var it = bodies.iterator();
    while (it.next()) |entry| {
        var name = entry.key_ptr.*;
        for (0..max_config_depth) |_| {
            const derived = bodies.get(name) orelse break;
            if (derived.hz) |hz| {
                try out.put(arena, entry.key_ptr.*, hz);
                break;
            }
            name = derived.from orelse break;
        }
    }
    return out;
}

/// The clock a config puts on the main CPU, if it is the one that names it.
fn mainClock(body: []const u8) ?u32 {
    for ([_][]const u8{ "M68000(config, m_maincpu, XTAL(", "m_maincpu->set_clock(XTAL(" }) |line| {
        const at = std.mem.indexOf(u8, body, line) orelse continue;
        return xtal(body[at + line.len ..]);
    }
    return null;
}

/// The config a config is built on: the first thing it does is call it.
fn derivedFrom(body: []const u8) ?[]const u8 {
    const call = "(config);";
    const at = std.mem.indexOf(u8, body, call) orelse return null;
    var start = at;
    while (start > 0 and (std.ascii.isAlphanumeric(body[start - 1]) or body[start - 1] == '_')) start -= 1;
    return if (start == at) null else body[start..at];
}

/// `10'000'000)`, the way MAME writes a crystal.
fn xtal(text: []const u8) ?u32 {
    var hz: u32 = 0;
    for (text) |c| {
        switch (c) {
            '0'...'9' => hz = hz * 10 + (c - '0'),
            '\'' => {},
            else => return if (c == ')') hz else null,
        }
    }
    return null;
}

/// One `ROM_LOAD` line, on its way to being one board file line.
/// A file name, where it lands, how long it is, and its CRC: the four a load
/// line cannot do without.
const load_args = 4;

/// A set's ROM map as it is read, and what stopped it being one.
const Loads = struct {
    arena: std.mem.Allocator,
    loads: std.ArrayList(Load) = .empty,
    /// What this build cannot express, remembered per region rather than
    /// refused on sight, so a set is only turned away for a region it actually
    /// has.
    beyond: [board.region_count]?[]const u8 = @splat(null),

    fn last(l: Loads) ?Load {
        return if (l.loads.items.len == 0) null else l.loads.items[l.loads.items.len - 1];
    }

    fn cannot(l: *Loads, into: board.Region, comptime fmt: []const u8, args: anytype) !void {
        l.beyond[@intFromEnum(into)] = try std.fmt.allocPrint(l.arena, fmt, args);
    }
};

const Load = struct {
    region: board.Region,
    dest: u32,
    len: u32,
    mode: []const u8,
    name: []const u8,
    src: u32,
    crc: ?u32,
};

fn regionOf(tag: []const u8) ?board.Region {
    if (std.mem.eql(u8, tag, "maincpu")) return .program;
    if (std.mem.eql(u8, tag, "gfx")) return .gfx;
    if (std.mem.eql(u8, tag, "audiocpu")) return .audio;
    if (std.mem.eql(u8, tag, "qsound")) return .qsound;
    if (std.mem.eql(u8, tag, "oki")) return .oki;
    // Not a chip: the twenty bytes a CPS-2 board's battery holds up, which MAME
    // carries as a region because a dump of one is a file like any other.
    if (std.mem.eql(u8, tag, "key")) return .key;
    return null;
}

/// MAME's load macros, in the two names each one has: how the file is read,
/// and what this build calls that.
fn modeOf(macro: []const u8) ?[]const u8 {
    const modes = .{
        .{ "ROM_LOAD16_WORD_SWAP", "word" },
        .{ "ROM_LOAD16_BYTE", "byte16" },
        .{ "ROM_LOAD64_WORD", "word64" },
        .{ "ROM_LOAD64_BYTE", "byte64" },
        // A 68000 region is big-endian, and both of these hold it that way.
        .{ "ROM_LOAD16_WORD", "byte" },
        .{ "ROM_LOAD", "byte" },
    };
    inline for (modes) |mode| {
        if (std.mem.eql(u8, macro, mode[0])) return mode[1];
    }
    return null;
}

/// The dump MAME says a line loads, out of `CRC(1234abcd) SHA1(...)`.
fn crcOf(hashes: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, hashes, "CRC(") orelse return null;
    const text = parens(hashes, at) orelse return null;
    return std.fmt.parseInt(u32, trim(text), 16) catch null;
}

fn registers(w: *std.Io.Writer, config: Config, system: board.System) !void {
    try w.writeAll(switch (system) {
        .cps1 => "\n# --- what the battery held -----------------------------------------------\n",
        // The same numbers on every CPS-2 board, and none of them the board's
        // own: sprites are addressed linearly by the object hardware and are in
        // no range, and the three scroll layers are all in the second bank.
        .cps2 => "\n# --- what a CPS-2 board is strapped to -----------------------------------\n",
    });
    try layerRegisters(w, config.cpsb);
    try decodedRegisters(w, config.cpsb);
    try ports(w, config);
    try banks(w, config.mapper);
}

/// The four every board has, because a board that decoded none of them could
/// not put a picture up at all.
fn layerRegisters(w: *std.Io.Writer, cpsb: Cpsb) !void {
    try w.writeAll("layer_control   = ");
    try reg(w, cpsb.layer_control);
    try w.writeAll("\npriority        =");
    for (cpsb.priority) |p| {
        try w.writeByte(' ');
        try reg(w, p);
    }
    try w.writeAll("\npalette_control = ");
    try reg(w, cpsb.palette_control);
    try w.writeAll("\nlayer_enable    =");
    for (cpsb.layer_enable) |e| try w.print(" 0x{x:0>2}", .{@as(u64, @intCast(e))});
    try w.writeByte('\n');
}

/// A register a board does not decode is not written at all: the parser
/// defaults it to none, and a file that says less is easier to read.
fn decodedRegisters(w: *std.Io.Writer, cpsb: Cpsb) !void {
    if (cpsb.id_offset >= 0) {
        try w.writeAll("id              = ");
        try reg(w, cpsb.id_offset);
        // MAME answers -1 on a board whose ID register is there but whose
        // value nobody has recorded, and a 68000 reads that as all ones.
        try w.print(" 0x{x:0>4}\n", .{@as(u16, @truncate(@as(u64, @bitCast(cpsb.id_value))))});
    }
    if (std.mem.indexOfNone(i64, &cpsb.multiply, &.{-1}) == null) return;
    try w.writeAll("multiply        =");
    for (cpsb.multiply) |f| {
        try w.writeByte(' ');
        try reg(w, f);
    }
    try w.writeByte('\n');
}

/// The extra input and output ports a board straps on, none of which most
/// boards have.
fn ports(w: *std.Io.Writer, config: Config) !void {
    const io = [_]struct { []const u8, i64 }{ .{ "in2", config.in2 }, .{ "in3", config.in3 }, .{ "out2", config.out2 } };
    for (io) |port| {
        if (port[1] == 0) continue;
        try w.print("{s: <15} = ", .{port[0]});
        try reg(w, port[1]);
        try w.writeByte('\n');
    }
}

/// The graphics bank sizes and the code ranges that live on them, which is the
/// half of the board file the tile decoder reads.
fn banks(w: *std.Io.Writer, mapper: Mapper) !void {
    try w.writeAll("\nbank_sizes =");
    for (mapper.sizes) |size| try w.print(" 0x{x}", .{size});
    try w.writeByte('\n');
    for (mapper.ranges) |range| {
        try w.writeAll("gfx_bank = ");
        var first = true;
        for (std.enums.values(board.Layer)) |layer| {
            if (range.types & @as(u8, 1) << @intFromEnum(layer) == 0) continue;
            if (!first) try w.writeByte('|');
            first = false;
            try w.writeAll(@tagName(layer));
        }
        try w.print(" 0x{x:0>5} 0x{x:0>5} {d}\n", .{ range.start, range.end, range.bank });
    }
}

fn reg(w: *std.Io.Writer, value: i64) !void {
    if (value < 0) return w.writeAll("none");
    return w.print("0x{x:0>2}", .{@as(u64, @intCast(value))});
}

fn lower(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    return std.ascii.lowerString(out, text);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a balanced call is what parens hands back, nested ones and all" {
    try testing.expectEqualStrings("a, b(c), d", parens("f(a, b(c), d) g", 0).?);
    // The `at` is where to start looking, not where the call is.
    try testing.expectEqualStrings("x", parens("f(a) g(x)", 5).?);
    try testing.expectEqual(@as(?[]const u8, null), parens("f(a, b", 0));
    try testing.expectEqual(@as(?[]const u8, null), parens("nothing here", 0));
}

test "braces do the same for an initialiser" {
    try testing.expectEqualStrings("{ 1, 2 }, { 3 }", braces("t[] = {{ 1, 2 }, { 3 }};", 0).?);
    try testing.expectEqual(@as(?[]const u8, null), braces("t[] = {1, 2", 0));
}

test "fields splits where C++ means it to, not at every comma" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const args = try fields(arena_state.allocator(), "a, f(b, c), { d, e }, \"g, h\"");
    try testing.expectEqual(@as(usize, 4), args.len);
    try testing.expectEqualStrings("a", args[0]);
    try testing.expectEqualStrings("f(b, c)", args[1]);
    try testing.expectEqualStrings("{ d, e }", args[2]);
    try testing.expectEqualStrings("\"g, h\"", args[3]);
}

test "a stray closer is a field boundary, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // A truncated line reaches here through more than one caller, and an
    // unmatched `)` used to take the depth below zero.
    const args = try fields(arena_state.allocator(), "a), b");
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("a)", args[0]);
    try testing.expectEqualStrings("b", args[1]);
}

test "comments go, and what is inside a string stays" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("a b", try stripComments(arena, "a /* gone */b"));
    try testing.expectEqualStrings("a \n", try stripComments(arena, "a // gone\n"));
    try testing.expectEqualStrings("\"a // b\"", try stripComments(arena, "\"a // b\""));
}

test "word stops where an identifier does" {
    try testing.expectEqualStrings("ROM_LOAD", word("ROM_LOAD( \"a\" )"));
    try testing.expectEqualStrings("init_dino", word("init_dino,"));
    try testing.expectEqualStrings("", word("(nothing"));
}

test "a CRC is the one hash of a load line this build keeps" {
    try testing.expectEqual(@as(?u32, 0x1c9b5e0e), crcOf("CRC(1c9b5e0e) SHA1(deadbeef)"));
    try testing.expectEqual(@as(?u32, null), crcOf("NO_DUMP"));
    try testing.expectEqual(@as(?u32, null), crcOf("CRC(not hex)"));
}

test "a CPS_B define reads as twenty numbers" {
    const cpsb = try Cpsb.parse("{ 0x00, 0x0401, {0x00,0x02,0x04,0x06}, {-1,-1,-1}, 0x66, {0x68,0x6a,0x6c,0x6e}, 0x70, {0x68,0x6a,0x6c,-1,-1} }");
    try testing.expectEqual(@as(i64, 0x00), cpsb.id_offset);
    try testing.expectEqual(@as(i64, 0x0401), cpsb.id_value);
    try testing.expectEqual(@as(i64, 0x66), cpsb.layer_control);
    try testing.expectEqual(@as(i64, 0x70), cpsb.palette_control);
    try testing.expectEqual(@as(i64, -1), cpsb.layer_enable[4]);
    // One number short, or one over, is a table this build has not understood.
    try testing.expectError(error.BadTable, Cpsb.parse("{ 0x00, 0x0401 }"));
}

test "every ROM_START of a driver, and nothing between them" {
    var sets = RomStarts.init(
        \\ROM_START( dino )
        \\ROM_LOAD( "a", 0, 0x80000, CRC(1) )
        \\ROM_END
        \\
        \\ROM_START( dinou )
        \\ROM_LOAD( "b", 0, 0x80000, CRC(2) )
        \\ROM_END
    );
    const first = sets.next().?;
    try testing.expectEqualStrings("dino", first.name);
    try testing.expect(std.mem.indexOf(u8, first.body, "\"a\"") != null);
    try testing.expect(std.mem.indexOf(u8, first.body, "\"b\"") == null);
    try testing.expectEqualStrings("dinou", sets.next().?.name);
    try testing.expectEqual(@as(?RomStarts.Block, null), sets.next());
}

test "a key is the CRYPT_PARAMS macro a set's ROM map names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const by_macro = try Mame.readCryptMacros(arena,
        \\#define CRYPT_PARAMS(a,b,c,d) ROM_PARAMETER(a) ROM_PARAMETER(b)
        \\#define avsp_key    CRYPT_PARAMS("15208f79","4ade6cb3","0000000","0ffffff")
        \\#define suicide_key CRYPT_PARAMS("00000000","00000000","ff0000","ffffff")
    );
    // The macro's own define is not a key, and neither is a dead board's.
    try testing.expectEqual(@as(u32, 1), by_macro.count());

    const c = Mame.cryptOf("ROM_REGION( 0x14, \"key\", 0 ) avsp_key", by_macro).?;
    try testing.expectEqual(@as(u32, 0x15208f79), c.master[0]);
    try testing.expectEqual(@as(u32, 0x4ade6cb3), c.master[1]);
    try testing.expectEqual(@as(u32, 0x0ffffff), c.upper);
    // A set whose block names no macro is a set with no key here.
    try testing.expectEqual(@as(?board.Crypt, null), Mame.cryptOf("ROM_LOAD( \"a\", 0, 1, CRC(2) )", by_macro));
}
