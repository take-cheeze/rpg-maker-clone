# Wio Terminal under Renode

P1/P2/P3 of [ADR 94](../../../docs/adr/0094-wio-terminal-renode-emulator.md):
a [Renode](https://renode.io) platform that boots this repo's real Wio
Terminal firmware ELFs (`wio`, `wio_walk`, `wio_sd_upload`) far enough to
prove the CPU actually runs its own `setup()`/`loop()` -- instead of only
compiling, as CI's `wio` job does today -- and now a real ILI9341 SPI
display model behind it, so a frame can be captured as a PNG.

## Status

**Verified, this platform:**

- All three firmware environments (`wio`, `wio_walk`, `wio_sd_upload`) reach
  their own `setup()`.
- `wio` (LVGL bring-up) and `wio_sd_upload` reach `loop()` and keep running
  it stably (sampled PC across repeated `RunFor` calls stays within the
  expected hot addresses, not stuck at one instruction).
- `wio_walk` reaches `setup()` but, even with a real SD card attached (P4),
  takes far longer than expected to reach `loop()`. Confirmed genuinely not
  a hang -- `millis()`/SysTick was checked directly (`_ulTickCount` read
  back over successive `RunFor` calls increases monotonically) -- and the
  root cause is broader than SD specifically: this model runs every SPI
  transfer instantaneously with no per-byte clock-rate cost, so *any*
  `delay()`/`millis()`-bounded real-time wait anywhere in the firmware costs
  vastly more *emulated instructions* than the same wall-clock wait costs on
  real hardware (which spends most of that time idle, not executing).
  `TFT_eSPI::init()` alone has ~295 ms of unconditional `delay()` calls
  (reset pulse timing, post-reset settle) that run *before* `SD.begin()` is
  even reached, on top of whatever `Seeed_Arduino_FS`'s own `sdWait()` retry
  logic costs on top of that. Measured: a single ~500 ms real-time wait this
  way costs on the order of a minute of wall-clock time on the machine this
  was measured on. Not a correctness bug -- worth a cheaper fix (e.g. a
  virtual-time-aware `SPI.transfer()` cost, or a monitor-side time-warp past
  known delay loops) before relying on full-boot timing for anything. A
  30-virtual-second attempt (with a real SD card attached, P4) ran for
  about 5 real minutes and still had not reached `loop()` when it hit a
  second, *unrelated* problem: Renode's own `ConsoleIOSource.HandleInput()`
  crashed with an unhandled `SemaphoreFullException` (a genuine upstream
  bug in its console/stdin-redirection handling on long-running headless
  sessions with `< /dev/null`, not anything in this platform or firmware --
  reproducible, but not investigated further here). Long unattended runs
  should account for this: redirecting from `/dev/null` is not safe for
  multi-minute sessions today.
- **The ILI9341 display model is verified correct**, directly: **P3's own
  regression test**, `app/wio/renode/lcd_smoke_test.resc`, drives
  SERCOM7/LCD's registers by hand (enable, then a 16x1 CASET/PASET window,
  then 16 red pixels followed by 16 blue) with no firmware involved, and
  `lcd SaveFramebufferPng` dumps the result. Checked with ImageMagick:
  `{8,0}` reads `srgb(255,0,0)`, `{8,1}` reads `srgb(0,0,255)`, `{20,0}`
  (outside the CASET window) stays `srgb(0,0,0)` -- CASET/PASET windowing,
  RAMWR auto-increment addressing and RGB565→RGB24 decode are all correct.
  Driving it from real firmware instead of by hand is blocked on the same
  delay()-cost problem above (`wio`'s LVGL path is separately blocked on
  the DMAC gap below) -- the peripheral itself is not in question, only how
  expensive it is to reach through the firmware's own boot path.

**Known gap, found along the way:** `wio`'s LVGL flush path uses
`SPIClass::transfer`'s DMA-driven bulk mode (`Adafruit_ZeroDMA`), which
spins forever waiting on a "job done" flag no DMA controller model ever
sets, once `loop()` actually tries to push a frame. `wio_walk`'s
`SPI.transfer()` (single-byte, blocking, no DMA) does not hit this. A DMAC
peripheral is not modelled here -- it is new scope, distinct from (and
smaller than) the ILI9341 peripheral P3 already delivered, since Renode's
own `sysbus` already provides DMA engine building blocks used elsewhere;
nobody has checked yet whether one of Renode's existing DMAC models (e.g.
for other Cortex-M SoCs) is close enough to adapt.

**P4 (SD card): the peripheral half needed no new code, wiring it up did
not unblock the render path either.** `SD.SDCard` (upstream, unmodified)
already implements SD-over-SPI directly -- `spiMode: true` in its
constructor, checked by reading `Transmit()` itself this time, not just the
class list (which is exactly what missed it originally: `SDCardExtensions.cs`
and the class name suggested "block storage only", but the class itself
already has a full SPI front end). `scripts/wio_renode_sdcard.bash` builds a
real FAT16 image with a real Nepheshel export on it and a `.repl` snippet
wiring it onto `sercom6_spi`. Attaching it, though, did **not** turn out to
be the last piece: `wio_walk` still does not reach `loop()` in any budget
tried (up to 30 virtual seconds). Register-level inspection at the stuck
point (`cpu0 AddHook` reading `r0`/`r1` — not `r3`, which the instruction at
that address had not written yet; sampling it was a measurement mistake,
not evidence of memory corruption) shows genuine `SERCOM::transferDataSPI`
traffic on `sercom7` (LCD), not SD -- the bottleneck is `TFT_eSPI::init()`'s
own ~295 ms of `delay()` calls, which run *before* `SD.begin()` is ever
reached. See the delay()-cost note above: this is the same root cause,
just showing up somewhere new, and disproves the hope that a successful SD
init alone would route around it.

```sh
ruby scripts/export_nano7_map.rb --target wio \
  data/Nepheshel206beta/Nepheshel206Nbeta 1 /tmp/rpg2k_walk_out
scripts/wio_renode_sdcard.bash /tmp/wio_renode_sdcard \
  /tmp/rpg2k_walk_out/map.bin:/RPG2kWalk/map.bin \
  /tmp/rpg2k_walk_out/tiles.bin:/RPG2kWalk/tiles.bin
# after loading wio_terminal.repl, layer the card on top:
#   machine LoadPlatformDescription @/tmp/wio_renode_sdcard/sdcard.repl
```

## Running it

Requires Renode itself (not a repo dependency -- nothing else here needs
it). Two ways to get it, depending on whether you need the display model:

- **Boot-only (P1/P2), the release binary**: grab a
  `*-portable-dotnet.tar.gz`/`.zip` release from
  [github.com/renode/renode/releases](https://github.com/renode/renode/releases)
  (needs no separate .NET install) and put `renode` on `PATH`, or point
  `RENODE_BIN` at the binary.
- **With the ILI9341 display (P3)**: the release binary is precompiled and
  cannot pick up new peripherals -- `scripts/wio_renode_build.bash` clones
  Renode's source at the pinned commit this was built and verified against,
  drops in `app/wio/renode/peripherals/`, and builds it (needs `git`,
  `cmake`, a C/C++ toolchain for tlib's native CPU cores, and the **.NET 8
  SDK** specifically -- not just the runtime the portable release bundles).
  Takes a few minutes the first time.

```sh
pio run -e wio_sd_upload   # or wio, or wio_walk
scripts/wio_renode_boot.bash .pio/build/wio_sd_upload/firmware.elf
# a longer virtual-time budget for firmware that needs more of it to settle:
scripts/wio_renode_boot.bash .pio/build/wio_walk/firmware.elf "00:00:02"

# To use the built-from-source Renode (needed for the ILI9341 model):
scripts/wio_renode_build.bash
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
  the `.repl`, delivering real bytes to a real device.
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

Two more debugging pitfalls, found while chasing P4's boot-timing question:

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
