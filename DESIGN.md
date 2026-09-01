# zicps: Capcom CP System Emulator

Design document and milestone plan. Audience: coding agents and human
contributors. This document is the source of truth for scope, architecture, and
engineering standards. Read it in full before writing code.

## 1. Goal

Build a complete, playable emulator for Capcom's CP System family. The board
this project started on is CP System 1.5 — the CPS Dash board: CPS-1 video, a
68000 running unencrypted program code, and a separate sound board carrying an
encrypted Z80 and a QSound DSP. CPS-1, CPS-1.5 and the plain CPS-1 sound board
all ship (§9, M0–M9); CP System II is the generation after them and is
specified here as M11–M13. Both CPUs already
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
| `src/common/audio.zig` — polyphase windowed-sinc resampler, exact-fraction rate carry, fixed ring buffer, no allocation and no floats at run time | copied verbatim, tests and all. Needs an upsampling path: this bank only drops a rate (§6.2) |
| `src/common/ui/snow.zig` — the idle screen | copied verbatim |
| `src/common/config.zig` — versioned `key = value` file, unknown keys ignored, values clamped | copied, new fields |
| `src/common/input.zig` — one `Action` enum covering pads and hotkeys, bindings written as key names, host keyboard behind a function pointer | same shape, arcade action list |
| `src/common/state.zig` — header plus `asBytes` of the machine, comptime `layout` hash refusing a state from another build | same technique, this machine's struct |
| `src/common/ui/shell.zig`, `src/main.zig` — menu, file browser, status bar, audio-paced frame loop, screenshots, replay | adapted: the cartridge card becomes a board card, the pad panel becomes a control panel |
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
same thing from the address a read arrives at and the M1 pin's own rule (§9,
M3's ceilings); the hook is still what settles it.

## 3. Architecture

### 3.1 Repository layout

New repository consuming z68k and z80 as Zig package dependencies. Do not fork
either CPU into this repo.

The tree is split by generation, because that is the axis the hardware is split
on: a chip Capcom reused across boards is common, and the wiring of one board is
that board's. Three siblings under `src/`, and nothing at the root of it but the
frontend.

```
zicps/
  build.zig
  build.zig.zon          # deps: z68k, z80, raylib (lazy)
  DESIGN.md              # this file
  src/
    main.zig             # entry point, arg parsing, frontend loop
    common/
      video.zig          # CPS-A / CPS-B: register files, tilemaps, palette
      clock.zig          # the reference tick, the rates, the sound board's line
      soundboard.zig     # sound-board Z80 bus, banking, command latch
      kabuki.zig         # opcode/data decryption, key from the board file
      qsound.zig         # DL-1425, high-level
      ym2151.zig         # the OPM
      oki.zig            # the M6295
      audio.zig          # mixing, resampling, ring buffer to the frontend
      controls.zig       # buttons, panel, what a pad holds
      input.zig          # key bindings on top of controls.zig
      eeprom.zig         # the 93C46, protocol only
      romset.zig         # ROM set loading, interleave, graphics decode
      board.zig          # the board file: what the battery held (§8)
      boards.zig         # the shipped board files, embedded and looked up
      state.zig          # save-state serialization, generic over the machine
      config.zig         # options persistence
      ui/
        shell.zig        # window, menu, board card, status bar
        snow.zig
    cps1/                # CPS-1 and CPS-1.5
      machine.zig        # machine state + bus (memory map, I/O, arbitration)
      video.zig          # object list, starfields, CPS-B protection reads
      scheduler.zig      # this board's frame loop: the order a line goes in
    cps2/                # CP System II — arrives at M11 (§9)
  test/
    system_test.zig      # headless frame-hash regression suite
    compat.zig           # boot every set in a directory, report what happened
    qsound_ref_test.zig  # differential harness against the QSound reference
  boards/                # one board file per MAME set, embedded at build time
  tools/
    fetch_qsound_reference.sh
    fetch_mame_source.sh
    mame_to_board.zig    # writes boards/ from MAME's tables; run by hand
    testrom/             # our own CPS-1 test ROM: source, board file, binary
```

**The one rule the layout exists to enforce: a module under `common/` may not
import from a system tree.** Dependencies point inward — `cps1/` and `cps2/`
import `common/`, never each other, and never the other way round. A shared
module that needs to know which board it is on is not shared; either the
knowledge belongs to the caller, or the seam is in the wrong place. The build
graph is what enforces this, the same way it enforces that only `main.zig` and
`common/ui/shell.zig` can reach raylib: a `common/` module is declared with no
system module among its imports, so the import will not resolve.

Two consequences worth writing down, because both look like exceptions and are
not. `common/kabuki.zig` decrypts a CPS-1-only Z80 ROM, but it is a pure
key-and-bytes transform that `common/soundboard.zig` calls from `load()`;
pushing it into `cps1/` would point a common module at a system tree, which is
the thing forbidden above. And `common/video.zig` holds the CPS-A/CPS-B pair
itself — the register files, the tilemaps and the palette, which MAME's
`cps1_v.cpp` shares between both generations verbatim — while each system's
`video.zig` holds its own object list and the order its passes go down in,
because that is the part the two generations genuinely disagree about.

Module names, not paths, are what `@import` sees: every source file is one
`b.addModule` entry and imports its neighbours by bare name. Inside `cps1/`,
`video` is *this board's* video and the shared chip pair is `chip`; from outside
the tree, the same module is `cps1_video`, because there the prefix is what
tells the two apart.

### 3.2 Data-oriented design (mandatory)

Every subsystem is a plain struct of data plus free-standing functions (or
methods that are pure state transitions). No hidden state, no allocation inside
the emulation loop, no callbacks between chips.

- All chip state lives in flat, fixed-size structs: `Video`, `Z80`, `QSound`,
  `Controls`. The whole machine is one `Machine` struct that owns them by value,
  one per generation — `cps1.Machine` today, `cps2.Machine` at M11.
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
graphics, and the sample ROM are heap slices held on `Machine` and reattached
after a save-state load, exactly as zigesis reattaches its cartridge. Nothing else
allocates, and nothing allocates per frame.

### 3.3 Timing model

Single-threaded and clock-driven, as zigesis is — but with one honest
difference. The Genesis has a single 53.693175 MHz master clock that every part
of the machine divides, and the emulator's time base is that wire. A CPS-1.5
board has **three independent oscillators**: the CPU crystal, the 16 MHz video
crystal, and the sound board's own. There is no master clock to divide, so the
time base here is a *reference tick* — the smallest rate that divides all of the
board's into integers — and it is a modelling convenience, not something on the
board.

That reference is **240 MHz** — 120 MHz in the tree today, doubling at M11 for
the reason below — and every CPU rate in the family divides it:

| Part | Rate | Reference divider |
|---|---|---|
| 68000, CPS-2 | 16 MHz | 15 |
| 68000, `cps1_12MHz` | 12 MHz | 20 |
| 68000, `cps1_10MHz` | 10 MHz | 24 |
| Sound-board Z80 | 8 MHz | 30 |
| Pixel clock | 8 MHz (16 MHz crystal ÷ 2) | 30 |
| QSound sample | 24.038 kHz (60 MHz ÷ 2 ÷ 1248) | 9984 |

512 dots per line and 262 lines make 134,144 dots a frame, so the picture runs
at 59.6374 Hz with 384 × 224 of it visible — the same on both generations. One
line is 15,360 reference ticks at 240 MHz: 768 cycles of a 12 MHz 68000, 1024 of
a 16 MHz one, 512 of Z80, and one and a half QSound samples.

The reference was 120 MHz through M10 and doubles at M11 (§9), because 120 does
not divide CPS-2's 16 MHz 68000 — 7.5 — and a fractional divider would put the
main CPU on the debt machinery that exists for the chips that genuinely need it.
Doubling is also what unblocks `cps1_10MHz`, the bug M9 named and deferred:
120 MHz has no integer for 10 MHz either. It is deliberately not folded into
M10, whose whole acceptance test is that no pinned hash moves, because doubling
rescales every integer division in the line loop and any rounding boundary that
shifts would be indistinguishable from a bug the split introduced.

The plain CPS-1 sound board's 3.579545 MHz stays fractional against any
reference worth having, and keeps the debt counters it has had since M9.

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

Explicitly out of scope: netplay, cheats, shader pipelines, per-game databases,
and any protection device a board file cannot describe.

CP System II was on that list until M10 (§9) took the tree apart along the seam
between the chips Capcom reused and the boards that used them; it is specified
as M11–M13 and is in scope. CP System III is not, and it is the reason the split
is by generation rather than by a two-way `if`: CPS-3 is a different CPU, a
different video chip and a cartridge-resident encrypted filesystem, so a machine
that assumed there were exactly two answers would have to be taken apart again.
`cps3/` is a directory nobody has to argue about creating.

CPS-1 boards with the YM2151 and OKI ADPCM sound hardware were on that list
until M9 (§9) took them off it. They were excluded for being a second sound
board on a machine this project calls a QSound machine, which is still what they
are — but they are also 175 of the 194 sets in the library, and a library that
size where nine sets in ten are silent is not the thing §1 set out to build.

A plain CPS-1 board also has three banks of DIP switches where a QSound board
has none, and zicps has no way to turn them: they read as the factory settings.
The one that matters is bank C's demo sounds, which reads zero when it is on —
left the other way, every one of those 175 sets stays silent until someone puts
a coin in.

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
a checksum over the program ROM (M5 correction: said "whether the program
ROM's own checksum matches what is in the header", and there is no such header —
a CPS-1 program image starts at its 68000 reset vectors and carries no checksum
field, so the card shows a sum it computes itself, as a reading with nothing to
compare it against rather than a verdict). Nothing here is looked up anywhere:
every reading comes out of the bytes the user supplied.

The card's second line names the board file itself — `dino.board` when it came
from the user's own file, `dino (built in)` when it came from the shipped
library (§8.1) — because a board file the user did not write is still a claim
about their machine, and which battery is in it should not be a mystery.

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

### 7.5 The other sound board: YM2151 and OKI M6295

Every CPS-1 board that is not a Dash board carries a different sound board, and
175 of the 194 sets in the library are on it. It is a plainer thing than §7.2's:
a Z80 at 3.579545 MHz with no Kabuki in front of it, an OPM for the music and an
ADPCM chip for speech and percussion.

The Z80's map, from MAME's `sub_map`: fixed ROM at `0000-7fff`, the bank window
at `8000-bfff`, 2 KiB of RAM at `d000-d7ff`, the YM2151 at `f000/f001`, the OKI
at `f002`, the bank register at `f004` (bit 0 only, so two banks), the OKI's
pin 7 at `f006`, and the two command latches at `f008` and `f00a`. The bank
window starts at `0x10000` in the audio region, which is where §7.2's board puts
it too.

Two differences from the Dash board matter more than the map does:

- **The 68000 posts commands into latches, not into shared RAM.** It writes
  `0x800180` and `0x800188`, byte-wide, write-only; the Z80 reads them back at
  `f008`/`f00a`. There is no window either CPU can read the other's memory
  through, so §7.2's shared RAM has no counterpart here.
- **Nothing on the board is periodic.** §7.2's Z80 takes an interrupt off a
  divider at 250 Hz. This one takes its interrupt from the YM2151's own IRQ pin,
  driven by the chip's timers, which the driver programs. The divider and the
  chip swap places, and the sound board's interrupt stops being something the
  scheduler can count out on its own.

The clocks are the awkward part. The YM2151 and the Z80 both run at 3.579545
MHz, which is not a divisor of §3.3's 120 MHz reference — but it is exactly
315/88 MHz, so the ratio is a small fraction rather than an irrational one: 21
Z80 cycles to 704 reference ticks, and 21 YM2151 samples (the chip divides its
clock by 64) to 45056. Both get the debt counter §3.3 already uses for QSound's
4992. The OKI is the easy one: 16 MHz over 16 is 1 MHz, over 132 is 7575.76 Hz,
and 15840 reference ticks divide that exactly — 19800 when a game pulls pin 7
low and asks for 6060.6 Hz instead. (Those five figures are against the 120 MHz
reference this section was written under; §3.3's reference doubles at M11 and
every one of them doubles with it.)

### 7.6 CP System II, quoted and not yet measured

Everything in this subsection is read from MAME at the pinned commit
`f34f02505e32c1993c6a782b6814232cbfc74e36` (mame0289), in `src/mame/capcom/`:
`cps2.cpp`, `cps2crypt.cpp` and `cps1_v.cpp`. None of it has been run yet.
Each item names the milestone that will confirm it, in §7.4's style: what is
written here is what the driver says, and what the milestone finds is what
replaces it.

**What is not new.** The reason CPS-2 is three milestones and not a rewrite is
how much of it is the board zicps already runs. `qsound_sub_map` in cps2.cpp is
identical to CPS-1's, down to the 250 Hz interrupt taken from 8 MHz ÷ 32000, so
`common/soundboard.zig`, `common/qsound.zig` and `clock.runSound`'s QSound arm
are reused with no change at all. So are the 93C46, the `gfx_cps1` graphics
decode, the 3072-entry palette, the 384 × 224 picture at 59.6374 Hz, the CPS-A
register file at `0x800100`, and the raster down-counters at CPS-B `0x0e`,
`0x10` and `0x12`. There is no Kabuki: the sound Z80 runs its ROM in clear.

**The memory map** (`cps2_state::cps2_base_map` and `cps2_main_map`), confirmed
at M11:

| Window | What it is |
|---|---|
| `0x000000-0x3fffff` | program ROM, 4 MiB — twice CPS-1's window |
| `0x400000-0x40000b` | the object output latch, mirrored at `0xfffff0` |
| `0x618000-0x619fff` | QSound shared RAM |
| `0x660000-0x663fff` | battery-backed RAM, present only if `0x804030` bit 14 is clear |
| `0x700000-0x701fff` | object RAM bank 0 |
| `0x708000-0x709fff` | object RAM bank 1, mirrored at `0x70e000` |
| `0x800100-0x80013f`, `0x804100-0x80413f` | CPS-A registers, twice |
| `0x800140-0x80017f`, `0x804140-0x80417f` | CPS-B registers, twice |
| `0x804000/0x804010/0x804020` | IN0, IN1, IN2 — the EEPROM's data-out is in IN2 |
| `0x804030` | QSound volume and the RAM-present bits |
| `0x804040` | the EEPROM's three pins |
| `0x8040b0-0x8040b2` | the DIP-switch read, which real boards leave floating |
| `0x8040e0` | bit 0: which object RAM bank the CPU sees |
| `0x900000-0x92ffff` | graphics RAM, exactly where CPS-1 has it |
| `0xff0000-0xffffff` | work RAM |

The 68000 is a 16 MHz part (`M68000(config, m_maincpu, 16_MHz_XTAL)`), which is
why §3.3's reference doubles.

**The encryption**, confirmed at M11. CPS-2 encrypts opcodes only: MAME gives
the CPU a second address space, `decrypted_opcodes_map`, holding a decrypted
copy of the whole 4 MiB program region while data reads see the ROM as dumped.
z68k already has the hook this needs — the `@hasDecl`-gated `setProgram`, added
for zigesis — so no core change is required, and the decrypt is done once at
load into a second heap slice rather than per fetch.

The cipher itself (`cps2crypt.cpp`) is two Feistel stages over a 16-bit word,
keyed off a 20-byte `key` ROM that each board carries beside its program.
`init_cps2crypt` reads that ROM out into ten 16-bit words through a fixed bit
permutation — bit `b` of the output is bit `(317 - b) % 160` of the key — and
then:

- `decoded[0..3]` are the 64-bit master key, as two 32-bit halves.
- `decoded[7]` and `decoded[8]` are the constants `0x4000` and `0x0900`, which
  makes them a free sanity check that a key file is a key file.
- `decoded[9]` sets the address range the cipher covers:
  `upper = (((~decoded[9] & 0x3ff) << 14) | 0x3fff) + 1`, from zero.
- `decoded[9] == 0xffff` is a **dead board** — the battery is gone and the key
  ROM reads as ones. MAME's answer is to encrypt only `0xff0000-0xffffff`, which
  is what a suicided board does: it runs far enough to find out it is dead. The
  frontend should say so on the board card (§5.2) rather than let the user
  wonder why the game is a black screen.

**The video**, confirmed at M12, and the one place CPS-2 genuinely differs:

- Object RAM is two 8 KiB banks. `0x8040e0` bit 0 picks the one the CPU writes,
  and the chip's copy is taken on the vblank edge — CPS-1's double buffering
  done with two banks instead of a copy out of graphics RAM. The bank the chip
  reads is the one at `0x700000`, which is the one the CPU has: a game fills the
  far window at `0x708000` and then flips, and no game writes the near one.
- The object list is drawn over every tilemap rather than in a layer slot of its
  own. The slot the CPS-B layer control still gives it says only where the
  sprites rank; that slot comes out of the order and the maps close up behind
  it, leaving three passes. Each pass ORs its own bit into a per-pixel priority
  plane, `pri_ctrl` ranks the three, and `primasks[8]` turns that ranking into,
  per sprite priority, the set of plane values that sprite is hidden under. A
  sprite pixel that is drawn claims the plane, so sprites never cut each other.
  CPS-1's `Line.over: [width]bool` is the degenerate one-bit case, and M12
  widened the field to `prio: [width]u8`.
- The board's priority-group registers do nothing here. On CPS-1 a tile's group
  names the pens drawn back over the sprites, in a second pass; CPS-2 has no
  such pass, so each of its three passes draws every pen it has and the ranking
  settles the rest.
- A sprite of priority 0 is under everything, including bare background, and so
  is drawn nowhere. `primasks[0]` is `0xff`.
- Sprite coordinates are ten bits, the code takes two more from the Y word, and
  the object output latch carries an X and Y offset the whole plane is panned
  by. The list ends at the first entry with `y >= 0x8000` or `attr >= 0xff00`.
- Graphics ROM arrives riffled: MAME's `unshuffle` undoes it a 2 MiB bank at a
  time, before the `gfx_cps1` decode that is otherwise shared with CPS-1.

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

The file the user supplies always wins, and a board file that is missing or
incoherent stops the load with exactly what it needed rather than drawing
garbage and leaving the user to guess. A wrong CPS-B offset looks like a video
bug, so failing loudly is worth more than any fallback guess.

Which generation a set is on is a line in that file too: `system = cps1`, added
at M11, with `cps1` as the default so that all 194 committed files and the
pinned hashes that go with them stand unchanged. A CPS-2 board file says
`system = cps2` and carries a `key` region beside `program` (§7.6). It carries
very little else: `cps1_v.cpp` has exactly one row — `{"cps2", CPS_B_21_DEF,
mapper_cps2}` — for all 324 CPS-2 sets, so the half of a CPS-2 board file that
is not ROM lines is a constant, and `tools/mame_to_board.zig` writes the same
eight lines into every one of them. It writes no `cpu_clock` either: every
CPS-2 board is a 16 MHz one, which is what `system = cps2` already means.

But asking every user to transcribe thirty lines out of a C++ file before their
set will run is a wall, and it is a wall nobody else puts up. So a library of
board files ships under `boards/`, one per MAME set, and is embedded in the
binary. Three things make that honest:

- **It is a transcription, not a discovery.** Nobody can read these numbers off
  a chip. Every emulator of this hardware is working from the same published
  research — MAME's `cps1_config_table` in `src/mame/capcom/cps1_v.cpp` — and
  ours says on every line of every file that this is where it came from.
  `tools/mame_to_board.zig` writes them; the output is committed and the tool
  is run by hand. It reads both drivers, because both generations are in that
  one table: a CPS-1 set has a row of its own, and every CPS-2 set is on the
  row called `cps2`.
  A board no table covers at all would be typed out under `boards/hand/`, which
  the tool lists in the index and otherwise leaves alone. Nothing is, since
  M13: the CPS-2 board that was hand-written to bring M11 up is now the tool's
  own output, byte for byte on every line that is not a comment.
- **It is selected by name, which is what everyone else does.** MAME keys that
  table off the romset's short name — the zip's basename — and so does FBNeo;
  jtcps1 picks by `.mra` file name. Nobody identifies a board by hashing the
  set, and the CRC32s in MAME's tables exist to verify a dump, never to name
  one. zicps does the same: `roms/dino.zip` looks for the board called `dino`.
- **It is checked.** Every generated line carries the CRC32 of the dump it was
  written against, so a set under the right name that is not that dump is
  refused by name (§8.2) instead of being drawn wrong.

The order is: `--board <path>`, then `<set>.board` beside the set, then the
board that shipped under the set's name, then a refusal that says both what it
looked for and that nothing ships under that name. The card in the window says
which of the three it got (§5.2), so whose battery is in the machine is never a
mystery.

The one board file that is committed *outside* that library describes the test
ROM this project builds for itself (§10) — our board, our ROM, our bytes.

### 8.2 ROM sets

A set is a directory of chip images or a zip of the same; zips are read with
`std.zip`, which is in the standard library and needs no dependency. The board
file describes what each file is and how it interleaves — 68000 program ROMs in
even/odd pairs or one byte of every two, graphics ROMs interleaved across four
or eight chips, the sound Z80's ROM, and the sample ROMs. Loading verifies sizes
and reports a set that does not add up rather than running off the end of a
buffer.

A ROM line may also carry `crc=` — the CRC32 of the whole file, as MAME records
it. Every generated board file does, and it buys two things. A file that is
there under the right name and is the wrong dump is refused, naming both CRCs.
And a chip that is *not* under the name the board file uses is looked for by
what it hashes to instead: a zip made before MAME last renamed these dumps holds
the right chips under old names, and the CRC in a zip's own directory is enough
to find them without unpacking anything. MAME does the same with the same
numbers. A directory set is matched by name only, because there the CRC would
have to be earned by reading every file.

One file is looked for outside the set as well. A CPS-2 key is twenty bytes,
and most zips in circulation were packed before MAME moved those keys out of
its source and into the sets, so a set that is otherwise complete is missing
the one file that decides whether the game runs at all. A `key` ROM the zip
does not carry is looked for in the directory the zip sits in — beside the
`.board` and the `.nv`, where the user's own files for that set already live —
and only then does the board file's own transcription of that key run the set
(M14). With neither the board is a suicided one. No other region gets that;
every other chip is part of the set or the set is not one.

One dump is bigger than its own CRC says it should be: an 8 Mbit mask ROM read
out of a 16 Mbit socket comes back twice over, and several CPS-2 sets in
circulation carry graphics chips dumped that way. A file longer than the board
file reads gets a second chance on the slice actually read, and loads if *that*
hashes to what the line names. The guarantee is unchanged — the bytes that reach
the region are the dump the board file was written for — and a wrong dump of the
right length is still refused, since only a longer file gets the second hash.

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
- **No EEPROM.** `0xf1c006` floats; §8.4's serial protocol arrives with the
  sidecar at M5 (M5 correction: said M6, with save states).
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
  each byte the instruction fetches. What the custom actually watches is M1,
  which is low for an opcode byte and the prefixes ahead of it and high for
  everything else, so the cursor carries M1 alongside it and decodes prefixes to
  know where the next opcode is due (M5 correction: M3 gave the opcode view to
  every byte read at the cursor, immediates included, which no real driver
  survives — see M5's ceilings). It is wrong only for a data read that lands
  exactly on the next unfetched byte inside the encrypted half, which a driver
  has no reason to do. The hook is still owed upstream, and the cursor
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

**Ceilings left behind.** Corrections to this document, made where they belong.
§5.2's board card cannot check the program ROM against its header, because a
CPS-1 program image has no header. M0's own ceilings above hand the EEPROM to
this milestone rather than to save states at M6, because M5's deliverables name
the sidecar and a board whose service menu forgets everything on exit fails M5's
acceptance, not M6's. And M3's fetch cursor was wrong: it gave the opcode view
to every byte read at the cursor, immediates included, where the custom watches
M1 and M1 is low only for an opcode byte and the prefixes ahead of it. Nothing
in the test suite caught it, because the test ROM was encrypted the same wrong
way; the first real set caught it in one instruction, a `ld sp,$ffff` that came
out as `ld sp,$db50` and put the stack in unmapped space, so the sound board
never wrote the byte the 68000 waits on and the machine hung with the screen
black. The fixture now encrypts the way a board does, and M3's ceiling above
says what the cursor carries.

The idle window's cost, measured under Xvfb with llvmpipe — software
rasterisation, the worst case a desktop can present: 33% of one core at 3x.
What that number is made of is the useful part. At 60 Hz the same window costs
59%, and at 1x it costs 19%, so it is the stretch that costs, not the snow:
generating 160 × 120 bytes of static is the constant term and it is small. The
snow therefore runs at half the frame rate of everything else (`snow_fps`),
which is free — a dead channel does not look any deader at 60. Any machine with
a GPU pays a fraction of this.

What M5 deliberately does not do, and where each is picked up:

- **No save states**, which is why the root menu has five rows and not seven.
  M6 adds them, and the status bar's quicksave age with them: the bar already
  reserves nothing for it, so that field arrives as a field.
- **A rebinding that collides is shown, not refused.** The keys page draws a
  conflicting row in the bad tone (`input.conflicts`), and then lets it stand.
  Refusing it would need somewhere to put the key that was displaced, and there
  is nowhere: the honest answer is to show the user the collision they made.
- **Escape is not bindable.** It is the way out of every page, including the
  rebinding prompt, which is the only reason the prompt can be cancelled at all.
- **The control panel lights player 1 only.** Player 2's buttons are bound, read
  and handed to the machine; there is simply one panel drawn, because a second
  one doubles the width of the bar's left half to show a second player who is
  usually not there.
- **No gamepad.** §5.1 asks for configurable key bindings and this binds keys.
  A pad would need its own binding page and its own axis-to-direction rules,
  and neither is in scope.
- **Fullscreen is borderless at the desktop's resolution**, so the picture
  stretches to whatever that is and the integer scale option does not apply
  while it is on. The scale is remembered and comes back with the window.
- **The browser lists directories and `.zip`, and nothing else.** It is not a
  file manager: there is no typing a path into it, no favourites, and no recent
  sets — §5.1 files that last one under nice-to-have and M7 can have it.
- **Per-channel audio muting is not on the menu.** The mixer has the control
  from M4 and the audio page does not expose it; it is a debugging knob, and
  §6.3's audio scope at M8 is where it belongs.
- **The service-menu half of the acceptance is unverified here.** The EEPROM's
  protocol and its sidecar have unit tests and a round trip, and a real QSound
  set now boots to its attract mode in the window, but nothing has yet sat in
  that board's own service menu and found its settings still there after a
  restart — §10's test ROM has no menu to enter. The rest is M7's sweep.

### M5.5: The board library

Numbered between M5 and M6 because it is what M5 revealed rather than what M5
planned: a shell that loads a set in three ways is no use when the set will not
load without a file the user has to transcribe out of a C++ table first. M6 and
after keep their numbers.

Deliverables: `boards/`, one board file per CPS-1/1.5 set MAME lists, embedded
in the binary and picked by the set's name (§8.1); `tools/mame_to_board.zig`,
which writes them, and `tools/fetch_mame_source.sh`, which fetches the three
MAME files it reads, commit-pinned and checksummed; a `crc=` on every ROM line
and the `byte16` load mode the non-QSound sets need (§8.2); the board card's
provenance line (§5.2).

Acceptance: `zig build boards -- testdata/mame` rewrites `boards/` with no diff;
every embedded board parses in the test suite, so one typo in 194 files fails
the build; each of the seven sets present here boots headless for 600 frames off
the shipped board alone; and the shipped `dino` board produces the frame and
audio hashes the hand-written one does, which is what says the generator
transcribes rather than invents.

**Ceilings left behind.**

- **194 of 233, and 187 of the 194 are untested.** The generator skips a set it
  cannot express exactly rather than guessing: 33 bootlegs whose `cps1_config_table`
  row carries a kludge value MAME's driver acts on and this emulator has no
  model for, plus `sf2reda` (a `ROM_CONTINUE` whose chip MAME loads elsewhere),
  `sf2dkot2` (`ROM_RELOAD`), `gulunpa` (`ROM_FILL` in the graphics region),
  `cworld2ja`/`cworld2jb` (file names with spaces in them, which a board file's
  line cannot hold), and `cps1mult` (64 MB of program ROM against a 4 MB
  ceiling). Of what did get written, only `captcomm`, `cawing`, `dino`,
  `ffight`, `mercs`, `punisher` and `sf2` have been booted; every other file
  says `Untested` in its own header. A wrong mapper in MAME's table is a wrong
  mapper here, and MAME's comments say plainly that some of these PALs are
  substitutes for dumps nobody has.
- **The library is video-only outside QSound, until M9.** A plain CPS-1 board's
  board file carries no `audio` or `qsound` lines, because §5.1 put the YM2151
  and the OKI out of scope when these files were written. Those 175 sets boot,
  draw and are silent, through the same path M3 already had for a set with no
  sound board. M9 is what changes that, and it regenerates every one of these
  files to carry the two regions they are missing. There is also no DIP switch
  model, so they run on their default settings and their service menus are
  unreachable — the EEPROM sets from M5 are the only ones that remember
  anything.
- **The CRC verifies, it does not identify.** A zip under the wrong name finds
  no board rather than the right one, which is the same rule MAME follows and
  the reason `roms/captcomm.zip` here turned out to be `captcommr1`: 12 of 12
  CRCs matched that set and none matched `captcomm`, so it runs off
  `boards/captcommr1.board` and `boards/captcomm.board` correctly refuses it.
  Naming a set by hashing it is a different feature, and no emulator of this
  hardware has it.
- **The name fallback inside a zip is zip-only.** A chip that is not under the
  name the board file uses is found by what it hashes to, because a zip's own
  directory records that (§8.2); a set unpacked into a directory would have to
  be read whole to earn the same, so there it is still matched by name. MAME
  draws the line in the same place.
- **The window has not seen most of this.** The seven sets boot and their
  pictures change on every one of 600 frames, which is what says nothing is
  stuck blank, but no window opened in this environment to look at them. M7's
  sweep is the shape that answer belongs in: it already reports a blank picture
  and a still one, and 194 boards is exactly the input it was written for.

### M6: Save states

Deliverables: versioned states with slots, hotkeys and menu pages, each row
carrying its age the way zigesis's do.

Acceptance: the round trip is bit-identical under the replay harness — save, run
N frames hashing every pixel and every sample, load, run the same N frames,
identical hashes — and a state from another build is refused rather than loaded.

**Ceilings left behind.**

- **The header knows which build wrote a state, not which set.** The comptime
  layout hash catches a machine that changed shape, which is what §8.3 asked
  for; nothing in the file says which game was in. The ROM slices are reattached
  from whatever machine is loaded (§3.2), so a `dino` state read into `sf2`
  would run `dino`'s RAM against `sf2`'s ROMs and produce garbage rather than a
  refusal. What actually prevents that is the path: slots are files beside the
  set, `game.zip.st3` and `game.zip.stq`, so a state is only ever offered for
  the set it was taken from. Copying one by hand defeats it. A set fingerprint
  in the header — the program ROMs' sum §5.2 already computes — is the fix, and
  it is one field whenever it is worth a version bump.
- **768 KiB a slot, uncompressed.** A state is `@sizeOf(Cps)` plus the 68000's
  88 bytes plus a 24-byte header, and the machine is almost entirely graphics
  RAM and framebuffer. Nine slots per set is about 6.7 MB on disk. That is the
  price of the memcpy having no serializer in it, and it buys the property that
  no field can be forgotten. Compression would be one call around the two
  `@memcpy`s if it ever matters.
- **A row's age is read when the page opens, not while it is open.** Nine stats
  a frame for a list that changes twice a session is not worth the syscalls, so
  `main.zig` re-reads them on entry to the page and after a write. A row that
  said "3m ago" keeps saying so while it is looked at. A timer would fix it and
  nothing here needs one yet.
- **The bar's quicksave age is this session's.** It ticks off raylib's clock
  from the last quicksave *this run*, so a fresh window says nothing about the
  quicksave still sitting on disk from yesterday, even though the Load State
  page reads that one's real age off the file. The bar field was specified as
  the age of the thing the user just did, and that is what it is.
- **No rewind, no autosave, no undoing a load.** Loading throws the running
  machine away, including a position nobody saved. zigesis's rewind ring is the
  shape this grows into and it is a different feature: it needs the state to be
  cheap to take many times a second, which is the same 768 KiB problem above.
- **A load rewinds the EEPROM too, and the sidecar follows it.** The battery is
  a field of the machine (§3.2), so it is in the copy like everything else, and
  the next flush writes the rewound contents out to `game.zip.nv`. That is the
  consistent reading — a state is the whole machine at an instant — but it means
  a load can undo a change made in the board's own service menu. MAME keeps NVRAM
  out of its states for exactly this reason; keeping it in is the choice §8.3's
  "a straight copy of the machine's bytes" makes, and reversing it would mean
  the first per-field exception in a design built to have none.
- **Nine slots, unnamed, no thumbnails.** The last one is the quicksave, which
  is why `next_slot` walks eight, and a row carries a label and an age and
  nothing else. A screenshot beside each state is what would make a slot list
  worth browsing rather than counting, and §5.2's card is where that work would
  land.

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

`zig build compat -- roms` is the sweep, `zig build video-diff -- <set> <dump>`
is the differential, and the recent-sets list is the nice-to-have §5.1 had left
owed. What the sweep says about the seven sets on this machine, at its default
1200 frames and `-Doptimize=ReleaseFast`:

```
set              frames  picture     still  sound
captcomm              -  the set has no cce_23f.8f, and nothing in it has crc 42c814c5 either
cawing             1200  drawing         0  peak 11461
dino               1200  drawing         7  peak 11695
ffight             1200  drawing         8  peak 17365
mercs              1200  drawing         0  peak 12023
punisher           1200  drawing         0  peak 6250
sf2                1200  drawing         0  peak 15355

6 booted, 1 refused, 0 worth a window
```

Six boards, three of them QSound and three of them YM2151 and OKI, each with a
credit in it and a game started, each drawing a picture that changes on all but
a handful of frames and each making a sound. `captcomm` refuses for the reason
M5.5 already wrote down: the zip is `captcommr1`, and this emulator verifies a
set rather than identifying one.

The two readings the sweep gets out of a board are only as good as what it does
to it, and both had to be corrected by looking rather than by reasoning. Booted
and left alone, `dino` and `punisher` read `silent` — an attract mode is silent
on purpose, so the sweep now puts a coin in. Given one coin and one press of
start, `sf2` and `cawing` read still for half the run — they were on their legal
notice when start came and were sitting on their title screens by the time it
mattered, so start now repeats every two seconds until the run ends. And `mercs`
read `BLANK`, which was an attract-mode fade to black caught on the last frame:
blank now means flat on *every* frame of the run. Each of those was a bug in the
instrument, and each was found the way §10 says to find one — by rendering the
frame and looking at it.

**Ceilings left behind.**

- **A sweep of seven, not of 194.** The instrument runs over whatever sets are
  present, and what is present here is the same seven M5.5 could boot. The other
  187 board files are still untested, and what the numbers above establish is
  that the sweep reports honestly on a set it can read, not that the library
  works. Anyone with the sets can now find out in about four minutes.
- **The sweep is not a test and does not gate.** It has its own build step
  rather than hanging off `zig build test`, because it needs ROMs the repo does
  not have and must not, and because nothing it prints is a pass or a fail.
  `flagged` — halted, blank, or still for the whole run — is a heuristic that
  says where to look, and a board that legitimately draws one still picture for
  twenty seconds would trip it.
- **One coin, one player, no service menu.** The panel the sweep drives is a
  coin and start, which is enough to get a one-player game running and is not
  enough to reach a board's own settings. There is still no DIP switch model
  (M5.5's ceiling), and the sweep writes no EEPROM sidecar, so a QSound set is
  swept on a battery nobody has ever set up — the same board a first-time owner
  would switch on, which is the right default and is not every board.
- **The differential's MAME side is unverified here.** `tools/mame_video_dump.lua`
  is written against `cps_state`'s own share names and has never been run: no
  MAME binary is installed on this machine. Everything downstream of it has
  been: a dump of `dino`'s own state at frame 1200, written in the Lua script's
  format and fed back through `video-diff`, reads, renders and comes out as the
  right picture — a cutscene, 92 colours, three scroll layers where the register
  file says they are. That round trip also found the one bug in the reader,
  which refused a file of exactly the size a dump is. So what is unproven is
  exactly one thing: whether those three share names are what a MAME build
  exposes.
- **The differential is a frame ahead on sprites, and knows it.** The palette is
  copied on a write to the base register and the object list is latched at
  vblank, so a dump taken at the end of MAME's frame *N* renders here with frame
  *N*'s objects where the board would have drawn frame *N-1*'s. A sprite that
  moved between the two frames is one frame ahead in this picture and nothing
  else is. Two pictures are compared by eye rather than by hash for this reason
  among others.
- **The recent list holds paths, not sets.** Eight of them, most recent first,
  in the options file. A row is a path that loaded once; nothing checks whether
  it still does, because a load that fails already says so and a list that
  quietly dropped the row someone was reaching for would be worse. A path longer
  than 256 bytes is not remembered at all, since half a path is a path to
  nowhere.
- **Per-channel muting is still owed, and is M8's.** §5.1 lists it under
  nice-to-haves and M5 deferred it; M8 is where the audio channel scope lands
  and where a mute per channel costs nothing on top.
- **The window itself is still unproven in this environment.** The recent list
  is pinned by a round trip through the config file, and the shell code that
  draws and walks it compiles, but no window has opened on this machine — X is
  present and unauthorized. That is the same ceiling M5.5 wrote down, and it is
  the one thing here a person with a display closes in a minute.

### M8: Debug tooling — deferred by design

Deliverables: the disassembling trace, the video inspectors of §6.3, and the
audio channel scope. Deferred for zigesis's reason: the debugger is worth most
once there is a list of things to point it at, and tracing, replay, frame
advance and per-channel mute already exist by then.

### M9: The other sound board — YM2151 and OKI M6295

The 175 sets §7.5 describes, playing. This is the largest single addition to
what the machine can be heard doing since M4, and it is the only milestone that
reopens a §5.1 exclusion rather than closing one.

Deliverables:

- `src/ym2151.zig`: the OPM. Eight channels of four operators, the eight
  algorithms, the envelope generator, the LFO with its four waveforms and its
  per-channel PMS/AMS, DT1 and DT2, the noise generator on channel 8's fourth
  operator, and the two timers — which are not an accessory here but the thing
  that drives the Z80's interrupt (§7.5).
- `src/oki.zig`: the M6295. Four voices of Dialogic ADPCM off a shared sample
  table, the phrase-start protocol the driver uses to key them, and the pin 7
  divider, which a game may change while it runs.
- One sound board, two boards. `soundboard.zig` gains a tag saying which board
  it is, and its bus branches on it. Not two modules and not an interface: the
  Z80, the bank window and the ROM views are the same on both, and only the map
  above them differs, so the difference belongs where it is — in the switch that
  is already there.
- The two command latches on the 68000 side, at `0x800180` and `0x800188`.
- An `oki` region in the board file, beside `audio` and `qsound`, and the
  ceiling that goes with it: 256 KiB, which is what all 213 sets in MAME's
  CPS-1 driver use.
- `tools/mame_to_board.zig` stops dropping the audio regions of a set with no
  QSound chip, and `boards/` is regenerated: 175 files gain their `audio` and
  `oki` lines. The library is the deliverable as much as the chips are.
- The timing of §7.5 in the scheduler: the Z80 and the YM2151 on debt counters
  against the 120 MHz reference, the OKI on an exact divisor, and the two chips
  summed into one stream at the OPM's rate — the OKI held between its own
  samples, which is what it physically does.

Acceptance:

- **The OPM is diffed, not eyeballed.** The same register log driven into this
  core and into Nuked-OPM, compared sample by sample, wired exactly as M4 wired
  qsound-hle: fetched into gitignored `testdata/`, a `zig build opm-ref` step of
  its own, folded into `zig build test` only when the reference is present, so a
  fresh checkout stays green without it. M4's experience is the reason this is
  listed first rather than last: the QSound core's accuracy came from the diff,
  not from listening.
- The OKI is checked against its own decoder: a known ADPCM phrase decoded to
  PCM and pinned, plus the step-index clamp at both ends, which is where every
  ADPCM implementation goes wrong.
- A recorded run of a plain CPS-1 set — `sf2`, since it is one of the seven
  M5.5 booted — hashes identically twice, audio included, under the replay
  harness of §10.
- M7's sweep reports something heard for every set that has an `audio` region,
  which is the whole library minus the sets §8.2's ceilings already exclude.

Ceilings, so nobody has to rediscover them:

- The OPM is a model of the chip a sample at a time, not of the die a gate at a
  time, and four things are left in `test/opm_ref_test.zig`'s `allowed`, which
  is 19540 of 8192 full scale on the worst of seven cases. It keys and hears
  all 32 operators on one sample boundary where the die sweeps them across one,
  so a channel's fourth operator starts a sample early and a four-deep
  algorithm multiplies that; its phase increments are a computed equal-tempered
  octave rather than the chip's own approximation of one; its LFO waveforms are
  the published shapes; and its noise is a shift register of the right length
  and not the right polynomial. Everything else was diffed and fixed — the
  envelope's three low-rate counters, the latched counter the fast rates read
  through, the key-on bits being in algorithm order, and the seven PMS depths,
  which are powers of two and then five and eleven of the last, not the
  manual's rounded cents. The per-case table the harness prints on failure is
  the thing to read: a regression moves one case, not all of them.
- The M6295 steps once per scheduler line rather than once per sample edge, and
  its four voices are summed and held between its own samples at a seventh of
  the OPM's rate. Nothing in the library asks for finer.
- M7's sweep does not exist yet, so the acceptance line above is met by the
  `peak` the headless runner now prints beside its audio hash: `sf2`, `cawing`,
  `ffight`, `mercs` and `captcomm` all reach it from attract alone. The QSound
  sets reach it only once coined, because their settings live in a service menu
  and not in a DIP bank — that is M4's board, not this one, and it is open.

Explicitly not in M9: the 68000's clock. `cps1_10MHz` is MAME's base config and
`cps1_12MHz` the override, so roughly half the library currently runs its 68000
20% fast against §3.3's fixed 12 MHz. That is a real bug, it predates this
milestone, and it will be tempting to blame on this milestone's timing work —
which is exactly why it is named here and fixed on its own.

### M10: The split — one tree per generation

No new hardware. Every file at the root of `src/` was named as if it were the
machine (`cps.zig`, `video.zig`, `scheduler.zig`) when each was two things
stirred together: a chip Capcom reused across generations, and the wiring of one
particular board. Adding CPS-2 means answering "which half is this?" for every
file, and doing that while also writing new hardware is how the answers get
chosen to suit whatever is being typed at the time. So this milestone does the
split and nothing else, and CPS-2 lands against a base that already has the
seam.

Deliverables:

- §3.1's three trees: `src/main.zig`, `src/common/`, `src/cps1/`, and the rule
  that a `common/` module may not import from a system tree. Eleven of the
  seventeen files moved with no content change at all, because `@import` sees
  module names and not paths.
- `src/cps.zig` cut three ways along the boundaries that were already in it:
  `common/controls.zig` (buttons, panel, pads), `common/eeprom.zig` (the 93C46
  and nothing about which port drove its pins), and `cps1/machine.zig` (the
  memory map and the bus). The board's knowledge of *which bit is which wire*
  stays on the board, in `eepromPins`.
- `src/video.zig` cut in two: `common/video.zig` keeps the CPS-A/CPS-B pair —
  register files, raster counters, palette, the tilemap table and `drawTilemap`,
  and `beginLine`/`drawLayer`/`emit` so that each system's `renderLine` stays
  short — and `cps1/video.zig` keeps the object list, both starfields, the
  CPS-B protection reads, and the order CPS-1 interleaves its four passes in.
- `src/scheduler.zig` cut in two: `common/clock.zig` takes the reference rates,
  the sound board's share of a line, and a `Timing` struct holding the ten debt
  counters that used to be fields on the machine; `cps1/scheduler.zig` keeps the
  frame loop, which is this board's order and not a shared one.
- `common/state.zig` becomes `Format(comptime M, comptime C)`, so the save-state
  layout hash is computed per machine type rather than for the only one there
  used to be.

Acceptance: `test`, `testrom` and `compat` all green with **every pinned frame
and audio hash unmoved** — that is the whole acceptance test for a milestone
that is supposed to change nothing. The one deliberate break is
`state.layout_hash`, which moves because the `Timing` fields left the machine
struct, so save states written before M10 are refused. That is the documented
purpose of that hash (§8.3) and not a regression.


Ceilings left behind:

- `common/video.zig` has no tests of its own. The rendering tests nearly all
  drive `renderLine`, which is CPS-1's, and they share their fixtures; they
  moved to `cps1/video.zig` whole rather than being split down the middle. The
  common half is covered through them. Give it tests of its own when CPS-2's
  `renderLine` gives it a second caller to test against.
- `Line.over` is still `[width]bool`. Widening it to a priority plane before
  M12 would be guessing at a shape with one implementation to fit.
- There is no `Machine` tagged union, no `system` board key and no `max_gfx`
  raise. With one arm a union is a switch with one case, and the board key would
  touch all 194 committed files for no behaviour; both arrive at M11 with a
  second generation to justify them.
- The 240 MHz reference is not in M10, for the reason §3.3 gives.
- One real bug was found by the differential and is worth naming, because it is
  the failure mode this kind of change has: `cboard` in `cps1/machine.zig` was
  left calling the *common* `readB` instead of CPS-1's, so the board ID read
  came back as open bus and every plain CPS-1 set failed its boot check four
  frames in. The unit tests and the test ROM stayed green — neither has a board
  ID to check — and `compat` against real sets is what caught it. A behaviour-
  preserving change is only as good as the thing that says behaviour was
  preserved.

### M11: CPS-2 boots

Deliverables:

- §3.3's reference doubles to 240 MHz, with its own re-pin of every hash, on its
  own commit, ahead of anything CPS-2. `cps1_10MHz` is fixed here too: it is the
  same change and M9 deferred it to exactly this point.
- `src/cps2/machine.zig`: §7.6's memory map. `src/cps2/scheduler.zig`: the frame
  loop, which reuses `clock.runSound`'s QSound arm unchanged.
- `src/cps2/crypt.zig`: the two-stage Feistel of §7.6, decrypting the whole
  program region once at load into a second slice, handed to z68k through
  `setProgram`. Its unit test is MAME's own: a known set's first sixteen
  decrypted opcodes, pinned.
- `romset.zig` gains a `key` region and the decrypted buffer; a dead key
  (§7.6's `decoded[9] == 0xffff`) loads and says "suicided board" on the card
  rather than being refused, because that is what the hardware does.
- `main.zig` grows the `Machine` tagged union with its second arm, and
  `board.zig` the `system` key of §8.1.

Acceptance: one CPS-2 set reaches its boot self-test and passes it, with sound.
`compat` grows a second directory and reports it separately, because a CPS-2 set
with no video yet is "blank" for a reason that is not a fault.


Ceilings left behind:

- **The acceptance is unmet, and cannot be met here.** A CPS-2 key is part of a
  set, not part of MAME: modern `cps2crypt.cpp` reads it from the set's own
  `key` region and carries no table of its own. None of the six sets in
  `roms/cps2` has one — they are all pre-key-era dumps — so no board on this
  machine decrypts, and none reaches its self-test. `ddtod` loads, says
  `SUICIDED BOARD` on the card, runs its own ciphertext and halts on the first
  frame, which is what the hardware does with a flat battery. Everything under
  the key is exercised: the map and its tests, the frame loop, the QSound arm,
  and the decryptor against MAME's own output. Put a set with a key in
  `roms/cps2` and the acceptance answers itself.
- For the same reason the crypt pin is not "a known set's first sixteen
  decrypted opcodes" but sixteen NOPs at sixteen addresses under a made-up key,
  with the expected words taken from `cps2crypt.cpp` compiled and run on the
  same input. It pins the same arithmetic; it does not pin that a real board's
  program comes out as 68000 code. Re-pin it against a real set when one is at
  hand.
- The `Machine` union is `src/machine.zig`, beside `main.zig` rather than inside
  it as the deliverable says. `test/compat.zig` needs the same union, and §3.1
  will not have it under `common/` because it knows both trees. Beside the
  frontend is the only shelf left.
- CPS-2 graphics load and decode into nothing. MAME unshuffles each 0x200000
  bank of the region before the ordinary tile decode runs, and neither that nor
  the object hardware that would draw the result is here; the region is carried
  so that M12 has something to point at.
- The program region is decrypted on every reset rather than once at load —
  2.5 MiB for `ddtod`, a few milliseconds. It is once a machine in practice.
  Move it into the set if reset ever has to be cheap.

### M12: CPS-2 video

Deliverables:

- `common/video.zig`: `Line.over` widens to `prio: [width]u8`, and what a
  tilemap pass leaves in that plane becomes a parameter — `.pens` for CPS-1's
  high-pen mark, `.pass` for CPS-2's bit per pass, `.none` for a layer nothing
  is settled against. CPS-1's `renderLine` is re-expressed against it in two
  lines: the mask flag becomes `.pens`, and `if (l.over[dx])` becomes
  `if (l.prio[dx] != 0)`. Its hashes do not move, which is what shows the
  widening is a generalisation and not a rewrite.
- `src/cps2/video.zig`: the vblank latch of the object list and its ranking, the
  sprite entry decode of §7.6, `layerOrder` — the sprite slot taken out of the
  layer order and the `primasks[8]` derivation — and the per-pixel compositing.
- `src/cps2/machine.zig` gains the latched `obj` copy and `pri_ctrl`;
  `src/cps2/scheduler.zig` draws a line per line and latches on the vblank edge,
  in the order CPS-1's does.
- `romset.zig` unshuffles each 0x200000 bank of a CPS-2 graphics region before
  the ordinary tile decode, rounding the region up to a whole bank first so that
  the last one is unshuffled whole whether or not chips fill it.

Acceptance: the M10 hashes stand — `zig build test` and `zig build testrom` pass
unchanged, and the `roms/cps1` sweep is what it was. The other half is unmet;
see below.


Ceilings left behind:

- **"A CPS-2 set draws its attract mode" cannot be shown here**, for M11's
  reason and no new one: no set in `roms/cps2` carries a key, so `ddtod` is a
  suicided board, runs its own ciphertext and halts on the first frame with
  nothing on screen. What the sweep prints is what M11 left. The video path is
  driven directly by unit tests instead — the bank latch, both end markers, the
  mask table against MAME's own numbers, the offsets, the flips, the block-code
  wrap, and a line taken through `renderLine` into the framebuffer. Put a keyed
  set in `roms/cps2` and the acceptance answers itself.
- The two pins that stand in for a real set are taken the same way M11's crypt
  pin was: MAME's `unshuffle` and `render_layers` compiled and run over inputs
  this repo chose. They pin the arithmetic, not that a real board's graphics
  come out as tiles.
- A sprite code past the end of the graphics region draws as transparent, where
  MAME wraps it modulo the number of tiles the region holds. Ours is the honest
  reading of an empty socket and it costs nothing to keep; revisit it if a set
  turns out to rely on the wrap.
- `compat`'s CPS-2 exemption is now only for a suicided board. A CPS-2 set that
  boots is judged blank, halted or still exactly as a CPS-1 one is.

### M13: The CPS-2 board library

Deliverables: `tools/mame_to_board.zig` emits CPS-2 rows — one constant register
mapping for all 324 sets (§8.1) — and `boards/` gains them; `max_gfx` goes from
16 MiB to 64 MiB, which is what the largest CPS-2 sets need; `compat` sweeps
both libraries.

The tool reads `cps2.cpp` beside `cps1.cpp` and runs every set in both through
the same `build`: the ROM map is the set's own, and the row it is on is either
its own or `cps2`. The rest is three small things — `key` becomes a region name
the ROM map recognises, `system = cps2` is written where the default is not
`cps1`, and no `cpu_clock` is written at all for a CPS-2 board, because 16 MHz
is what `system = cps2` already means.

Acceptance: met. `boards/` ships 516 files, 322 of them CPS-2, and every one
parses, is under its own name once, and answers `find` — the same three tests
that gate the CPS-1 library, over both. The generated `ddtod.board` is the
hand-written one M11 was brought up on, byte for byte on every line that is not
a comment, so `boards/hand/` is empty and the M11 and M12 results stand
unchanged. The M10 hashes stand: `zig build test` and `zig build testrom` pass,
and the `roms/cps1` sweep is what it was — no CPS-1 board file moved.

What the sweep says, on `roms/cps1 roms/cps2` at 1200 frames:

- The six CPS-1 sets are what they were, and `captcomm` is refused for the
  reason it was before this milestone: that zip is a different dump of the set,
  and the CRC on the board line says so.
- All six CPS-2 sets load and run on a board file that ships. All six are
  suicided boards, so what they do afterwards is not news: `armwar` and `mvsc`
  draw ciphertext, `msh` and `sfa3` stay blank, `ddtod` and `avsp` halt on the
  first frame. This is M11's ceiling and no new one — no set in `roms/cps2`
  carries a key.

Ceilings left behind:

- **Two of MAME's 324 sets get no board file.** `gigaman2` has no `key` region,
  an 8051 where the sound Z80 goes and an OKI where QSound goes: it is in that
  driver for what it copies, not for what it is. `ssf2us2` has a dump whose file
  name has a space in it, which a board file line cannot hold — the same
  limitation two CPS-1 sets already hit. Both are named in the tool's summary.
- **41 CPS-2 sets have a `ROM_FILL` of zeros at the bottom of their graphics
  region, and the board file does not say so.** Those are chips the B-board
  does not carry, and the loader now reads an unpopulated CPS-2 graphics byte as
  0 rather than as an erased EPROM's 0xff: a tile fetched out of an empty socket
  comes back as pen 0, which is the transparent one and the same reading M12
  gave a code past the end of the region. A fill of anything else, or into any
  other region, is still a set this tool turns away — one CPS-1 bootleg,
  `gulunpa`, is.
- **A shipped board file is a transcription, and 322 more of them are 322 more
  claims nobody here has checked against a board.** Every CPS-2 file says
  `Untested` in its header, and none of them can say otherwise until a set with
  a key is at hand. The `booted` list in the tool is still seven CPS-1 sets.
- The 64 MiB `max_gfx` is a ceiling on the region a board file may name, not a
  measurement: the largest set anyone has dumped, `mmatrix`, fills half of it.
- `boards/` is 2.1 MB of text now, and all of it is embedded, so the binary
  carries about a megabyte more than it did. Reading the library off disk would
  buy that back and cost the one property that makes it worth having: that
  `zicps sf2.zip` needs nothing beside it.

### M14: The key the battery held

Deliverables: a CPS-2 board file carries `crypt = <master high> <master low>
<lower> <upper>`, the 64-bit master key and the byte range it covers, and a set
that arrives without its own twenty bytes runs on that instead of on its own
ciphertext. Plus one frontend fix that is not about keys at all: a halted 68000
no longer tears the window down (§5.2), because on this generation halting is
something a board does on the bench.

Where the numbers come from is the whole of this milestone. MAME kept the CPS-2
keys in its source until 0.178 moved them into the ROM sets, so 0.289 — which
the rest of `boards/` is transcribed from — is the one release that cannot say
what a dead board's battery held. `tools/fetch_mame_source.sh` gained a second
pin for exactly two files, `src/mame/machine/cps2crypt.h` and
`src/mame/drivers/cps2.cpp` at `mame0176`, kept under names of their own because
the driver has the same file name in both releases and is not the same file.
The header defines one `CRYPT_PARAMS( key1, key2, lower, upper )` macro per key
and the driver names one macro per `ROM_START`, so a set's key is the macro its
block mentions. That is the same kind of published BSD-3-Clause research as the
Kabuki keys every CPS-1 file already carries, and §8.1's three conditions cover
it unchanged: it is a transcription, it says so in its own header, and a file
the user supplies beats it.

**The set's own key always wins.** `decrypt` (`cps2/scheduler.zig`) reads the
`key` region first and only falls back when it reads dead, because a real
battery beats a transcription and because a `.key` beside the zip (§8.2) is the
user's file. The card row says which of the three happened — `DECRYPTED`,
`BOARD FILE`, `SUICIDED BOARD` — so it is never a mystery which key ran.

Acceptance: met, and this is the first end-to-end evidence that any CPS-2 board
file in the library is right. `zig build compat -- roms/cps1 roms/cps2` at 1200
frames: all six CPS-2 sets draw and make sound (`avsp` peak 25351, `mvsc` 18548,
`ddtod` 22180, `armwar` 9861, `msh` 6509, `sfa3` 5007), where before this
milestone two of them halted in frame 1 and the rest drew ciphertext or nothing.
The CPS-1 sweep is unmoved — 6 booted, 1 refused — and the M10 hashes stand.
Regenerating `boards/` adds a `crypt` line to 254 of the 322 CPS-2 files and
changes nothing else but their header comment.

Ceilings left behind:

- **68 CPS-2 sets get no `crypt` line**, and the tool lists all of them. 44 are
  the Phoenix sets, whose programs are already decrypted and whose key is
  *meant* to read as erased — a key there would be wrong. The other 24 are sets
  0.176 never had, added or renamed since (`1944u`, `19xxu`, `armwarb`,
  `mshbr1`, `progearu`, `ssf2tbu`, …). Those still run as suicided boards
  without a `.key` of their own.
- **These keys are transcribed, not measured**, like every other number in a
  board file — and unlike the rest, they come from a MAME the remainder of the
  library does not, which is a second pin to keep in step. A key that decrypts
  to a program that runs is self-checking in a way a register offset is not,
  but only for the sets anyone here has run.
- **Six sets is what has been watched.** 316 CPS-2 files still say `Untested`,
  and `booted` in the tool is still seven CPS-1 sets: `compat` proves a set
  draws and makes noise for 1200 frames, not that it plays correctly.
- A halted machine now keeps its window, so `compat`'s `worth a window` and the
  headless `--frames` are still the only things that notice a halt. That is
  deliberate: the frontend says it in a toast and on the card instead.

## 10. Testing Strategy Summary

- CPU cores: SingleStepTests conformance, gated in the repo that owns each core.
  Never regress these; a core change lands there and arrives here as a tag bump.
- Machine: deterministic headless runs with pinned frame and audio hashes,
  driven by recorded input logs. Every bug fix adds a case.
- **The free-ROM problem, and how this project solves it.** zigesis could pin
  its hashes to freely distributable homebrew and a public-domain conformance
  ROM. Nothing equivalent exists for this machine, and §10's last rule forbids
  the alternative. So the regression seed is a ROM this project writes for
  itself: our source, our binary, our board file, all in the tree and all
  redistributable. It exercises the layers, the object list, priority, the
  raster interrupt, the palette copy, and a QSound command sequence.
  It was planned as a CCPS ([the CPS-1 SDK](https://fabiensanglard.net/ccps/))
  project and built as fourteen 68000 instructions assembled by
  `test/system_test.zig`, driven by a table of register writes with one entry
  per scene and the scene chosen from the controls at reset. A toolchain nobody
  has to install, a ROM image no build step has to produce, and the same
  coverage. It reports itself the same way, without needing a font: the palette
  puts the page number in each pixel's red nibble, so counting finished pixels
  per page reads back as a row of numbers rather than as an image nobody can
  diff by eye.
- Hardware behaviour that no ROM reaches is unit-tested by building the state in
  memory — poke graphics RAM, render a line, hash it — the way zigesis tests the
  video modes its test ROMs never enter.
- **What is measured against something outside this project, and what is not.**
  The two CPUs are, and both sound chips with a die behind them are:
  SingleStepTests upstream, qsound-hle at M4, Nuked-OPM at M9. Both are fetched
  into gitignored `testdata/` and both skip themselves when it is absent, so CI
  fetches them before it builds — a differential that silently did not run is
  worse than one that is not there.
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

MIT. See [`LICENSE`](LICENSE). The board files under `boards/` are
transcribed from MAME's CPS-1 driver and carry its BSD-3-Clause terms; see
[`boards/README.md`](boards/README.md).
