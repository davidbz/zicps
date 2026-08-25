# zicps

A Capcom CP System 1.5 (CPS Dash) arcade emulator, written in Zig.

It emulates the whole board: the 68000, the encrypted Z80 sound CPU, the CPS-A
and CPS-B-21 video chips, the QSound DSP, the control panel and the settings
EEPROM — plus a small, friendly desktop app to play in.

zicps doesn't ship any games. You'll need your own legally obtained ROM set to
run anything.

## What it can do

- Runs CPS-1 and CPS-1.5 sets, from a zip or a directory of chip images, with
  accurate video and QSound audio.
- Ships a board file for nearly every set MAME lists, so `zicps sf2.zip` just
  runs with nothing to configure.
- Keeps the board's own settings in a file beside your set, so what you set in
  its service menu is still there next time.
- Drag-and-drop and menu-based loading, pause, fast-forward, frame advance,
  screenshots, fullscreen, CRT-style scanline overlay.
- Rebindable keys for two players, on a 3- or 6-button panel.
- Deterministic enough to record a run and replay it frame for frame, and to
  render with no window at all and hash the result.

A few things aren't supported: CPS-1 boards with the older YM2151 + ADPCM sound
hardware (those sets run silent), CP System II, save states, netplay and cheats.

## The board file

On a real CPS-1.5 board the video-chip register mapping, the graphics bank table
and the sound CPU's decryption key don't live in the ROMs — they live in RAM
held up by a battery. When the battery dies the board keeps every chip and
forgets how to be itself; that's what people mean when they call these boards
"suicidal".

zicps models that battery as plain `key = value` text you can read and edit,
holding exactly what the battery held. One ships for nearly every CPS-1/1.5 set
MAME lists, under [`boards/`](boards/), transcribed from MAME's published tables
and embedded in the binary.

Three places are looked at, in this order, and the first one found wins:

1. `--board <path>`, if you passed one.
2. `<set>.board` beside your set — your own file always beats ours.
3. `boards/<set name>`, the shipped one, found by the set's name the way MAME
   names it.

No board file anywhere, no boot — and if the one you have is wrong, zicps says
what it needed rather than drawing garbage. See
[`boards/README.md`](boards/README.md).

## Getting started

You'll need [Zig](https://ziglang.org/) 0.16.0. On Linux you'll also need a few
system libraries so [raylib](https://www.raylib.com/) can open a window:

```
sudo apt-get install libgl1-mesa-dev libx11-dev libxrandr-dev \
  libxinerama-dev libxcursor-dev libxi-dev libxext-dev
```

(macOS and Windows don't need anything extra.) Then build it:

```
zig build
```

And run it, pointing at your set:

```
zig build run -- path/to/your-set.zip
```

Started without a set, zicps idles on a dead channel until you drop one on the
window or pick one from the menu.

## Controls

| Key | Does |
|-----|------|
| Arrows | Joystick |
| A / S / D | Buttons 1 / 2 / 3 |
| Q / W / E | Buttons 4 / 5 / 6 (6-button panel only) |
| 5 / 6 | Insert a coin, player 1 / 2 |
| Enter / 2 | Start, player 1 / 2 |
| 9 | Service |
| F1 | Test switch — the board's own settings menu |
| Esc | Menu (and back out of it) |
| O | Load set |
| P | Pause |
| Space | Scanlines |
| F5 | Reset |
| F8 | Advance one frame (and pause) |
| F11 | Fullscreen |
| F12 | Screenshot |
| Tab (held) | Fast-forward, 4x |

Every key is rebindable from Options → Keys, including the second player
(unbound by default). The menu works on arrow keys and Enter.

A QSound board has no DIP switches, so F1 is the only door into its settings.
Those settings are written next to your set (`game.zip.nv`), and screenshots
land there too. Everything you change in the menu is written back to
`zicps/config.ini` in your config directory.

## Command line

```
zicps [rom-set] [options]

  --board <path>     the board file (default: the set's path with .board)
  --frames N         run N frames with no window and print a state hash
  --replay <path>    drive the controls from a recorded input log
  --record <path>    write every frame's controls to an input log
  --hash             print a hash every frame, not only the last
```

## Tests

The tests build the emulator without a display, so they need none of the
system libraries above:

```
zig build test
```

There is also a scoreboard over the test ROM this project builds for itself,
which fails when any page of it draws a pixel more or less than it used to:

```
zig build testrom
```

The QSound core is checked by diffing it against ctr's `qsound-hle`, sample by
sample. That reference is a separate download and is not committed; fetch it
first, and `zig build test` picks it up from then on:

```
./tools/fetch_qsound_reference.sh
zig build qsound-ref
```

## References

zicps is built on top of [z68k](https://github.com/davidbz/z68k) and
[z80](https://github.com/davidbz/z80), conformance-tested 68000 and Z80 cores,
and leans on some excellent community research:

- [MAME](https://github.com/mamedev/mame)'s Capcom driver — the CPS-B-21
  register mappings and Kabuki keys the board files are transcribed from.
- [jtcps1](https://github.com/jotego/jtcores) — Jotego's hardware-verified FPGA
  core for this board family.
- [Fabien Sanglard's CPS-1 graphics study](https://fabiensanglard.net/cps1_gfx/)
  and [CCPS](https://fabiensanglard.net/ccps/), the SDK this project builds its
  own test ROM with.
- [ArcadeHacker's CPS-1 series](http://arcadehacker.blogspot.com/2015/04/capcom-cps1-part-1.html)
  — the batteries, the CPS-B-21 configuration and the Kabuki keys.
- [qsound-hle](https://github.com/ValleyBell/qsound-hle) — ctr and ValleyBell's
  from-scratch DSP implementation, used to check the QSound core.

## License

MIT. See [`LICENSE`](LICENSE). The board files under `boards/` are transcribed
from MAME's CPS-1 driver and carry its BSD-3-Clause terms; see
[`boards/README.md`](boards/README.md).
