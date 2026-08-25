//! The control panel and key bindings: which host key drives which machine
//! input and which emulator hotkey.
//!
//! The key codes are raylib's, which are GLFW's, which are ASCII for the
//! printable keys — but nothing here calls raylib, and the build graph makes
//! sure it cannot. `main.zig` is the only file that asks a keyboard anything;
//! this one only says what an answer means. The name table is what makes the
//! config file human-editable: a binding is written as `UP` or `F11`, not as
//! 265 or 300.

const std = @import("std");
const cps = @import("cps");

/// Everything a key can be bound to. Both players' buttons come first, each in
/// `cps.Button` order so `padMask` is a shift rather than a switch, then the
/// panel inputs in `cps.Panel` order, then the hotkeys.
pub const Action = enum {
    p1_right,
    p1_left,
    p1_down,
    p1_up,
    p1_b1,
    p1_b2,
    p1_b3,
    p1_b4,
    p1_b5,
    p1_b6,
    p2_right,
    p2_left,
    p2_down,
    p2_up,
    p2_b1,
    p2_b2,
    p2_b3,
    p2_b4,
    p2_b5,
    p2_b6,
    coin1,
    coin2,
    service,
    start1,
    start2,
    test_switch,
    menu,
    pause,
    reset,
    fullscreen,
    open,
    save_state,
    load_state,
    next_slot,
    quick_save,
    quick_load,
    fast_forward,
    frame_advance,
    screenshot,
    scanlines,

    pub const count = @typeInfo(Action).@"enum".fields.len;
    pub const pads = 2;
    pub const pad_count = cps.button_count;
    /// Where the panel and the hotkeys start.
    pub const panel_first = pads * pad_count;
    pub const hotkey_first = panel_first + cps.panel_count;

    /// The `cps.Inputs.pad` bit this action holds down, or 0 if it is not a
    /// player's button.
    pub fn padMask(a: Action) u16 {
        const i = @intFromEnum(a);
        if (i >= panel_first) return 0;
        return @as(u16, 1) << @intCast(i % pad_count);
    }

    /// The `cps.Inputs.panel` bit this action holds down, or 0.
    pub fn panelMask(a: Action) u8 {
        const i = @intFromEnum(a);
        if (i < panel_first or i >= hotkey_first) return 0;
        return @as(u8, 1) << @intCast(i - panel_first);
    }

    pub fn label(a: Action) [:0]const u8 {
        return switch (a) {
            .p1_right => "P1 Right",
            .p1_left => "P1 Left",
            .p1_down => "P1 Down",
            .p1_up => "P1 Up",
            .p1_b1 => "P1 Button 1",
            .p1_b2 => "P1 Button 2",
            .p1_b3 => "P1 Button 3",
            .p1_b4 => "P1 Button 4",
            .p1_b5 => "P1 Button 5",
            .p1_b6 => "P1 Button 6",
            .p2_right => "P2 Right",
            .p2_left => "P2 Left",
            .p2_down => "P2 Down",
            .p2_up => "P2 Up",
            .p2_b1 => "P2 Button 1",
            .p2_b2 => "P2 Button 2",
            .p2_b3 => "P2 Button 3",
            .p2_b4 => "P2 Button 4",
            .p2_b5 => "P2 Button 5",
            .p2_b6 => "P2 Button 6",
            .coin1 => "Coin 1",
            .coin2 => "Coin 2",
            .service => "Service Credit",
            .start1 => "Start 1",
            .start2 => "Start 2",
            .test_switch => "Test",
            .menu => "Menu",
            .pause => "Pause",
            .reset => "Reset",
            .fullscreen => "Fullscreen",
            .open => "Open Set",
            .save_state => "Save State",
            .load_state => "Load State",
            .next_slot => "Next State Slot",
            .quick_save => "Quicksave",
            .quick_load => "Quickload",
            .fast_forward => "Fast Forward",
            .frame_advance => "Frame Advance",
            .screenshot => "Screenshot",
            .scanlines => "Scanlines",
        };
    }
};

pub const Bindings = [Action.count]u32;

comptime {
    // The two orders this file's shifts depend on.
    std.debug.assert(Action.p1_b1.padMask() == cps.Button.b1.mask());
    std.debug.assert(Action.test_switch.panelMask() == cps.Panel.test_switch.mask());
}

/// Arrows and two rows of three for player 1, and the panel keys an arcade
/// cabinet's test rig is wired to. Player 2 ships unbound: two players on one
/// keyboard is a choice, not a default, and an unbound pad reads as nothing
/// pressed. Escape is the menu, so raylib's exit-on-escape has to be turned off.
pub const defaults: Bindings = blk: {
    var b: Bindings = @splat(0);
    b[@intFromEnum(Action.p1_up)] = key_up;
    b[@intFromEnum(Action.p1_down)] = key_down;
    b[@intFromEnum(Action.p1_left)] = key_left;
    b[@intFromEnum(Action.p1_right)] = key_right;
    b[@intFromEnum(Action.p1_b1)] = 'A';
    b[@intFromEnum(Action.p1_b2)] = 'S';
    b[@intFromEnum(Action.p1_b3)] = 'D';
    // The six-button panel's rows sit one above the other, so its keys do too.
    b[@intFromEnum(Action.p1_b4)] = 'Q';
    b[@intFromEnum(Action.p1_b5)] = 'W';
    b[@intFromEnum(Action.p1_b6)] = 'E';
    // The panel keys every cabinet test rig uses.
    b[@intFromEnum(Action.coin1)] = '5';
    b[@intFromEnum(Action.coin2)] = '6';
    b[@intFromEnum(Action.service)] = '9';
    b[@intFromEnum(Action.start1)] = key_enter;
    b[@intFromEnum(Action.start2)] = '2';
    // A QSound board has no DIP switches, so this is the only door into its
    // settings (DESIGN.md §8.4).
    b[@intFromEnum(Action.test_switch)] = key_f1;
    b[@intFromEnum(Action.menu)] = key_escape;
    b[@intFromEnum(Action.pause)] = 'P';
    b[@intFromEnum(Action.reset)] = key_f5;
    b[@intFromEnum(Action.fullscreen)] = key_f11;
    b[@intFromEnum(Action.open)] = 'O';
    b[@intFromEnum(Action.save_state)] = key_f2;
    b[@intFromEnum(Action.next_slot)] = key_f3;
    b[@intFromEnum(Action.load_state)] = key_f4;
    b[@intFromEnum(Action.quick_save)] = key_f6;
    b[@intFromEnum(Action.quick_load)] = key_f7;
    b[@intFromEnum(Action.fast_forward)] = key_tab;
    b[@intFromEnum(Action.frame_advance)] = key_f8;
    b[@intFromEnum(Action.screenshot)] = key_f12;
    b[@intFromEnum(Action.scanlines)] = ' ';
    break :blk b;
};

const key_escape = 256;
const key_enter = 257;
const key_right = 262;
const key_left = 263;
const key_down = 264;
const key_up = 265;
const key_tab = 258;
const key_f1 = 290;
const key_f2 = 291;
const key_f3 = 292;
const key_f4 = 293;
const key_f5 = 294;
const key_f6 = 295;
const key_f7 = 296;
const key_f8 = 297;
const key_f11 = 300;
const key_f12 = 301;

/// The bits a cabinet's control panel is wired for. A three-button panel has
/// no 4, 5 or 6 bolted to it, so the machine is never handed those however the
/// keyboard is bound — and the shell draws them as holes that never light.
pub fn wiring(six: bool) u16 {
    const all = (@as(u16, 1) << cps.button_count) - 1;
    if (six) return all;
    return all & ~(cps.Button.b4.mask() | cps.Button.b5.mask() | cps.Button.b6.mask());
}

/// Player `pad`'s buttons for this frame. `down` is the host's keyboard, which
/// is raylib's `IsKeyDown` and nothing else — passing it in is what keeps the
/// window out of this file.
pub fn buttons(b: Bindings, pad: usize, down: *const fn (u32) bool) u16 {
    var out: u16 = 0;
    const base = pad * Action.pad_count;
    for (0..Action.pad_count) |i| {
        if (b[base + i] != 0 and down(b[base + i])) out |= @as(u16, 1) << @intCast(i);
    }
    return out;
}

/// The panel's inputs for this frame: coins, starts, service and test.
pub fn panel(b: Bindings, down: *const fn (u32) bool) u8 {
    var out: u8 = 0;
    for (Action.panel_first..Action.hotkey_first) |i| {
        if (b[i] != 0 and down(b[i])) out |= @as(u8, 1) << @intCast(i - Action.panel_first);
    }
    return out;
}

/// True when two actions share a key, which the rebinding UI highlights.
pub fn conflicts(b: Bindings, a: Action) bool {
    const key = b[@intFromEnum(a)];
    if (key == 0) return false;
    for (b, 0..) |other, i| {
        if (other == key and i != @intFromEnum(a)) return true;
    }
    return false;
}

/// Keys with a name worth writing down. Everything else round-trips as a
/// decimal code, which is ugly in the config file but never wrong.
const named = [_]struct { []const u8, u32 }{
    .{ "NONE", 0 },
    .{ "SPACE", 32 },
    .{ "ESC", key_escape },
    .{ "ENTER", key_enter },
    .{ "TAB", key_tab },
    .{ "BACKSPACE", 259 },
    .{ "INSERT", 260 },
    .{ "DELETE", 261 },
    .{ "RIGHT", key_right },
    .{ "LEFT", key_left },
    .{ "DOWN", key_down },
    .{ "UP", key_up },
    .{ "PAGEUP", 266 },
    .{ "PAGEDOWN", 267 },
    .{ "HOME", 268 },
    .{ "END", 269 },
    .{ "F1", key_f1 },
    .{ "F2", key_f2 },
    .{ "F3", key_f3 },
    .{ "F4", key_f4 },
    .{ "F5", key_f5 },
    .{ "F6", key_f6 },
    .{ "F7", key_f7 },
    .{ "F8", key_f8 },
    .{ "F9", 298 },
    .{ "F10", 299 },
    .{ "F11", key_f11 },
    .{ "F12", key_f12 },
    .{ "LSHIFT", 340 },
    .{ "LCTRL", 341 },
    .{ "LALT", 342 },
    .{ "RSHIFT", 344 },
    .{ "RCTRL", 345 },
    .{ "RALT", 346 },
};

/// Enough for every name in the table and for the decimal fallback an unnamed
/// code round-trips as, which is what `keyName` needs a buffer for.
pub const max_key_name = 16;

/// Writes the key's name into `buf` and returns it. Printable codes are their
/// own name, so `A` is "A" and `[` is "[".
pub fn keyName(key: u32, buf: []u8) []const u8 {
    for (named) |n| {
        if (n[1] == key) return n[0];
    }
    if (key > ' ' and key < 127) {
        buf[0] = @intCast(key);
        return buf[0..1];
    }
    return std.fmt.bufPrint(buf, "{d}", .{key}) catch "?";
}

pub fn keyCode(name: []const u8) ?u32 {
    for (named) |n| {
        if (std.mem.eql(u8, n[0], name)) return n[1];
    }
    if (name.len == 1) return name[0];
    return std.fmt.parseInt(u32, name, 10) catch null;
}

const testing = std.testing;

test "pad and panel bits line up with what the bus reads" {
    try testing.expectEqual(cps.Button.up.mask(), Action.p1_up.padMask());
    try testing.expectEqual(cps.Button.b6.mask(), Action.p1_b6.padMask());
    try testing.expectEqual(cps.Button.b6.mask(), Action.p2_b6.padMask());
    try testing.expectEqual(cps.Panel.coin1.mask(), Action.coin1.panelMask());
    try testing.expectEqual(cps.Panel.start2.mask(), Action.start2.panelMask());
    // An action is one or the other, never both.
    try testing.expectEqual(@as(u8, 0), Action.p1_up.panelMask());
    try testing.expectEqual(@as(u16, 0), Action.coin1.padMask());
    try testing.expectEqual(@as(u16, 0), Action.menu.padMask());
    try testing.expectEqual(@as(u8, 0), Action.menu.panelMask());
}

test "bindings turn held keys into what the machine is handed" {
    const held = struct {
        fn down(key: u32) bool {
            return key == 'A' or key == key_up or key == 'K' or key == '5';
        }
    }.down;
    var b = defaults;
    const p1 = cps.Button.b1.mask() | cps.Button.up.mask();
    try testing.expectEqual(p1, buttons(b, 0, &held));
    try testing.expectEqual(cps.Panel.coin1.mask(), panel(b, &held));

    // Player 2 is unbound out of the box, and an unbound key is never held.
    try testing.expectEqual(@as(u16, 0), buttons(b, 1, &held));
    b[@intFromEnum(Action.p2_b1)] = 'K';
    try testing.expectEqual(cps.Button.b1.mask(), buttons(b, 1, &held));
    try testing.expectEqual(p1, buttons(b, 0, &held));

    // A three-button panel cannot hand over the buttons it has no holes for,
    // and hands over everything it does.
    b[@intFromEnum(Action.p1_b6)] = 'A';
    try testing.expectEqual(p1 | cps.Button.b6.mask(), buttons(b, 0, &held) & wiring(true));
    try testing.expectEqual(p1, buttons(b, 0, &held) & wiring(false));
    for ([_]cps.Button{ .up, .down, .left, .right, .b1, .b2, .b3 }) |btn| {
        try testing.expectEqual(btn.mask(), btn.mask() & wiring(false));
    }
}

test "every key name round-trips, and fits the buffer they are written to" {
    var buf: [max_key_name]u8 = undefined;
    for (named) |n| try testing.expect(n[0].len <= max_key_name);
    for (defaults) |key| {
        try testing.expectEqual(key, keyCode(keyName(key, &buf)).?);
    }
    // The unnamed ones fall back to decimal, and that has to survive too.
    try testing.expectEqual(@as(u32, 348), keyCode(keyName(348, &buf)).?);
}

test "the defaults do not fight each other" {
    for (std.enums.values(Action)) |a| {
        if (!conflicts(defaults, a)) continue;
        std.debug.print("{s} is bound twice\n", .{@tagName(a)});
        return error.TestUnexpectedResult;
    }
}

test "conflicts are found in both directions" {
    var b = defaults;
    try testing.expect(!conflicts(b, .p1_up));
    b[@intFromEnum(Action.pause)] = b[@intFromEnum(Action.p1_b1)];
    try testing.expect(conflicts(b, .pause));
    try testing.expect(conflicts(b, .p1_b1));
}
