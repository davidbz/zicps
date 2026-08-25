# zicps

A Capcom CP System 1.5 (CPS Dash) arcade emulator, written in Zig.

It emulates the whole board: the 68000, the encrypted Z80 sound CPU, the CPS-A
and CPS-B-21 video chips, the QSound DSP, the control panel, save states and the
board's own settings EEPROM — plus a small, friendly desktop app to play in.

zicps doesn't ship with any games. To run a board you supply your own legally
obtained ROM set, and zicps supplies the **board file** that says how to read
it — or you write your own.

## The board file

On a real CPS-1.5 board, the video-chip register mapping, the graphics bank
table and the sound CPU's decryption key don't live in the ROMs — they live in
RAM held up by a battery. When the battery dies the board keeps every chip and
forgets how to be itself; that's what people mean when they call these boards
"suicidal".

zicps models that battery as plain `key = value` text you can read and edit,
holding exactly what the battery held. One ships for nearly every CPS-1/1.5 set
MAME lists, under [`boards/`](boards/), transcribed from MAME's published tables
and embedded in the binary — so `zicps sf2.zip` just runs.

Three places are looked at, in this order, and the first one found wins:

1. `--board <path>`, if you passed one.
2. `<set>.board` beside your set — your own file always beats ours.
3. `boards/<set name>`, the shipped one, found by the set's name the way MAME
   names it.

No board file anywhere, no boot — and if the one you have is wrong, zicps says
what it needed rather than drawing garbage. The shipped ones are a convenience,
not an authority: most have never been booted by anyone here, and outside the
QSound sets they carry no sound at all. See [`boards/README.md`](boards/README.md).

## Status

Early, but it runs. The design is written ([`DESIGN.md`](DESIGN.md)) and the
emulator is being built against it, milestone by milestone: the machine, the
video chips, the sound board, QSound and the frontend are in, and a real board's
ROM set boots to its attract mode. Save states are next, and nobody has yet sat
down and played one through — that sweep is a milestone of its own.

## Running

```
zig build run -- path/to/your-set.zip
```

With no argument it opens on a dead channel; drop a set on the window, press
any key for the menu, or use `Load Set`. Escape opens the menu, F1 is the
board's test switch, 5 inserts a coin and Enter starts. Every key is rebindable
from `Options → Keys`, and everything you change is written back to
`zicps/config.ini` in your config directory.

## Building

You'll need [Zig](https://ziglang.org/) 0.16.0. On Linux, raylib needs the
usual X11 and GL headers:

```
sudo apt install libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev \
                 libxcursor-dev libxi-dev libxext-dev
```

The tests need none of that — they build the emulator without a display:

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

## What it won't do

CPS-1 boards with the older YM2151 + ADPCM sound hardware, CP System II,
netplay, cheats, shader pipelines, and per-game databases of any kind.

## References

zicps is built on [z68k](https://github.com/davidbz/z68k) and
[z80](https://github.com/davidbz/z80), conformance-tested 68000 and Z80 cores,
and reuses the frontend and engineering standards of
[zigesis](https://github.com/davidbz/zigesis). It leans on some excellent
community research, all credited in [`DESIGN.md`](DESIGN.md).

## License

MIT. See [`LICENSE`](LICENSE). The board files under `boards/` are
transcribed from MAME's CPS-1 driver and carry its BSD-3-Clause terms; see
[`boards/README.md`](boards/README.md).
