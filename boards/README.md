# The board library

One file per CPS-1/1.5 or CPS-2 set, named the way MAME names the set, embedded
in the binary at build time (`list.zig`, `src/boards.zig`). A board file is what
a working board keeps in the RAM its battery holds up — the CPS-B register
mapping, the graphics bank table and the Kabuki key, or on CPS-2 the decryption
key — plus where every chip in the zip lands. See DESIGN.md for the format.

A CPS-2 file says `system = cps2` and is the same file every time apart from its
ROM lines: MAME has one row for all 324 of those sets, because every CPS-2 board
is the CPS-B-21 at its default strapping.

`roms/dino.zip` finds `dino` here, but only last: `--board <path>` wins, then a
`<set>.board` beside the set, then this library. Your own file always beats
ours.

## Where the numbers come from

Nobody can read these registers off a chip. They are transcribed from MAME's
Capcom drivers by `tools/mame_to_board.zig`, which is run by hand against a
checked-out MAME tree (`tools/fetch_mame_source.sh`, pinned to mame0289) and
whose output is committed:

- `src/mame/capcom/cps1_v.cpp` — `cps1_config_table`, the `CPS_B_*` register
  layouts and the `mapper_*` bank tables, including the one `cps2` row.
- `src/mame/capcom/cps1.cpp` — the `ROM_START` blocks: file names, lengths,
  interleave and CRC32.
- `src/mame/capcom/cps2.cpp` — the same, for the CPS-2 sets.
- `src/mame/capcom/kabuki.cpp` — the four decryption keys per encrypted set.

That data is copyright the MAME team, Nicola Salmoria, Paul Leaman and
contributors, and is used under the BSD-3-Clause terms MAME grants for it. No
ROM bytes are here, only the numbers that say how to read yours.

## What these files do not carry

- **No decryption key.** A CPS-2 file names the `.key` its set should carry and
  nothing more. Without one in the set, the board is a suicided board: it runs
  its own ciphertext, exactly as the hardware does.
- **No DIP switches.** Those sets run on their default settings.
- **No promise beyond the table.** Seven of these boot on real sets here; every
  other file says `Untested` in its header and is only as right as MAME's table.
  A wrong mapper there is a wrong mapper here.

A `crc=` on a ROM line verifies a dump; it does not name one. A zip under the
wrong name finds no board at all rather than the wrong board.
