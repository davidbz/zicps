# zicps

A Capcom CP System 1.5 (CPS Dash) arcade emulator, written in Zig.

It emulates the whole board: the 68000, the encrypted Z80 sound CPU, the CPS-A
and CPS-B-21 video chips, the QSound DSP, the control panel, save states and the
board's own settings EEPROM — plus a small, friendly desktop app to play in.

zicps doesn't ship with any games, and it ships no database of them either. To
run a board you supply two things: your own legally obtained ROM set, and a
**board file** describing that board's configuration.

## The board file

On a real CPS-1.5 board, the video-chip register mapping, the graphics bank
table and the sound CPU's decryption key don't live in the ROMs — they live in
RAM held up by a battery. When the battery dies the board keeps every chip and
forgets how to be itself; that's what people mean when they call these boards
"suicidal".

zicps models that battery as a file you supply next to your ROM set: plain
`key = value` text you can read and edit, holding exactly what the battery held.
No board file, no boot — and if it's wrong, zicps says what it needed rather
than drawing garbage.

## Status

Early. The design is written ([`DESIGN.md`](DESIGN.md)); the emulator is being
built against it, milestone by milestone. Nothing here plays a game yet.

## Building

You'll need [Zig](https://ziglang.org/) 0.16.0.

```
zig build test
```

There is also a scoreboard over the test ROM this project builds for itself,
which fails when any page of it draws a pixel more or less than it used to:

```
zig build testrom
```

Once there's a window to open, Linux will also need the usual X11/GL packages
for [raylib](https://www.raylib.com/); that arrives with the frontend milestone.

## What it won't do

CPS-1 boards with the older YM2151 + ADPCM sound hardware, CP System II,
netplay, cheats, shader pipelines, and per-game databases of any kind.

## References

zicps is built on [z68k](https://github.com/davidbz/z68k) and
[z80](https://github.com/davidbz/z80), conformance-tested 68000 and Z80 cores,
and reuses the frontend and engineering standards of
[zigesis](https://github.com/davidbz/zigesis). It leans on some excellent
community research, all credited in [`DESIGN.md`](DESIGN.md) §11.

## License

MIT. See [`LICENSE`](LICENSE).
