# zicps: Capcom CP System 1.5 Emulator

Design document and milestone plan. Audience: coding agents and human
contributors. This document is the source of truth for scope, architecture, and
engineering standards. Read it in full before writing code.

## 1. Goal

Build a complete, playable emulator for Capcom's CP System 1.5 — the CPS Dash
board: CPS-1 video, a 68000 running unencrypted program code, and a separate
sound board carrying an encrypted Z80 and a QSound DSP. Both CPUs already
exist as finished, conformance-tested packages: [z68k](https://github.com/davidbz/z68k)
(all 317,500 SingleStepTests m68000 cases, exact on architectural state, cycle
counts, and data-space bus cycles) and [z80](https://github.com/davidbz/z80)
(1,604,000 of 1,604,000 on state and cycles). This project supplies the rest of
the machine and a small, polished desktop frontend.

The engineering standards, the data-oriented rule, the build-graph separation
between emulation and display, the testing philosophy, and the habit of writing
down ceilings all come from [zigesis](https://github.com/davidbz/zigesis), a
finished Genesis emulator built on the same two cores. This is the second
machine on that foundation, not a fresh start.

## 2. Starting Material

There is no proof of concept for this machine. What exists is a finished
emulator for a different one, and the parts of it that are not about the
Genesis at all.

Reused, and how:

| From zigesis | How it arrives |
|---|---|
| `src/audio.zig` — polyphase windowed-sinc resampler, exact-fraction rate carry, fixed ring buffer, no allocation and no floats at run time | copied verbatim, tests and all. Needs an upsampling path: this bank only drops a rate (§6.2) |
| `src/ui/snow.zig` — the idle screen | copied verbatim |
| `src/config.zig` — versioned `key = value` file, unknown keys ignored, values clamped | copied, new fields |
| `src/input.zig` — one `Action` enum covering pads and hotkeys, bindings written as key names, host keyboard behind a function pointer | same shape, arcade action list |
| `src/state.zig` — header plus `asBytes` of the machine, comptime `layout` hash refusing a state from another build | same technique, this machine's struct |
| `src/ui/shell.zig`, `src/main.zig` — menu, file browser, status bar, audio-paced frame loop, screenshots, replay | adapted: the cartridge card becomes a board card, the pad panel becomes a control panel |
| `build.zig` module graph, the three workflows, the headless suites in `test/` | patterns copied, targets renamed |

Not reused, and deliberately: the frontend is *copied* rather than shared as a
package. zigesis is done. Turning its frontend into a library would mean
designing that interface against two consumers, re-tagging a finished repo for
every arcade-side tweak, and generalising a `Mixer` that this machine needs to
change anyway. The duplicated code is about two thousand lines that will
diverge, which is cheaper than the coupling.

One change is needed upstream rather than here. The sound board's Z80 sits
behind a Kabuki custom, which decrypts opcodes and data differently, so the same
address answers with different bytes depending on whether the CPU is fetching an
instruction or reading a table. `z80`'s `fetchOpcode` currently goes through the
same `bus.z80Read8` as data. The fix is an optional `z80Fetch` on the bus,
`@hasDecl`-gated so a bus without one keeps today's behaviour: it lands in the
z80 repo, is gated by that repo's conformance corpus, and arrives here as a tag
bump. zigesis is unaffected.

It has not landed yet. M3 shipped without it, on a fetch cursor that infers the
same thing from the address a read arrives at (§9, M3's ceilings); the hook is
still what settles it.

## 3. Architecture

### 3.1 Repository layout

New repository consuming z68k and z80 as Zig package dependencies. Do not fork
either CPU into this repo.

```
zicps/
  build.zig
  build.zig.zon          # deps: z68k, z80, raylib (lazy)
  DESIGN.md              # this file
  src/
    main.zig             # entry point, arg parsing, frontend loop
    cps.zig              # machine state + bus (memory map, I/O, arbitration)
    scheduler.zig        # reference-clock accounting, per-line stepping
    video.zig            # CPS-A / CPS-B: layers, sprites, priority, palette
    soundboard.zig       # sound-board Z80 bus, banking, command latch
    kabuki.zig           # opcode/data decryption, key from the board file
    qsound.zig           # DL-1425, high-level
    audio.zig            # mixing, resampling, ring buffer to the frontend
    input.zig            # controls, key bindings
    romset.zig           # ROM set loading, interleave, graphics decode
    board.zig            # the board file: what the battery held (§8)
    state.zig            # save-state serialization
    config.zig           # options persistence
    ui/
      shell.zig          # window, menu, board card, status bar
      snow.zig
  test/
    system_test.zig      # headless frame-hash regression suite
    compat.zig           # boot every set in a directory, report what happened
    qsound_ref_test.zig  # differential harness against the QSound reference
  tools/
    fetch_qsound_reference.sh
    testrom/             # our own CPS-1 test ROM: source, board file, binary
```

### 3.2 Data-oriented design (mandatory)

Every subsystem is a plain struct of data plus free-standing functions (or
methods that are pure state transitions). No hidden state, no allocation inside
the emulation loop, no callbacks between chips.

- All chip state lives in flat, fixed-size structs: `Video`, `Z80`, `QSound`,
  `Controls`. The whole machine is one `Cps` struct that owns them by value.
  This is what makes save states trivial: serializing the machine is copying
  these structs (§8).
- Business logic never lives next to I/O. The video chip renders into a
  framebuffer array; only the frontend touches raylib. QSound writes samples
  into a buffer; only `audio.zig` talks to the sound device. Emulation code must
  compile and run headless with no raylib import anywhere in its tree, and the
  build graph — not anyone's discipline — is what enforces it.
- Communication between chips is explicit data flow driven by the scheduler: the
  machine reads outputs from one struct and feeds inputs to another. No chip
  holds a pointer into another chip.
- The z68k and z80 pattern is the model: the CPU knows nothing about the board;
  the machine implements the bus and passes itself as it.

The exception, stated once so it is not mistaken for drift: a ROM set is
megabytes whose size is known only at load, so the program ROM, the decoded
graphics, and the sample ROM are heap slices held on `Cps` and reattached after
a save-state load, exactly as zigesis reattaches its cartridge. Nothing else
allocates, and nothing allocates per frame.

### 3.3 Timing model

Single-threaded and clock-driven, as zigesis is — but with one honest
difference. The Genesis has a single 53.693175 MHz master clock that every part
of the machine divides, and the emulator's time base is that wire. A CPS-1.5
board has **three independent oscillators**: the CPU crystal, the 16 MHz video
crystal, and the sound board's own. There is no master clock to divide, so the
time base here is a *reference tick* of 120 MHz — the smallest number that
divides all four rates as integers — and it is a modelling convenience, not
something on the board.

| Part | Rate | Reference divider |
|---|---|---|
| 68000 | 12 MHz | 10 |
| Sound-board Z80 | 8 MHz | 15 |
| Pixel clock | 8 MHz (16 MHz crystal ÷ 2) | 15 |
| QSound sample | 24.038 kHz (60 MHz ÷ 2 ÷ 1248) | 4992 |

512 dots per line and 262 lines make 134,144 dots a frame, so the picture runs
at 59.6374 Hz with 384 × 224 of it visible. One line is 7680 reference ticks:
768 cycles of 68000, 512 of Z80, and one and a half QSound samples.

(Earlier drafts of this section said 59.6295 Hz, and MAME's `cps1.cpp` carries a
comment saying 59.63. Both are the same arithmetic rounded differently:
8,000,000 ÷ 134,144 is 59.6374.)

Step granularity is the scanline, as in zigesis: run the 68000 for a line's
worth of cycles, run the Z80 for its share, tick QSound, render the line,
deliver interrupts at the correct lines. Remainders are carried across lines as
integer debt (`tick_debt` and its per-part twins) so frames do not drift, and an
absolute reference-tick counter runs the whole time, never reset, because every
question a chip asks about its own state turns out to be a question about *when*.

Finer-than-line synchronization is out of scope until something demands it. The
raster interrupt is programmed by line, which is the resolution the board itself
offers, so a line is not obviously too coarse here; when it is, split the line at
the write rather than rearchitecting.

## 4. Engineering Standards (mandatory, enforced in review)

These rules override habit, style preference, and upstream example code.
Reviewers and agents must reject changes that violate them.

1. Separation of business logic and data (DOP). Structs describe state.
   Functions transform state. Rendering/audio/input backends consume state.
   See §3.2. A function that both mutates chip state and calls a raylib
   function is a defect.
2. Early return. Validate and bail at the top; the happy path stays at the
   lowest indentation. No `else` after a return. Deep nesting is a smell:
   extract a function or invert the condition.
3. No magic numbers. Every address range, register index, bit position,
   divider, and dimension is a named constant (`const vint_level = 2;`,
   `const palette_entries = 3072;`). Hardware addresses may appear once, at
   their definition site, with a name.
4. Fewer comments, readable code. Comments explain hardware behavior that the
   code cannot express (quirks, why a counter reloads at a strange value),
   never what the code does. If a comment restates the line below it, delete
   one of them. Doc comments on public types and entry points are fine and
   short.

Additional standing rules:

- No allocations in the per-frame path. Buffers are fixed-size arrays sized by
  named constants; the load-time exception is §3.2's and no other.
- Every milestone lands with its tests. A subsystem without a headless test is
  not done.
- Every milestone that closes writes down its ceilings — what it models
  approximately, and what it would take to do properly. A known shortcut named
  in this document is engineering; the same shortcut undocumented is a bug
  waiting to be rediscovered.
- `zig fmt` clean, `zig build test` green, CI on every push.

## 5. Product Specification

### 5.1 Scope philosophy

In scope (required):

- Load a ROM set from a directory or a zip, with its board file (§8), from a
  file browser, a drag-and-drop, or the command line.
- Save states: multiple slots, from the menu and via hotkeys.
- Configurable key bindings for both players and every emulator hotkey.
- Coin, start, service and test inputs, because a board with no DIP switches
  keeps its settings in a service menu and there is no other way in.
- Options persisted to a plain-text config file, human-editable, versioned.
- Pause, reset, window scale (1x-4x, integer), fullscreen toggle.
- Audio enable/volume.

Nice to have, only after all of the required list ships: recent-sets list,
per-channel audio muting, fast-forward and frame advance, screenshot hotkey,
CRT-style scanline overlay.

Explicitly out of scope: CPS-1 boards with the YM2151 and OKI ADPCM sound
hardware (this is a QSound machine; that path is a different sound board and a
milestone nobody has asked for), CP System II, netplay, cheats, shader
pipelines, per-game databases, and any protection device a board file cannot
describe.

### 5.2 The window

One window, simple design, no toolbar clutter. Three states, as in zigesis:

- **Idle** (nothing loaded): full-window animated static, a CRT tuned to a dead
  channel, with a single line of text that opens the menu. Dropping a set on the
  window works too.
- **Running**: the 384 × 224 framebuffer stretched over the window the way a
  monitor does it. Arcade pixels are not square and the picture is not 4:3 at
  1:1, so the stretch is the correct behaviour rather than a compromise.
- **Menu open**: emulation paused, a plain vertical menu over a dimmed frame,
  keyboard and mouse navigable. Resume / Load Set / Save State / Load State /
  Options / Reset / Quit.

The root page's right half is the **board card**, the counterpart of zigesis's
cartridge card: what the set contains (how many program, graphics and sample
ROMs, and how large), what the board file says the board was configured as, and
whether the program ROM's own checksum matches what is in the header. Nothing
here is looked up anywhere — every reading comes out of the files the user
supplied, which is also why this emulator ships no database and names nothing.

Under all three states sits the status bar, sized into the window rather than
overlaid, carrying the control panel, the set's name, and on the right the
hotkey marks, the quicksave's age, a badge when the volume is off, and the frame
rate. All of §5.2 of zigesis's rules apply unchanged, including the one the
whole right-hand side depends on: an item whose text changes gets a field wide
enough for anything it can say, not a box shrink-wrapped to this frame's value.

The control panel is drawn as the cabinet's: an eight-way stick and six buttons
in the two rows of three they sit in, plus coin and start, each lit by the
button word the machine is handed this frame. A board wired for three buttons
draws the top row as empty holes rather than leaving it out, so nothing to its
right moves when the option changes, and an empty hole never lights.

## 6. Technical Requirements

### 6.1 Video

raylib: one RGBA texture the size of the framebuffer, updated once per frame and
drawn stretched, nearest-neighbour. The framebuffer is a fixed array sized for
the largest picture the board can produce; the rendering path never allocates
and never touches raylib.

The headless path is not a debug feature but the backbone of testing: render N
frames with no window, hash the framebuffer, hash the resampled audio, and exit.
It must keep working forever.

### 6.2 Audio

raylib `AudioStream` at 48 kHz stereo, s16, drained by `main.zig` and by nothing
else. QSound produces stereo samples at its native 24.038 kHz during line
stepping; `audio.zig` rate-converts into the ring buffer; the ring's fill level
is the frame pacing signal — sleep when far ahead, run flat out when behind.

One thing genuinely changes from zigesis, and it is the direction of the rate
conversion. There the chips ran at 53 kHz and the sinc bank dropped them to 48;
here 24.038 kHz has to come *up*, and the existing bank is documented
downsample-only for good reason — its cutoff is expressed as a fraction of the
lower rate. Upsampling evaluates the same polyphase bank at the output rate
instead of the input rate, with the cutoff set by the *input* Nyquist. The M2
rule from zigesis applies to the result: measure the alias and image floor on
real chip output, do not assert it. That measurement is a deliverable of the
milestone, not a footnote.

What must not be "fixed": the chip itself has no sample interpolation, so its
own output is aliased by design and the games were written to that sound. The
resampler cleans up what *we* add, not what the DSP does.

### 6.3 Debugability

Built in from the start, compiled in always and runtime-toggled, because this is
how every subsequent milestone gets diagnosed:

- 68000 and Z80 instruction tracing to stderr or a file, per-CPU, with a
  frame/line/cycle prefix.
- Deterministic replay: given a set and a recorded input log, a run is
  bit-identical. No wall-clock time or PRNG in the emulation core — the snow's
  PRNG lives in the frontend. Every bug becomes a reproducible bug.
- Frame hashing in headless mode, pinned by the regression suite.
- Video inspectors: dump each layer, the object list, the palette pages, and
  both register files as images or text. These can be crude; they exist to
  answer "what is the video chip being told" in seconds.
- On a CPU exception loop or an invalid state, print machine context (PC
  history, SR, pending IRQs, video registers) rather than dying silently.

## 7. Hardware Notes (research summary)

What follows is the working model. Where a figure is quoted from a secondary
source rather than measured, §7.4 says so.

### 7.1 Video: CPS-A (DL-0311) and CPS-B-21 (DL-0921)

The 68000's map:

| Range | What |
|---|---|
| `0x000000-0x1fffff` | program ROM, unencrypted on this board |
| `0x800000-0x800007` | player controls |
| `0x800018-0x80001f` | system inputs (coins, start, service, test) and, on boards that have them, three banks of DIP switches |
| `0x800030-0x800037` | coin counters and lockouts |
| `0x800100-0x80013f` | CPS-A register file |
| `0x800140-0x80017f` | CPS-B register file, mapped by a PAL on the B-board — which is why its offsets differ per board (§8) |
| `0xf00000-0xf0ffff` | the sound board's program ROM, readable a byte at a time by the 68000 |
| `0x900000-0x92ffff` | graphics RAM: name tables, object list, row-scroll table, palette source |
| `0xf18000-0xf19fff`, `0xf1e000-0xf1ffff` | shared RAM with the sound board |
| `0xf1c000`, `0xf1c002` | third and fourth player controls |
| `0xf1c004` | second coin control |
| `0xf1c006` | serial EEPROM |
| `0xff0000-0xffffff` | 64 KiB work RAM |

The CPS-A file is fixed across boards and holds, at word offsets from
`0x800100`: the object, scroll1, scroll2, scroll3, row-scroll and palette base
addresses (each divided by 256); the three layers' X and Y scroll; two starfield
positions; the row-scroll table offset; and a video control word carrying
flip-screen and the row-scroll enable.

Six layers compose the picture: three tilemaps — scroll1 of 8x8 tiles, scroll2
of 16x16, scroll3 of 32x32, each name table 64 tiles square, so 512, 1024 and
2048 pixels wide respectively (M1 correction: this said 512 for all three) — the
object (sprite) layer,
and two starfields. Their order, their enables, and the four priority masks that
decide which tilemap pixels cut through sprites live in the CPS-B file.

The palette is six pages of 32 palettes of 16 entries, each entry four nibbles
of brightness, red, green and blue. It is not written directly: the board copies
it out of graphics RAM when the palette base register is written, one page per
enabled bit, and the documented quirk is that an unset first bit does not skip
page 0 but copies it into the first page that *is* enabled, while for later
pages an unset bit really does skip.

Interrupts: **level 2 is vblank and level 4 is the raster**, delivered at a
programmed line, with level 6 when both land together. Graphics ROMs hold 4bpp
tiles interleaved across chips; they are decoded once at load into a linear
byte-per-pixel buffer, which is the sane trade — decoding on the fly would be
the same work every frame.

### 7.2 The sound board: an encrypted Z80

The Z80 runs at 8 MHz with fixed ROM low, a banked ROM window above it, its own
RAM, the QSound command registers and ready flag, and shared RAM the 68000
writes commands into. The 68000 does not drive the sound chip; it posts a
command and the driver on the Z80 does the rest, so without a running sound
board there is no music at all.

The Z80 is not a plain one. It sits behind a Kabuki custom whose decryption
differs between opcode fetches and data reads, with the key held in
battery-backed RAM on the board — the same battery §8 is about. Modelled
faithfully, this is not "decrypt the ROM": it is two views of the same address
space, selected by whether the CPU is fetching. Hence the `z80Fetch` hook (§2);
the decryption itself is a pure function of the key and runs once at load into
two buffers.

### 7.3 QSound (DL-1425)

A DSP16A with a mask-programmed ROM, at 60 MHz, producing one stereo sample per
2496 DSP clocks — 24.038 kHz. Sixteen loopable PCM channels, each with a sample
bank, start, pitch, loop point, end, volume and pan; the pan runs through a
table of FIR filters, and the whole mix goes through a small echo buffer with a
fixed filter and adjustable feedback and length. There is no sample
interpolation, which is why samples were authored at about the output rate.

The chip also has three one-shot ADPCM channels and a second filter mode with an
extra filter. No known board uses either, so both are out of scope until
something asks for them, and this document is where that decision is recorded.

The model is high-level: the channels, the pan/FIR path and the echo written
directly from documented behaviour, rather than a DSP16A core running the mask
ROM. The reason is not effort but redistribution — an LLE needs an 8 KiB program
ROM that cannot be committed or fetched, which would make the entire audio path
skip on any machine that does not already own one. Verification is differential
instead (§9 M4). What the mask ROM holds besides program — the
three mix curves and the five FIR coefficient sets — is committed, in
`qsound_rom.zig`: those are as much a fact of the chip as its sample rate, and
without them there is no pan/FIR path to write.

### 7.4 What is quoted rather than measured

Each of these is checked against primary sources — the MAME driver, the jtcps1
core — before the milestone that depends on it, and the finding is written into
this document at that point:

- The QSound board's exact crystal derivations for the 68000 and the Z80, and
  the DSP's clock-to-sample divider (§3.3's 120 MHz reference is only correct if
  those four rates are).
- The sound board's Z80 port and register map.
- The raster interrupt's registers, **confirmed at M2**: there is no enable bit
  and there are no line registers. Two nine-bit down-counters are reloaded from
  CPS-B `0x10` and `0x12` at line 0, count down one a line, and pull IPL2 — a
  level 4 interrupt, or a level 6 one when it lands on the same line as vblank —
  as either reaches zero. The power-up reload of `0x1ff` never gets there inside
  a 262-line frame, which is how a board that does not use the interrupt is
  written down. A write with bit 15 set reloads that counter there and then; a
  read returns the live counter rather than the reload. The `0x4e` bit 9 enable
  and the `0x50`/`0x52` line positions quoted here before were an older driver's
  and are not in the current one. IPL2 is wired at all only on later B boards
  with JP1 closed, so the two offsets are a board-file line (`raster_line`) that
  defaults to `none`.
- The CPS-B priority masks and the object list, **confirmed at M2**: the four
  priority registers are pen masks, one per group, and a tile picks its group
  with bits 7 and 8 of its attribute word. A pen whose bit is set in that mask
  is drawn *over* the sprites — but only by the tilemap in the pass immediately
  under the object list, and only where that tilemap drew at all. A group whose
  register the board's PAL does not decode masks nothing. The object list is 256
  entries of four words — x, y, code, attribute — ending at the first attribute
  with `0xff` in its top byte, drawn last entry first so the first entry a game
  writes ends up on top, and double-buffered: the chip takes its copy at vblank,
  so a list written during a frame is the one drawn in the next.

## 8. The Board File, ROM Sets, Persistence

### 8.1 The board file is the battery

A CPS-1.5 board is not fully described by its ROMs. The CPS-B-21's register
mapping, its graphics-bank table, and the Kabuki key all live in RAM held up by
a battery on the board; when the battery dies the board keeps its ROMs and
forgets how to be itself, which is what "suicide" means to the people who repair
these things. That per-board configuration is *data on the board*, not silicon.

So this emulator models the battery as a file the user supplies beside their ROM
set: plain `key = value` text in exactly `config.zig`'s format, listing the
CPS-B register offsets, the layer and priority registers, the graphics bank
ranges, the Kabuki key, and how the set's files interleave. It is
human-editable and hand-writable, because on real hardware it is
hand-programmable.

This is also what keeps the repository clean. This project ships no per-board
database and names no board: it reads what it is given, and if the board file is
missing or incoherent it says exactly what it needed and stops, rather than
drawing garbage and leaving the user to guess. A wrong CPS-B offset looks like a
video bug, so failing loudly here is worth more than any fallback guess.

The one board file that *is* committed describes the test ROM this project
builds for itself (§10) — our board, our ROM, our bytes.

### 8.2 ROM sets

A set is a directory of chip images or a zip of the same; zips are read with
`std.zip`, which is in the standard library and needs no dependency. The board
file describes what each file is and how it interleaves — 68000 program ROMs in
even/odd pairs, graphics ROMs interleaved across four or eight chips, the sound
Z80's ROM, and the sample ROMs. Loading verifies sizes and reports a set that
does not add up rather than running off the end of a buffer.

Graphics are decoded once, at load, into a linear byte-per-pixel buffer. That is
the biggest allocation the program makes and it happens exactly once per set.

### 8.3 Save states

Because all machine state is plain structs owned by value (§3.2), a state is a
small versioned header plus a straight copy of the machine's bytes and the two
CPUs'. There is no per-field serializer to forget a field in, which is the usual
way save states rot. The header carries a comptime hash of every field's name,
type and offset, so a state written by a different build is refused rather than
loaded as garbage, and the heap slices (§3.2) are reattached after the copy.
Slots are files beside the set.

### 8.4 EEPROM

A QSound board has no DIP switches: its settings live in a serial EEPROM at
`0xf1c006` and are edited in the board's own service menu, which is why §5.1
requires the service and test inputs. The EEPROM is emulated as the small serial
device it is and backed by a `.nv` file beside the set, read when the set is
loaded and written on exit and on a debounce — the same shape zigesis uses for
cartridge saves, for the same reason: a game writes its settings a byte at a
time.

## 9. Milestones

Each milestone is a shippable deliverable with acceptance criteria. Do them in
order; do not start a milestone with the previous one's tests red. Each one ends
by writing its ceilings into this document.

The repository, its three workflows, and the `check`/`test` harness land with
this document, ahead of M0: `zig build test` is green and meaningful from the
first commit, because the copied resampler and snow modules bring their own
tests with them.

### M0: The machine, ROM sets, board files, headless runner

Deliverables: z68k and z80 as dependencies; `cps.zig` with the memory map and
bus; `romset.zig` and `board.zig` with their unit tests; `config.zig` and
`input.zig`; the headless runner (`--frames N`, frame hashing, deterministic
replay from an input log); the module graph enforcing that nothing but
`main.zig` and `ui/shell.zig` can reach raylib.

Acceptance: a set and its board file load, the 68000 runs from its reset vector,
a set that does not add up is rejected with a message naming the problem, and
two runs of the same input log hash identically on two platforms.

**Ceilings left behind.** Corrections to this document, made where they belong:
the refresh rate in §3.3, and three entries in §7.1's map — the program ROM
window is 2 MiB not 4, the CPS-B file ends at `0x80017f` not `0x8001ff`, and the
table was missing the system inputs at `0x800018` and the sound ROM the 68000
can read back at `0xf00000`.

What M0 deliberately does not do, and where each is picked up:

- **No interrupts at all.** The 68000 runs a line's cycles and nothing ever
  raises IPL, so a real game spins in its wait loop. Vblank at level 2 is M1's,
  the raster at level 4 is M2's.
- **Nothing is drawn.** The framebuffer exists so that the hash and the save
  state have their final shape now, and stays blank until M1. `--frames N`
  therefore hashes the whole machine — RAM, graphics RAM, the register files,
  the CPU — and not the picture alone, or it would hash the same on every run
  of every set and prove nothing. Keep it hashing all of that once video lands.
- **No sound board.** The Z80 is a dependency in the build graph and nothing
  more; `0xf00000` reads back the audio ROM, the shared RAM windows are plain
  memory, and no one is on the other side of them until M3. Kabuki decryption
  is M3's, QSound is M4's, and `--hash` gains an audio hash with them.
- **No EEPROM.** `0xf1c006` floats; §8.4's serial protocol arrives with save
  states at M6.
- **Coin counters and lockouts latch and do nothing.** They are written by
  games and the write has to land somewhere.
- **No `--record`.** A replay log is a file of one 32-bit word a frame, which
  the tests write directly; recording one from a window needs the window, so it
  arrives with M5.
- **Graphics decode is per-row and unaddressed.** The 4bpp interleave is undone
  at load into a byte per pixel, but nothing yet turns a tile code into an
  offset in that buffer — bank ranges and layout selection are M1's.
- **The 68000 carries no timing debt.** 7680 reference ticks a line divide by
  10 exactly. §3.3's debt machinery is real and arrives with QSound's 4992 at
  M4; only the overrun of an instruction across the line boundary is carried now.
- **One real board's numbers appear in `board.zig`, as a test fixture.** §8.1
  says no board is named in the repo; this one is a string literal inside a
  parser test, because a parser test needs something real to parse. It stays a
  test fixture, is not shipped, and must not grow siblings.

### M1: Video I — tilemaps

Deliverables: the CPS-A register file; the palette copy out of graphics RAM
including the page-0 quirk; the three tilemap layers rendered per line into the
framebuffer; vblank at level 2.

Acceptance: the in-repo test ROM (§10) draws its tilemaps and matches pinned
line hashes; unit tests that poke graphics RAM directly cover tile fetch,
scrolling, and the palette quirk without needing a ROM at all.

**Ceilings left behind.** One correction to this document, made where it
belongs: §7.1 said the three tilemaps are each 512 pixels wide. All three name
tables are 64 tiles square, so they are 512, 1024 and 2048 pixels wide.

What M1 deliberately does not do, and where each is picked up:

- **The layer order is fixed: scroll3, then scroll2, then scroll1.** The CPS-B
  layer control picks the real order out of four two-bit fields, the layer
  enables gate each one, and the video control word gates scroll2 and scroll3
  again. All of it is read from the board file already and none of it is
  consulted; it lands with sprites at M2, because the order only means anything
  once there is a sprite layer to interleave.
- **No priority masks, no sprites, no starfields, no row scroll, no flip
  screen, no raster interrupt.** Every one of them is M2's.
- **Vblank is held for one line, not until the acknowledge cycle.** The real
  board drops IPL1 when the 68000 acknowledges the interrupt; z68k has no
  acknowledge hook, so the line after vblank is stepped instruction by
  instruction and the pin is dropped the moment the vector is entered. That is
  exact for a handler that runs at all, and wrong only for a game that masks
  level 2 across all 768 cycles of line 240 — it misses that frame. An
  acknowledge callback in z68k would settle it properly.
- **The palette is copied on the write to the base register and nowhere else.**
  That is what §7.1 describes and what the hardware is understood to do, but the
  timing of the copy against the beam is not modelled: a game that writes the
  base register mid-frame gets the whole new palette from the top of the frame.
- **The in-repo test ROM is hand-emitted 68000 opcodes.** §10 calls for a ROM
  built with CCPS; the toolchain is not in the tree, and a nine-instruction
  program walking a table of writes proves the same path. The CCPS build arrives
  with the milestone that needs a ROM to *report* something — sprites and
  QSound — rather than just to draw.

### M2: Video II — sprites, priority, raster

Deliverables: the object list; the CPS-B layer control, layer enables and the
four priority masks; row scroll; the two starfields; flip screen; the raster
interrupt at level 4, at the programmed line.

Acceptance: pinned frame hashes for the test ROM's scenes, including one that
changes scroll mid-frame from the raster interrupt; a scoreboard step
(`zig build testrom`) that walks the ROM's pages and fails when a pinned score
moves in either direction, which is this project's equivalent of a conformance
ROM and the reason the test ROM is worth writing.

**Ceilings left behind.** Corrections to this document, made where they belong:
§7.4's raster entry was quoting an older driver — there is no enable bit and
there are no line registers, and the confirmed counters are written there now,
along with the confirmed priority and object-list semantics. The board file
gains two lines with them: `raster_line`, which defaults to `none` because IPL2
is not wired on every B board, and `layer_enable`, whose five masks are in the
chip's own order — scroll1, scroll2, scroll3, stars1, stars2 — and not the order
of the layer field in the layer control word.

What M2 deliberately does not do, and where each is picked up:

- **The raster interrupt is raised at the line boundary.** CPS-B has a third
  counter, at `0x0e`, that delays the interrupt by a count of dot pairs into the
  line; it is read and ignored, so a handler that writes a scroll register gets
  its change from the top of the next line rather than from partway across one.
  The counter is there to be added when a game is seen to tear at the wrong dot.
- **Level 4 is dropped after one line if the CPU never took it**, exactly as
  M1's vblank is and for the same missing z68k acknowledge hook. A frame in
  which both fire on the same line asserts level 6, which is right, but two
  raster counters set to the same line are one interrupt and not two.
- **Flip screen turns the finished line round.** The 384x224 window is centred
  in the 512x256 space the counters scan, so a 180-degree rotation of the
  picture is the same picture the board would put out — for a still frame. A
  game that writes a scroll register from a raster handler under flip gets the
  change on the mirrored line, because the line the CPU is interrupted for is
  no longer the line being drawn.
- **The starfield enable bits are crossed, as MAME has them:** the mask its
  tables call stars1 turns on the field that scrolls with the STARS2 registers.
  Board files are written against those tables, so tidying it here would only
  move the crossover into every board file.
- **The starfields are drawn under everything.** They are painted before the
  layer passes rather than taking a slot of their own, which is what the driver
  does; whether the layer control can put a tilemap under them is not known.
- **Sprites are 16x16 and nothing else.** The object list's block fields are
  honoured, but there is no CPS2-style object DMA and no sprite masking beyond
  the priority bitmap.
- **The picture is still built a whole line at a time.** Everything a game
  writes during a line lands on that line, which is enough for scroll and
  palette changes from a raster handler and wrong for a game that changes a
  register partway across a visible line.
- **The scoreboard scores pixels by palette page.** The acceptance ROM gives
  every page a red nibble of its own, so a page count says which layer put what
  on screen — but two layers that swap identical pictures score the same. The
  frame hash beside each score is what catches that.

### M3: The sound board

Deliverables: the Z80 wired with real bus semantics and banking; `kabuki.zig`
and the `z80Fetch` hook (a z80 tag bump); the shared-RAM command path from the
68000; the audio pipeline — the copied mixer plus §6.2's upsampling path, with
its measurement — driven by a command-logging stub in place of the DSP.

Acceptance: a sound driver executes under trace and issues QSound register
writes in a sane order; the pipeline is proven end to end with a synthetic
source, including the measured image floor; the machine keeps running at the
right speed with audio pacing it.

**Ceilings left behind.** The measurement §6.2 asks for, first, because it
changed the filter: raising 24.038 kHz to 48 kHz leaves a floor 55 dB under a
3 kHz tone, and what is left at that floor is not the image but the spurs a
quantised fractional delay puts either side of the tone — the image itself is
below them. Coming down, 32 filter phases were enough, because the bank is
walked once every 4.66 input samples; going up it is walked on every output
frame, and 32 phases measured -48 dB. Each doubling buys 6 dB (64: -49 dB, 128:
-55 dB, 256: -61 dB) until the taps' own stopband takes over, so the bank is 128
phases now and 33 KB of table. The mixer also lost the second source it
inherited from zigesis: a QSound board has one sound chip, and summing two was
code with nothing to sum.

What M3 deliberately does not do, and where each is picked up:

- **There is no `z80Fetch` hook.** The pinned z80 has no way to tell the bus
  that a read is an opcode fetch, so which of the two Kabuki views a read gets
  is decided by a cursor: the address the next instruction byte is due at, put
  back on the program counter before every instruction and walked forward by
  each byte the instruction fetches. It is wrong only for a data read that
  lands exactly on the next unfetched byte inside the encrypted half, which a
  driver has no reason to do. The hook is still owed upstream, and the cursor
  goes with the tag bump.
- **The DSP is a stub that logs.** Register writes land in the file and in a
  32-entry window on the driver; `qsound.sample` returns silence. The rate, the
  debt that produces it, the resampler and the ring are real, so M4 replaces one
  function and nothing else.
- **The chip is sampled after the Z80 has had the whole line**, rather than in
  step with it, so a register written mid-line takes effect from that line's
  first sample: 16 samples of slack at 24 kHz on where a note starts.
- **The two CPUs meet only in shared RAM, a line at a time.** The 68000 has its
  line and then the Z80 has its own, so a posted command is read one line later
  at worst. Nothing on the board makes the two CPUs meet anywhere else.
- **A set with no sound ROM has no sound board at all.** The in-repo test ROM is
  one: rather than let a Z80 fetch 0xff out of empty space and spend the run
  taking RST 38, the sound board is skipped when its region is empty.
- **Audio pacing is measured, not felt.** With no window there is no device to
  pace against, so what the headless runner proves is that a frame produces
  48000/59.6374 output frames and that the ring is drained every frame. The
  device's own clock becomes the pace at M5, and that is where a fill-level
  policy belongs.
- **Nothing resets or halts the sound board from the main board.** The Z80 comes
  up with the machine and runs until it stops; a game that expects to hold it in
  reset would not notice, because there is nothing yet for it to hear.

### M4: QSound

Deliverables: the sixteen PCM channels with bank, start, pitch, loop, end,
volume and pan; the pan/FIR path; the echo; per-channel mute for debugging.

Verification is differential, not by ear, exactly as zigesis validated its FM
core against Nuked-OPN2. `tools/fetch_qsound_reference.sh` fetches ctr's
BSD-3-licensed `qsound-hle` (commit-pinned, checksummed) into gitignored
`testdata/`; `zig build qsound-ref` drives the same register log into both and
diffs the output sample by sample; `zig build test` includes it when the
reference is present and skips the whole step when it is not, so a fresh
checkout is still green.

Acceptance: a published deviation table per case (channel playback, looping,
pitch, panning, echo), audio hashes pinned in the regression suite, and every
deviation either fixed or named as a deliberate one with its reason.

**Measured.** Five register logs, driven into this core and into qsound-hle one
sample at a time, compared on both channels and on the busy flag a driver spins
on (`test/qsound_ref_test.zig`, against commit `68e63be`):

| case             | samples | differing | worst deviation |
| ---------------- | ------: | --------: | --------------: |
| channel playback |    1007 |         0 |               0 |
| looping          |    1408 |         0 |               0 |
| pitch            |    1110 |         0 |               0 |
| panning          |    1545 |         0 |               0 |
| echo             |    2410 |         0 |               0 |

Nothing deviates on any path a board reaches, so the tolerance in the harness is
zero rather than a figure: a difference of one is a failure. Every deviation
named below is off those paths and is there on purpose.

**Ceilings left behind.** The one that changed the shape of the project first:
about two kilobytes of the DL-1425's mask ROM is committed, in
`src/qsound_rom.zig`. §7.3 rules out running that ROM because the 8 KiB of
*program* in it cannot be redistributed, and that reasoning does not carry to
the coefficients beside it — the three mix curves and the five FIR sets are as
much a fact of the chip as its sample rate, and without them there is no
pan/FIR path to write at all. So they are committed, with their BSD-3
attribution, and the emulator plays on a fresh checkout. qsound-hle itself stays
what §11 calls it: a test-time reference, fetched and never linked in.

What M4 deliberately does not do, and why:

- **The three ADPCM channels are absent**, as §7.3 rules. Their registers are
  not decoded, so a driver that wrote them would hear nothing rather than hear
  something wrong. No known board writes them.
- **Filter mode 2 falls back to mode 1.** §7.3 rules it out too. The state
  register is decoded, so a driver that asks for it shows up as `next_state`
  reading `init2` rather than as silence, and the dry path simply keeps the one
  filter instead of gaining a second.
- **A filter register pointing at nothing leaves the filter as it was.** The
  reference divides a signed offset to find its table, so addresses just under
  the first one wrap to it and load table 0; this returns nothing there. No
  driver points a filter at the DSP's own variables, which is what that range
  is, and the two agree on every address that names a real table.
- **A filter table shorter than 95 taps is zero-padded** rather than read off
  the end of the ROM image, which is what the reference does. Only a register
  pointing into the last 94 entries of the overlap run can reach it.
- **Per-channel mute is not on the chip at all.** It is a debugging control, so
  it sits outside the differential: a muted voice still walks the sample ROM and
  still costs what it costs, and contributes zero to both the mix and the echo
  send. Unmuting it puts it back where the walk left it, not where the driver
  pointed it.
- **The busy flag is modelled on the DSP's own turn, not its clock.** It drops
  on every register write and comes back when the chip finishes a sample, which
  is what a driver's spin loop waits for; combined with M3's per-line sampling,
  a driver waits about a scanline per register write, which is the shape of the
  hardware rather than its exact count.

### M5: Frontend shell

Deliverables: the idle snow; set loading by browser, drag-and-drop and command
line; the menu of §5.2; the board card; key rebinding; config persistence;
window scale and fullscreen; pause and reset; coin, start, service and test
inputs; the EEPROM sidecar.

Acceptance: every required item in §5.1 except save states is reachable from the
menu, works, and survives a restart through the config file; the board's own
service menu can be entered and its settings persist across runs; the idle
window costs negligible CPU.

### M6: Save states

Deliverables: versioned states with slots, hotkeys and menu pages, each row
carrying its age the way zigesis's do.

Acceptance: the round trip is bit-identical under the replay harness — save, run
N frames hashing every pixel and every sample, load, run the same N frames,
identical hashes — and a state from another build is refused rather than loaded.

### M7: Compatibility and polish

Deliverables: a sweep over whatever sets are present, in the shape of zigesis's
`compat.zig`: boot each one headless, run it for a fixed number of frames, and
report whether the CPU halted, whether the picture is blank, how long it has
been still, and whether anything was heard. Nothing pinned, nothing named,
nothing failing — it is triage, and it says where to point a window. Plus the
video state differential of §10, which is what turns a set the sweep flags into
a named bug, and the nice-to-haves of §5.1 as they earn their keep.

Acceptance: every set the author can test boots and plays, and every remaining
issue has a reproduction through the replay harness.

### M8: Debug tooling — deferred by design

Deliverables: the disassembling trace, the video inspectors of §6.3, and the
audio channel scope. Deferred for zigesis's reason: the debugger is worth most
once there is a list of things to point it at, and tracing, replay, frame
advance and per-channel mute already exist by then.

## 10. Testing Strategy Summary

- CPU cores: SingleStepTests conformance, gated in the repo that owns each core.
  Never regress these; a core change lands there and arrives here as a tag bump.
- Machine: deterministic headless runs with pinned frame and audio hashes,
  driven by recorded input logs. Every bug fix adds a case.
- **The free-ROM problem, and how this project solves it.** zigesis could pin
  its hashes to freely distributable homebrew and a public-domain conformance
  ROM. Nothing equivalent exists for this machine, and §10's last rule forbids
  the alternative. So the regression seed is a ROM this project writes for
  itself, with the CPS-1 SDK ([CCPS](https://fabiensanglard.net/ccps/)): our
  source, our binary, our board file, all committed and all redistributable. It
  exercises the layers, the object list, priority, the raster interrupt, the
  palette copy, and a QSound command sequence, and it reports its own results on
  screen so the harness can read them back as text rather than as pixels.
- Hardware behaviour that no ROM reaches is unit-tested by building the state in
  memory — poke graphics RAM, render a line, hash it — the way zigesis tests the
  video modes its test ROMs never enter.
- **What is measured against something outside this project, and what is not.**
  The two CPUs are, and the DSP is: SingleStepTests upstream, qsound-hle at M4.
  The video chip, the CPS-B configuration, the bus and the timing are not. The
  acceptance ROM's pinned scores and frame hashes are this project's renderer
  measured against this project's renderer, which catches a regression exactly
  and a misreading of the hardware not at all. Two outside references close
  that, and neither of them is a gate:
  - **The board's own service menu**, which arrives free with M5. §5.1 requires
    the service and test inputs and M5 delivers them; every board then has a
    diagnostic that draws a crosshatch and colour bars, walks every input, and
    runs a sound test naming the channel it plays. A known-correct picture and a
    known-correct order, reported as text, on any set the author owns. Checked
    by hand.
  - **MAME's debugger as a source of hardware state**, the way jtcps1 verifies
    its video: dump graphics RAM and the CPS-A/B register file at a chosen
    frame, load that state into `Video`, render it, and compare. That is the
    bullet above with the poke coming from a real game rather than from us, and
    it is what separates a wrong renderer from a wrong bus when a set draws
    badly. A dump is derived from a ROM nobody may redistribute, so it lives in
    gitignored `testdata/` and gates nothing. M7's, or sooner the first time a
    real set looks wrong.
- **The homebrew that exists, and why it stays out of the tree.** cal2's CPS1
  diagnostics ROM tests work RAM and shared graphics RAM, checksums the program
  ROMs and plays music, reporting all of it as text — the shape this project
  wants. It is hosted by the author's permission rather than under a licence,
  and it wants a CPS-B-21 C board, so it is something to run by hand once the
  video is solid and never something this repo fetches. The rule below is why:
  not redistributable, so not a gate.
- Non-redistributable ROMs are never committed or fetched, and no test depends
  on one. Anything checked against a board the author owns is reported as such
  and is not a regression gate, because a hash nobody else can reproduce is not
  a test.

## 11. References

Machine and CPUs:

- z68k, the 68000 core, and its DESIGN.md: https://github.com/davidbz/z68k
- z80, the sound CPU core: https://github.com/davidbz/z80
- zigesis, the Genesis emulator this project's standards and frontend come from:
  https://github.com/davidbz/zigesis
- SingleStepTests suites for m68000 and z80:
  https://github.com/SingleStepTests
- MAME's Capcom driver and its Kabuki implementation, and the QSound device —
  read for behaviour, do not copy code: https://github.com/mamedev/mame
- jtcps1, Jotego's hardware-verified FPGA core for this board family:
  https://github.com/jotego/jtcores
- Fabien Sanglard's CPS-1 graphics study: https://fabiensanglard.net/cps1_gfx/
- CCPS, his CPS-1 SDK, which is how this project builds its own test ROM:
  https://fabiensanglard.net/ccps/
- ArcadeHacker's CPS-1 series on the batteries, the CPS-B-21 configuration and
  the Kabuki keys: http://arcadehacker.blogspot.com/2015/04/capcom-cps1-part-1.html
- cal2's CPS1 diagnostics ROM, hosted by permission — run by hand, never
  fetched (§10): https://jammarcade.net/cps1-diagnostics-rom/

Audio:

- qsound-hle: the disassembled DSP program, ctr's from-scratch implementation,
  and the original patents. BSD-3, test-only, the differential reference:
  https://github.com/ValleyBell/qsound-hle
  Its transcription of the DL-1425 coefficient tables is redistributed under
  that licence in `src/qsound_rom.zig` (§9 M4); the code itself is not.
- MAME's `qsound.cpp`, the low-level model that runs the real DSP program, for
  the host-side command and ready-flag handshake.

## License

MIT. See [`LICENSE`](LICENSE).
