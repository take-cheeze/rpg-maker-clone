# Wio Terminal under Renode

P1/P2 of [ADR 94](../../../docs/adr/0094-wio-terminal-renode-emulator.md): a
[Renode](https://renode.io) platform description that boots this repo's real
Wio Terminal firmware ELFs (`wio`, `wio_walk`, `wio_sd_upload`) far enough to
prove the CPU actually runs its own `setup()`/`loop()`, instead of only
compiling as CI's `wio` job does today.

## Status

**Verified, this platform:**

- All three firmware environments (`wio`, `wio_walk`, `wio_sd_upload`) reach
  their own `setup()`.
- `wio` (LVGL bring-up) and `wio_sd_upload` reach `loop()` and keep running
  it stably (sampled PC across repeated `RunFor` calls stays within the
  expected hot addresses, not stuck at one instruction).
- `wio_walk` reaches `setup()` and is legitimately busy inside
  `Seeed_Arduino_FS`'s own `sdWait()` retry loop when no real SD card is
  modelled -- a `millis()`-bounded timeout, not a hang, but slow enough
  (multiple real seconds per virtual second at that point) that this repo's
  session budget didn't run it to completion. Not evidence of a bug, just
  unconfirmed to the same depth as the other two.

**Known gap, found along the way:** `wio`'s LVGL flush path uses
`SPIClass::transfer`'s DMA-driven bulk mode (`Adafruit_ZeroDMA`), which
spins forever waiting on a "job done" flag no DMA controller model ever
sets, once `loop()` actually tries to push a frame. `wio_walk`'s
`SPI.transfer()` (single-byte, blocking, no DMA) does not hit this. A DMAC
peripheral is not modelled here -- it is new scope, distinct from (and
smaller than) the ADR 94 P3 ILI9341 peripheral, since Renode's own
`sysbus` already provides `IDoubleWordPeripheral`/DMA engine building
blocks used elsewhere; nobody has checked yet whether one of Renode's
existing DMAC models (e.g. for other Cortex-M SoCs) is close enough to
adapt.

**Not modelled at all yet (ADR 94 P3/P4):** the ILI9341/ST7789 display (no
framebuffer capture, so nothing to compare against a real screen) and the SD
card (no `.bin` files get read -- `wio_walk` will always report "no SD
card" here, matching real hardware with an empty slot).

## Running it

Requires Renode itself (not a repo dependency -- nothing else here needs
it): grab a `*-portable-dotnet.tar.gz`/`.zip` release from
[github.com/renode/renode/releases](https://github.com/renode/renode/releases)
(the portable-dotnet build needs no separate .NET install) and put `renode`
on `PATH`, or point `RENODE_BIN` at the binary.

```sh
pio run -e wio_sd_upload   # or wio, or wio_walk
scripts/wio_renode_boot.bash .pio/build/wio_sd_upload/firmware.elf
# a longer virtual-time budget for firmware that needs more of it to settle:
scripts/wio_renode_boot.bash .pio/build/wio_walk/firmware.elf "00:00:02"
```

Prints `=== REACHED setup() ===` / `=== REACHED loop() ===` when the
firmware's own symbols of those names are hit, and the CPU's PC after the
requested amount of *virtual* time. A genuine unstubbed spin loop (an
Arduino-core register read this platform does not model, most likely) shows
up as a wall-clock cost wildly out of proportion to the virtual time
requested, or as the exact same PC on every sample if you call
`scripts/wio_renode_boot.bash` more than once back to back.

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
