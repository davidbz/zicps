//! Options persistence: a plain `key = value` text file, read at
//! startup and rewritten whenever the menu changes something. The board file
//! is written in this same format, and for the opposite reason: settings
//! can fall back to a default, a board cannot.
//!
//! Unknown keys are ignored and out-of-range values are clamped, so a
//! hand-edited file can be wrong without being fatal. A file whose `version` is
//! not ours is ignored whole: this is settings, and defaults are a fine answer.

const std = @import("std");
const input = @import("input");

pub const version = 1;

pub const min_scale = 1;
pub const max_scale = 4;
pub const max_volume = 100;

/// How the cabinet's control panel is wired. Not something the battery holds
/// and not something a ROM says: it is what is bolted to the panel, so
/// it is an option like the window scale is.
pub const Buttons = enum { three, six };

/// How many sets the menu remembers, and how much of a path it keeps. Eight is
/// what fits on a screen without scrolling; a set buried deeper than 256 bytes
/// of path is one the browser can still reach.
pub const max_recent = 8;
pub const max_recent_path = 256;

pub const Config = struct {
    scale: u8 = 3,
    fullscreen: bool = false,
    scanlines: bool = false,
    audio: bool = true,
    volume: u8 = 100,
    buttons: Buttons = .six,
    keys: input.Bindings = input.defaults,
    /// The sets loaded lately, most recent first, each a path and a zero. A
    /// slot that starts with a zero is the end of the list: the menu is not
    /// asked to hold gaps.
    recent: [max_recent][max_recent_path]u8 = @splat(@splat(0)),

    pub fn parse(text: []const u8) Config {
        var cfg = Config{};
        var seen_version = false;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "version")) {
                if (!std.mem.eql(u8, val, std.fmt.comptimePrint("{d}", .{version}))) return .{};
                seen_version = true;
            } else if (std.mem.eql(u8, key, "scale")) {
                cfg.scale = std.math.clamp(parseInt(u8, val) orelse cfg.scale, min_scale, max_scale);
            } else if (std.mem.eql(u8, key, "fullscreen")) {
                cfg.fullscreen = parseBool(val) orelse cfg.fullscreen;
            } else if (std.mem.eql(u8, key, "scanlines")) {
                cfg.scanlines = parseBool(val) orelse cfg.scanlines;
            } else if (std.mem.eql(u8, key, "audio")) {
                cfg.audio = parseBool(val) orelse cfg.audio;
            } else if (std.mem.eql(u8, key, "volume")) {
                cfg.volume = @min(max_volume, parseInt(u8, val) orelse cfg.volume);
            } else if (std.mem.eql(u8, key, "buttons")) {
                cfg.buttons = std.meta.stringToEnum(Buttons, val) orelse cfg.buttons;
            } else if (std.mem.eql(u8, key, "recent")) {
                // The file is written most-recent-first, so it is read in
                // order into the next free slot and nothing is moved.
                const at = cfg.recentCount();
                if (at < max_recent and val.len != 0 and val.len < max_recent_path) set(&cfg.recent[at], val);
            } else if (std.mem.startsWith(u8, key, "key.")) {
                const action = std.meta.stringToEnum(input.Action, key["key.".len..]) orelse continue;
                cfg.keys[@intFromEnum(action)] = input.keyCode(val) orelse continue;
            }
        }
        // A file without a version line is from nowhere we know.
        return if (seen_version) cfg else .{};
    }

    pub fn write(cfg: Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("# zicps options\nversion = {d}\n", .{version});
        try w.print("scale = {d}\n", .{cfg.scale});
        try w.print("fullscreen = {}\n", .{cfg.fullscreen});
        try w.print("scanlines = {}\n", .{cfg.scanlines});
        try w.print("audio = {}\n", .{cfg.audio});
        try w.print("volume = {d}\n", .{cfg.volume});
        try w.print("buttons = {t}\n", .{cfg.buttons});
        for (0..cfg.recentCount()) |i| {
            try w.print("recent = {s}\n", .{cfg.recentAt(i)});
        }
        var buf: [input.max_key_name]u8 = undefined;
        for (std.enums.values(input.Action)) |action| {
            const key = cfg.keys[@intFromEnum(action)];
            try w.print("key.{s} = {s}\n", .{ @tagName(action), input.keyName(key, &buf) });
        }
    }

    /// How many of the slots are filled, which is the first empty one.
    pub fn recentCount(cfg: *const Config) usize {
        for (&cfg.recent, 0..) |*slot, i| {
            if (slot[0] == 0) return i;
        }
        return max_recent;
    }

    pub fn recentAt(cfg: *const Config, i: usize) []const u8 {
        return std.mem.sliceTo(&cfg.recent[i], 0);
    }

    /// A set just loaded: it goes to the front, and the one copy of it that
    /// might already be further down goes away. A path too long to keep is
    /// dropped rather than cut, because half a path is a path to nowhere.
    pub fn remember(cfg: *Config, path: []const u8) void {
        if (path.len == 0 or path.len >= max_recent_path) return;
        // Where it already was, so it moves rather than doubles; otherwise the
        // last slot, which is the one that falls off the end.
        var i = cfg.indexOfRecent(path) orelse @min(cfg.recentCount(), max_recent - 1);
        while (i > 0) : (i -= 1) cfg.recent[i] = cfg.recent[i - 1];
        set(&cfg.recent[0], path);
    }

    fn indexOfRecent(cfg: *const Config, path: []const u8) ?usize {
        for (0..cfg.recentCount()) |i| {
            if (std.mem.eql(u8, cfg.recentAt(i), path)) return i;
        }
        return null;
    }
};

/// A slot holds a path and then zeroes: the tail is cleared as well as the
/// path written, so a short path landing on a long one leaves nothing behind.
fn set(slot: *[max_recent_path]u8, path: []const u8) void {
    slot.* = @splat(0);
    @memcpy(slot[0..path.len], path);
}

fn parseInt(comptime T: type, val: []const u8) ?T {
    return std.fmt.parseInt(T, val, 10) catch null;
}

fn parseBool(val: []const u8) ?bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return null;
}

const testing = std.testing;

test "a written config parses back identical" {
    var cfg = Config{ .scale = 2, .fullscreen = true, .scanlines = true, .audio = false, .volume = 42, .buttons = .three };
    cfg.keys[@intFromEnum(input.Action.start1)] = 'Q';
    cfg.keys[@intFromEnum(input.Action.menu)] = 348; // unnamed: goes out as a number

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.write(&w);
    try testing.expectEqual(cfg, Config.parse(w.buffered()));
}

test "junk and out-of-range values fall back instead of failing" {
    const cfg = Config.parse(
        \\# comment
        \\version = 1
        \\scale = 99
        \\volume = not-a-number
        \\nonsense = 3
        \\key.p1_up = F1
    );
    try testing.expectEqual(@as(u8, max_scale), cfg.scale);
    try testing.expectEqual(@as(u8, max_volume), cfg.volume);
    try testing.expectEqual(input.keyCode("F1").?, cfg.keys[@intFromEnum(input.Action.p1_up)]);
}

test "a set loaded again moves to the front instead of doubling" {
    var cfg = Config{};
    for ([_][]const u8{ "a.zip", "b.zip", "c.zip" }) |path| cfg.remember(path);
    try testing.expectEqual(@as(usize, 3), cfg.recentCount());
    try testing.expectEqualStrings("c.zip", cfg.recentAt(0));
    try testing.expectEqualStrings("a.zip", cfg.recentAt(2));

    cfg.remember("a.zip");
    try testing.expectEqual(@as(usize, 3), cfg.recentCount());
    try testing.expectEqualStrings("a.zip", cfg.recentAt(0));
    try testing.expectEqualStrings("b.zip", cfg.recentAt(2));

    // Past the end, the oldest falls off and the list stops growing.
    var buf: [8]u8 = undefined;
    for (0..max_recent + 4) |i| cfg.remember(try std.fmt.bufPrint(&buf, "s{d}.zip", .{i}));
    try testing.expectEqual(@as(usize, max_recent), cfg.recentCount());
    try testing.expectEqualStrings("s11.zip", cfg.recentAt(0));
    try testing.expectEqualStrings("s4.zip", cfg.recentAt(max_recent - 1));

    // And it survives a round trip in the same order it was in.
    var text: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try cfg.write(&w);
    try testing.expectEqual(cfg, Config.parse(w.buffered()));
}

test "a foreign or unversioned file is ignored whole" {
    try testing.expectEqual(Config{}, Config.parse("version = 99\nscale = 1\n"));
    try testing.expectEqual(Config{}, Config.parse("scale = 1\n"));
}
