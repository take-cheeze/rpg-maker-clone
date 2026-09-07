# 94. A Renode emulator for the Wio Terminal port

Date: 2026-09-07

## Status

Proposed — P1 through P4 below are done and verified (see
`app/wio/renode/`), including all three firmware ELFs (`wio`, `wio_walk`,
`wio_sd_upload`) reaching their own `loop()` reliably and fast, with a real
SD card and ILI9341 display attached. What an earlier draft of this ADR
called a platform-wide `delay()`-bound performance limitation, found while
pursuing P4, turned out on investigation to be two specific, fixable bugs
(one in this repo's own `SAMD51_SERCOM_SPI` peripheral, one a missing
command in upstream `SD.SDCard`) — both now fixed; see the P4 entry, the
Consequences section below, and `app/wio/renode/README.md`'s "Two real bugs
found and fixed getting here, not a platform limitation" section for the
corrected account. P5's CI half is done
(`.github/workflows/build.yml`'s `wio-renode` job); its profiling half
(`machine EnableProfiler` around a real `draw_map()` call) is not started.
The one genuinely remaining gap is a DMA controller model, needed by both
`wio` and `wio_walk` to get past `pushImage`/LVGL-flush and render an actual
frame — see the DMAC row in the table below and P4's entry.

## Context

ADR 7 put the RPG2k runtime's HAL bring-up and the shared `wio_walk` map
engine (ADR 91) on real Wio Terminal hardware, and this project's first
confirmed run of either firmware on an actual board happened in the session
that also fixed `wio_walk`'s tile colours (see the changelog fragment
`wio-walk-first-hardware-run.fixed.md`). That session's colour bug is exactly
why an emulator is worth having: it was a SAMD51-specific quirk in
`TFT_eSPI::pushImage`'s bulk SPI transfer path, found only by flashing real
hardware three times and reading a physical screen between each attempt. CI
(`.github/workflows/build.yml`'s `wio` job) only compiles both firmware
environments — "this environment cannot cross-build or flash the board" is
stated outright in that job's own comment — so nothing catches a regression
here except a human with the board in hand. The ask this ADR answers: can we
get *some* of that feedback loop into CI/local dev without hardware, in
particular CPU-usage profiling of the render hot path (`draw_map` /
`rw_compose_cell` / `to565_push` / `pushImage`)?

**No off-the-shelf option covers this board.** Wokwi (the common
browser-based AVR/ESP32/STM32/RP2040 simulator) has no SAMD21/SAMD51 support
at all. [Renode](https://renode.io) (Antmicro's C#-based embedded simulator,
built for exactly this CI-without-hardware use case, with a scriptable
`.repl` platform-description format, a Robot Framework test harness, and a
built-in execution profiler — `machine EnableProfiler`, exercised by
`tests/unit-tests/profiler-trace.robot` upstream) is the closest fit, but as
shipped it only has a bare-bones `platforms/cpus/atsamd51g19a.repl`: a
Cortex-M4F core, one SERCOM UART, flash/RAM sized close to the Wio Terminal's
own budget, and three `Python.PythonPeripheral` register stubs to get a
*different* SAMD51 board (an Adafruit ItsyBitsy M4 running Zephyr) through
clock-tree bring-up. No Wio Terminal platform, no display, no SD, no buttons,
and Renode itself was not installed in this dev environment before P1 (it is
a standalone download, not a repo dependency — see `app/wio/renode/README.md`
for how to get it; nothing else here requires it).

**Peripheral-by-peripheral feasibility**, checked against the upstream
`renode/renode-infrastructure` source (not just documentation, since the
supported-boards list itself says it is incomplete):

| Peripheral | Upstream support | Verdict |
| --- | --- | --- |
| Cortex-M4F core, NVIC, flash/RAM | `platforms/cpus/atsamd51g19a.repl` | Reuse as a starting point |
| SERCOM UART | `UART.SAMD5_UART` | Reuse (already in the base platform) |
| SERCOM SPI | Nothing — `SPI.SAM_SPI` (`src/.../Peripherals/SPI/SAM_SPI.cs`) turned out to be the unrelated classic SAM4/SAME70 "SPI" peripheral (PDC DMA, write-protection registers, `SPI_SR`/`SPI_RDR`/`SPI_TDR`) — a different Atmel IP block, not SERCOM, register-for-register incompatible. **Verified wrong by reading the C# source before wiring it in**, not assumed; see below for what P2 actually used instead. | Genuinely nothing upstream models SERCOM at all, in any mode. |
| GPIO PORT (5-way switch, buttons, LCD D/C) | `GPIOPort.SAMD21_GPIO` (`src/.../Peripherals/GPIOPort/SAMD21_GPIO.cs`) | **Confirmed reusable as-is in P3**, for the LCD's D/C output pin specifically (PORTC.6) — instantiated directly at PORTC's SAMD51 base address with no changes needed. The 5-way switch/buttons (input pins, not yet exercised by any firmware's boot path up to `loop()`) remain unverified. |
| Clock tree (GCLK/OSCCTRL/MCLK) | Only the 3 stubs already in `atsamd51g19a.repl` (`gclk_phctrl1`, `pac_intflag`, `pac_status`) going in | **Confirmed in P1**: Arduino's `startup.c`/`wiring.c` need 9 register stubs total (the 3 above plus 6 more — see `app/wio/renode/wio_terminal.repl`), not an unbounded set. All 9 map to registers this repo's own read of the SAMD51 CMSIS headers named exactly, addressed from `startup.c`'s actual poll sites rather than guessed. |
| ILI9341/ST7789 SPI TFT display | Nothing upstream (confirmed: no `ILI9341`/`ST7789`/generic SPI-command-stream-to-framebuffer peripheral anywhere in `renode`/`renode-infrastructure`) | **Done in P3** — `Video.ILI9341_SPI` (`app/wio/renode/peripherals/Video/ILI9341_SPI.cs`), scoped to exactly `CASET`/`PASET`/`RAMWR` as planned. Verified correct directly, not just "it compiles": `app/wio/renode/lcd_smoke_test.resc` drives the registers by hand and the resulting PNG's pixels are exactly right (red/blue rows land in and stay bounded to the CASET/PASET window; ImageMagick-checked, see `app/wio/renode/README.md`). |
| SD card over SPI | **Wrong going in, corrected in P4**: this ADR originally said nothing upstream speaks SD's SPI-mode wire protocol, based on the class list and `SDCardExtensions.cs` alone. `SD.SDCard` itself, read directly, already has a `spiMode` constructor flag and a full `Transmit()`/SPI state machine (`WaitingForCommand`/`WaitingForArgBytes`/single- and multi-block read and write, R1 generation, the same command-byte bit-pattern check independently arrived at while first drafting a from-scratch replacement) — it is a general SD-over-SPI implementation, not SDIO-only. | **Nothing to write.** `SD.SDCard @ sercom6_spi` with `spiMode: true` is the whole of P4's peripheral half; `scripts/wio_renode_sdcard.bash` builds the FAT-formatted card image (`mkfs.vfat`/`mtools`) a real firmware's FAT driver needs to find files on. |
| DMA controller (DMAC) | Not checked yet | **Found in P2, not anticipated going in**: `wio`'s LVGL flush path uses `SPIClass::transfer`'s DMA-driven bulk mode (`Adafruit_ZeroDMA`), which spins forever on a "job done" flag nothing sets once a DMAC exists to set it. **Corrected in P4**: `wio_walk`'s tile rendering (`pushImage()`) goes through that exact same DMA-driven bulk path, not the single-byte blocking one this ADR originally assumed — disassembly confirms both firmwares' bulk transfers land in the same `SPIClass::transfer(const void*, void*, size_t, bool)` overload. Only `fillScreen`/`fillCircle` (scalar single-pixel calls) avoid DMA. Scope and upstream availability still unassessed — a P3-adjacent gap, smaller than the ILI9341 peripheral itself but not yet sized. |

The peripheral picture changed in both directions once actually checked
against source and tried against real firmware, not just read about: SPI
looked free (`SAM_SPI`) and turned out to need writing from scratch, while
the clock tree looked open-ended and turned out to be exactly 9 stubs. The
lesson generalises — this ADR's own remaining size estimates (P3/P4 below)
carry the same "unverified until attempted" caveat the clock tree did before
P1, and should be treated that way rather than as settled.

## Decision

Build the emulator in phases, each with its own exit criteria, the same
shape ADR 7 used for the port itself — because the honest answer, like ADR
7's, is that nobody knows yet exactly how far the clock-tree stubbing in
Phase 1 goes until it is attempted against Renode directly, and this ADR
should not promise more certainty than that.

- **P0 — this ADR.** No emulator code lands with it.
- **P1 — CPU boots, no peripherals beyond UART. Done.** Vendored under this
  repo as `app/wio/renode/wio_terminal.repl` (not upstreamed to Renode's own
  tree — this board is not something Renode itself would carry). Forked
  from `platforms/cpus/atsamd51g19a.repl`, adding 9 register stubs Arduino's
  `SystemInit()`/`init()` need to get through the clock tree without
  spinning forever (each documented in the `.repl` file against the exact
  `startup.c` line and CMSIS register name it answers). All three firmware
  ELFs (`wio`, `wio_walk`, `wio_sd_upload`) reach their own `setup()`
  symbol — the originally-planned exit criteria ("the emulated UART shows
  expected output") turned out to be the wrong check: this board's Arduino
  `Serial` is native USB CDC, not the SERCOM UART the base platform models
  (that would be `Serial1`), so a symbol-address hook
  (`cpu0 AddHook <setup_addr> ...`) is what `app/wio/renode/boot.resc`
  actually uses. See `app/wio/renode/README.md` for the two non-obvious
  pitfalls found getting here (`flipflop` vs `counter` stub choice; one stub
  per register, not per peripheral).
- **P2 — GPIO + SPI wired up, no display/SD content yet. Substantially
  done.** Planned to reuse `SAM_SPI` and an adapted `SAMD21_GPIO`; `SAM_SPI`
  turned out to be the wrong peripheral entirely (see the table above), so
  P2 used the same register-stub approach as P1 instead — four more
  per-register stubs per SERCOM instance (`CTRLA`, `INTFLAG`, `SYNCBUSY`,
  `DATA`), for both SERCOM6 (`SDCARD_SPI`) and SERCOM7 (`LCD_SPI`) per the
  Wio Terminal Arduino variant's actual pin mapping. Exit criteria met for
  `wio`: it reaches **and keeps stably running** `loop()` (PC sampled across
  repeated `RunFor` calls stays in the expected polling addresses, not
  wedged on one instruction) — the SPI writes this ADR asked P2 to confirm
  complete, complete. `wio_walk` reaches `setup()` and is legitimately busy
  in a `millis()`-bounded SD retry timeout rather than hung, but was not run
  long enough to confirm it reaches `loop()` too (real-time cost, not a
  correctness question). GPIO/`SAMD21_GPIO` was never reached — nothing in
  any of the three firmwares' boot path up to `loop()` touches the button
  pins yet (they are read from inside `loop()` itself, on the next poll
  after the one sampled). **Also found, not planned for:** `wio`'s LVGL
  flush path needs a DMA controller model (see the table above) that
  nothing here provides yet — `loop()` runs, but the first real frame flush
  will spin forever once it's actually exercised past the point this session
  sampled it.
- **P3 — the ILI9341 framebuffer peripheral. Done, with a scope
  adjustment.** The peripheral itself (`Video.ILI9341_SPI`) landed as
  planned and is verified correct directly (see the table above and
  `app/wio/renode/README.md`), plus `SPI.SAMD51_SERCOM_SPI` — a real
  SERCOM-in-SPI-mode controller, replacing P2's per-register `flipflop`
  stubs for SERCOM6/7 with something that answers those same polls
  correctly *by construction* and actually delivers bytes to an attached
  device, which turned out to be necessary before any real peripheral could
  receive anything at all (register stubs have no bus underneath them to
  attach a device to). Building either meant building Renode from source
  (`scripts/wio_renode_build.bash`, pinned commit
  `ab721d88e135a1bcb8ed2ecc5a38f51cbe61fdd2`) since release binaries are
  precompiled — this repo's own nix devshell already had every prerequisite
  (cmake, gcc/g++) except the .NET 8 **SDK** (the portable release only
  bundles the runtime), a straightforward extra install.
  **What did not land**: driving the peripheral from real firmware instead
  of by hand. See P4 below — attaching a real SD card did not turn out to
  be the last piece.
- **P4 — the SD-over-SPI peripheral. Half the work turned out to already
  exist; the other half was two real bugs, not a performance wall.**
  `SD.SDCard` already implements a full SD-over-SPI state machine
  (`spiMode: true`) — checked directly this time (reading `Transmit()`
  itself, not just the class list, which is exactly the mistake that missed
  `SAM_SPI`'s SPI mode... in the other direction: this ADR said *nothing*
  spoke SPI-mode SD, and something did). P4's actual new code is
  `scripts/wio_renode_sdcard.bash`, which builds a real FAT16-formatted disk
  image (`mkfs.vfat`/`mtools`) holding a real Nepheshel export and a `.repl`
  snippet wiring it onto `sercom6_spi`, layered onto the base platform with
  a second `LoadPlatformDescription` call (`.repl` files do not support
  `$variable` substitution the way `.resc` scripts do, so the image path —
  inherently environment-specific — cannot live in the committed
  `wio_terminal.repl`), plus `app/wio/renode/patches/sdcard-acmd42.patch`
  (see below).

  **What an earlier draft of this entry said here was wrong.** Attaching a
  real card did not reach `loop()` in up to 30 virtual seconds, and that was
  attributed to a platform-wide `delay()`-bound wall-clock cost (the theory
  that every SPI byte is "free" in virtual time, so `TFT_eSPI::init()`'s
  ~295 ms of unconditional `delay()` calls and `sdWait()`'s retry timeouts
  each cost disproportionate *real* time to simulate through). That
  diagnosis was inferred from how long booting took, not from reading what
  the CPU was actually stuck doing, and it was wrong: two specific, fixable
  bugs were the entire cause.

  1. **`SAMD51_SERCOM_SPI` was missing `IBytePeripheral`.** This repo's own
     SPI controller (P3) only implemented `IDoubleWordPeripheral`, but the
     Arduino SAMD core's `SERCOM.cpp` polls `INTFLAG` with an `ldrb` (byte
     access) for every single byte transferred. Renode does not
     auto-bridge a byte-sized CPU access to a DoubleWord-only peripheral —
     it silently returns 0 and logs "Attempted Byte read isn't supported by
     the peripheral" at `NOISY` level, easy to miss without deliberately
     raising log verbosity. The firmware's own SPI driver therefore spun
     forever waiting for a ready bit that could never arrive by that access
     path, even though the same register computed correctly via
     `sysbus ReadDoubleWord` (confirmed as a genuine live-lock, not merely
     slow: a silent Python counter in the hook showed 28,255 iterations in
     100 ms of virtual time). Fixed by adding
     `IBytePeripheral.ReadByte`/`WriteByte`, delegating to
     `ReadByteUsingDoubleWord`/`WriteByteUsingDoubleWord`
     (`Antmicro.Renode.Core.Extensions`) — the same pattern Renode's own
     `SEMA4.cs` and `SAMD21_GPIO.cs` use for the same reason.
  2. **Upstream `SD.SDCard` does not implement `ACMD42`.** After fix 1,
     `wio_walk` with a card attached still failed `SD.begin()`.
     `logLevel 1 sercom6_spi.sdcard` showed "Unsupported command: 42.
     Ignoring it" — `Seeed_Arduino_FS`'s driver sends `ACMD42`
     (`SET_CLR_CARD_DETECT`) unconditionally during init and treats the
     (correct, per the SD spec) illegal-command R1 response as fatal.
     Fixed via `app/wio/renode/patches/sdcard-acmd42.patch`, a small patch
     against upstream `SD.SDCard` adding a benign R1-ready response for
     `ACMD42` — mirroring how the same file already handles `CMD59`.
     Applied automatically by `scripts/wio_renode_build.bash`.

  With both fixed, all three firmware ELFs reach `loop()` reliably, in a
  small fraction of the wall-clock time the (wrong) delay-cost theory had
  implied, including `wio_walk` with a real SD card attached: it gets
  through `SD.begin()` and the backdrop `fillScreen()` call. The backdrop
  then renders the wrong solid colour — expected, not a new bug:
  `fillScreen()` uses `to565()`'s BGR-swapped encoding for the scalar path,
  while `ILI9341_SPI` (P3) was written to match `to565_push()`'s plain
  RGB565 encoding (the bulk/DMA path), and the emulator does not replicate
  the real hardware's specific dual-encoding quirk. See
  `app/wio/renode/README.md` for detail. The original exit criteria
  ("`wio_walk` … renders the same map this session walked") is still not
  met — not because of any remaining performance cost, but because of the
  DMAC gap (see the table above): both `wio`'s LVGL flush and `wio_walk`'s
  tile `pushImage()` calls need a DMA controller model neither firmware's
  boot path has been driven far enough to exercise yet.

  The unrelated Renode bug found while chasing the original (wrong)
  diagnosis — `ConsoleIOSource.HandleInput()` throwing an unhandled
  `SemaphoreFullException` on a long headless run with stdin redirected
  from `/dev/null` — remains a genuine upstream stability issue worth
  knowing about for long unattended runs, but is no longer load-bearing for
  this ADR now that both real firmwares boot in well under the time it took
  to hit it. See `app/wio/renode/README.md`.
- **P5 — profiling and CI wiring. CI half done; profiling not started.**
  The "does this run in GitHub Actions" question, deferred by this ADR's
  original Consequences section, is answered: `.github/workflows/build.yml`
  has a `wio-renode` job that builds Renode from source (cached on
  `app/wio/renode/peripherals/**`'s hash), boots all three firmware ELFs and
  asserts each reaches both `setup()` and `loop()`, re-runs
  `app/wio/renode/lcd_smoke_test.resc` and checks its output pixels with
  ImageMagick, and smoke-tests the SD card image tooling
  (`scripts/wio_renode_sdcard.bash`) — a plain shell job, not a Robot
  Framework test as originally sketched, since this repo's existing CI has
  no other Robot Framework jobs to fit alongside. Using `machine
  EnableProfiler` (or instruction-count tracing) around a real `draw_map()`
  call to get cycle/instruction numbers for the render hot path — this
  ADR's original motivating ask — is not started, and is blocked on the
  same DMAC gap P4 ran into: nothing here yet drives `draw_map()` far enough
  to profile it.

Each phase is independently useful and gate-able — P2 alone already answers
"does the firmware hang on this board's clock tree," which is a real
regression class distinct from the colour bug. Later phases are not blocked
on earlier ones being perfect, only booted.

## Consequences

- **Closes a real gap, mostly.** The ILI9341 model (P3) is built and
  verified correct against hand-driven register writes, and is now (P4)
  driven by real firmware far enough to prove a real SD card, a real FAT
  filesystem, and a real firmware SPI driver all work together up to an
  actual `fillScreen()` call — closing most of the distance to catching a
  `pushImage`-style colour regression the way this ADR was originally
  motivated by. What is left is the DMAC gap: neither `wio`'s LVGL flush
  nor `wio_walk`'s tile `pushImage()` calls can be exercised yet, so a
  regression in that specific bulk-transfer path — the one that actually
  caused this ADR's motivating bug — still is not caught. The
  platform-wide `delay()`-bound performance wall an earlier draft of this
  ADR described here does not exist: it was two specific, now-fixed bugs
  (see P4's entry above), not a property of the platform.
- **One new C# peripheral landed in P3, none needed in P4.**
  `SAMD51_SERCOM_SPI` and `ILI9341_SPI` (`app/wio/renode/peripherals/`) are
  new code in Renode's own codebase — a different language and build
  system than this repo's C++, built via `scripts/wio_renode_build.bash`
  against a pinned upstream commit rather than vendored into a fork.
  Whether they eventually go upstream (contributed to `renode/renode`) is
  still an open question; for now they live in this repo and get copied in
  at build time. P4 needed no new peripheral at all — `SD.SDCard` already
  had one — so this ADR's "two new C# peripherals" framing for the whole
  project turned out to overstate the real cost by half.
- **Does not replace real-hardware testing.** An emulator that models
  "correct" ILI9341/SPI behaviour would *not* have caught this session's bug
  on its own — the bug was this specific `TFT_eSPI` fork's SAMD51-only
  behaviour diverging from the textbook. `ILI9341_SPI` was deliberately
  written to what this firmware's *actual* wire protocol is (plain
  MSB-first RGB565, matching `to565_push`'s corrected output, not a naive
  read of the format) rather than "textbook ILI9341," precisely so it would
  reproduce the corrected, real-hardware-verified image — but that
  correspondence itself is still only reasoned about, not confirmed by
  actually rendering the same frame both ways and diffing them, since
  firmware-driven rendering is what's still blocked. That comparison
  remains the real bar, the same way ADR 7's P1 exit criteria demanded real
  `size` numbers instead of estimates.
- **Now runs in CI.** `.github/workflows/build.yml`'s `wio-renode` job
  builds Renode from source and boots all three firmware ELFs on every
  push, reversing this ADR's original "defer that decision" stance — once
  the two bugs in P4's entry above were fixed, a from-scratch Renode build
  (cached on the peripheral sources' hash) plus three boots plus the
  ILI9341/SD smoke tests added only a modest amount of CI time, not the
  open-ended cost the earlier delay()-cost theory would have implied.
- **Risk register:** the `delay()`-cost problem an earlier draft of this
  ADR listed here as the single biggest open risk to the whole platform did
  not materialise as described — it was misdiagnosed; the real cause was
  the two bugs fixed in P4's entry above, and both are now fixed. The DMAC
  gap (found in P2, confirmed in P4 to affect both firmwares, not just
  `wio`) is now the platform's real remaining risk: it blocks both this
  ADR's original motivating use case (catching a `pushImage` colour
  regression) and P5's profiling goal, and its scope is still unassessed.
  P2's own experience (SPI looked reusable and was not; the clock tree
  looked open-ended and was exactly 9 stubs; P4's SD-over-SPI looked like
  new code and needed none; and now, a performance wall that looked
  platform-wide and was two specific bugs) is a reminder that this ADR's
  own size and cause estimates keep being wrong, in both directions — treat
  any that remain (the DMAC gap chief among them) as unverified until
  attempted. This entire ADR's phases remain additive to, not a replacement
  for, testing on the real board this session used.
