//! The controls a CP System cabinet has: two joysticks with six buttons each,
//! and the panel switches beside them. The same panel on every generation —
//! which port a board reads them back on is the board's business, not the
//! panel's, so the bit assignments live with the machine and not here.

/// One player's controls, active high. Bit order is the board's own: the four
/// directions in the order the wiring reads them, then six buttons.
pub const Button = enum(u4) {
    right,
    left,
    down,
    up,
    b1,
    b2,
    b3,
    b4,
    b5,
    b6,

    pub fn mask(b: Button) u16 {
        return @as(u16, 1) << @intFromEnum(b);
    }
};
pub const button_count = @typeInfo(Button).@"enum".fields.len;

/// The panel inputs a board with no DIP switches cannot do without: without
/// service and test there is no way into the settings menu.
pub const Panel = enum(u3) {
    coin1,
    coin2,
    service,
    start1,
    start2,
    test_switch,

    pub fn mask(p: Panel) u8 {
        return @as(u8, 1) << @intFromEnum(p);
    }
};
pub const panel_count = @typeInfo(Panel).@"enum".fields.len;

/// What the frontend hands the machine each frame: both pads, and the panel.
pub const Inputs = struct {
    pad: [2]u16 = @splat(0),
    panel: u8 = 0,
};
