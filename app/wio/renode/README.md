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
- `wio_walk` reaches `setup()` and is legitimately busy inside
  `Seeed_Arduino_FS`'s own `sdWait()` retry loop when no real SD card is
  modelled. Confirmed genuinely not a hang -- `millis()`/SysTick was checked
  directly (`_ulTickCount` read back over successive `RunFor` calls
  increases monotonically) -- just expensive: this model runs every SPI
  transfer instantaneously with no per-byte clock-rate cost, so a
  `millis()`-bounded real-time timeout needs vastly more *emulated
  instructions* than the same wall-clock timeout costs on real hardware
  (which spends most of that time idle on the wire, not executing). Getting
  through a single ~500 ms retry timeout this way costs on the order of a
  minute of wall-clock time on the machine this was measured on; nobody has
  sat through the whole `SD.begin()` failure path to `loop()` yet. Not a
  correctness bug, and irrelevant once P4 attaches a real card (the success
  path doesn't hit these timeouts) -- but real, and worth a cheaper fix
  (e.g. a virtual-time-aware `SPI.transfer()` cost, or short-circuiting
  `sdWait` under emulation) before relying on this path for anything.
- **The ILI9341 display model is verified correct**, directly: **P3's own
  regression test**, `app/wio/renode/lcd_smoke_test.resc`, drives
  SERCOM7/LCD's registers by hand (enable, then a 16x1 CASET/PASET window,
  then 16 red pixels followed by 16 blue) with no firmware involved, and
  `lcd SaveFramebufferPng` dumps the result. Checked with ImageMagick:
  `{8,0}` reads `srgb(255,0,0)`, `{8,1}` reads `srgb(0,0,255)`, `{20,0}`
  (outside the CASET window) stays `srgb(0,0,0)` -- CASET/PASET windowing,
  RAMWR auto-increment addressing and RGB565→RGB24 decode are all correct.
  Driving it from real firmware instead of by hand is blocked on the same
  `wio_walk`/SD-timeout cost above (`wio`'s LVGL path is separately blocked
  on the DMAC gap below) -- the peripheral itself is not in question, only
  how expensive it is to reach through the firmware's own boot path.

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

**Not modelled yet (ADR 94 P4):** the SD card. Nothing is registered on
`sercom6_spi`, so `wio_walk` always reports "no SD card", matching real
hardware with an empty slot -- see `app/wio/renode/peripherals/` below for
what P3 already built that P4 can follow the shape of.

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
