//! The machine that is running, whichever generation it is in front of you.
//!
//! The two boards share no struct — different memory maps, different
//! schedulers, different sizes — so this is where the frame loop stops caring
//! which one is in the cabinet. Everything above it (the window, the sweep)
//! holds one of these and asks it for the handful of things it needs.
//!
//! It sits beside `main.zig` and not under `common/`, because a module that
//! knows both generations is not a common one: dependencies point inward, and
//! this is the frontend end of them.

const std = @import("std");
const board = @import("board");
const romset = @import("romset");
const state = @import("state");
const cps1 = @import("cps1");
const cps2 = @import("cps2");
const cps1_scheduler = @import("scheduler");
const cps2_scheduler = @import("cps2_scheduler");

pub const Cpu = cps1_scheduler.Cpu;

/// Which key a CPS-2 program was decrypted with. `none` is a suicided board,
/// running on its own ciphertext.
pub const KeySource = enum { none, set, board };

pub const Machine = union(board.System) {
    cps1: Arm(cps1.Machine, cps1_scheduler),
    cps2: Arm(cps2.Machine, cps2_scheduler),

    /// Power-on, and also what a Reset does: every chip back to its reset state
    /// with the same set in the board. Not the 68000's reset line — that would
    /// keep work RAM, and this is a cabinet being switched off.
    ///
    /// The EEPROM does not survive it, because it is a battery and not a chip:
    /// the caller writes it out and reads it back around the call.
    pub fn start(m: *Machine, b: board.Board, rom: romset.Set) void {
        m.* = switch (b.system) {
            .cps1 => .{ .cps1 = undefined },
            .cps2 => .{ .cps2 = undefined },
        };
        switch (m.*) {
            inline else => |*a| a.start(b, rom),
        }
    }

    pub fn runFrame(m: *Machine) void {
        switch (m.*) {
            inline else => |*a| a.runFrame(),
        }
    }

    pub fn hash(m: *Machine) u64 {
        switch (m.*) {
            inline else => |*a| return a.hash(),
        }
    }

    pub fn cpu(m: *Machine) *Cpu {
        switch (m.*) {
            inline else => |*a| return &a.cpu,
        }
    }

    /// One of the fields both machines have, and have at the same type: the
    /// controls, the mixer, the battery and the video chips are above the line
    /// the generations differ below. Naming the field rather than writing an
    /// accessor per field is also what makes the compiler check that claim.
    pub fn part(m: *Machine, comptime name: []const u8) *@FieldType(cps1.Machine, name) {
        switch (m.*) {
            inline else => |*a| return &@field(a.c, name),
        }
    }

    /// The bigger of the two state files, so one buffer serves either arm. A
    /// state written by one is refused by the other on its layout hash, which
    /// is the same refusal a state from another build gets.
    pub const max_state_bytes = @max(
        Arm(cps1.Machine, cps1_scheduler).st.bytes,
        Arm(cps2.Machine, cps2_scheduler).st.bytes,
    );
    pub const state_limit: std.Io.Limit = .limited(max_state_bytes + 1);

    /// Writes the state and answers the part of `out` that is one.
    pub fn save(m: *Machine, out: *[max_state_bytes]u8) []const u8 {
        switch (m.*) {
            inline else => |*a| {
                const st = @TypeOf(a.*).st;
                st.save(&a.c, &a.cpu, out[0..st.bytes]);
                return out[0..st.bytes];
            },
        }
    }

    pub fn load(m: *Machine, in: []const u8) state.Error!void {
        switch (m.*) {
            inline else => |*a| return @TypeOf(a.*).st.load(&a.c, &a.cpu, in),
        }
    }

    /// A CPS-2 board whose key ROM has decayed. It still runs — on its own
    /// ciphertext — so this is something to say rather than a reason to refuse
    /// the set.
    pub fn suicided(m: *Machine) bool {
        return switch (m.*) {
            .cps1 => false,
            .cps2 => |*a| a.c.suicided,
        };
    }

    /// Where the key that decrypted this program came from: the set's own
    /// twenty bytes, the board file's transcription of them, or nowhere.
    pub fn keySource(m: *Machine) KeySource {
        return switch (m.*) {
            .cps1 => .none,
            .cps2 => |*a| if (a.c.suicided) .none else if (a.c.key_from_board) .board else .set,
        };
    }
};

/// One generation's machine, its 68000 and its save-state format, which is the
/// machine's own size and so is no more shareable than the machine is.
pub fn Arm(comptime M: type, comptime sched: type) type {
    return struct {
        c: M,
        cpu: sched.Cpu,

        const Self = @This();
        pub const st = state.Format(M, sched.Cpu);

        fn start(a: *Self, b: board.Board, rom: romset.Set) void {
            a.c = .{ .board = b, .rom = rom };
            sched.reset(&a.c, &a.cpu);
        }

        fn runFrame(a: *Self) void {
            sched.runFrame(&a.c, &a.cpu);
        }

        fn hash(a: *const Self) u64 {
            return sched.hash(&a.c, &a.cpu);
        }
    };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "which arm is live is the board file's `system` key, and nothing else" {
    const m = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(m);

    m.start(.{}, .empty);
    try testing.expectEqual(board.System.cps1, @as(board.System, m.*));
    try testing.expect(!m.suicided());

    // A CPS-2 set with no key ROM at all decodes dead, which is what a board
    // whose battery went flat looks like — and it still starts.
    m.start(.{ .system = .cps2, .cpu_hz = board.cps2_cpu_hz }, .empty);
    try testing.expectEqual(board.System.cps2, @as(board.System, m.*));
    try testing.expect(m.suicided());

    // The parts above the line are the same fields either way, and a state
    // written for one arm cannot be read into the other.
    m.part("inputs").pad[0] = 1;
    try testing.expectEqual(@as(u16, 1), m.cps2.c.inputs.pad[0]);
    try testing.expect(@TypeOf(m.cps1).st.layout_hash != @TypeOf(m.cps2).st.layout_hash);
}
