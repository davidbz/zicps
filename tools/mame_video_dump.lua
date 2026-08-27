-- Writes the video state differential's dump out of MAME.
--
-- At a chosen frame it saves graphics RAM, the CPS-A and CPS-B register files
-- and the frame number into one `.vdump`, and takes MAME's own snapshot of the
-- same frame. `zig build video-diff` renders the dump with this emulator's
-- renderer, and the two pictures go side by side.
--
--     mame dino -autoboot_script tools/mame_video_dump.lua \
--               -autoboot_delay 0 -video none -sound none
--
-- The frame and the output directory are read from the environment, because
-- MAME's autoboot takes no arguments of its own:
--
--     ZICPS_FRAME=600 ZICPS_OUT=testdata/video mame ...
--
-- MAME quits when the dump is written, so a run is one dump.
--
-- ponytail: unverified — no MAME binary on the machine this was written on.
-- The share names below are `cps_state`'s own (`src/mame/capcom/cps1.cpp`), so
-- what is most likely to need a nudge is those and nothing else.

local magic = "zicps-vd"
local version = 1

local frame_wanted = tonumber(os.getenv("ZICPS_FRAME") or "600")
local out_dir = os.getenv("ZICPS_OUT") or "testdata/video"

-- Little-endian, which is what `read()` in test/video_diff.zig expects and
-- what the hardware is anyway.
local function u32(v)
    return string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff)
end

-- A share reads back as bytes in the host's order but as *words* in the
-- guest's, so the 16-bit register files are re-emitted a word at a time rather
-- than copied. Graphics RAM is bytes to this emulator too, and is copied.
local function words(share, bytes)
    local out = {}
    for i = 0, bytes - 2, 2 do
        local w = share:read_u16(i)
        out[#out + 1] = string.char(w & 0xff, (w >> 8) & 0xff)
    end
    return table.concat(out)
end

local function bytes_of(share, count)
    local out = {}
    for i = 0, count - 1 do
        out[#out + 1] = string.char(share:read_u8(i))
    end
    return table.concat(out)
end

local machine = manager.machine
local shares = machine.memory.shares
local gfxram = shares[":gfxram"] or shares["gfxram"]
local cps_a = shares[":cps_a_regs"] or shares["cps_a_regs"]
local cps_b = shares[":cps_b_regs"] or shares["cps_b_regs"]
if not (gfxram and cps_a and cps_b) then
    error("no cps1 video shares here: this script wants a CPS-1 driver")
end

local frame = 0
local done = false

emu.add_machine_frame_notifier(function()
    if done then return end
    frame = frame + 1
    if frame < frame_wanted then return end
    done = true

    local name = string.format("%s/%s-%04d.vdump", out_dir, machine.system.name, frame)
    local f = assert(io.open(name, "wb"))
    f:write(magic, u32(version), u32(frame))
    f:write(words(cps_a, 0x40))
    f:write(words(cps_b, 0x40))
    f:write(bytes_of(gfxram, 0x30000))
    f:close()

    -- MAME's picture of the same frame, to hold the other one up against.
    machine.video:snapshot()
    print(string.format("wrote %s at frame %d", name, frame))
    machine:exit()
end)
