# Wio Terminal under Renode

P1-P4 of [ADR 94](../../../docs/adr/0094-wio-terminal-renode-emulator.md): a
[Renode](https://renode.io) platform that boots this repo's real Wio
Terminal firmware ELFs (`wio`, `wio_walk`, `wio_sd_upload`), reliably and
fast, all the way to their own `loop()` -- instead of only compiling, as
CI's `wio` job does today -- with a real ILI9341 SPI display model and a
real (emulated) SD card behind it, so `wio_walk` reads an actual exported
Nepheshel map off an actual FAT filesystem before anything this platform
still lacks (a DMA controller model) stops it short of a full render.

## Status

**Verified, this platform:**

- All three firmware environments (`wio`, `wio_walk`, `wio_sd_upload`) reach
  their own `setup()` **and** `loop()`, reliably and fast (well under a
  second of wall-clock time for 300 ms of virtual time) -- see below for
  why earlier rounds of this work saw `wio_walk`/`wio_sd_upload` take what
  looked like a fundamental, unfixable amount of wall-clock time to get
  there, and were wrong about why.
- **The ILI9341 display model is verified correct**, directly: **P3's own
  regression test**, `app/wio/renode/lcd_smoke_test.resc`, drives
  SERCOM7/LCD's registers by hand (enable, then a 16x1 CASET/PASET window,
  then 16 red pixels followed by 16 blue) with no firmware involved, and
  `lcd SaveFramebufferPng` dumps the result. Checked with ImageMagick:
  `{8,0}` reads `srgb(255,0,0)`, `{8,1}` reads `srgb(0,0,255)`, `{20,0}`
  (outside the CASET window) stays `srgb(0,0,0)` -- CASET/PASET windowing,
  RAMWR auto-increment addressing and RGB565→RGB24 decode are all correct.
- `wio_walk`, booted with a real SD card attached (P4,
  `scripts/wio_renode_sdcard.bash`), now gets **all the way through
  `SD.begin()` and `draw_map()`'s backdrop fill** -- a real file was read
  off a real (emulated) FAT filesystem. What's on screen at that point is a
  solid, *wrong-coloured* fill, not a rendering bug: `draw_map()` calls
  `fillScreen(to565(backdrop))` before it draws any tiles, and `to565()`
  encodes for a different real-hardware SPI quirk (a byte-swap specific to
  `TFT_eSPI`'s *scalar* single-pixel writes) than `to565_push()` does (the
  same board's *bulk*/DMA writes, what tiles use, and what `ILI9341_SPI`
  was written to expect) -- see the colour-fix session this whole ADR
  exists because of. This platform does not replicate that hardware quirk
  at all (there is nothing to correct for, on either path), so it only
  ever decodes one of the two encodings correctly. This is a known,
  understood cost of not modelling that specific quirk, not a fix TODO.

**Two real bugs found and fixed getting here, not a platform limitation.**
Earlier drafts of this document explained `wio_walk` and `wio_sd_upload`
taking what looked like forever to reach `loop()` as an inherent cost of
this platform running every SPI transfer instantaneously (so any real
`delay()`/`millis()` wait would cost hugely more emulated instructions than
wall-clock time on real hardware). That diagnosis was wrong. The actual
causes were two fixable bugs, found by refusing to accept "it's just slow"
without checking what the CPU's own reads were actually seeing:

- **`SAMD51_SERCOM_SPI` needed `IBytePeripheral`, not just
  `IDoubleWordPeripheral`.** Real SERCOM registers are a mix of widths --
  `INTFLAG` is 8-bit, and this firmware's driver (`SERCOM.cpp` in the
  Arduino SAMD core) polls it with `ldrb`, a byte-sized load. Renode does
  **not** automatically serve a byte access against a peripheral that only
  implements `IDoubleWordPeripheral` -- it logs "Attempted Byte read isn't
  supported by the peripheral" at `NOISY` level (easy to miss unless you go
  looking) and returns 0. `INTFLAG` always reading 0 to the CPU's own poll
  loop -- while a `sysbus ReadDoubleWord` on the exact same address, from
  the Monitor, correctly computed the ready bits -- is what "hangs forever"
  actually was: not a slow but finite retry loop, a genuine live-lock,
  every single byte a device sent, for every firmware that touches SPI at
  all past the clock tree. The fix is two one-line methods
  (`ReadByte`/`WriteByte`, delegating to `ReadByteUsingDoubleWord`/
  `WriteByteUsingDoubleWord`) -- see `SAMD51_SERCOM_SPI.cs` and the
  `SAMD21_GPIO` peripheral it copies the pattern from.
- **Renode's own upstream `SD.SDCard` doesn't implement `ACMD42`**
  (`SET_CLR_CARD_DETECT`), an optional command that only matters for a
  DAT3/CD pin pull-up SPI mode does not use. `Seeed_Arduino_FS`'s driver
  sends it unconditionally during `SD.begin()` anyway and treats *any*
  non-ready response as fatal -- including the "illegal command" R1 a
  correctly-behaving card gives back for a command it does not support,
  which is exactly what `SD.SDCard` correctly did. `SD.begin()` aborting
  right after otherwise succeeding through `CMD0`/`CMD8`/`ACMD41`/`CMD58`
  looked, from this session's side, like it must be more of the same
  delay-cost problem; it was a real (if obscure) driver/card incompatibility
  instead. `app/wio/renode/patches/sdcard-acmd42.patch` adds a harmless
  R1-ready response for `ACMD42`, mirroring how the same file already
  handles `CMD59` (also not really implemented, also given a benign
  response because real drivers expect one).

Once both were fixed, the "delay-cost" theory evaporated along with the
bugs it was actually describing: SD init, FatFs directory traversal and
reading `map.bin` all now happen in a small fraction of a second of virtual
time, at a normal wall-clock cost.

**What's still genuinely missing, not a bug:** a DMA controller model.
Both `wio`'s LVGL flush path and `wio_walk`'s `pushImage()` (for tiles, not
the scalar `fillScreen`/`fillCircle` calls) go through `SPIClass::transfer`'s
DMA-driven bulk mode (`Adafruit_ZeroDMA`), which spins forever waiting on a
"job done" flag no DMA controller model ever sets. This is new scope,
distinct from (and smaller than) the ILI9341 peripheral P3 already
delivered, since Renode's own `sysbus` already provides DMA engine building
blocks used elsewhere; nobody has checked yet whether one of Renode's
existing DMAC models (e.g. for other Cortex-M SoCs) is close enough to
adapt. This -- not delay() cost -- is the real remaining blocker on the
original "render a real frame and compare it pixel-for-pixel" goal.

```sh
ruby scripts/export_nano7_map.rb --target wio \
  data/Nepheshel206beta/Nepheshel206Nbeta 1 /tmp/rpg2k_walk_out
scripts/wio_renode_sdcard.bash /tmp/wio_renode_sdcard \
  /tmp/rpg2k_walk_out/map.bin:/RPG2kWalk/map.bin \
  /tmp/rpg2k_walk_out/tiles.bin:/RPG2kWalk/tiles.bin
# after loading wio_terminal.repl, layer the card on top:
#   machine LoadPlatformDescription @/tmp/wio_renode_sdcard/sdcard.repl
```

**A genuine, unrelated Renode stability bug, found along the way and worth
knowing about separately:** a 30-virtual-second run (from before the two
fixes above, back when that much virtual time still seemed necessary) ran
for about 5 real minutes and crashed on `ConsoleIOSource.HandleInput()`
throwing an unhandled `SemaphoreFullException` -- an upstream bug in
Renode's own console/stdin-redirection handling on long-running headless
sessions with `< /dev/null`, reproducible but not investigated further
here. Long unattended runs should still account for this if they ever need
to run for real minutes rather than fractions of a second.

## Running it

Requires Renode itself (not a repo dependency -- nothing else here needs
it) **built from source**, not a release binary: `wio_terminal.repl` uses
`SPI.SAMD51_SERCOM_SPI` and `Video.ILI9341_SPI` (this repo's own
peripherals, since P3) for SERCOM6/7 unconditionally, which no release
binary has compiled in -- there is no plain-release-binary path for even a
P1/P2-style boot check any more.

```sh
scripts/wio_renode_build.bash   # needs git, cmake, a C/C++ toolchain (tlib's
                                 # native CPU cores) and the .NET 8 SDK
                                 # specifically -- not just the runtime a
                                 # release binary would bundle. A few minutes
                                 # the first time.

pio run -e wio_sd_upload   # or wio, or wio_walk
RENODE_BIN=/tmp/wio-renode-build/renode-src/renode \
  scripts/wio_renode_boot.bash .pio/build/wio_sd_upload/firmware.elf
```

Prints `=== REACHED setup() ===` / `=== REACHED loop() ===` when the
firmware's own symbols of those names are hit, and the CPU's PC after the
requested amount of *virtual* time. A genuine unstubbed spin loop (an
Arduino-core register read this platform does not model, most likely) shows
up as a wall-clock cost wildly out of proportion to the virtual time
requested, or as the exact same PC on every sample if you call
`scripts/wio_renode_boot.bash` more than once back to back.

## `app/wio/renode/peripherals/` -- the ILI9341 display model (P3)

Two new Renode peripherals, written for this platform since nothing
upstream models either (checked against the upstream C# source, not
assumed -- see ADR 94's peripheral-feasibility table):

- **`SPI/SAMD51_SERCOM_SPI.cs`**: a real SERCOM-in-SPI-mode controller.
  Replaces the four per-register `flipflop` stubs P2 used for SERCOM6/7
  (`CTRLA`/`INTFLAG`/`SYNCBUSY`/`DATA`) with one peripheral that answers
  those same polls correctly *by construction* -- always-ready once
  enabled, matching the "everything is instantaneous" model the rest of
  this platform already uses -- and, unlike a register stub, actually calls
  `Transmit()` on whatever `ISPIPeripheral` is registered on it via `@` in
  the `.repl`, delivering real bytes to a real device. Implements
  `IBytePeripheral` as well as `IDoubleWordPeripheral` (delegating to
  `ReadByteUsingDoubleWord`/`WriteByteUsingDoubleWord`) -- without that,
  every `ldrb` poll of `INTFLAG` live-locked; see the Status section above
  for the full story.
- **`Video/ILI9341_SPI.cs`**: the 320x240 panel itself. Scoped to exactly
  what this firmware's `TFT_eSPI` fork sends -- `CASET`/`PASET`/`RAMWR` are
  interpreted (including RAMWR's auto-increment addressing across many
  short SPI bursts, which is what lets a single command precede a whole
  `pushImage` tile grid); every other command byte (the ILI9341 init
  sequence, MADCTL, …) is consumed with no effect, since this is not a
  general ILI9341 model. Takes the D/C (data/command select) line as a
  numbered GPIO input (0) rather than part of the SPI byte stream, matching
  real 4-wire SPI TFT wiring -- wired in `wio_terminal.repl` from PORTC pin
  6 (`LCD_DC`, per the Wio Terminal Arduino variant). Exposes
  `SaveFramebufferPng(path)` as a Monitor command
  (`sercom7_spi.lcd SaveFramebufferPng "/path.png"` -- nested peripherals
  need their full dotted path in the Monitor, a bare `lcd` will not
  resolve).

`app/wio/renode/lcd_smoke_test.resc` is the regression test for the second
one: see its header comment for exact usage and expected pixel values.

## `app/wio/renode/patches/` -- one small upstream fix (P4)

`sdcard-acmd42.patch`: adds a harmless R1-ready response to upstream
`SD.SDCard` for `ACMD42` (`SET_CLR_CARD_DETECT`), which it does not
implement and `Seeed_Arduino_FS`'s driver sends unconditionally, treating
the correct "illegal command" response as fatal (see the Status section
above). `scripts/wio_renode_build.bash` applies it automatically
(`git apply`, against the `src/Infrastructure` submodule specifically,
since that is where `SDCard.cs` actually lives) -- nothing else needs to
know it exists.

Two more debugging pitfalls, found while chasing what turned out to be the
two bugs above:

- **`.repl` files do not support `$variable` substitution** -- that is a
  `.resc` (Monitor script) feature only; putting `$foo` in a `.repl` is a
  syntax error. This is why the SD card image (an inherently
  environment-specific path) is a *second*, separately-loaded `.repl`
  snippet (`scripts/wio_renode_sdcard.bash` generates one) rather than a
  variable inside `wio_terminal.repl` -- `machine LoadPlatformDescription`
  can be called more than once against the same machine to layer
  additional peripherals onto an already-loaded platform.
- **`cpu0 AddHook <addr> "..."` fires *before* the instruction at that
  address executes**, not after. Reading a register the instruction at
  that address is about to *write* (e.g. the destination of a `ldr`) gets
  you its previous, unrelated value, not the new one -- this looked exactly
  like memory corruption (a SERCOM object's internal hardware pointer
  reading back as a GPIO PORT address) until re-checked by reading the
  registers the instruction *reads from* instead (its arguments) rather
  than the one it's about to write.

## `wio_terminal.repl`

Starts from Renode's own bundled `platforms/cpus/atsamd51g19a.repl` (a bare
Cortex-M4F + one SERCOM UART, proven only against a *different* SAMD51
board's Zephyr shell) and adds the clock-tree and SERCOM stubs Arduino's own
`startup.c`/`wiring.c` need to get through `SystemInit()`/`init()` on *this*
board without spinning forever on a register nothing answers. Every stub in
the file has a comment naming the exact `startup.c` line and CMSIS register
it exists for -- read those before adding more; two things in there are not
obvious and cost real iteration time to find:

- **flipflop vs counter.** `scripts/pydev/flipflop.py` (ships with Renode)
  toggles a register between `0x00000000` and `0xFFFFFFFF` on every read,
  which satisfies a `while (reg & mask)`-style poll within at most two
  reads regardless of which bit the mask covers -- the right default for
  "make this register read as ready" stubs. `scripts/pydev/counter.py`
  increments by one on every read instead; use it only where two *different*
  bits of the *same register* must both read as set across two *separate*
  re-reads (`OSCCTRL->Dpll[n].DPLLSTATUS.bit.CLKRDY == 0 ||
  ...bit.LOCK == 0` compiles to exactly that) -- flipflop can never satisfy
  that pattern, since consecutive reads are always the complementary
  all-0/all-1 extreme, so the second bit is never set at the same moment as
  the first. This is a real trap, not a style choice: it produced a genuine
  infinite loop the first time this platform was built, and looks identical
  in the log to a plain missing stub.
- **One stub per register, not one per peripheral.** The same trap recurs
  at register granularity: `SERCOM::resetSPI()` writes `CTRLA`, polls
  `CTRLA`'s own self-clear bit, then polls the *separate* `SYNCBUSY`
  register for a bit at the same position. A single wide stub spanning both
  offsets shares one toggle state between them and live-locks exactly like
  the DPLLSTATUS case above, just one level up. Each SERCOM register this
  firmware's driver actually touches (`CTRLA`, `INTFLAG`, `SYNCBUSY`,
  `DATA`) gets its own independent `Python.PythonPeripheral` instance. The
  one exception that is safe to leave wide is `GCLK_PCHCTRL[0..47]`: each
  channel's poll only ever re-reads its own single address in a tight loop
  (write `CHEN`, re-read the same offset), so there is no cross-register
  correlation to break.
