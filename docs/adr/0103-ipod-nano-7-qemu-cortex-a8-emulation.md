# 103. QEMU Cortex-A8 emulation for the iPod nano 7G walk app

Date: 2026-09-08

## Status

Accepted, extended same-day: the "What this does and does not answer about
CPU cost" section prompted a follow-up question about QEMU's `-m 128M` --
an arbitrary figure bearing no relationship to any real limit. The **Memory
budget** section below (and `app/nano7/qemu/link.ld`) replaces it with
linker `MEMORY` regions sized against the one real NanoApps limit this app
is actually subject to, `-m` shrunk from 128 MiB to 4 MiB to match, and a
naming bug in the first draft of that change (a linker-script file-match
pattern silently not matching its object file, so the intended split
overflowed instead of separating cleanly) was caught by the overflow itself
demanding a fix, then confirmed fixed by checking the resulting section
sizes directly -- and confirmed for real, not just assumed working, by
deliberately linking a 600 KB oversized `.rodata` blob in and watching the
linker reject it with the expected region-overflow error.

## Context

ADR 102 built `app/nano7/host`: a host-side implementation of the
`hb_raw_surface`/`hb_sdk` API surface `rpg2k_walk.c` calls, letting that
device source file link and run as a native executable. It answers "does
this code render a real map correctly" without hardware, and does it well —
but it is native x86-on-host execution, not ARM emulation at all, so it has
nothing to say about CPU cost. Asked directly ("how much can you emulator
estimate actual device cpu costs?"), the honest answer was: not at all — no
instruction stream is being executed or timed, the host CPU's core, cache
hierarchy and clock have no fixed relationship to the device's, and the
device's actual expensive step (the MIPI/SPI push to the LCD) isn't modelled
at all, only a host memory-write loop standing in for it.

The follow-up ask was explicit: real QEMU- or Renode-level emulation, with
display support, and permission to skip whatever isn't in scope for that
goal. That changes the target. ADR 102's reasoning for *why not* emulate the
SoC still holds in one respect — this repo has no rights to and no interest
in reverse-engineering Apple's real S5L-family SoC or running its signed
retailOS — but the actual ask does not require either of those. It requires
running the *real compiled ARM instruction stream* (the same
`arm-none-eabi-gcc -mcpu=cortex-a8` build NanoApps' own `sdk/hb_app.mk`
produces) on a *real Cortex-A8 core model*, with *some* real display
peripheral behind it, and nothing else the real device's proprietary OS
would otherwise supply is actually needed for that.

**Checked directly, not assumed** (this repo's own `apt` mirror, verified by
installing and running each tool during this session):

- `qemu-system-arm` (Ubuntu 24.04's package, QEMU 8.2.2) ships a `cortex-a8`
  CPU model *and* a `realview-pb-a8` machine ("ARM RealView Platform
  Baseboard for Cortex-A8") — the exact core the real device uses, on a
  board QEMU already models with a real PL011 UART and a real PL110 Color
  LCD Controller (`qemu-system-arm -M realview-pb-a8 -cpu cortex-a8 ...`,
  `info mtree` in the QEMU monitor lists both, plus the machine's RAM at
  `0x70000000`–`0x77ffffff`). Unlike ADR 94's Wio Terminal work, which had to
  write two new C# peripherals from scratch (`SAMD51_SERCOM_SPI`,
  `ILI9341_SPI`) because Renode's upstream SAMD51 support was a bare CPU
  stub, **QEMU needed zero new peripheral code** here — the display and UART
  this ADR uses are QEMU's own, already-shipping models.
- A bare-metal ELF booted via `-kernel` reaches its own `main()` reliably:
  confirmed by booting a minimal "print over UART0" test image before any of
  this ADR's real code existed. QEMU starts the core in SVC mode, MMU and
  caches off, and jumps straight to the ELF's entry point — no bootloader,
  no vector table, no Linux-style boot protocol needed for a freestanding
  image that never enables interrupts.
- The PL110's real register layout (`TIM0`/`TIM1`'s `PPL`/`LPP`/margin
  fields, the `CNTL` register's `LcdBpp`/`LcdTFT`/`BGR`/`LcdPwr` bits, and
  the realview-specific `CNTL`/`IENB` offset swap) was read from upstream
  Linux's `include/linux/amba/clcd.h` and `drivers/video/amba-clcd.c`
  (`clcdfb_decode()`), not guessed — the same "read the real source" rule
  ADR 94 used for `SD.SDCard`. **Verified pixel-correct against QEMU's own
  `screendump`**, the same discipline as ADR 94's `lcd_smoke_test.resc`: a
  hand-drawn red/left, blue/right test pattern, written to a 32-bit XRGB
  buffer with the exact `HB_RGB` layout `hb_raw_surface.h` documents, showed
  up **colour-swapped** with the `CNTL` register's naive bit set — real
  hardware feedback, not an assumption — and setting `CNTL`'s `BGR` bit
  fixed it exactly, confirmed pixel-by-pixel via `screendump` a second time.
  With that one bit, the framebuffer format needs **zero per-pixel
  conversion** from `HB_RGB`'s own `0x00RRGGBB` layout — the same
  `hb_raw_fb()` array format ADR 102's host build already uses.
- The Cortex-A8 PMU's cycle counter (`PMCCNTR`, standard ARMv7-A CP15
  registers, not chip-specific) **is implemented and live** under QEMU's
  TCG: verified by timing three busy-loops of 1,000 / 10,000 / 100,000
  iterations before any of this ADR's real code existed and confirming the
  deltas scale with the loop count (roughly 9×–11× per 10× longer loop, not
  exactly linear — TCG's own block-compilation overhead, not a broken
  counter — but real, working, and repeatable), not a register that reads
  back zero.

No filesystem, no SD/MMC, no touch digitizer, no timer/RTC peripheral, and
no interrupts are modelled — all deliberately out of scope, per the "skip
features not in our interest" instruction this ADR was written under. None
of them are needed to answer the actual question.

## Decision

Build `app/nano7/qemu`: a from-scratch, minimal bare-metal image that boots
under `qemu-system-arm -M realview-pb-a8 -cpu cortex-a8` and links
`app/nano7/rpg2k_walk/rpg2k_walk.c` and
`app/shared/rpg2k_walk/rpg2k_walk_core.c` **completely unmodified**, cross-
compiled for the real target CPU — the same discipline ADR 102 used for the
host build, now with a real ARM instruction stream underneath it instead of
native host code.

- **`app/nano7/qemu/boot.S`** — the entire startup: set the stack pointer,
  call `main()`, loop forever if it returns. No vector table (nothing here
  ever unmasks an interrupt), no MMU/cache setup (QEMU already starts that
  way and this target never turns either on).
- **`app/nano7/qemu/link.ld`** — a flat image linked at `0x70010000`, inside
  the `realview-pb-a8` machine's RAM bank, with a 256 KiB stack past `.bss`.
  No load address games: this target is the only thing in the address
  space.
- **`app/nano7/qemu/nano7_qemu_shim.c`** — the bare-metal platform half:
  - `hb_fs_read` matches the path suffix ("map.bin" / "tiles.bin" — the only
    two paths `rpg2k_walk.c` ever reads) against two binary blobs **linked
    directly into the image** (`scripts/nano7_qemu_build.bash`'s
    `arm-none-eabi-objcopy -I binary` step, producing
    `_binary_map_bin_start`/`_end` symbols this file declares `extern`).
    There is no SD card or filesystem here at all — a deliberately skipped
    feature, not a gap: the app's own file-reading logic is already covered
    by both the host build and the `walk_core` ctest, so nothing new would
    be verified by also emulating SD/FAT here.
  - `hb_time_uptime_ms` is a harness-advanced counter, exactly ADR 102's
    headless-mode convention (20 ms per call) — no RTC/timer peripheral
    wired up, on purpose, for the same reason.
  - PL011 UART0 (`0x10009000`) is this file's **own** debug/log channel only
    — the app never calls anything UART-shaped.
  - PL110 CLCD (`0x10020000`) is programmed once at startup, pointed at
    `hb_raw_fb()`'s own array (its address taken at runtime, not
    hard-coded), 24bpp/TFT/BGR per the verified register layout above.
  - The Cortex-A8 PMU's cycle counter is enabled once, and `main()` reads it
    around `hb_raw_init()` and every `hb_raw_frame()` call across a 60-tick
    synthetic run (a held "move down" touch starting a few frames in, the
    same script ADR 102's headless host mode runs), logging each delta over
    UART.
- **`app/nano7/shim_common/hb_fb_ops.c`** — pulled out of ADR 102's host
  shim in this same change: the framebuffer array and the six `hb_raw_*`
  pixel primitives plus `hb_draw_str`'s placeholder glyphs are identical
  logic between the host and QEMU builds (neither touches a file, a clock,
  or a register), so they are now one file both link, instead of two copies
  that could quietly drift apart and undermine either build's claim to
  reproduce the same rendering. `app/nano7/host/nano7_host_shim.c` now holds
  only what is genuinely host-specific: `hb_fs_read` over `stdio`,
  `hb_time_uptime_ms` over `SDL_GetTicks`, and the SDL window/BMP harness.
- **`scripts/nano7_qemu_build.bash`** — stages an exported map as
  `map.bin`/`tiles.bin` (fixed names, since `objcopy`'s generated symbol
  names are derived from the exact filename given), cross-compiles every
  source above with `-mcpu=cortex-a8` (linking `libgcc` for the software
  divide routines this core has no hardware instruction for — the same
  reason NanoApps' own `sdk/hb_app.mk` links it), and links the flat image.
- **`scripts/nano7_qemu_run.bash`** — boots the image with its UART
  redirected to a log file and a QMP control socket, waits for the shim's
  own `"NANO7-QEMU done"` marker to appear in that log, issues a
  `screendump` (QEMU's monitor command that reads the *real* PL110-addressed
  framebuffer memory, not a synthetic capture), and quits — no `-display`,
  no `Xvfb`, needed at all; this runs entirely headless because the guest
  itself never needs a real display attached, only the address range a real
  one would scan out from.
- **`scripts/nano7_qemu_smoke_check.rb`** — a plain-Ruby PPM reader (QEMU's
  `screendump` format), the same non-flat-fill census check as
  `nano7_host_smoke_check.rb`'s BMP reader, plus (informational, not
  asserted on) a print of the UART log's per-frame cycle counts: min / max /
  average across the run, explicitly labelled as a QEMU-TCG comparative
  signal rather than hardware nanoseconds.
- **CI**: a new `nano7-qemu` job (`.github/workflows/build.yml`), parallel to
  `wio-renode`, installing `gcc-arm-none-eabi` and `qemu-system-arm` (both
  plain `apt` packages — no from-source build, unlike `wio-renode`'s pinned
  Renode build), exporting a real Nepheshel map, building, booting, and
  running the pixel + cycle-count check on every push.

## What this does and does not answer about CPU cost

Directly answering the question this ADR exists for: this **does** run the
real ARM instruction stream (the actual `arm-none-eabi-gcc -mcpu=cortex-a8`
output, not a native host build) through a real Cortex-A8 core model, so the
cycle counts it reports reflect the *real compiled code's* control flow, the
real absence of a hardware integer divide, and this specific core's
instruction set — none of which the host build in ADR 102 could speak to at
all. Comparing these numbers before and after a change to
`rw_compose_cell`/`draw_map`/the touch-direction math is a real, meaningful
regression signal now, in a way it simply was not before this ADR.

What it still is **not**: a promise that a given cycle count is how long the
real device takes, in real time. Concretely:

- QEMU's TCG does not claim cycle-accurate timing even for CPU-only
  instructions — the busy-loop scaling check above (roughly 9×–11× per 10×
  more iterations, not exactly 10×) shows real, working counts, not a
  fiction, but also shows they are not a precision instrument.
- **The real device's actual expensive step — the framebuffer push over
  MIPI/SPI (this app's `hb_raw_blit`) — is not modelled as a timed transfer
  at all here.** This target's PL110 reads directly from plain RAM with no
  bus contention or transfer latency simulated; a real device's touch
  digitizer, OS compositor and physical panel refresh are not present
  either. The CPU-side compositing cost this ADR measures is real; the
  device's *total* per-frame cost is CPU-side compositing plus that
  transfer, and only the first half is covered.
- No cache/TLB/branch-predictor timing model is claimed to match real
  Cortex-A8 silicon; QEMU's TCG cortex-a8 CPU model executes the correct
  instructions in the correct order, not necessarily in the same number of
  real cycles a physical part would take for the same stream.

This is the same honest scope Renode's own profiler carries for the Wio
Terminal (ADR 94's P5: `machine EnableProfiler` was aimed at exactly this
kind of comparative signal, not literal hardware nanoseconds, and never got
that far there — blocked on the DMAC gap). This ADR's harness reaches
further than that one did, precisely because it never needed a DMA
controller at all: `hb_raw_blit` is a plain CPU-store loop in this app, not
a DMA-driven bulk transfer the way Wio's `pushImage` is.

## Memory budget: which real limit, and which one isn't real

QEMU's `-m` originally read `128M` — comfortably enough to run in, and
completely arbitrary. Asked to size it against the app's actual NanoApps
limit instead, the first thing worth getting right is *which* limit that
is, because the codebase already has an answer that turns out not to apply
here.

`app/nano7/rpg2k_walk`'s `Makefile` sets `RAW_SURFACE := 1`, which NanoApps'
own `sdk/hb_app.mk` turns into `RELOC := 1`: **"the resident loads a
`.hbapp` into an operator-new arena"** (that file's own comment on the
`RELOC` block). That is a different loading path from the fixed
`BSS_VA`/`LINK_VA` scheme (`0x09200000`/`0x09280000`) — that scheme is
`LV_SURFACE`-specific, per `hb_app.mk`'s own comment on it: parking `.bss`
there is so an LVGL app **coexisting with the live compositor** doesn't
stomp its heap, a concern that doesn't apply to a `RELOC` app running
standalone. `rpg2k_walk.c`'s own `MAP_MAX_W`/`MAP_MAX_H`/`MAX_TILES` comment
already cites that 512 KiB gap as its `.bss` budget, and already hedges
that "that gap is not documented as a hard per-app `.bss` ceiling" — this
ADR can now say why: it's the wrong app kind's limit, carried over as a
conservative guess. ADR 61 is explicit about what a `RELOC` app's real
constraint is instead: **"the 500 KB ceiling is specifically the
relocatable app blob"** — code plus the reloc table `mkrelocapp.py` emits
from it — while "a large runtime data set is free; only the code has to be
tiny." `.bss` isn't the number that was ever actually measured to matter.

`app/nano7/qemu/link.ld` now encodes that distinction with named `MEMORY`
regions instead of one blanket figure:

| Region | Size | What | Real NanoApps limit? |
| --- | --- | --- | --- |
| `image` | 500 KiB | `.text` + `.rodata` | **Yes** — the packed-`.hbapp` ceiling ADR 61 measured apps crashing past |
| `blobs` | 128 KiB | the two exported map files, linked in directly (no filesystem here at all) | No — on real hardware these are read from disk at runtime, not part of the uploaded blob at all |
| `app_bss` | 512 KiB | `rpg2k_walk.c`'s and `rpg2k_walk_core.c`'s own static buffers | No, per ADR 61 above — kept anyway because it's what the app was actually engineered against, now enforced instead of an unchecked comment |
| `shadow_fb` | 405 KiB | `hb_fb_ops.c`'s framebuffer array | No — on real hardware this is the resident's own OS-composited buffer (`hb_raw_surface.h`: "hands us the OS-composited framebuffer"), not something the app allocates at all |
| `stack` | 256 KiB | this harness's own stack | No — undocumented where a `RELOC` app's stack actually comes from |

Only `image` is a real, verified NanoApps limit; the other four are this
harness's own bookkeeping, kept in separate regions specifically so a
generously-sized convenience (`blobs`, `shadow_fb`, `stack`) can never
silently absorb headroom that should have been checked against a real one,
and so `app_bss`'s own (unverified-for-this-app-kind, but intentionally
kept) budget can't be masked by `shadow_fb` sharing its region — which is
exactly what happened building this: the first cut put the framebuffer in
`app_bss` by mistake (a linker-script file-match pattern targeting the
wrong object filename), and the resulting overflow read as "the app is 10 KB
over its real budget" when the app itself was nowhere close — a wrong
verdict a shared, unlabelled region would have kept giving. Separating them
by *what each byte count would mean on real hardware*, not just by which
`.c` file it comes from, is what makes the `image` region's pass/fail
actually mean something.

Total span from `ORIGIN(image)`: 1,844,224 B (~1.76 MiB). `-m` is `4M` —
sized to that with headroom, not the original `128M`, and confirmed booting
correctly at that size. This is not itself a NanoApps limit (QEMU's
`realview-pb-a8` RAM bank has nothing to do with the real device's address
space at all) — it just stops the harness from being handed two orders of
magnitude more RAM than anything here could plausibly use, which was the
actual complaint about `128M`.

**Verified, not assumed**: deliberately linking an extra ~600 KB `.rodata`
blob into a scratch build reproduces the exact failure mode the real
`image` limit exists to catch — `ld` refuses with `region 'image'
overflowed by 109684 bytes` — confirming the enforcement is real and not
just a MEMORY block that happens to compile.

## Consequences

- **A second, complementary tier alongside ADR 102**, not a replacement for
  it: the host build (fast, no cross toolchain, good for correctness/logic
  regressions and interactive use) and this QEMU build (slower, needs
  `arm-none-eabi-gcc` + `qemu-system-arm`, gives a real-ISA cycle signal and
  exercises the real cross-compiled binary rather than a native host one)
  answer different questions, and both link the same unmodified
  `rpg2k_walk.c`.
- **Refactor lands with it**: `app/nano7/shim_common/hb_fb_ops.c` is now
  shared, which also *simplified* ADR 102's own host shim (removed, not
  added, code there) rather than only adding new surface area.
- **A real, new CI failure mode**: a future change that grows
  `rpg2k_walk.c`/`rpg2k_walk_core.c`'s compiled code past the 500 KiB
  `image` region now fails the link step outright, catching the one thing
  ADR 61 says actually breaks on real hardware ("apps hang or crash on
  launch" past that ceiling) before it would ever reach a jailbroken
  device. The other four regions (`blobs`/`app_bss`/`shadow_fb`/`stack`)
  exist to keep that one check honest, not to police limits of their own —
  see the memory-budget section above for why none of them are real
  NanoApps ceilings.
- **Still not real-hardware verification.** Neither this nor ADR 102
  replaces the real jailbroken-device session ADR 61 documents. A quirk in
  the real NanoApps resident, the real OS compositor, or the real touch
  digitizer is invisible to both; this ADR closes the *CPU cost* gap
  specifically, which neither prior harness could address at all.
- **No filesystem/SD/touch/RTC modelled, on purpose.** A future need to
  exercise `hb_fs_read`'s error path against a real SD/FAT stack, or real
  touch-driven input rather than a scripted walk, would need new scope this
  ADR deliberately did not build — consistent with "skip features not in
  our interest," not an oversight.
- **CI cost**: `apt`-installable packages only (`gcc-arm-none-eabi`,
  `qemu-system-arm`), no from-source build and no pinned-commit cache the
  way `wio-renode` needs for its patched Renode — cheaper to keep running
  than that job, and does not (unlike `wio-renode`'s DMAC gap) hit a wall
  short of its own motivating goal.
