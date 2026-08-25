# The board library

One file per CPS-1/1.5 set, named the way MAME names the set, embedded in the
binary at build time (`list.zig`, `src/boards.zig`). A board file is what a
working board keeps in the RAM its battery holds up — the CPS-B register
mapping, the graphics bank table and the Kabuki key — plus where every chip in
the zip lands. See DESIGN.md for the format.

`roms/dino.zip` finds `dino` here, but only last: `--board <path>` wins, then a
`<set>.board` beside the set, then this library. Your own file always beats
ours.

## Where the numbers come from

Nobody can read these registers off a chip. They are transcribed from MAME's
CPS-1 driver by `tools/mame_to_board.zig`, which is run by hand against a
checked-out MAME tree (`tools/fetch_mame_source.sh`, pinned to mame0289) and
whose output is committed:

- `src/mame/capcom/cps1_v.cpp` — `cps1_config_table`, the `CPS_B_*` register
  layouts and the `mapper_*` bank tables.
- `src/mame/capcom/cps1.cpp` — the `ROM_START` blocks: file names, lengths,
  interleave and CRC32.
- `src/mame/capcom/kabuki.cpp` — the four decryption keys per encrypted set.

That data is copyright the MAME team, Nicola Salmoria and contributors, and is
used under the BSD-3-Clause terms MAME grants for it. No ROM bytes are here,
only the numbers that say how to read yours.

## What these files do not carry

- **No sound outside QSound.** Only the CPS-1.5 sets have `audio` and `qsound`
  lines; a plain CPS-1 board's YM2151 and OKI are out of scope,
  so those sets run silent.
- **No DIP switches.** Those sets run on their default settings.
- **No promise beyond the table.** Seven of these boot on real sets here; every
  other file says `Untested` in its header and is only as right as MAME's table.
  A wrong mapper there is a wrong mapper here.

A `crc=` on a ROM line verifies a dump; it does not name one. A zip under the
wrong name finds no board at all rather than the wrong board.
