//! The program: the window and the frame loop, with the headless runner of
//! DESIGN.md §6.1 still under it. `--frames N` renders with no window, hashes
//! the machine and exits; that is the backbone of testing rather than a debug
//! feature, which is why it was the first thing that existed and has to keep
//! working forever.
//!
//! This and `ui/shell.zig` are the only files allowed to reach raylib, and the
//! build graph is what enforces that rather than anyone remembering.

const std = @import("std");
const builtin = @import("builtin");
const board = @import("board");
const romset = @import("romset");
const cps = @import("cps");
const scheduler = @import("scheduler");
const video = @import("video");
const audio = @import("audio");
const input = @import("input");
const config = @import("config");
const snow = @import("snow");
const boards = @import("boards");
const shell = @import("shell");

const rl = @cImport(@cInclude("raylib.h"));

const Config = config.Config;

/// A board file is text a person typed; a replay log is one word per frame.
const max_board_bytes = 64 << 10;
const max_replay_bytes = 16 << 20;
const max_config_bytes = 64 << 10;

/// Drawn frames a second with no machine running: the snow has no audio to
/// pace against and nothing to be in time with. A menu over a loaded set is
/// still worth 60, where a held key is felt; an empty window is not, and the
/// snow is no more convincing at 60 Hz than at half of it.
const idle_fps = 60;
const snow_fps = 30;

/// Emulated frames per drawn one while the fast-forward key is held. Four is
/// fast enough to skip an attract mode and slow enough to still see it.
const fast_forward_frames = 4;

/// A game writes the EEPROM a bit at a time, so the sidecar is rewritten at
/// most this often while it plays, and once more on the way out.
const nv_write_seconds = 5;

const audio_sample_size = 16; // s16
const audio_channels = 2;
/// What raylib hands the device at a time. Smaller is less latency and more
/// chances to underrun; this is about 40ms at 48kHz.
const audio_chunk_frames = 2048;
/// How far ahead of playback the mixer is allowed to get before the loop
/// sleeps off the surplus.
const audio_target_frames = 2 * audio_chunk_frames;

/// One frame of the control panel, little-endian: both players' buttons and the
/// panel's six inputs. Wider than zigesis's word because this machine has two
/// six-button players and a coin door.
const log_frame_bytes = 4;
const log_pad2_shift = cps.button_count;
const log_panel_shift = 2 * cps.button_count;

fn pack(in: cps.Inputs) u32 {
    return @as(u32, in.pad[0]) |
        @as(u32, in.pad[1]) << log_pad2_shift |
        @as(u32, in.panel) << log_panel_shift;
}

fn unpack(word: u32) cps.Inputs {
    const pad_mask = (@as(u32, 1) << cps.button_count) - 1;
    return .{
        .pad = .{
            @truncate(word & pad_mask),
            @truncate((word >> log_pad2_shift) & pad_mask),
        },
        .panel = @truncate(word >> log_panel_shift),
    };
}

/// A recorded input log. Past the end reads as nothing held, so a short log
/// runs a long test without special-casing.
const Replay = struct {
    log: []const u8,

    fn at(r: Replay, frame: u32) cps.Inputs {
        const offset = @as(usize, frame) * log_frame_bytes;
        if (offset + log_frame_bytes > r.log.len) return .{};
        return unpack(std.mem.readInt(u32, r.log[offset..][0..log_frame_bytes], .little));
    }
};

fn record(r: *std.ArrayList(u8), gpa: std.mem.Allocator, in: cps.Inputs) !void {
    var word: [log_frame_bytes]u8 = undefined;
    std.mem.writeInt(u32, &word, pack(in), .little);
    try r.appendSlice(gpa, &word);
}

/// What a user error exits with. The message has already been printed and says
/// more than a Zig stack trace would.
fn fail() noreturn {
    std.process.exit(1);
}

/// The command line, once. Every refusal here has already said what was wrong,
/// so nothing in this struct needs checking again.
const Options = struct {
    /// Empty when no set was named, which an empty argument could not name
    /// anyway. The window opens on snow and the menu loads one.
    set: []const u8 = "",
    board: ?[]const u8 = null,
    replay: ?[]const u8 = null,
    record: ?[]const u8 = null,
    frames: ?u32 = null,
    every_frame: bool = false,
};

/// The value an option takes, or a message and no exit code worth reading a
/// stack trace for.
fn value(args: *std.process.Args.Iterator, flag: []const u8) []const u8 {
    return args.next() orelse {
        std.debug.print("{s} wants a value after it\n", .{flag});
        fail();
    };
}

/// `--help` prints and exits rather than returning, so the caller has an
/// `Options` or nothing.
fn parseArgs(args: *std.process.Args.Iterator) Options {
    var o = Options{};

    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--hash")) {
            o.every_frame = true;
        } else if (std.mem.eql(u8, arg, "--board")) {
            o.board = value(args, arg);
        } else if (std.mem.eql(u8, arg, "--replay")) {
            o.replay = value(args, arg);
        } else if (std.mem.eql(u8, arg, "--record")) {
            o.record = value(args, arg);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const count = value(args, arg);
            o.frames = std.fmt.parseInt(u32, count, 10) catch {
                std.debug.print("--frames wants a number of frames, got `{s}`\n", .{count});
                fail();
            };
        } else if (o.set.len == 0) {
            o.set = arg;
        } else {
            std.debug.print("ignoring extra argument {s}\n", .{arg});
        }
    }
    return o;
}

/// A set and the board file that says how to read it, loaded together because
/// neither is any use without the other.
const Machine = struct {
    b: board.Board,
    rom: romset.Set,
    /// Which board file this machine was built from, for the card: the name
    /// of the file the user supplied, or of the board that shipped with this
    /// build. Only the load knows which of the two won.
    source: [max_source]u8 = @splat(0),

    fn from(m: *const Machine) []const u8 {
        return std.mem.sliceTo(&m.source, 0);
    }

    fn deinit(m: *Machine, gpa: std.mem.Allocator) void {
        m.rom.deinit(gpa);
    }
};

/// Room for a file name on the card. Not a path: a card that says which
/// directory it read is a card nobody can read.
const max_source = 64;

/// Reads a set and its board file, saying why in `diag` rather than exiting:
/// the menu can load a set that turns out to be wrong without the window
/// having to close.
fn loadSet(
    gpa: std.mem.Allocator,
    io: std.Io,
    set: []const u8,
    board_path: ?[]const u8,
    diag: *board.Diag,
) !Machine {
    // The board file lives beside the set under the set's own name, whether the
    // set is a directory or a zip.
    var default_board: [std.fs.max_path_bytes]u8 = undefined;
    const board_file = board_path orelse beside(&default_board, set, ".board") catch {
        diag.set("path too long", .{});
        return error.BadBoardFile;
    };

    // What a set is called is what MAME calls it, which is what the boards
    // that ship with this build are named after (DESIGN.md §8.1). The user's
    // own file still wins: theirs is the board in front of them, and ours is
    // a transcription of a table.
    const name = std.fs.path.stem(std.fs.path.basename(board_file));

    var machine = Machine{ .b = undefined, .rom = undefined };
    const cwd = std.Io.Dir.cwd();
    var owned = true;
    const text = cwd.readFileAlloc(io, board_file, gpa, .limited(max_board_bytes)) catch |err| shipped: {
        const built_in = if (board_path == null) boards.find(name) else null;
        if (built_in) |ours| {
            owned = false;
            label(&machine.source, "{s} (built in)", .{name});
            break :shipped ours;
        }
        diag.set("no board file at {s} ({t}), and none for `{s}` ships with this build", .{ board_file, err, name });
        return error.BadBoardFile;
    };
    defer if (owned) gpa.free(text);
    if (owned) label(&machine.source, "{s}", .{std.fs.path.basename(board_file)});

    machine.b = try board.parse(text, diag);
    machine.rom = try romset.load(gpa, io, cwd, set, &machine.b, diag);
    return machine;
}

/// Fills a card's line, cut to fit rather than refused: half a name still says
/// which file this was.
fn label(into: *[max_source]u8, comptime fmt: []const u8, args: anytype) void {
    var w = std.Io.Writer.fixed(into[0 .. into.len - 1]);
    w.print(fmt, args) catch {};
    into[w.buffered().len] = 0;
}

/// The half of a load failure that only the command line can print: what a
/// board file is for, which is not obvious the first time zicps refuses to
/// start. The menu says the same thing with less room, so it says less.
fn explainBoard() void {
    std.debug.print(
        \\A CPS-1.5 board keeps its configuration in battery-backed RAM, so zicps needs
        \\a board file describing this board before it can run the set. One ships for every
        \\set MAME names, under boards/, and is found by the set's own name; a file beside
        \\the set or --board wins over it. See DESIGN.md §8.1.
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    const o = parseArgs(&args);

    // Two thirds of a megabyte of RAM, registers and framebuffer: too much for
    // the stack, and allocated exactly once whatever set goes in it.
    const c = try gpa.create(cps.Cps);
    defer gpa.destroy(c);
    c.* = .{ .board = .{}, .rom = .{ .program = &.{}, .gfx = &.{}, .audio = &.{}, .qsound = &.{} } };
    var cpu: scheduler.Cpu = .{};

    var diag = board.Diag{};
    var machine: ?Machine = null;
    defer if (machine) |*m| m.deinit(gpa);
    if (o.set.len != 0) {
        machine = loadSet(gpa, io, o.set, o.board, &diag) catch {
            std.debug.print("{s}: {s}\n", .{ o.set, diag.message() });
            explainBoard();
            fail();
        };
    }

    if (o.frames) |n| {
        const m = &(machine orelse {
            std.debug.print("--frames needs a set to run\n", .{});
            fail();
        });
        startMachine(c, &cpu, m);
        return headless(io, gpa, c, &cpu, n, o.replay, o.record, o.every_frame);
    }

    const cfg_path = try configPath(gpa, init.environ_map);
    defer gpa.free(cfg_path);
    var cfg: Config = blk: {
        const text = std.Io.Dir.cwd().readFileAlloc(io, cfg_path, gpa, .limited(max_config_bytes)) catch {
            // Nothing there yet: write the defaults out, so there is a file to
            // hand-edit without having to change something in the menu first.
            saveConfig(io, cfg_path, .{}) catch |err| std.debug.print("cannot write {s}: {t}\n", .{ cfg_path, err });
            break :blk .{};
        };
        defer gpa.free(text);
        break :blk Config.parse(text);
    };

    try windowed(io, gpa, c, &cpu, &cfg, &machine, .{
        .config = cfg_path,
        .set = o.set,
        .board = o.board,
        .replay = o.replay,
        .record = o.record,
    });
}

/// Power-on, and also what the Reset menu entry does: every chip back to its
/// reset state with the same set in the board. Not the 68000's reset line —
/// that would keep work RAM, and this is a cabinet being switched off.
///
/// The EEPROM does not survive this, because it is a battery, not a chip: the
/// caller writes it out and reads it back around the call (`flushNv`).
fn startMachine(c: *cps.Cps, cpu: *scheduler.Cpu, m: *const Machine) void {
    c.* = .{ .board = m.b, .rom = m.rom };
    cpu.* = .{};
    scheduler.reset(c, cpu);
}

// ------------------------------------------------------------------ headless

fn headless(
    io: std.Io,
    gpa: std.mem.Allocator,
    c: *cps.Cps,
    cpu: *scheduler.Cpu,
    n: u32,
    replay_path: ?[]const u8,
    record_path: ?[]const u8,
    every_frame: bool,
) !void {
    const replay: ?Replay = if (replay_path) |p| .{
        .log = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)) catch |err| {
            std.debug.print("cannot read replay {s}: {t}\n", .{ p, err });
            fail();
        },
    } else null;
    defer if (replay) |r| gpa.free(r.log);
    var log: ?std.ArrayList(u8) = if (record_path == null) null else .empty;
    defer if (log) |*r| r.deinit(gpa);

    var sound = Sound{};
    var frame: u32 = 0;
    while (frame < n and !cpu.halted) : (frame += 1) {
        if (replay) |r| c.inputs = r.at(frame);
        if (log) |*r| try record(r, gpa, c.inputs);
        scheduler.runFrame(c, cpu);
        sound.drain(&c.mixer);
        if (every_frame) report(c, cpu, &sound, frame + 1);
    }
    if (!every_frame) report(c, cpu, &sound, frame);
    if (log) |*r| try writeLog(io, record_path.?, r.items);

    if (cpu.halted) {
        std.debug.print("the 68000 halted at pc={x:0>6} sr={x:0>4} after {d} frames\n", .{ cpu.pc, @as(u16, @bitCast(cpu.sr)), frame });
        fail();
    }
}

fn writeLog(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    std.debug.print("recorded {d} frames of input to {s}\n", .{ bytes.len / log_frame_bytes, path });
}

/// The sound that came out, hashed as it goes past. With no window there is no
/// device to pace against, so the sample count is what says the machine ran at
/// the right speed: a frame is worth 48000/59.6374 of them and nothing else.
///
/// Draining is not optional even when nobody is listening. The ring is finite,
/// and a run that never emptied it would quietly start dropping frames a fifth
/// of a second in, which is a different machine from the one being tested.
const Sound = struct {
    h: std.hash.Wyhash = .init(0),
    frames: u64 = 0,

    fn drain(s: *Sound, m: *audio.Mixer) void {
        while (m.pop()) |f| : (s.frames += 1) s.h.update(std.mem.asBytes(&f));
    }
};

fn report(c: *const cps.Cps, cpu: *const scheduler.Cpu, sound: *const Sound, frame: u32) void {
    // A copy, because finishing the hash consumes it and the run goes on.
    var h = sound.h;
    std.debug.print("frame {d} hash={x:0>16} audio={x:0>16} samples={d}\n", .{
        frame,
        scheduler.hash(c, cpu),
        h.final(),
        sound.frames,
    });
}

// ------------------------------------------------------------------- files

/// `sets/game.zip`, `sets/game` and the `sets/game/` a shell completes a
/// directory to all look beside themselves for `sets/game.board`.
fn beside(buf: []u8, path: []const u8, suffix: []const u8) ![]const u8 {
    // What basename splits on, which on Windows is both slashes and not just
    // `sep_str`. A backslash is a legal character in a POSIX file name, so the
    // set only widens where it really is a separator.
    const seps = if (builtin.os.tag == .windows)
        std.fs.path.sep_str_windows ++ std.fs.path.sep_str_posix
    else
        std.fs.path.sep_str_posix;
    const trimmed = std.mem.trimEnd(u8, path, seps);
    const name = std.fs.path.basename(trimmed);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        return std.fmt.bufPrint(buf, "{s}{s}", .{ trimmed, suffix });
    return std.fmt.bufPrint(buf, "{s}{s}", .{ trimmed[0 .. trimmed.len - (name.len - dot)], suffix });
}

/// XDG on Linux, `%APPDATA%` on Windows, and the working directory when the
/// environment says nothing — options are worth persisting, not worth failing
/// a launch over.
fn configPath(gpa: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |dir| return std.fs.path.join(gpa, &.{ dir, "zicps", "config.ini" });
    if (env.get("HOME")) |dir| return std.fs.path.join(gpa, &.{ dir, ".config", "zicps", "config.ini" });
    if (env.get("APPDATA")) |dir| return std.fs.path.join(gpa, &.{ dir, "zicps", "config.ini" });
    return gpa.dupe(u8, "zicps.ini");
}

fn saveConfig(io: std.Io, path: []const u8, cfg: Config) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.write(&w);
    try cwd.writeFile(io, .{ .sub_path = path, .data = w.buffered() });
}

/// The EEPROM sidecar of DESIGN.md §8.4: `game.zip.nv` beside the set, with
/// the extension *added* rather than replaced, so a directory set and a zip of
/// the same name keep their own settings.
fn nvPath(buf: []u8, set: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.nv", .{set});
}

/// Read once when the set goes in. A short or missing file leaves the chip
/// erased, which is what an unused battery reads as and what sends the board
/// into its own service menu to be set up.
fn loadNv(io: std.Io, c: *cps.Cps, set: []const u8) void {
    var buf: [shell.max_path]u8 = undefined;
    const path = nvPath(&buf, set) catch return;
    var bytes: [cps.eeprom_bytes]u8 = @splat(0xff);
    const read = std.Io.Dir.cwd().readFile(io, path, &bytes) catch return;
    c.eeprom.load(read);
}

fn flushNv(io: std.Io, c: *cps.Cps, set: []const u8) !void {
    if (!c.eeprom.dirty) return;
    var buf: [shell.max_path]u8 = undefined;
    const path = try nvPath(&buf, set);
    var bytes: [cps.eeprom_bytes]u8 = undefined;
    c.eeprom.save(&bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &bytes });
    c.eeprom.dirty = false;
}

/// Holds a path that outlives the `Request.load` slice it was copied from,
/// which points into the shell's own buffer.
fn keepPath(buf: []u8, path: []const u8) []const u8 {
    const n = @min(path.len, buf.len);
    @memcpy(buf[0..n], path[0..n]);
    return buf[0..n];
}

// -------------------------------------------------------------- board card

/// The 16-bit sum of every byte of the program ROMs. CPS-1 program images
/// carry no checksum field to check it against — the head of the first one is
/// the 68000's vector table and nothing else — so this is a reading, not a
/// verdict: the same set gives the same number every time, and two people
/// comparing dumps can say so in one line. See DESIGN.md §5.2.
fn programSum(program: []const u8) u16 {
    var sum: u16 = 0;
    for (program) |byte| sum +%= byte;
    return sum;
}

/// The card the menu shows beside itself: what the set and the board file
/// turned out to say, all of it read out of the two files the user supplied.
/// Built when the set goes in, because none of it changes while the game plays.
fn describeBoard(ui: *shell.Ui, m: *const Machine, set: []const u8) void {
    shell.cardStart(ui, std.fs.path.basename(set), m.from());

    var regions: [4]usize = @splat(0);
    for (m.b.romList()) |rom| regions[@intFromEnum(rom.region)] += 1;

    shell.cardRow(ui, "PROGRAM", .plain, "{d} ROMs / {d} KiB", .{ regions[0], m.rom.program.len >> 10 });
    shell.cardRow(ui, "GRAPHICS", .plain, "{d} ROMs / {d} KiB", .{ regions[1], m.rom.gfx.len >> 10 });
    // A CPS-1.5 always has both, but a board file can describe a set that is
    // missing one, and silence is how that shows up rather than a crash.
    if (m.rom.audio.len == 0) {
        shell.cardRow(ui, "SOUND", .bad, "NONE", .{});
    } else {
        shell.cardRow(ui, "SOUND", .plain, "{d} ROMs / {d} KiB", .{ regions[2], m.rom.audio.len >> 10 });
    }
    if (m.rom.qsound.len == 0) {
        shell.cardRow(ui, "SAMPLES", .bad, "NONE", .{});
    } else {
        shell.cardRow(ui, "SAMPLES", .plain, "{d} ROMs / {d} KiB", .{ regions[3], m.rom.qsound.len >> 10 });
    }
    // The Kabuki key is the one thing in the board file that is a secret
    // rather than a setting: without it the Z80 runs garbage and the cabinet
    // is silent, so whether there is one is worth a line of its own.
    shell.cardRow(ui, "KABUKI", if (m.b.kabuki == null) .bad else .good, "{s}", .{
        if (m.b.kabuki == null) "NO KEY" else "KEY SET",
    });
    // Which CPS-B-21 batch this board is, as far as anything can tell from
    // outside: the register offsets the chip was strapped for. Each reading
    // needs its own buffer — they are both alive until the row is formatted.
    var ctrl: [2]u8 = undefined;
    var pal: [2]u8 = undefined;
    shell.cardRow(ui, "CPS-B", .plain, "ctrl {s} / pal {s} / gfx x{d}", .{
        hexOrNone(&ctrl, m.b.layer_control),
        hexOrNone(&pal, m.b.palette_control),
        m.b.range_count,
    });
    shell.cardRow(ui, "SUM", .plain, "{x:0>4}", .{programSum(m.rom.program)});
}

/// A CPS-B register offset for the card, or "--" for one the board file left
/// out.
fn hexOrNone(buf: *[2]u8, reg: board.Reg) []const u8 {
    const offset = reg orelse return "--";
    return std.fmt.bufPrint(buf, "{x:0>2}", .{offset}) catch unreachable;
}

// ----------------------------------------------------------------- window

/// The window is sized for the picture plus the status bar under it.
fn windowW(scale: u8) c_int {
    return video.width * @as(c_int, scale);
}

fn windowH(scale: u8) c_int {
    const bar_share = 10; // what `shell.barHeight` comes out at, as a fraction
    const picture = video.height * @as(c_int, scale);
    return picture + @divTrunc(picture, bar_share);
}

fn keyDown(key: u32) bool {
    return rl.IsKeyDown(@intCast(key));
}

/// Hands raylib a full sub-buffer whenever it has one free and the mixer has
/// one ready. Polling like this is the pattern raylib's own audio-stream
/// example uses, so there is no callback thread to synchronize with.
fn drainAudio(c: *cps.Cps, stream: rl.AudioStream) void {
    while (c.mixer.ready() >= audio_chunk_frames and rl.IsAudioStreamProcessed(stream)) {
        var pcm: [audio_chunk_frames]audio.Frame = undefined;
        for (&pcm) |*frame| frame.* = c.mixer.pop().?;
        rl.UpdateAudioStream(stream, &pcm, pcm.len);
    }
}

/// Sleeps off the surplus once the mixer is further ahead of playback than the
/// target; being behind returns immediately, so the emulator catches up on its
/// own without ever needing to skip a frame.
fn paceToAudio(c: *cps.Cps, io: std.Io) void {
    if (c.mixer.ready() <= audio_target_frames) return;
    const surplus_ms = (c.mixer.ready() - audio_target_frames) * std.time.ms_per_s / audio.sample_rate;
    io.sleep(.fromMilliseconds(@intCast(surplus_ms)), .awake) catch {};
}

fn fbImage(c: *cps.Cps) rl.Image {
    return .{
        .data = &c.v.fb,
        .width = video.width,
        .height = video.height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
}

const WindowedArgs = struct {
    config: []const u8,
    set: []const u8,
    board: ?[]const u8,
    replay: ?[]const u8,
    record: ?[]const u8,
};

/// The window, the frame loop and the shell: idle snow with no set, the
/// picture with one, and the menu over either.
fn windowed(
    io: std.Io,
    gpa: std.mem.Allocator,
    c: *cps.Cps,
    cpu: *scheduler.Cpu,
    cfg: *Config,
    machine: *?Machine,
    args: WindowedArgs,
) !void {
    const replay: ?Replay = if (args.replay) |p| .{
        .log = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)),
    } else null;
    defer if (replay) |r| gpa.free(r.log);
    var log: ?std.ArrayList(u8) = if (args.record == null) null else .empty;
    defer if (log) |*r| r.deinit(gpa);

    rl.InitWindow(windowW(cfg.scale), windowH(cfg.scale), "zicps");
    if (!rl.IsWindowReady()) {
        // Closing a window that never opened is a segfault, so leave first.
        std.debug.print("no window (no display?); try --frames N --hash instead\n", .{});
        return error.NoDisplay;
    }
    defer rl.CloseWindow();
    rl.SetExitKey(rl.KEY_NULL); // Escape is the menu key, not the quit key

    const tex = rl.LoadTextureFromImage(fbImage(c));
    var flakes = snow.Snow{};
    var snow_px: [snow.width * snow.height]u32 = @splat(0xFF00_0000);
    const snow_tex = rl.LoadTextureFromImage(.{
        .data = &snow_px,
        .width = snow.width,
        .height = snow.height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    });

    // The stream, not the vsync, paces the loop while a game runs: no
    // SetTargetFPS, just `paceToAudio` below.
    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();
    // Without a device nothing ever drains the mixer, so the ring sits full and
    // `paceToAudio` would sleep the loop down to a crawl. Fall back to timer
    // pacing and keep the picture running.
    const has_audio = rl.IsAudioDeviceReady();
    if (!has_audio) std.debug.print("no audio device; pacing on the frame timer instead\n", .{});
    rl.SetAudioStreamBufferSizeDefault(audio_chunk_frames);
    const stream = rl.LoadAudioStream(audio.sample_rate, audio_sample_size, audio_channels);
    defer rl.UnloadAudioStream(stream);
    rl.PlayAudioStream(stream);

    // Where this set's own files go. `set.len == 0` is the idle window.
    var path_buf: [shell.max_path]u8 = undefined;
    var set: []const u8 = if (args.set.len == 0) "" else keepPath(&path_buf, args.set);
    var ui = shell.Ui{};
    if (machine.*) |*m| {
        startMachine(c, cpu, m);
        loadNv(io, c, set);
        describeBoard(&ui, m, set);
    }

    var diag = board.Diag{};
    var nv_next: f64 = 0;
    var applied_scale = cfg.scale;
    var applied_fullscreen = false;
    var target_fps: c_int = -1;
    var frames: u32 = 0;
    var quit = false;
    while (!rl.WindowShouldClose() and !quit and !cpu.halted) {
        switch (shell.update(&ui, cfg, machine.* != null)) {
            .none => {},
            .quit => quit = true,
            // The EEPROM is a battery: it survives a reset, so it goes out to
            // disk and comes back in around the machine being rebuilt. The
            // board's own service menu is what writes it, and losing that on
            // every reset would make the menu pointless.
            .reset => if (machine.*) |*m| {
                flushNv(io, c, set) catch |err| ui.status("cannot save settings: {t}", .{err});
                startMachine(c, cpu, m);
                loadNv(io, c, set);
                frames = 0;
            },
            .load => |p| {
                var next = loadSet(gpa, io, p, null, &diag) catch {
                    ui.status("{s}: {s}", .{ std.fs.path.basename(p), diag.message() });
                    continue;
                };
                flushNv(io, c, set) catch |err| ui.status("cannot save settings: {t}", .{err});
                if (machine.*) |*old| old.deinit(gpa);
                machine.* = next;
                set = keepPath(&path_buf, p);
                startMachine(c, cpu, &next);
                loadNv(io, c, set);
                describeBoard(&ui, &next, set);
                ui.status("{s}: {d} KiB program, {d} KiB graphics", .{
                    std.fs.path.basename(set),
                    next.rom.program.len >> 10,
                    next.rom.gfx.len >> 10,
                });
                frames = 0;
            },
            // Numbered by frame, so holding the key down never overwrites the
            // shot before it and the order they were taken in is the order
            // they sort in.
            .screenshot => if (machine.* != null) {
                var buf: [shell.max_path]u8 = undefined;
                const shot_path = std.fmt.bufPrintZ(&buf, "{s}.{d}.png", .{ set, frames }) catch continue;
                if (rl.ExportImage(fbImage(c), shot_path.ptr)) {
                    ui.status("wrote {s}", .{shot_path});
                } else ui.status("cannot write {s}", .{shot_path});
            },
        }
        if (ui.dirty) {
            saveConfig(io, args.config, cfg.*) catch |err| ui.status("cannot save options: {t}", .{err});
            ui.dirty = false;
        }
        if (cfg.fullscreen != applied_fullscreen) {
            rl.ToggleBorderlessWindowed();
            applied_fullscreen = cfg.fullscreen;
        }
        if (!cfg.fullscreen and cfg.scale != applied_scale) {
            rl.SetWindowSize(windowW(cfg.scale), windowH(cfg.scale));
            applied_scale = cfg.scale;
        }
        // The mixer is where the volume knob lives, so muted is volume 0.
        c.mixer.volume_pct = if (cfg.audio) cfg.volume else 0;
        if (c.eeprom.dirty and rl.GetTime() >= nv_next) {
            flushNv(io, c, set) catch |err| ui.status("cannot save settings: {t}", .{err});
            nv_next = rl.GetTime() + nv_write_seconds;
        }

        const running = machine.* != null and !ui.open and (!ui.paused or ui.step);
        if (running) {
            // A paused machine owes exactly one frame; a fast-forwarded one
            // runs several per drawn frame. Either way the recording still gets
            // one word per emulated frame, so a replay of it is a replay.
            const steps: u32 = if (ui.step) 1 else if (ui.fast) fast_forward_frames else 1;
            for (0..steps) |_| {
                c.inputs = if (replay) |r| r.at(frames) else readPanel(cfg.*);
                if (log) |*r| try record(r, gpa, c.inputs);
                scheduler.runFrame(c, cpu);
                frames += 1;
                // Drained inside the loop: the ring holds well under a
                // fast-forwarded burst, so it has to go out as it is made.
                if (has_audio) drainAudio(c, stream);
            }
            ui.step = false;
        } else {
            c.inputs = .{};
        }
        ui.pad = c.inputs.pad[0];
        ui.panel = c.inputs.panel;
        ui.six = cfg.buttons == .six;

        // Idle and paused frames have no audio to pace against, so the timer
        // takes over; a running game hands pacing back to the ring buffer.
        // Fast-forward paces on the timer too: capping the *drawn* frames at
        // the video rate is what makes it a fixed multiple of full speed rather
        // than as fast as the box happens to be.
        const want_fps: c_int = if (machine.* == null)
            snow_fps
        else if (!running)
            idle_fps
        else if (has_audio and !ui.fast)
            0
        else
            video_fps;
        if (want_fps != target_fps) {
            rl.SetTargetFPS(want_fps);
            target_fps = want_fps;
        }

        rl.BeginDrawing();
        if (machine.* != null) {
            rl.UpdateTexture(tex, &c.v.fb);
            drawPicture(tex, video.width, video.height);
            if (cfg.scanlines) shell.drawScanlines(video.height);
        } else {
            flakes.step(&snow_px);
            rl.UpdateTexture(snow_tex, &snow_px);
            drawPicture(snow_tex, snow.width, snow.height);
            if (cfg.scanlines) shell.drawScanlines(snow.height);
            shell.drawIdlePrompt();
        }
        shell.draw(&ui, cfg);
        rl.EndDrawing();

        // Nothing is reading the mixer when idle, and fast-forward is the one
        // case where outrunning the device is the point.
        if (!running or !has_audio or ui.fast) continue;
        paceToAudio(c, io);
    }

    flushNv(io, c, set) catch |err| std.debug.print("cannot save settings: {t}\n", .{err});
    if (log) |*r| try writeLog(io, args.record.?, r.items);
    if (frames != 0) {
        var sound = Sound{};
        report(c, cpu, &sound, frames);
    }
}

/// The board's refresh, rounded to whole frames a second: only the timer
/// fallback uses it, and `SetTargetFPS` takes an integer anyway.
const video_fps: c_int = @divTrunc(scheduler.refresh_num + @divTrunc(scheduler.refresh_den, 2), scheduler.refresh_den);

/// The cabinet's control panel this frame. The wiring mask is what makes a
/// three-button option real: the keys stay bound, and the machine is simply
/// never handed the three bits that have no button bolted to them.
fn readPanel(cfg: Config) cps.Inputs {
    const wiring = input.wiring(cfg.buttons == .six);
    return .{
        .pad = .{
            input.buttons(cfg.keys, 0, keyDown) & wiring,
            input.buttons(cfg.keys, 1, keyDown) & wiring,
        },
        .panel = input.panel(cfg.keys, keyDown),
    };
}

/// The window is a cabinet's glass: the picture is stretched to fill it,
/// however the window was sized. The glass is the window less the status bar.
fn drawPicture(tex: rl.Texture, w: f32, h: f32) void {
    rl.DrawTexturePro(
        tex,
        .{ .x = 0, .y = 0, .width = w, .height = h },
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(rl.GetScreenWidth()),
            .height = @floatFromInt(rl.GetScreenHeight() - shell.barHeight()),
        },
        .{ .x = 0, .y = 0 },
        0,
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
}

fn usage() void {
    std.debug.print(
        \\usage: zicps [rom-set] [options]
        \\
        \\  [rom-set]          a directory of chip images, or a zip of the same;
        \\                     with none, the window opens idle and the menu loads one
        \\  --board <path>     the board file (default: the set's path with .board)
        \\  --frames N         run N frames with no window and print a state hash
        \\  --replay <path>    drive the controls from a recorded input log
        \\  --record <path>    write every frame's controls to an input log
        \\  --hash             print a hash every frame, not only the last
        \\
    , .{});
}

const testing = std.testing;

test "an input log round-trips every bit the machine can be handed" {
    const in = cps.Inputs{
        .pad = .{ cps.Button.up.mask() | cps.Button.b6.mask(), cps.Button.left.mask() },
        .panel = cps.Panel.coin1.mask() | cps.Panel.test_switch.mask(),
    };
    try testing.expectEqual(in, unpack(pack(in)));

    // A log that runs out reads as nothing held, so a short log runs a long
    // test without a special case.
    var word: [log_frame_bytes]u8 = undefined;
    std.mem.writeInt(u32, &word, pack(in), .little);
    const r = Replay{ .log = &word };
    try testing.expectEqual(in, r.at(0));
    try testing.expectEqual(cps.Inputs{}, r.at(1));
}

test "a recording is a replay of itself" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);

    const frames = [_]cps.Inputs{
        .{ .pad = .{ cps.Button.right.mask(), 0 } },
        .{},
        .{ .pad = .{ 0, cps.Button.b3.mask() }, .panel = cps.Panel.start1.mask() },
    };
    for (frames) |in| try record(&log, testing.allocator, in);

    const r = Replay{ .log = log.items };
    for (frames, 0..) |in, i| try testing.expectEqual(in, r.at(@intCast(i)));
    try testing.expectEqual(frames.len * log_frame_bytes, log.items.len);
}

test "the board file is looked for beside the set, under the set's own name" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("sets/game.board", try beside(&buf, "sets/game.zip", ".board"));
    try testing.expectEqualStrings("sets/game.board", try beside(&buf, "sets/game", ".board"));
    // A dot in a directory on the way there is not the set's extension.
    try testing.expectEqualStrings("my.sets/game.board", try beside(&buf, "my.sets/game", ".board"));
}

test "a set named with a trailing slash still finds its board file" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("sets/game.board", try beside(&buf, "sets/game/", ".board"));
}

test "the settings sidecar adds its extension rather than replacing one" {
    // A directory set and a zip of the same name are two different sets, and
    // two boards: they must not share a battery.
    var buf: [shell.max_path]u8 = undefined;
    try testing.expectEqualStrings("sets/game.zip.nv", try nvPath(&buf, "sets/game.zip"));
    try testing.expectEqualStrings("sets/game.nv", try nvPath(&buf, "sets/game"));
}

test "the program sum is a reading of every byte, in order" {
    try testing.expectEqual(@as(u16, 0), programSum(&.{}));
    try testing.expectEqual(@as(u16, 0x01ff), programSum(&(.{0xff} ** 2 ++ .{1})));
    // Wide enough that a megabyte of ROM cannot wrap it into an accident, and
    // order-independent by construction, which is what makes it comparable
    // across two people's dumps and useless as a check on anything else.
    try testing.expectEqual(programSum(&.{ 1, 2, 3 }), programSum(&.{ 3, 2, 1 }));
}

test "the drawn frame rate falls back to the board's own refresh" {
    // 59.6374 Hz, and the timer takes an integer.
    try testing.expectEqual(@as(c_int, 60), video_fps);
}

test "unplugging three buttons narrows what the machine is handed" {
    // The keys stay bound either way: it is the wiring mask that is the option,
    // which is why the panel's holes and the machine's word cannot disagree.
    const six = input.wiring(true);
    const three = input.wiring(false);
    try testing.expectEqual(six, three | cps.Button.b4.mask() | cps.Button.b5.mask() | cps.Button.b6.mask());
    try testing.expectEqual(@as(u16, 0), three & cps.Button.b6.mask());
    try testing.expect(three & cps.Button.b3.mask() != 0);
}
