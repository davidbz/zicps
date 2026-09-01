//! The program: the window and the frame loop, with the headless runner still
//! under it. `--frames N` renders with no window, hashes the machine and
//! exits; that is the backbone of testing rather than a debug feature, which
//! is why it was the first thing that existed and has to keep working forever.
//!
//! This and `ui/shell.zig` are the only files allowed to reach raylib, and the
//! build graph is what enforces that rather than anyone remembering.

const std = @import("std");
const board = @import("board");
const romset = @import("romset");
const emu = @import("machine");
const controls = @import("controls");
const eeprom = @import("eeprom");
const clock = @import("clock");
const video = @import("video");
const audio = @import("audio");
const input = @import("input");
const config = @import("config");
const snow = @import("snow");
const boards = @import("boards");
const shell = @import("shell");

const rl = @cImport(@cInclude("raylib.h"));

const Config = config.Config;
/// The set that is in the board, which is not the machine running it: this one
/// is the two files the user handed over, and `emu.Machine` is the hardware.
const Machine = boards.Machine;

/// A replay log is one word per frame.
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
const log_pad2_shift = controls.button_count;
const log_panel_shift = 2 * controls.button_count;

fn pack(in: controls.Inputs) u32 {
    return @as(u32, in.pad[0]) |
        @as(u32, in.pad[1]) << log_pad2_shift |
        @as(u32, in.panel) << log_panel_shift;
}

fn unpack(word: u32) controls.Inputs {
    const pad_mask = (@as(u32, 1) << controls.button_count) - 1;
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

    fn at(r: Replay, frame: u32) controls.Inputs {
        const offset = @as(usize, frame) * log_frame_bytes;
        if (offset + log_frame_bytes > r.log.len) return .{};
        return unpack(std.mem.readInt(u32, r.log[offset..][0..log_frame_bytes], .little));
    }
};

fn record(r: *std.ArrayList(u8), gpa: std.mem.Allocator, in: controls.Inputs) !void {
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

/// The half of a load failure that only the command line can print: what a
/// board file is for, which is not obvious the first time zicps refuses to
/// start. The menu says the same thing with less room, so it says less.
fn explainBoard() void {
    std.debug.print(
        \\A CPS-1.5 board keeps its configuration in battery-backed RAM, so zicps needs
        \\a board file describing this board before it can run the set. One ships for every
        \\set MAME names, under boards/, and is found by the set's own name; a file beside
        \\the set or --board wins over it.
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
    // the stack, and allocated exactly once whatever set goes in it. Which arm
    // of it is live is the board file's business, so it starts as the empty
    // CPS-1 the idle window draws snow over.
    const c = try gpa.create(emu.Machine);
    defer gpa.destroy(c);
    c.start(.{}, .empty);

    var diag = board.Diag{};
    var machine: ?Machine = null;
    defer if (machine) |*m| m.deinit(gpa);
    if (o.set.len != 0) {
        machine = boards.loadSet(gpa, io, o.set, o.board, &diag) catch {
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
        startMachine(c, m);
        return headless(io, gpa, c, n, o.replay, o.record, o.every_frame);
    }

    const cfg_path = try configPath(gpa, init.environ_map);
    defer gpa.free(cfg_path);
    var cfg = loadConfig(io, gpa, cfg_path);

    try windowed(io, gpa, c, &cfg, &machine, .{
        .config = cfg_path,
        .set = o.set,
        .board = o.board,
        .replay = o.replay,
        .record = o.record,
    });
}

/// The options file. Nothing there yet writes the defaults out, so there is a
/// file to hand-edit without having to change something in the menu first.
fn loadConfig(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes)) catch {
        saveConfig(io, path, .{}) catch |err| std.debug.print("cannot write {s}: {t}\n", .{ path, err });
        return .{};
    };
    defer gpa.free(text);
    return Config.parse(text);
}

/// Power-on, and also what the Reset menu entry does: every chip back to its
/// reset state with the same set in the board. Not the 68000's reset line —
/// that would keep work RAM, and this is a cabinet being switched off.
///
/// The EEPROM does not survive this, because it is a battery, not a chip: the
/// caller writes it out and reads it back around the call (`flushNv`).
fn startMachine(c: *emu.Machine, m: *const Machine) void {
    c.start(m.b, m.rom);
}

// ------------------------------------------------------------------ headless

fn headless(
    io: std.Io,
    gpa: std.mem.Allocator,
    c: *emu.Machine,
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
    const inputs = c.part("inputs");
    while (frame < n and !c.cpu().halted) : (frame += 1) {
        if (replay) |r| inputs.* = r.at(frame);
        if (log) |*r| try record(r, gpa, inputs.*);
        c.runFrame();
        sound.drain(c.part("mixer"));
        if (every_frame) report(c, &sound, frame + 1);
    }
    if (!every_frame) report(c, &sound, frame);
    if (log) |*r| try writeLog(io, record_path.?, r.items);

    const cpu = c.cpu();
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
    /// The loudest it got, which is the difference between a machine that is
    /// playing and one that is running its driver into a chip nobody wired up.
    peak: u32 = 0,

    fn drain(s: *Sound, m: *audio.Mixer) void {
        while (m.pop()) |f| : (s.frames += 1) {
            s.h.update(std.mem.asBytes(&f));
            s.peak = @max(s.peak, @max(@abs(@as(i32, f.l)), @abs(@as(i32, f.r))));
        }
    }
};

fn report(c: *emu.Machine, sound: *const Sound, frame: u32) void {
    // A copy, because finishing the hash consumes it and the run goes on.
    var h = sound.h;
    std.debug.print("frame {d} hash={x:0>16} audio={x:0>16} samples={d} peak={d}\n", .{
        frame,
        c.hash(),
        h.final(),
        sound.frames,
        sound.peak,
    });
}

// ------------------------------------------------------------------- files

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

/// The EEPROM sidecar: `game.zip.nv` beside the set, with
/// the extension *added* rather than replaced, so a directory set and a zip of
/// the same name keep their own settings.
fn nvPath(buf: []u8, set: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.nv", .{set});
}

/// Read once when the set goes in. A short or missing file leaves the chip
/// erased, which is what an unused battery reads as and what sends the board
/// into its own service menu to be set up.
fn loadNv(io: std.Io, c: *emu.Machine, set: []const u8) void {
    var buf: [shell.max_path]u8 = undefined;
    const path = nvPath(&buf, set) catch return;
    var bytes: [eeprom.bytes]u8 = @splat(0xff);
    const read = std.Io.Dir.cwd().readFile(io, path, &bytes) catch return;
    c.part("eeprom").load(read);
}

fn flushNv(io: std.Io, c: *emu.Machine, set: []const u8) !void {
    const chip = c.part("eeprom");
    if (!chip.dirty) return;
    var buf: [shell.max_path]u8 = undefined;
    const path = try nvPath(&buf, set);
    var bytes: [eeprom.bytes]u8 = undefined;
    chip.save(&bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &bytes });
    chip.dirty = false;
}

// -------------------------------------------------------------- save states

/// `game.zip.st3` beside the set, the extension added rather than replaced for
/// the same reason `nvPath` adds it. The quicksave is lettered rather than
/// numbered, so the key that writes it can never land on a slot the user
/// filled by hand.
fn statePath(buf: []u8, set: []const u8, slot: usize) ![]const u8 {
    if (slot == shell.quick_slot) return std.fmt.bufPrint(buf, "{s}.stq", .{set});
    return std.fmt.bufPrint(buf, "{s}.st{d}", .{ set, slot + 1 });
}

fn saveState(w: *Window, slot: usize) void {
    var path_buf: [shell.max_path]u8 = undefined;
    const path = statePath(&path_buf, w.set, slot) catch return;
    // A state is the machine's own size, which is far more than a stack frame.
    const buf = w.gpa.create([emu.Machine.max_state_bytes]u8) catch |err| return w.ui.status("{t}", .{err});
    defer w.gpa.destroy(buf);

    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = path, .data = w.c.save(buf) }) catch |err| {
        return w.ui.status("cannot write {s}: {t}", .{ path, err });
    };

    var name: [shell.max_slot_name]u8 = undefined;
    w.ui.status("saved {s}", .{shell.slotLabel(slot, &name)});
    if (slot == shell.quick_slot) shell.quicksaved(&w.ui);
    w.ui.slots_stale = true;
}

fn loadState(w: *Window, slot: usize) void {
    var path_buf: [shell.max_path]u8 = undefined;
    const path = statePath(&path_buf, w.set, slot) catch return;
    var name: [shell.max_slot_name]u8 = undefined;
    const slot_name = shell.slotLabel(slot, &name);

    const buf = std.Io.Dir.cwd().readFileAlloc(w.io, path, w.gpa, emu.Machine.state_limit) catch |err| {
        return w.ui.status("{s}: {t}", .{ slot_name, err });
    };
    defer w.gpa.free(buf);
    // A state from another build is refused here rather than loaded as
    // garbage, and the machine that was running is still running.
    w.c.load(buf) catch |err| return w.ui.status("{s}: {t}", .{ slot_name, err });
    w.ui.status("loaded {s}", .{slot_name});
}

/// The ages the slot list reads out. Statted when the page opens and when a
/// state is written, not every frame: nine syscalls a frame for a list that
/// changes twice a session is the kind of thing a profile finds later.
fn refreshSlots(w: *Window) void {
    if (!w.ui.slots_stale) return;
    w.ui.slots_stale = false;
    const now = std.Io.Timestamp.now(w.io, .real).toSeconds();
    for (0..shell.state_slots) |slot| {
        var path_buf: [shell.max_path]u8 = undefined;
        var age_buf: [shell.max_slot_age]u8 = undefined;
        const path = statePath(&path_buf, w.set, slot) catch continue;
        const stat = std.Io.Dir.cwd().statFile(w.io, path, .{}) catch {
            shell.slotRow(&w.ui, slot, null);
            continue;
        };
        shell.slotRow(&w.ui, slot, shell.ago(&age_buf, now - stat.mtime.toSeconds()));
    }
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
/// comparing dumps can say so in one line.
fn programSum(program: []const u8) u16 {
    var sum: u16 = 0;
    for (program) |byte| sum +%= byte;
    return sum;
}

/// One region's row on the card. A CPS-1.5 always has all four, but a board
/// file can describe a set that is missing one, and a row saying so is how
/// that shows up rather than a crash.
fn romRow(ui: *shell.Ui, name: []const u8, count: usize, bytes: usize) void {
    if (bytes == 0) return shell.cardRow(ui, name, .bad, "NONE", .{});
    shell.cardRow(ui, name, .plain, "{d} ROMs / {d} KiB", .{ count, bytes >> 10 });
}

/// The card the menu shows beside itself: what the set and the board file
/// turned out to say, all of it read out of the two files the user supplied.
/// Built when the set goes in, because none of it changes while the game plays.
fn describeBoard(ui: *shell.Ui, m: *const Machine, set: []const u8, suicided: bool) void {
    shell.cardStart(ui, std.fs.path.basename(set), m.from());

    var regions = std.EnumArray(board.Region, usize).initFill(0);
    for (m.b.romList()) |rom| regions.getPtr(rom.region).* += 1;

    romRow(ui, "PROGRAM", regions.get(.program), m.rom.program.len);
    romRow(ui, "GRAPHICS", regions.get(.gfx), m.rom.gfx.len);
    romRow(ui, "SOUND", regions.get(.audio), m.rom.audio.len);
    // The samples say which sound board this is, so the row names it: a QSound
    // set has a DL-1425 sample ROM and a plain CPS-1 one has the M6295's.
    const plain = m.b.sound() == .cps1;
    if (plain)
        romRow(ui, "ADPCM", regions.get(.oki), m.rom.oki.len)
    else
        romRow(ui, "SAMPLES", regions.get(.qsound), m.rom.qsound.len);
    // The Kabuki key is the one thing in the board file that is a secret
    // rather than a setting: without it the Z80 runs garbage and the cabinet
    // is silent, so whether there is one is worth a line of its own. Only a
    // QSound board has one to be missing.
    if (!plain and m.b.system == .cps1) shell.cardRow(ui, "KABUKI", if (m.b.kabuki == null) .bad else .good, "{s}", .{
        if (m.b.kabuki == null) "NO KEY" else "KEY SET",
    });
    // A CPS-2 board's key is in the set rather than the board file, and a board
    // whose battery went flat reads back as one that says nothing. It still
    // runs — on its own ciphertext, into a self-test that fails — so this is a
    // line on the card and not a refusal.
    if (m.b.system == .cps2) shell.cardRow(ui, "KEY", if (suicided) .bad else .good, "{s}", .{
        if (suicided) "SUICIDED BOARD" else "DECRYPTED",
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
fn drainAudio(c: *emu.Machine, stream: rl.AudioStream) void {
    const mixer = c.part("mixer");
    while (mixer.ready() >= audio_chunk_frames and rl.IsAudioStreamProcessed(stream)) {
        var pcm: [audio_chunk_frames]audio.Frame = undefined;
        for (&pcm) |*frame| frame.* = mixer.pop().?;
        rl.UpdateAudioStream(stream, &pcm, pcm.len);
    }
}

/// Sleeps off the surplus once the mixer is further ahead of playback than the
/// target; being behind returns immediately, so the emulator catches up on its
/// own without ever needing to skip a frame.
fn paceToAudio(c: *emu.Machine, io: std.Io) void {
    const ready = c.part("mixer").ready();
    if (ready <= audio_target_frames) return;
    const surplus_ms = (ready - audio_target_frames) * std.time.ms_per_s / audio.sample_rate;
    io.sleep(.fromMilliseconds(@intCast(surplus_ms)), .awake) catch {};
}

fn fbImage(c: *emu.Machine) rl.Image {
    return .{
        .data = &c.part("v").fb,
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

/// Everything the frame loop carries from one iteration to the next. The loop
/// is a handful of named steps rather than one long body, and each step takes
/// this instead of a dozen out-parameters.
///
/// `set` points into `path_buf`, so this lives where it is made and only ever
/// travels by pointer.
const Window = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    c: *emu.Machine,
    cfg: *Config,
    machine: *?Machine,
    args: WindowedArgs,

    replay: ?Replay,
    log: ?std.ArrayList(u8),
    has_audio: bool,
    stream: rl.AudioStream,
    tex: rl.Texture,
    snow_tex: rl.Texture,

    ui: shell.Ui = .{},
    diag: board.Diag = .{},
    flakes: snow.Snow = .{},
    snow_px: [snow.width * snow.height]u32 = @splat(0xFF00_0000),
    path_buf: [shell.max_path]u8 = undefined,
    set: []const u8 = "",
    frames: u32 = 0,
    quit: bool = false,
    nv_next: f64 = 0,
    applied_scale: u8 = 0,
    applied_fullscreen: bool = false,
    target_fps: c_int = -1,
};

/// The window, the frame loop and the shell: idle snow with no set, the
/// picture with one, and the menu over either.
fn windowed(
    io: std.Io,
    gpa: std.mem.Allocator,
    c: *emu.Machine,
    cfg: *Config,
    machine: *?Machine,
    args: WindowedArgs,
) !void {
    const replay: ?Replay = if (args.replay) |p| .{
        .log = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)),
    } else null;
    defer if (replay) |r| gpa.free(r.log);

    try openWindow(cfg);
    defer rl.CloseWindow();

    // The stream, not the vsync, paces the loop while a game runs: no
    // SetTargetFPS, just `paceToAudio`. Without a device nothing ever drains
    // the mixer, so the ring sits full and `paceToAudio` would sleep the loop
    // down to a crawl. Fall back to timer pacing and keep the picture running.
    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();
    const has_audio = rl.IsAudioDeviceReady();
    if (!has_audio) std.debug.print("no audio device; pacing on the frame timer instead\n", .{});
    rl.SetAudioStreamBufferSizeDefault(audio_chunk_frames);
    const stream = rl.LoadAudioStream(audio.sample_rate, audio_sample_size, audio_channels);
    defer rl.UnloadAudioStream(stream);
    rl.PlayAudioStream(stream);

    var w = Window{
        .io = io,
        .gpa = gpa,
        .c = c,
        .cfg = cfg,
        .machine = machine,
        .args = args,
        .replay = replay,
        .log = if (args.record == null) null else .empty,
        .has_audio = has_audio,
        .stream = stream,
        .tex = rl.LoadTextureFromImage(fbImage(c)),
        .snow_tex = undefined,
        .applied_scale = cfg.scale,
    };
    defer if (w.log) |*r| r.deinit(gpa);
    w.snow_tex = rl.LoadTextureFromImage(.{
        .data = &w.snow_px,
        .width = snow.width,
        .height = snow.height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    });

    // Where this set's own files go. `set.len == 0` is the idle window.
    if (args.set.len != 0) w.set = keepPath(&w.path_buf, args.set);
    if (machine.*) |*m| {
        remember(cfg, &w.ui, w.set);
        startMachine(c, m);
        loadNv(io, c, w.set);
        describeBoard(&w.ui, m, w.set, c.suicided());
    }

    try runLoop(&w);
    try closeOut(&w);
}

/// The window itself, or nothing: closing one that never opened is a segfault,
/// so a display that is not there is left rather than carried on with.
fn openWindow(cfg: *const Config) !void {
    rl.InitWindow(windowW(cfg.scale), windowH(cfg.scale), "zicps");
    if (!rl.IsWindowReady()) {
        std.debug.print("no window (no display?); try --frames N --hash instead\n", .{});
        return error.NoDisplay;
    }
    rl.SetExitKey(rl.KEY_NULL); // Escape is the menu key, not the quit key
}

/// One drawn frame a turn: what the shell asked for, what the machine ran of
/// it, and what is drawn of that.
fn runLoop(w: *Window) !void {
    while (!rl.WindowShouldClose() and !w.quit and !w.c.cpu().halted) {
        try serveRequest(w);
        refreshSlots(w);
        applyOptions(w);
        const running = try stepFrames(w);
        paceDrawing(w, running);
        drawFrame(w);
        // Nothing is reading the mixer when idle, and fast-forward is the one
        // case where outrunning the device is the point.
        if (running and w.has_audio and !w.ui.fast) paceToAudio(w.c, w.io);
    }
}

/// The battery, the replay log and the run's own summary: what a window leaves
/// behind on the way out.
fn closeOut(w: *Window) !void {
    flushNv(w.io, w.c, w.set) catch |err| std.debug.print("cannot save settings: {t}\n", .{err});
    if (w.log) |*r| try writeLog(w.io, w.args.record.?, r.items);
    if (w.frames == 0) return;
    var sound = Sound{};
    report(w.c, &sound, w.frames);
}

/// Whatever the shell asked for this frame.
fn serveRequest(w: *Window) !void {
    switch (shell.update(&w.ui, w.cfg, w.machine.* != null)) {
        .none => {},
        .quit => w.quit = true,
        // The EEPROM is a battery: it survives a reset, so it goes out to disk
        // and comes back in around the machine being rebuilt. The board's own
        // service menu is what writes it, and losing that on every reset would
        // make the menu pointless.
        .reset => if (w.machine.*) |*m| {
            saveNv(w);
            startMachine(w.c, m);
            loadNv(w.io, w.c, w.set);
            w.frames = 0;
        },
        .load => |p| loadIntoWindow(w, p),
        // Gated on a set being in the way `.reset` is: with no machine there is
        // nothing to write down, and `w.set` is the empty string, so a state
        // would land on a file named after nothing.
        .save_state => |slot| if (w.machine.* != null) saveState(w, slot),
        .load_state => |slot| if (w.machine.* != null) loadState(w, slot),
        // Numbered by frame, so holding the key down never overwrites the shot
        // before it and the order they were taken in is the order they sort in.
        .screenshot => if (w.machine.* != null) {
            var buf: [shell.max_path]u8 = undefined;
            const shot_path = std.fmt.bufPrintZ(&buf, "{s}.{d}.png", .{ w.set, w.frames }) catch return;
            if (rl.ExportImage(fbImage(w.c), shot_path.ptr)) {
                w.ui.status("wrote {s}", .{shot_path});
            } else w.ui.status("cannot write {s}", .{shot_path});
        },
    }
}

/// Swaps the running machine for the set at `path`. A set that will not load
/// says so in the status line and leaves the old one running.
fn loadIntoWindow(w: *Window, path: []const u8) void {
    var next = boards.loadSet(w.gpa, w.io, path, null, &w.diag) catch {
        w.ui.status("{s}: {s}", .{ std.fs.path.basename(path), w.diag.message() });
        return;
    };
    saveNv(w);
    if (w.machine.*) |*old| old.deinit(w.gpa);
    w.machine.* = next;
    w.set = keepPath(&w.path_buf, path);
    remember(w.cfg, &w.ui, w.set);
    startMachine(w.c, &next);
    loadNv(w.io, w.c, w.set);
    describeBoard(&w.ui, &next, w.set, w.c.suicided());
    w.ui.status("{s}: {d} KiB program, {d} KiB graphics", .{
        std.fs.path.basename(w.set),
        next.rom.program.len >> 10,
        next.rom.gfx.len >> 10,
    });
    w.frames = 0;
}

/// A set that loaded goes on the recent list, which lives in the options file:
/// marking the config dirty is what gets it written, the same as a menu toggle.
fn remember(cfg: *Config, ui: *shell.Ui, path: []const u8) void {
    cfg.remember(path);
    ui.dirty = true;
}

fn saveNv(w: *Window) void {
    flushNv(w.io, w.c, w.set) catch |err| w.ui.status("cannot save settings: {t}", .{err});
}

/// What the menu changed since last frame, applied to the window, the mixer
/// and the two files this program writes.
fn applyOptions(w: *Window) void {
    if (w.ui.dirty) {
        saveConfig(w.io, w.args.config, w.cfg.*) catch |err| w.ui.status("cannot save options: {t}", .{err});
        w.ui.dirty = false;
    }
    if (w.cfg.fullscreen != w.applied_fullscreen) {
        rl.ToggleBorderlessWindowed();
        w.applied_fullscreen = w.cfg.fullscreen;
    }
    if (!w.cfg.fullscreen and w.cfg.scale != w.applied_scale) {
        rl.SetWindowSize(windowW(w.cfg.scale), windowH(w.cfg.scale));
        w.applied_scale = w.cfg.scale;
    }
    // The mixer is where the volume knob lives, so muted is volume 0.
    w.c.part("mixer").volume_pct = if (w.cfg.audio) w.cfg.volume else 0;
    if (w.c.part("eeprom").dirty and rl.GetTime() >= w.nv_next) {
        saveNv(w);
        w.nv_next = rl.GetTime() + nv_write_seconds;
    }
}

/// Runs the machine for as long as this drawn frame is worth, and answers
/// whether it ran at all.
fn stepFrames(w: *Window) !bool {
    // Whatever the panel ended the frame holding is what the menu draws lit,
    // whether the machine ran or not.
    defer {
        w.ui.pad = w.c.part("inputs").pad[0];
        w.ui.panel = w.c.part("inputs").panel;
        w.ui.six = w.cfg.buttons == .six;
    }

    const running = w.machine.* != null and !w.ui.open and (!w.ui.paused or w.ui.step);
    if (!running) {
        w.c.part("inputs").* = .{};
        return false;
    }

    // A paused machine owes exactly one frame; a fast-forwarded one runs
    // several per drawn frame. Either way the recording still gets one word
    // per emulated frame, so a replay of it is a replay.
    const steps: u32 = if (w.ui.step or !w.ui.fast) 1 else fast_forward_frames;
    for (0..steps) |_| {
        w.c.part("inputs").* = if (w.replay) |r| r.at(w.frames) else readPanel(w.cfg.*);
        if (w.log) |*r| try record(r, w.gpa, w.c.part("inputs").*);
        w.c.runFrame();
        w.frames += 1;
        // Drained inside the loop: the ring holds well under a
        // fast-forwarded burst, so it has to go out as it is made.
        if (w.has_audio) drainAudio(w.c, w.stream);
    }
    w.ui.step = false;
    return true;
}

/// Idle and paused frames have no audio to pace against, so the timer takes
/// over; a running game hands pacing back to the ring buffer. Fast-forward
/// paces on the timer too: capping the *drawn* frames at the video rate is what
/// makes it a fixed multiple of full speed rather than as fast as the box
/// happens to be.
fn paceDrawing(w: *Window, running: bool) void {
    const want_fps: c_int = if (w.machine.* == null)
        snow_fps
    else if (!running)
        idle_fps
    else if (w.has_audio and !w.ui.fast)
        0
    else
        video_fps;
    if (want_fps == w.target_fps) return;
    rl.SetTargetFPS(want_fps);
    w.target_fps = want_fps;
}

fn drawFrame(w: *Window) void {
    rl.BeginDrawing();
    if (w.machine.* != null) {
        rl.UpdateTexture(w.tex, &w.c.part("v").fb);
        drawPicture(w.tex, video.width, video.height);
        if (w.cfg.scanlines) shell.drawScanlines(video.height);
    } else {
        w.flakes.step(&w.snow_px);
        rl.UpdateTexture(w.snow_tex, &w.snow_px);
        drawPicture(w.snow_tex, snow.width, snow.height);
        if (w.cfg.scanlines) shell.drawScanlines(snow.height);
        shell.drawIdlePrompt();
    }
    shell.draw(&w.ui, w.cfg);
    rl.EndDrawing();
}

/// The board's refresh, rounded to whole frames a second: only the timer
/// fallback uses it, and `SetTargetFPS` takes an integer anyway.
const video_fps: c_int = @divTrunc(clock.refresh_num + @divTrunc(clock.refresh_den, 2), clock.refresh_den);

/// The cabinet's control panel this frame. The wiring mask is what makes a
/// three-button option real: the keys stay bound, and the machine is simply
/// never handed the three bits that have no button bolted to them.
fn readPanel(cfg: Config) controls.Inputs {
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
    const in = controls.Inputs{
        .pad = .{ controls.Button.up.mask() | controls.Button.b6.mask(), controls.Button.left.mask() },
        .panel = controls.Panel.coin1.mask() | controls.Panel.test_switch.mask(),
    };
    try testing.expectEqual(in, unpack(pack(in)));

    // A log that runs out reads as nothing held, so a short log runs a long
    // test without a special case.
    var word: [log_frame_bytes]u8 = undefined;
    std.mem.writeInt(u32, &word, pack(in), .little);
    const r = Replay{ .log = &word };
    try testing.expectEqual(in, r.at(0));
    try testing.expectEqual(controls.Inputs{}, r.at(1));
}

test "a recording is a replay of itself" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);

    const frames = [_]controls.Inputs{
        .{ .pad = .{ controls.Button.right.mask(), 0 } },
        .{},
        .{ .pad = .{ 0, controls.Button.b3.mask() }, .panel = controls.Panel.start1.mask() },
    };
    for (frames) |in| try record(&log, testing.allocator, in);

    const r = Replay{ .log = log.items };
    for (frames, 0..) |in, i| try testing.expectEqual(in, r.at(@intCast(i)));
    try testing.expectEqual(frames.len * log_frame_bytes, log.items.len);
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
    try testing.expectEqual(six, three | controls.Button.b4.mask() | controls.Button.b5.mask() | controls.Button.b6.mask());
    try testing.expectEqual(@as(u16, 0), three & controls.Button.b6.mask());
    try testing.expect(three & controls.Button.b3.mask() != 0);
}
